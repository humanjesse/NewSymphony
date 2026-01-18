// Task Store - Beads-inspired agent task memory system
// Provides dependency-aware task tracking with ready queue optimization
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// 8-character hex ID from SHA256 hash
pub const TaskId = [8]u8;

/// Task status enum
pub const TaskStatus = enum {
    pending, // Not started
    in_progress, // Currently being worked on
    completed, // Done
    blocked, // Waiting on dependencies
    cancelled, // Abandoned

    pub fn fromString(str: []const u8) ?TaskStatus {
        const map = std.StaticStringMap(TaskStatus).initComptime(.{
            .{ "pending", .pending },
            .{ "in_progress", .in_progress },
            .{ "completed", .completed },
            .{ "blocked", .blocked },
            .{ "cancelled", .cancelled },
        });
        return map.get(str);
    }

    pub fn toString(self: TaskStatus) []const u8 {
        return @tagName(self);
    }
};

/// Task priority (0 = highest)
pub const TaskPriority = enum(u8) {
    critical = 0, // P0 - Do immediately
    high = 1, // P1 - Do soon
    medium = 2, // P2 - Normal (default)
    low = 3, // P3 - Backlog
    wishlist = 4, // P4 - Maybe someday

    pub fn fromInt(val: u8) TaskPriority {
        return switch (val) {
            0 => .critical,
            1 => .high,
            2 => .medium,
            3 => .low,
            else => .wishlist,
        };
    }

    pub fn toInt(self: TaskPriority) u8 {
        return @intFromEnum(self);
    }
};

/// Task type classification
pub const TaskType = enum {
    task, // Single action item (default)
    bug, // Fix something broken
    feature, // New capability
    research, // Investigation/exploration
    wisp, // Ephemeral (auto-deletes, in-memory only)
    molecule, // Epic container with children

    pub fn fromString(str: []const u8) ?TaskType {
        const map = std.StaticStringMap(TaskType).initComptime(.{
            .{ "task", .task },
            .{ "bug", .bug },
            .{ "feature", .feature },
            .{ "research", .research },
            .{ "wisp", .wisp },
            .{ "molecule", .molecule },
        });
        return map.get(str);
    }

    pub fn toString(self: TaskType) []const u8 {
        return @tagName(self);
    }
};

/// A comment on a task (append-only audit trail - Beads philosophy)
pub const Comment = struct {
    agent: []const u8, // Which agent made the comment (owned)
    content: []const u8, // The message content (owned)
    timestamp: i64, // When the comment was made

    pub fn deinit(self: *Comment, allocator: Allocator) void {
        allocator.free(self.agent);
        allocator.free(self.content);
    }
};

/// Dependency type between tasks
pub const DependencyType = enum {
    blocks, // Hard dependency - blocked task cannot start
    parent, // Hierarchical - child belongs to parent
    related, // Soft reference - no execution impact
    discovered, // Provenance - where task came from

    pub fn fromString(str: []const u8) ?DependencyType {
        const map = std.StaticStringMap(DependencyType).initComptime(.{
            .{ "blocks", .blocks },
            .{ "parent", .parent },
            .{ "related", .related },
            .{ "discovered", .discovered },
        });
        return map.get(str);
    }

    pub fn toString(self: DependencyType) []const u8 {
        return @tagName(self);
    }

    pub fn isBlocking(self: DependencyType) bool {
        return self == .blocks;
    }
};

/// A dependency edge between two tasks
pub const Dependency = struct {
    src_id: TaskId, // Source task
    dst_id: TaskId, // Destination task
    dep_type: DependencyType, // Relationship type
    weight: f32 = 1.0, // Semantic weight (reserved for future)
};

