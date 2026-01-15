// Application state management (Phase 1: Todo tracking for master loop)
const std = @import("std");
const mem = std.mem;
const fs = std.fs;

/// Normalize a path for consistent comparison.
/// Uses realpath for existing files, manual normalization for new files.
fn normalizePath(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    // Try realpath first (handles symlinks, ./, ../, etc.)
    return fs.cwd().realpathAlloc(allocator, path) catch |err| {
        if (err == error.FileNotFound) {
            // File doesn't exist - do manual normalization
            return manualNormalize(allocator, path);
        }
        return err;
    };
}

/// Manual path normalization for non-existent files.
/// Returns an ABSOLUTE path by joining cwd with the normalized relative path.
/// Handles: leading ./, redundant //, embedded . and .. components.
fn manualNormalize(allocator: mem.Allocator, path: []const u8) ![]const u8 {
    // Handle empty path
    if (path.len == 0) {
        return fs.cwd().realpathAlloc(allocator, ".");
    }

    // Get current working directory (absolute)
    const cwd = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    // Collect path components, resolving . and ..
    var components = std.ArrayListUnmanaged([]const u8){};
    defer components.deinit(allocator);

    // Start with cwd components
    var cwd_iter = mem.splitScalar(u8, cwd, '/');
    while (cwd_iter.next()) |comp| {
        if (comp.len > 0) {
            try components.append(allocator, comp);
        }
    }

    // Process input path components
    var path_iter = mem.splitScalar(u8, path, '/');
    while (path_iter.next()) |comp| {
        if (comp.len == 0 or mem.eql(u8, comp, ".")) {
            // Skip empty components and "."
            continue;
        } else if (mem.eql(u8, comp, "..")) {
            // Go up one directory (but don't go above root)
            if (components.items.len > 0) {
                _ = components.pop();
            }
        } else {
            try components.append(allocator, comp);
        }
    }

    // Build absolute path
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (components.items) |comp| {
        try result.append(allocator, '/');
        try result.appendSlice(allocator, comp);
    }

    // Handle root case
    if (result.items.len == 0) {
        try result.append(allocator, '/');
    }

    return result.toOwnedSlice(allocator);
}

/// Todo status enum for tracking progress
pub const TodoStatus = enum { pending, in_progress, completed };

/// Individual todo with ID, content, and status
pub const Todo = struct {
    id: []const u8, // String ID like "todo_1", "todo_2", etc.
    content: []const u8,
    status: TodoStatus,
};

/// Pending file to be indexed by Graph RAG
pub const PendingIndexFile = struct {
    path: []const u8, // owned
    content: []const u8, // owned
};

/// Session-ephemeral application state
pub const AppState = struct {
    allocator: mem.Allocator,
    todos: std.ArrayListUnmanaged(Todo),
    next_todo_id: usize,
    session_start: i64,
    iteration_count: usize,
    read_files: std.StringHashMapUnmanaged(void), // Track files read in this session
    indexed_files: std.StringHashMapUnmanaged(void), // Track files indexed in Graph RAG
    pending_index_files: std.ArrayListUnmanaged(PendingIndexFile), // Queue for background indexing

    pub fn init(allocator: mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .todos = .{},
            .next_todo_id = 1,
            .session_start = std.time.milliTimestamp(),
            .iteration_count = 0,
            .read_files = .{},
            .indexed_files = .{},
            .pending_index_files = .{},
        };
    }

    pub fn addTodo(self: *AppState, content: []const u8) ![]const u8 {
        // Generate string ID like "todo_1", "todo_2", etc.
        const todo_id = try std.fmt.allocPrint(self.allocator, "todo_{d}", .{self.next_todo_id});
        errdefer self.allocator.free(todo_id);

        self.next_todo_id += 1;

        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.todos.append(self.allocator, .{
            .id = todo_id,
            .content = owned_content,
            .status = .pending,
        });

        return todo_id;
    }

    pub fn updateTodo(self: *AppState, todo_id: []const u8, new_status: TodoStatus) !void {
        for (self.todos.items) |*todo| {
            if (mem.eql(u8, todo.id, todo_id)) {
                todo.status = new_status;
                return;
            }
        }
        return error.TodoNotFound;
    }

    pub fn getTodos(self: *AppState) []const Todo {
        return self.todos.items;
    }

    pub fn markFileAsRead(self: *AppState, path: []const u8) !void {
        // Normalize path for consistent comparison
        const normalized = try normalizePath(self.allocator, path);
        errdefer self.allocator.free(normalized);

        // Check if already tracked
        if (self.read_files.contains(normalized)) {
            self.allocator.free(normalized);
            return;
        }

        try self.read_files.put(self.allocator, normalized, {});
    }

    pub fn wasFileRead(self: *AppState, path: []const u8) bool {
        // Normalize path for consistent comparison
        const normalized = normalizePath(self.allocator, path) catch return false;
        defer self.allocator.free(normalized);
        return self.read_files.contains(normalized);
    }

    pub fn markFileAsIndexed(self: *AppState, path: []const u8) !void {
        // Check if already indexed to avoid duplicate allocations
        if (self.indexed_files.contains(path)) {
            return; // Already indexed
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.indexed_files.put(self.allocator, owned_path, {});
    }

    pub fn wasFileIndexed(self: *AppState, path: []const u8) bool {
        return self.indexed_files.contains(path);
    }

    /// Queue a file for background Graph RAG indexing
    pub fn queueFileForIndexing(self: *AppState, path: []const u8, content: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.pending_index_files.append(self.allocator, .{
            .path = owned_path,
            .content = owned_content,
        });
    }

    /// Check if there are files pending indexing
    pub fn hasPendingIndexing(self: *AppState) bool {
        return self.pending_index_files.items.len > 0;
    }

    /// Pop the next pending file from the indexing queue
    /// Returns null if queue is empty
    /// Caller owns returned memory and must free path and content
    pub fn popPendingIndexFile(self: *AppState) ?PendingIndexFile {
        if (self.pending_index_files.items.len == 0) return null;
        return self.pending_index_files.orderedRemove(0);
    }

    pub fn deinit(self: *AppState) void {
        for (self.todos.items) |todo| {
            self.allocator.free(todo.id);
            self.allocator.free(todo.content);
        }
        self.todos.deinit(self.allocator);

        // Free read_files hashmap
        var iter = self.read_files.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.read_files.deinit(self.allocator);

        // Free indexed_files hashmap
        var indexed_iter = self.indexed_files.keyIterator();
        while (indexed_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.indexed_files.deinit(self.allocator);

        // Free pending index files queue
        for (self.pending_index_files.items) |pending| {
            self.allocator.free(pending.path);
            self.allocator.free(pending.content);
        }
        self.pending_index_files.deinit(self.allocator);
    }
};