/// Individual task with all metadata
pub const Task = struct {
    id: TaskId,
    title: []const u8, // Owned
    description: ?[]const u8, // Owned, optional
    status: TaskStatus,
    priority: TaskPriority,
    task_type: TaskType,
    labels: [][]const u8, // Owned array of owned strings
    created_at: i64,
    updated_at: i64,
    completed_at: ?i64,
    parent_id: ?TaskId, // For molecules (epics)
    blocked_by_count: usize, // Cached count of blocking dependencies
    comments: []Comment = &.{}, // Append-only audit trail (Beads philosophy)

    /// Free all owned memory
    pub fn deinit(self: *Task, allocator: Allocator) void {
        allocator.free(self.title);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        for (self.labels) |label| {
            allocator.free(label);
        }
        allocator.free(self.labels);
        // Free comments (Beads audit trail)
        for (self.comments) |*comment| {
            var c = comment.*;
            c.deinit(allocator);
        }
        if (self.comments.len > 0) {
            allocator.free(self.comments);
        }
    }
};

/// Parameters for creating a new task
pub const CreateTaskParams = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    priority: TaskPriority = .medium,
    task_type: TaskType = .task,
    labels: ?[]const []const u8 = null,
    parent_id: ?TaskId = null,
    blocks: ?[]const TaskId = null, // Tasks this new task will block
};

/// Result of completing a task
pub const CompleteResult = struct {
    task_id: TaskId,
    unblocked: []TaskId, // Tasks that became unblocked
};

/// Query filters for listing tasks
pub const TaskFilter = struct {
    status: ?TaskStatus = null,
    priority: ?TaskPriority = null,
    task_type: ?TaskType = null,
    parent_id: ?TaskId = null,
    ready_only: bool = false, // Only tasks with blocked_by_count == 0
    label: ?[]const u8 = null,
};

/// Session state for cold start recovery and current task tracking
pub const SessionState = struct {
    session_id: []const u8, // Format: {timestamp}-{random_hex} e.g. "1705312345-a3f8"
    current_task_id: ?TaskId = null,
    started_at: i64,
    notes: ?[]const u8 = null, // Session notes for handoff

    pub fn deinit(self: *SessionState, allocator: Allocator) void {
        allocator.free(self.session_id);
        if (self.notes) |n| allocator.free(n);
    }
};

/// Generate a unique session ID: {timestamp}-{random_hex}
pub fn generateSessionId(allocator: Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();

    // Generate 4 random hex chars
    var random_bytes: [2]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const hex_chars = "0123456789abcdef";
    var random_hex: [4]u8 = undefined;
    random_hex[0] = hex_chars[random_bytes[0] >> 4];
    random_hex[1] = hex_chars[random_bytes[0] & 0x0f];
    random_hex[2] = hex_chars[random_bytes[1] >> 4];
    random_hex[3] = hex_chars[random_bytes[1] & 0x0f];

    return std.fmt.allocPrint(allocator, "{d}-{s}", .{ timestamp, random_hex });
}

/// Task store - in-memory storage with dependency graph
pub const TaskStore = struct {
    allocator: Allocator,
    tasks: std.AutoHashMap(TaskId, Task),
    dependencies: std.ArrayListUnmanaged(Dependency),
    ready_cache_valid: bool,
    ready_cache: std.ArrayListUnmanaged(TaskId),

    // Session state for current task tracking
    current_task_id: ?TaskId = null,
    session_id: ?[]const u8 = null,
    session_started_at: ?i64 = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = std.AutoHashMap(TaskId, Task).init(allocator),
            .dependencies = .{},
            .ready_cache_valid = false,
            .ready_cache = .{},
            .current_task_id = null,
            .session_id = null,
            .session_started_at = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all tasks
        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            var t = task.*;
            t.deinit(self.allocator);
        }
        self.tasks.deinit();
        self.dependencies.deinit(self.allocator);
        self.ready_cache.deinit(self.allocator);

        // Free session state
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
    }

    /// Initialize a new session with a unique ID
    pub fn startSession(self: *Self) !void {
        // Clean up old session if any
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }
        self.session_id = try generateSessionId(self.allocator);
        self.session_started_at = std.time.timestamp();
        self.current_task_id = null;
    }

    /// Restore session state from cold start
    pub fn restoreSession(self: *Self, session_id: []const u8, current_task_id: ?TaskId, started_at: i64) !void {
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }
        self.session_id = try self.allocator.dupe(u8, session_id);
        self.session_started_at = started_at;
        self.current_task_id = current_task_id;
    }

    /// Set the current task explicitly (for start_task)
    pub fn setCurrentTask(self: *Self, task_id: TaskId) !void {
        // Verify task exists
        if (!self.tasks.contains(task_id)) {
            return error.TaskNotFound;
        }

        self.current_task_id = task_id;

        // Update task status to in_progress if pending
        if (self.tasks.getPtr(task_id)) |task| {
            if (task.status == .pending) {
                task.status = .in_progress;
                task.updated_at = std.time.timestamp();
            }
        }
    }

    /// Get the current task, auto-assigning from ready queue if none set
    /// Returns null if no tasks are ready
    pub fn getCurrentTask(self: *Self) !?*Task {
        // If we have a current task, return it
        if (self.current_task_id) |cid| {
            if (self.tasks.getPtr(cid)) |task| {
                // Only return if task is still workable
                if (task.status == .in_progress or task.status == .pending) {
                    return task;
                }
            }
            // Current task is no longer valid, clear it
            self.current_task_id = null;
        }

        // Auto-assign from ready queue
        const ready = try self.getReadyTasks();
        defer self.allocator.free(ready);

        if (ready.len > 0) {
            // Pick highest priority (already sorted)
            const task_id = ready[0].id;
            self.current_task_id = task_id;

            // Mark as in_progress
            if (self.tasks.getPtr(task_id)) |task| {
                task.status = .in_progress;
                task.updated_at = std.time.timestamp();
                self.ready_cache_valid = false;
                return task;
            }
        }

        return null;
    }

    /// Clear the current task (called before auto-advance)
    pub fn clearCurrentTask(self: *Self) void {
        self.current_task_id = null;
    }

    /// Get current task ID without auto-assignment
    pub fn getCurrentTaskId(self: *Self) ?TaskId {
        return self.current_task_id;
    }

    /// Generate a hash-based task ID from title and timestamp
    pub fn generateId(title: []const u8, timestamp: i64) TaskId {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(title);
        hasher.update(mem.asBytes(&timestamp));
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        var id: TaskId = undefined;
        const hex_chars = "0123456789abcdef";
        for (0..4) |i| {
            id[i * 2] = hex_chars[hash[i] >> 4];
            id[i * 2 + 1] = hex_chars[hash[i] & 0x0f];
        }
        return id;
    }

    /// Create a new task
    pub fn createTask(self: *Self, params: CreateTaskParams) !TaskId {
        const now = std.time.timestamp();
        const id = generateId(params.title, now);

        // Check for ID collision (very rare)
        if (self.tasks.contains(id)) {
            return error.TaskIdCollision;
        }

        // Clone title
        const title = try self.allocator.dupe(u8, params.title);
        errdefer self.allocator.free(title);

        // Clone description if present
        const description = if (params.description) |desc|
            try self.allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |d| self.allocator.free(d);

        // Clone labels
        const labels: [][]const u8 = if (params.labels) |lbls| blk: {
            const cloned = try self.allocator.alloc([]const u8, lbls.len);
            errdefer self.allocator.free(cloned);
            var i: usize = 0;
            errdefer {
                for (cloned[0..i]) |l| self.allocator.free(l);
            }
            for (lbls) |lbl| {
                cloned[i] = try self.allocator.dupe(u8, lbl);
                i += 1;
            }
            break :blk cloned;
        } else try self.allocator.alloc([]const u8, 0);

        const task = Task{
            .id = id,
            .title = title,
            .description = description,
            .status = .pending,
            .priority = params.priority,
            .task_type = params.task_type,
            .labels = labels,
            .created_at = now,
            .updated_at = now,
            .completed_at = null,
            .parent_id = params.parent_id,
            .blocked_by_count = 0,
        };

        try self.tasks.put(id, task);

        // Add blocking dependencies if specified
        if (params.blocks) |blocked_ids| {
            for (blocked_ids) |blocked_id| {
                try self.addDependency(id, blocked_id, .blocks);
            }
        }

        // Invalidate ready cache
        self.ready_cache_valid = false;

        return id;
    }

    /// Get a task by ID
    pub fn getTask(self: *Self, task_id: TaskId) ?*Task {
        return self.tasks.getPtr(task_id);
    }

    /// Update a task's status
    pub fn updateStatus(self: *Self, task_id: TaskId, new_status: TaskStatus) !void {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        task.status = new_status;
        task.updated_at = std.time.timestamp();

        if (new_status == .completed) {
            task.completed_at = task.updated_at;
        }

        self.ready_cache_valid = false;
    }

    /// Update task priority
    pub fn updatePriority(self: *Self, task_id: TaskId, new_priority: TaskPriority) !void {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        task.priority = new_priority;
        task.updated_at = std.time.timestamp();
    }

    /// Update task title
    pub fn updateTitle(self: *Self, task_id: TaskId, new_title: []const u8) !void {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        self.allocator.free(task.title);
        task.title = try self.allocator.dupe(u8, new_title);
        task.updated_at = std.time.timestamp();
        self.ready_cache_valid = false;
    }

    /// Update task type (cannot change to/from wisp)
    pub fn updateTaskType(self: *Self, task_id: TaskId, new_type: TaskType) !void {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;
        // Wisps are immutable - cannot change to or from wisp
        if (task.task_type == .wisp or new_type == .wisp) {
            return error.CannotChangeWispType;
        }
        task.task_type = new_type;
        task.updated_at = std.time.timestamp();
        self.ready_cache_valid = false;
    }

    /// Add a comment to a task (Beads philosophy - append-only audit trail)
    pub fn addComment(self: *Self, task_id: TaskId, agent: []const u8, content: []const u8) !void {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;

        // Create new comment
        const new_comment = Comment{
            .agent = try self.allocator.dupe(u8, agent),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
        };

        // Grow comments array
        const old_comments = task.comments;
        const new_comments = try self.allocator.alloc(Comment, old_comments.len + 1);
        @memcpy(new_comments[0..old_comments.len], old_comments);
        new_comments[old_comments.len] = new_comment;

        // Free old array if it was allocated (not the default empty slice)
        if (old_comments.len > 0) {
            self.allocator.free(old_comments);
        }

        task.comments = new_comments;
        task.updated_at = std.time.timestamp();
    }

    /// Get the last comment from a specific agent (useful for checking latest feedback)
    pub fn getLastCommentFrom(self: *Self, task_id: TaskId, agent: []const u8) ?*const Comment {
        const task = self.tasks.get(task_id) orelse return null;

        // Iterate backwards to find most recent
        var i = task.comments.len;
        while (i > 0) {
            i -= 1;
            if (mem.eql(u8, task.comments[i].agent, agent)) {
                return &task.comments[i];
            }
        }
        return null;
    }

    /// Get tasks that have comments containing a specific prefix (e.g., "BLOCKED:", "REJECTED:")
    /// Used by orchestration to find tasks needing attention
    pub fn getTasksWithCommentPrefix(self: *Self, prefix: []const u8) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            // Check if any comment starts with prefix
            for (task.comments) |comment| {
                if (mem.startsWith(u8, comment.content, prefix)) {
                    try result.append(self.allocator, task.*);
                    break; // Only add task once
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Count comments from a specific agent with a prefix (e.g., count rejections)
    pub fn countCommentsWithPrefix(self: *Self, task_id: TaskId, agent: []const u8, prefix: []const u8) usize {
        const task = self.tasks.get(task_id) orelse return 0;

        var match_count: usize = 0;
        for (task.comments) |comment| {
            if (mem.eql(u8, comment.agent, agent) and mem.startsWith(u8, comment.content, prefix)) {
                match_count += 1;
            }
        }
        return match_count;
    }

    /// Add a dependency between tasks
    pub fn addDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        // Verify both tasks exist
        if (!self.tasks.contains(src_id)) return error.SourceTaskNotFound;
        if (!self.tasks.contains(dst_id)) return error.DestTaskNotFound;

        // Prevent self-dependency
        if (mem.eql(u8, &src_id, &dst_id)) return error.SelfDependency;

        // Check for duplicate
        for (self.dependencies.items) |dep| {
            if (mem.eql(u8, &dep.src_id, &src_id) and
                mem.eql(u8, &dep.dst_id, &dst_id) and
                dep.dep_type == dep_type)
            {
                return error.DependencyExists;
            }
        }

        // Check for circular dependency (simple check - src -> dst -> src)
        if (dep_type.isBlocking()) {
            for (self.dependencies.items) |dep| {
                if (dep.dep_type.isBlocking() and
                    mem.eql(u8, &dep.src_id, &dst_id) and
                    mem.eql(u8, &dep.dst_id, &src_id))
                {
                    return error.CircularDependency;
                }
            }
        }

        try self.dependencies.append(self.allocator, .{
            .src_id = src_id,
            .dst_id = dst_id,
            .dep_type = dep_type,
        });

        // Update blocked_by_count if blocking dependency
        if (dep_type.isBlocking()) {
            if (self.tasks.getPtr(dst_id)) |dst_task| {
                dst_task.blocked_by_count += 1;
                if (dst_task.status == .pending) {
                    dst_task.status = .blocked;
                }
            }
        }

        self.ready_cache_valid = false;
    }

    /// Remove a dependency
    pub fn removeDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        var found_idx: ?usize = null;

        for (self.dependencies.items, 0..) |dep, i| {
            if (mem.eql(u8, &dep.src_id, &src_id) and
                mem.eql(u8, &dep.dst_id, &dst_id) and
                dep.dep_type == dep_type)
            {
                found_idx = i;
                break;
            }
        }

        if (found_idx) |idx| {
            const dep = self.dependencies.orderedRemove(idx);

            // Update blocked_by_count if was blocking
            if (dep.dep_type.isBlocking()) {
                if (self.tasks.getPtr(dst_id)) |dst_task| {
                    if (dst_task.blocked_by_count > 0) {
                        dst_task.blocked_by_count -= 1;
                    }
                    // Update status if now unblocked
                    if (dst_task.blocked_by_count == 0 and dst_task.status == .blocked) {
                        dst_task.status = .pending;
                    }
                }
            }

            self.ready_cache_valid = false;
        } else {
            return error.DependencyNotFound;
        }
    }

    /// Complete a task and cascade to dependents
    /// If this was the current task, clears it (call getCurrentTask for auto-advance)
    pub fn completeTask(self: *Self, task_id: TaskId) !CompleteResult {
        const task = self.tasks.getPtr(task_id) orelse return error.TaskNotFound;

        task.status = .completed;
        task.completed_at = std.time.timestamp();
        task.updated_at = task.completed_at.?;

        // Clear current task if we just completed it
        if (self.current_task_id) |cid| {
            if (mem.eql(u8, &cid, &task_id)) {
                self.current_task_id = null;
            }
        }

        // Find all tasks blocked by this one
        var unblocked = std.ArrayListUnmanaged(TaskId){};
        errdefer unblocked.deinit(self.allocator);

        // Remove blocking dependencies where this task is the source
        var i: usize = 0;
        while (i < self.dependencies.items.len) {
            const dep = self.dependencies.items[i];
            if (mem.eql(u8, &dep.src_id, &task_id) and dep.dep_type.isBlocking()) {
                // Decrement blocked count on destination
                if (self.tasks.getPtr(dep.dst_id)) |dst_task| {
                    if (dst_task.blocked_by_count > 0) {
                        dst_task.blocked_by_count -= 1;
                    }
                    // If now unblocked, update status and track it
                    if (dst_task.blocked_by_count == 0 and dst_task.status == .blocked) {
                        dst_task.status = .pending;
                        try unblocked.append(self.allocator, dep.dst_id);
                    }
                }
                _ = self.dependencies.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        self.ready_cache_valid = false;

        return .{
            .task_id = task_id,
            .unblocked = try unblocked.toOwnedSlice(self.allocator),
        };
    }

    /// Get tasks matching filter criteria
    pub fn listTasks(self: *Self, filter: TaskFilter) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            // Apply filters
            if (filter.status) |s| {
                if (task.status != s) continue;
            }
            if (filter.priority) |p| {
                if (task.priority != p) continue;
            }
            if (filter.task_type) |t| {
                if (task.task_type != t) continue;
            }
            if (filter.parent_id) |pid| {
                if (task.parent_id == null or !mem.eql(u8, &task.parent_id.?, &pid)) continue;
            }
            if (filter.ready_only) {
                if (task.blocked_by_count > 0 or task.status == .blocked) continue;
                if (task.status != .pending) continue;
            }
            if (filter.label) |lbl| {
                var found = false;
                for (task.labels) |task_lbl| {
                    if (mem.eql(u8, task_lbl, lbl)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            try result.append(self.allocator, task.*);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get the current in_progress task (if any)
    pub fn getCurrentInProgressTask(self: *Self) ?*Task {
        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            if (task.status == .in_progress) {
                return task;
            }
        }
        return null;
    }

    /// Get all ready tasks (pending with no blockers), sorted by priority
    pub fn getReadyTasks(self: *Self) ![]Task {
        // Rebuild cache if invalid
        if (!self.ready_cache_valid) {
            self.ready_cache.clearRetainingCapacity();

            var iter = self.tasks.valueIterator();
            while (iter.next()) |task| {
                if (task.status == .pending and
                    task.blocked_by_count == 0 and
                    task.task_type != .molecule)
                {
                    try self.ready_cache.append(self.allocator, task.id);
                }
            }

            self.ready_cache_valid = true;
        }

        // Build result array
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        for (self.ready_cache.items) |id| {
            if (self.tasks.get(id)) |task| {
                try result.append(self.allocator, task);
            }
        }

        // Sort by priority (lower = higher priority)
        mem.sort(Task, result.items, {}, struct {
            fn lessThan(_: void, a: Task, b: Task) bool {
                return a.priority.toInt() < b.priority.toInt();
            }
        }.lessThan);

        return result.toOwnedSlice(self.allocator);
    }

    /// Get count of tasks by status
    pub const TaskCounts = struct {
        pending: usize = 0,
        in_progress: usize = 0,
        completed: usize = 0,
        blocked: usize = 0,
    };

    pub fn getTaskCounts(self: *Self) TaskCounts {
        var counts = TaskCounts{};

        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            switch (task.status) {
                .pending => counts.pending += 1,
                .in_progress => counts.in_progress += 1,
                .completed => counts.completed += 1,
                .blocked => counts.blocked += 1,
                .cancelled => {},
            }
        }

        return counts;
    }

    /// Get children of a molecule/epic
    pub fn getChildren(self: *Self, parent_id: TaskId) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            if (task.parent_id) |pid| {
                if (mem.eql(u8, &pid, &parent_id)) {
                    try result.append(self.allocator, task.*);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get total task count
    pub fn count(self: *Self) usize {
        return self.tasks.count();
    }

    /// Format task ID as string (returns pointer to static memory in TaskId)
    pub fn formatId(id: TaskId) []const u8 {
        return &id;
    }

    /// Parse task ID from string
    pub fn parseId(str: []const u8) !TaskId {
        if (str.len != 8) return error.InvalidTaskId;
        var id: TaskId = undefined;
        @memcpy(&id, str[0..8]);
        return id;
    }

    /// Get siblings (tasks with the same parent)
    pub fn getSiblings(self: *Self, task_id: TaskId) ![]Task {
        const task = self.tasks.get(task_id) orelse return error.TaskNotFound;
        const parent_id = task.parent_id orelse return self.allocator.alloc(Task, 0);

        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        var iter = self.tasks.valueIterator();
        while (iter.next()) |t| {
            if (t.parent_id) |pid| {
                if (mem.eql(u8, &pid, &parent_id) and !mem.eql(u8, &t.id, &task_id)) {
                    try result.append(self.allocator, t.*);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get tasks that block a given task
    pub fn getBlockedBy(self: *Self, task_id: TaskId) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        for (self.dependencies.items) |dep| {
            if (mem.eql(u8, &dep.dst_id, &task_id) and dep.dep_type.isBlocking()) {
                if (self.tasks.get(dep.src_id)) |t| {
                    try result.append(self.allocator, t);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get tasks that are blocked by a given task
    pub fn getBlocking(self: *Self, task_id: TaskId) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        for (self.dependencies.items) |dep| {
            if (mem.eql(u8, &dep.src_id, &task_id) and dep.dep_type.isBlocking()) {
                if (self.tasks.get(dep.dst_id)) |t| {
                    try result.append(self.allocator, t);
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Traverse the dependency graph using BFS
    /// Returns all reachable tasks up to max_depth
    pub fn traverseDependencies(self: *Self, start_id: TaskId, max_depth: usize, edge_type: ?[]const u8) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        var visited = std.AutoHashMap(TaskId, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayListUnmanaged(struct { id: TaskId, depth: usize }){};
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, .{ .id = start_id, .depth = 0 });
        try visited.put(start_id, {});

        if (self.tasks.get(start_id)) |t| {
            try result.append(self.allocator, t.*);
        }

        var idx: usize = 0;
        while (idx < queue.items.len) : (idx += 1) {
            const current = queue.items[idx];
            if (current.depth >= max_depth) continue;

            for (self.dependencies.items) |dep| {
                const neighbor_id = if (mem.eql(u8, &dep.src_id, &current.id))
                    dep.dst_id
                else if (mem.eql(u8, &dep.dst_id, &current.id))
                    dep.src_id
                else
                    continue;

                // Filter by edge type if specified
                if (edge_type) |et| {
                    if (!mem.eql(u8, dep.dep_type.toString(), et)) continue;
                }

                if (!visited.contains(neighbor_id)) {
                    try visited.put(neighbor_id, {});
                    try queue.append(self.allocator, .{ .id = neighbor_id, .depth = current.depth + 1 });
                    if (self.tasks.get(neighbor_id)) |t| {
                        try result.append(self.allocator, t.*);
                    }
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get epic/molecule summary - aggregates child task counts
    pub const EpicSummary = struct {
        task: Task,
        total_children: usize,
        completed_children: usize,
        blocked_children: usize,
        in_progress_children: usize,
        completion_percent: u8,
    };

    pub fn getEpicSummary(self: *Self, epic_id: TaskId) !?EpicSummary {
        const epic = self.tasks.get(epic_id) orelse return null;

        if (epic.task_type != .molecule) {
            return EpicSummary{
                .task = epic,
                .total_children = 0,
                .completed_children = 0,
                .blocked_children = 0,
                .in_progress_children = 0,
                .completion_percent = 0,
            };
        }

        const children = try self.getChildren(epic_id);
        defer self.allocator.free(children);

        var completed: usize = 0;
        var blocked: usize = 0;
        var in_progress: usize = 0;

        for (children) |child| {
            switch (child.status) {
                .completed => completed += 1,
                .blocked => blocked += 1,
                .in_progress => in_progress += 1,
                else => {},
            }
        }

        const total = children.len;
        const pct: u8 = if (total > 0) @intCast((completed * 100) / total) else 0;

        return EpicSummary{
            .task = epic,
            .total_children = total,
            .completed_children = completed,
            .blocked_children = blocked,
            .in_progress_children = in_progress,
            .completion_percent = pct,
        };
    }

    /// Get open tasks at a given depth from root
    pub fn getOpenAtDepth(self: *Self, max_depth: usize) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer result.deinit(self.allocator);

        // Find root tasks (no parent)
        var roots = std.ArrayListUnmanaged(TaskId){};
        defer roots.deinit(self.allocator);

        var iter = self.tasks.valueIterator();
        while (iter.next()) |task| {
            if (task.parent_id == null and task.task_type == .molecule) {
                try roots.append(self.allocator, task.id);
            }
        }

        // BFS from roots to find open tasks at depth
        var visited = std.AutoHashMap(TaskId, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayListUnmanaged(struct { id: TaskId, depth: usize }){};
        defer queue.deinit(self.allocator);

        for (roots.items) |root_id| {
            try queue.append(self.allocator, .{ .id = root_id, .depth = 0 });
            try visited.put(root_id, {});
        }

        var idx: usize = 0;
        while (idx < queue.items.len) : (idx += 1) {
            const current = queue.items[idx];

            if (current.depth <= max_depth) {
                if (self.tasks.get(current.id)) |task| {
                    if (task.status == .pending or task.status == .in_progress) {
                        if (task.task_type != .molecule or current.depth == max_depth) {
                            try result.append(self.allocator, task);
                        }
                    }
                }
            }

            if (current.depth < max_depth) {
                // Get children
                const children = try self.getChildren(current.id);
                defer self.allocator.free(children);

                for (children) |child| {
                    if (!visited.contains(child.id)) {
                        try visited.put(child.id, {});
                        try queue.append(self.allocator, .{ .id = child.id, .depth = current.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

// Tests
test "TaskStore basic operations" {
    const allocator = std.testing.allocator;

    var store = TaskStore.init(allocator);
    defer store.deinit();

    // Create a task
    const id = try store.createTask(.{ .title = "Test task" });
    try std.testing.expect(store.count() == 1);

    // Get task
    const task = store.getTask(id);
    try std.testing.expect(task != null);
    try std.testing.expectEqualStrings("Test task", task.?.title);
    try std.testing.expect(task.?.status == .pending);
}

test "TaskStore dependencies" {
    const allocator = std.testing.allocator;

    var store = TaskStore.init(allocator);
    defer store.deinit();

    const task1 = try store.createTask(.{ .title = "Task 1" });
    const task2 = try store.createTask(.{ .title = "Task 2" });

    // Add blocking dependency: task1 blocks task2
    try store.addDependency(task1, task2, .blocks);

    // task2 should be blocked
    const t2 = store.getTask(task2);
    try std.testing.expect(t2.?.blocked_by_count == 1);
    try std.testing.expect(t2.?.status == .blocked);

    // Complete task1
    const result = try store.completeTask(task1);
    defer allocator.free(result.unblocked);

    // task2 should be unblocked
    const t2_after = store.getTask(task2);
    try std.testing.expect(t2_after.?.blocked_by_count == 0);
    try std.testing.expect(t2_after.?.status == .pending);
    try std.testing.expect(result.unblocked.len == 1);
}

test "TaskStore ready query" {
    const allocator = std.testing.allocator;

    var store = TaskStore.init(allocator);
    defer store.deinit();

    _ = try store.createTask(.{ .title = "Ready task", .priority = .high });
    const blocker = try store.createTask(.{ .title = "Blocker" });
    const blocked = try store.createTask(.{ .title = "Blocked task" });

    try store.addDependency(blocker, blocked, .blocks);

    const ready = try store.getReadyTasks();
    defer allocator.free(ready);

    // Should have 2 ready tasks (not the blocked one)
    try std.testing.expect(ready.len == 2);
}
