// Task Database - SQLite persistence for task memory system
const std = @import("std");
const sqlite = @import("sqlite");
const task_store = @import("task_store");

const Allocator = std.mem.Allocator;
const Task = task_store.Task;
const TaskId = task_store.TaskId;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;
const Dependency = task_store.Dependency;
const DependencyType = task_store.DependencyType;
const Comment = task_store.Comment;

pub const TaskDB = struct {
    db: *sqlite.Db,
    allocator: Allocator,
    transaction_depth: u32 = 0, // Track nested transaction depth for savepoint management
    transaction_mutex: std.Thread.Mutex = .{}, // Protects transaction_depth and transaction operations

    const Self = @This();

    /// Initialize database connection and create schema if needed
    pub fn init(allocator: Allocator, db_path: []const u8) !Self {
        const db = try sqlite.open(
            db_path,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        );
        errdefer sqlite.close(db);

        var self = Self{
            .db = db,
            .allocator = allocator,
        };

        // Enable WAL mode for better concurrency
        try sqlite.exec(db, "PRAGMA journal_mode=WAL");

        // Enable foreign keys
        try sqlite.exec(db, "PRAGMA foreign_keys=ON");

        // Create schema
        try self.createSchema();

        return self;
    }

    pub fn deinit(self: *Self) void {
        sqlite.close(self.db);
    }

    /// Create database schema (calls base tables + migrations)
    fn createSchema(self: *Self) !void {
        try self.createBaseTables();
        try self.runMigrations();
    }

    /// Create base tables and indexes (safe to run always with IF NOT EXISTS)
    fn createBaseTables(self: *Self) !void {
        // Tasks table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\    id TEXT PRIMARY KEY,
            \\    title TEXT NOT NULL,
            \\    description TEXT,
            \\    status TEXT NOT NULL,
            \\    priority INTEGER NOT NULL,
            \\    task_type TEXT NOT NULL,
            \\    labels TEXT,
            \\    created_at INTEGER NOT NULL,
            \\    updated_at INTEGER NOT NULL,
            \\    completed_at INTEGER,
            \\    parent_id TEXT,
            \\    metadata TEXT,
            \\    FOREIGN KEY (parent_id) REFERENCES tasks(id) ON DELETE SET NULL
            \\)
        );

        // Dependencies table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS task_dependencies (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    src_id TEXT NOT NULL,
            \\    dst_id TEXT NOT NULL,
            \\    dep_type TEXT NOT NULL,
            \\    weight REAL DEFAULT 1.0,
            \\    created_at INTEGER NOT NULL,
            \\    FOREIGN KEY (src_id) REFERENCES tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (dst_id) REFERENCES tasks(id) ON DELETE CASCADE,
            \\    UNIQUE(src_id, dst_id, dep_type)
            \\)
        );

        // Comments table (Beads audit trail)
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS task_comments (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    task_id TEXT NOT NULL,
            \\    agent TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    timestamp INTEGER NOT NULL,
            \\    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
            \\)
        );

        // Indexes
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority, status)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_deps_src ON task_dependencies(src_id)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_deps_dst ON task_dependencies(dst_id)
        );

        // Metadata table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS task_db_metadata (
            \\    key TEXT PRIMARY KEY,
            \\    value TEXT NOT NULL
            \\)
        );
    }

    /// Run version-gated migrations
    fn runMigrations(self: *Self) !void {
        // Get current schema version (default to 0 for new databases)
        const version_str = try self.getMetadata("schema_version");
        defer if (version_str) |v| self.allocator.free(v);

        const current_version: u32 = if (version_str) |v|
            std.fmt.parseInt(u32, v, 10) catch 0
        else
            0;

        // Migration v0 -> v1: Initial schema (handled by createBaseTables)
        if (current_version < 1) {
            try self.setMetadata("schema_version", "1");
        }

        // Migration v1 -> v2: Add blocked_reason column
        if (current_version < 2) {
            try sqlite.exec(self.db, "ALTER TABLE tasks ADD COLUMN blocked_reason TEXT");
            try self.setMetadata("schema_version", "2");
        }

        // Migration v2 -> v3: Session state table and commit tracking
        if (current_version < 3) {
            // Add session_state table for cold-start recovery
            try sqlite.exec(self.db,
                \\CREATE TABLE IF NOT EXISTS session_state (
                \\    id INTEGER PRIMARY KEY CHECK (id = 1),
                \\    session_id TEXT NOT NULL,
                \\    current_task_id TEXT,
                \\    started_at INTEGER NOT NULL
                \\)
            );

            // Add commit tracking columns (ignore error if already exist)
            sqlite.exec(self.db, "ALTER TABLE tasks ADD COLUMN started_at_commit TEXT") catch {};
            sqlite.exec(self.db, "ALTER TABLE tasks ADD COLUMN completed_at_commit TEXT") catch {};

            // Optimize ready queue query
            try sqlite.exec(self.db,
                \\CREATE INDEX IF NOT EXISTS idx_tasks_ready
                \\ON tasks(status, task_type, priority, created_at)
            );

            try self.setMetadata("schema_version", "3");
        }
    }

    /// Save a task to the database (insert or update)
    pub fn saveTask(self: *Self, task: *const Task) !void {
        // Wisps are ephemeral - don't persist to SQLite
        if (task.task_type == .wisp) return;

        // Serialize labels to JSON
        var labels_json = std.ArrayListUnmanaged(u8){};
        defer labels_json.deinit(self.allocator);
        try labels_json.append(self.allocator, '[');
        for (task.labels, 0..) |label, i| {
            if (i > 0) try labels_json.append(self.allocator, ',');
            try labels_json.append(self.allocator, '"');
            try labels_json.appendSlice(self.allocator, label);
            try labels_json.append(self.allocator, '"');
        }
        try labels_json.append(self.allocator, ']');

        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO tasks (
            \\    id, title, description, status, priority, task_type,
            \\    labels, created_at, updated_at, completed_at, parent_id
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        // Bind task ID
        try sqlite.bindText(stmt, 1, &task.id);

        // Bind title
        try sqlite.bindText(stmt, 2, task.title);

        // Bind description
        if (task.description) |desc| {
            try sqlite.bindText(stmt, 3, desc);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        // Bind status
        try sqlite.bindText(stmt, 4, task.status.toString());

        // Bind priority
        try sqlite.bindInt64(stmt, 5, task.priority.toInt());

        // Bind task_type
        try sqlite.bindText(stmt, 6, task.task_type.toString());

        // Bind labels JSON
        try sqlite.bindText(stmt, 7, labels_json.items);

        // Bind timestamps
        try sqlite.bindInt64(stmt, 8, task.created_at);
        try sqlite.bindInt64(stmt, 9, task.updated_at);

        if (task.completed_at) |completed| {
            try sqlite.bindInt64(stmt, 10, completed);
        } else {
            try sqlite.bindNull(stmt, 10);
        }

        // Bind parent_id
        if (task.parent_id) |pid| {
            try sqlite.bindText(stmt, 11, &pid);
        } else {
            try sqlite.bindNull(stmt, 11);
        }

        _ = try sqlite.step(stmt);

        // Save comments to separate table (Beads audit trail)
        try self.saveComments(&task.id, task.comments);
    }

    /// Load a task from the database by ID (uses self.allocator)
    pub fn loadTask(self: *Self, task_id: TaskId) !?Task {
        return self.loadTaskWithAllocator(task_id, self.allocator);
    }

    /// Load a task from the database by ID with specified allocator
    pub fn loadTaskWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) !?Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id,
            \\       started_at_commit, completed_at_commit
            \\FROM tasks WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        const rc = try sqlite.step(stmt);
        if (rc != sqlite.SQLITE_ROW) {
            return null;
        }

        return try self.taskFromRowWithAllocator(stmt, alloc);
    }

    /// Load all tasks from the database
    pub fn loadAllTasks(self: *Self) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id,
            \\       started_at_commit, completed_at_commit
            \\FROM tasks
        );
        defer sqlite.finalize(stmt);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(self.allocator);
            tasks.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const task = try self.taskFromRow(stmt);
            try tasks.append(self.allocator, task);
        }

        return tasks.toOwnedSlice(self.allocator);
    }

    /// Parse a task from a SQLite row (uses self.allocator)
    fn taskFromRow(self: *Self, stmt: *sqlite.Stmt) !Task {
        return self.taskFromRowWithAllocator(stmt, self.allocator);
    }

    /// Parse a task from a SQLite row with specified allocator
    fn taskFromRowWithAllocator(self: *Self, stmt: *sqlite.Stmt, alloc: Allocator) !Task {
        // ID (column 0)
        var id: TaskId = undefined;
        if (sqlite.columnText(stmt, 0)) |id_text| {
            if (id_text.len >= 8) {
                @memcpy(&id, id_text[0..8]);
            } else {
                return error.InvalidTaskId;
            }
        } else {
            return error.InvalidTaskId;
        }

        // Title (column 1)
        const title = if (sqlite.columnText(stmt, 1)) |t|
            try alloc.dupe(u8, t)
        else
            return error.InvalidTaskData;

        // Description (column 2)
        const description = if (sqlite.columnType(stmt, 2) != sqlite.SQLITE_NULL)
            if (sqlite.columnText(stmt, 2)) |d|
                try alloc.dupe(u8, d)
            else
                null
        else
            null;

        // Status (column 3)
        const status = if (sqlite.columnText(stmt, 3)) |s|
            TaskStatus.fromString(s) orelse .pending
        else
            .pending;

        // Priority (column 4)
        const priority = TaskPriority.fromInt(@intCast(sqlite.columnInt64(stmt, 4)));

        // Task type (column 5)
        const task_type = if (sqlite.columnText(stmt, 5)) |t|
            TaskType.fromString(t) orelse .task
        else
            .task;

        // Labels (column 6) - parse JSON array
        var labels = std.ArrayListUnmanaged([]const u8){};
        if (sqlite.columnType(stmt, 6) != sqlite.SQLITE_NULL) {
            if (sqlite.columnText(stmt, 6)) |labels_json| {
                // Simple JSON array parsing: ["label1", "label2"]
                var in_string = false;
                var start: ?usize = null;
                for (labels_json, 0..) |c, i| {
                    if (c == '"' and !in_string) {
                        in_string = true;
                        start = i + 1;
                    } else if (c == '"' and in_string) {
                        if (start) |s| {
                            const label = try alloc.dupe(u8, labels_json[s..i]);
                            try labels.append(alloc, label);
                        }
                        in_string = false;
                        start = null;
                    }
                }
            }
        }

        // Timestamps (columns 7, 8, 9)
        const created_at = sqlite.columnInt64(stmt, 7);
        const updated_at = sqlite.columnInt64(stmt, 8);
        const completed_at = if (sqlite.columnType(stmt, 9) != sqlite.SQLITE_NULL)
            sqlite.columnInt64(stmt, 9)
        else
            null;

        // Parent ID (column 10)
        var parent_id: ?TaskId = null;
        if (sqlite.columnType(stmt, 10) != sqlite.SQLITE_NULL) {
            if (sqlite.columnText(stmt, 10)) |pid_text| {
                if (pid_text.len >= 8) {
                    var pid: TaskId = undefined;
                    @memcpy(&pid, pid_text[0..8]);
                    parent_id = pid;
                }
            }
        }

        // Commit tracking (columns 11, 12) - Tinkerer/Judge workflow
        const started_at_commit = if (sqlite.columnType(stmt, 11) != sqlite.SQLITE_NULL)
            if (sqlite.columnText(stmt, 11)) |c|
                try alloc.dupe(u8, c)
            else
                null
        else
            null;
        errdefer if (started_at_commit) |c| alloc.free(c);

        const completed_at_commit = if (sqlite.columnType(stmt, 12) != sqlite.SQLITE_NULL)
            if (sqlite.columnText(stmt, 12)) |c|
                try alloc.dupe(u8, c)
            else
                null
        else
            null;
        errdefer if (completed_at_commit) |c| alloc.free(c);

        // Load comments from separate table (Beads audit trail)
        const comments = try self.loadCommentsWithAllocator(&id, alloc);

        return Task{
            .id = id,
            .title = title,
            .description = description,
            .status = status,
            .priority = priority,
            .task_type = task_type,
            .labels = try labels.toOwnedSlice(alloc),
            .created_at = created_at,
            .updated_at = updated_at,
            .completed_at = completed_at,
            .parent_id = parent_id,
            .blocked_by_count = 0, // Will be recalculated when loading dependencies
            .comments = comments,
            .started_at_commit = started_at_commit,
            .completed_at_commit = completed_at_commit,
        };
    }

    /// Delete a task from the database
    pub fn deleteTask(self: *Self, task_id: TaskId) !void {
        const stmt = try sqlite.prepare(self.db, "DELETE FROM tasks WHERE id = ?");
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        _ = try sqlite.step(stmt);
    }

    /// Save a dependency to the database
    pub fn saveDependency(self: *Self, dep: *const Dependency) !void {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO task_dependencies (src_id, dst_id, dep_type, weight, created_at)
            \\VALUES (?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &dep.src_id);
        try sqlite.bindText(stmt, 2, &dep.dst_id);
        try sqlite.bindText(stmt, 3, dep.dep_type.toString());

        // Bind weight as text since we need to handle floats
        var weight_buf: [32]u8 = undefined;
        const weight_str = try std.fmt.bufPrint(&weight_buf, "{d:.2}", .{dep.weight});
        try sqlite.bindText(stmt, 4, weight_str);

        try sqlite.bindInt64(stmt, 5, now);

        _ = try sqlite.step(stmt);
    }

    /// Load all dependencies from the database
    pub fn loadAllDependencies(self: *Self) ![]Dependency {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT src_id, dst_id, dep_type, weight FROM task_dependencies
        );
        defer sqlite.finalize(stmt);

        var deps = std.ArrayListUnmanaged(Dependency){};
        errdefer deps.deinit(self.allocator);

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var src_id: TaskId = undefined;
            var dst_id: TaskId = undefined;

            if (sqlite.columnText(stmt, 0)) |src_text| {
                if (src_text.len >= 8) {
                    @memcpy(&src_id, src_text[0..8]);
                } else continue;
            } else continue;

            if (sqlite.columnText(stmt, 1)) |dst_text| {
                if (dst_text.len >= 8) {
                    @memcpy(&dst_id, dst_text[0..8]);
                } else continue;
            } else continue;

            const dep_type = if (sqlite.columnText(stmt, 2)) |t|
                DependencyType.fromString(t) orelse .related
            else
                .related;

            // Weight - stored as text, default to 1.0
            const weight: f32 = 1.0;

            try deps.append(self.allocator, .{
                .src_id = src_id,
                .dst_id = dst_id,
                .dep_type = dep_type,
                .weight = weight,
            });
        }

        return deps.toOwnedSlice(self.allocator);
    }

    /// Delete a dependency
    /// Returns error.DependencyNotFound if the dependency doesn't exist
    pub fn deleteDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        const stmt = try sqlite.prepare(self.db,
            \\DELETE FROM task_dependencies WHERE src_id = ? AND dst_id = ? AND dep_type = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &src_id);
        try sqlite.bindText(stmt, 2, &dst_id);
        try sqlite.bindText(stmt, 3, dep_type.toString());

        _ = try sqlite.step(stmt);

        // Check if any rows were affected
        const affected = sqlite.changes(self.db);
        if (affected == 0) {
            return error.DependencyNotFound;
        }
    }

    /// Save comments for a task (replaces existing comments)
    fn saveComments(self: *Self, task_id: *const TaskId, comments: []const Comment) !void {
        // Delete existing comments for this task
        const delete_stmt = try sqlite.prepare(self.db, "DELETE FROM task_comments WHERE task_id = ?");
        defer sqlite.finalize(delete_stmt);

        try sqlite.bindText(delete_stmt, 1, task_id);
        _ = try sqlite.step(delete_stmt);

        // Insert new comments
        for (comments) |comment| {
            const insert_stmt = try sqlite.prepare(self.db,
                \\INSERT INTO task_comments (task_id, agent, content, timestamp)
                \\VALUES (?, ?, ?, ?)
            );
            defer sqlite.finalize(insert_stmt);

            try sqlite.bindText(insert_stmt, 1, task_id);
            try sqlite.bindText(insert_stmt, 2, comment.agent);
            try sqlite.bindText(insert_stmt, 3, comment.content);

            try sqlite.bindInt64(insert_stmt, 4, comment.timestamp);

            _ = try sqlite.step(insert_stmt);
        }
    }

    /// Append a single comment to a task (O(1) instead of O(n) delete+reinsert)
    pub fn appendComment(self: *Self, task_id: *const TaskId, comment: Comment) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO task_comments (task_id, agent, content, timestamp)
            \\VALUES (?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, task_id);
        try sqlite.bindText(stmt, 2, comment.agent);
        try sqlite.bindText(stmt, 3, comment.content);

        try sqlite.bindInt64(stmt, 4, comment.timestamp);

        _ = try sqlite.step(stmt);
    }

    /// Load comments for a task (uses self.allocator)
    fn loadComments(self: *Self, task_id: *const TaskId) ![]Comment {
        return self.loadCommentsWithAllocator(task_id, self.allocator);
    }

    /// Load comments for a task with specified allocator
    fn loadCommentsWithAllocator(self: *Self, task_id: *const TaskId, alloc: Allocator) ![]Comment {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT agent, content, timestamp FROM task_comments
            \\WHERE task_id = ? ORDER BY timestamp ASC
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, task_id);

        var comments = std.ArrayListUnmanaged(Comment){};
        errdefer {
            for (comments.items) |*c| {
                alloc.free(c.agent);
                alloc.free(c.content);
            }
            comments.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const agent = if (sqlite.columnText(stmt, 0)) |a|
                try alloc.dupe(u8, a)
            else
                try alloc.dupe(u8, "unknown");

            const content = if (sqlite.columnText(stmt, 1)) |c|
                try alloc.dupe(u8, c)
            else
                try alloc.dupe(u8, "");

            const timestamp = sqlite.columnInt64(stmt, 2);

            try comments.append(alloc, .{
                .agent = agent,
                .content = content,
                .timestamp = timestamp,
            });
        }

        return comments.toOwnedSlice(alloc);
    }

    /// Set a metadata key-value pair
    fn setMetadata(self: *Self, key: []const u8, value: []const u8) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO task_db_metadata (key, value) VALUES (?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);
        try sqlite.bindText(stmt, 2, value);

        _ = try sqlite.step(stmt);
    }

    /// Get a metadata value by key
    fn getMetadata(self: *Self, key: []const u8) !?[]const u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT value FROM task_db_metadata WHERE key = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            if (sqlite.columnText(stmt, 0)) |text| {
                return try self.allocator.dupe(u8, text);
            }
        }
        return null;
    }

    /// Begin a transaction (uses SAVEPOINTs for nesting)
    /// SQLite ignores nested BEGIN, so we use SAVEPOINTs to provide true nesting
    /// Uses IMMEDIATE mode to acquire write lock immediately, preventing lost updates
    /// when multiple threads may modify the same data concurrently
    /// Thread-safe: protected by transaction_mutex
    pub fn beginTransaction(self: *Self) !void {
        self.transaction_mutex.lock();
        defer self.transaction_mutex.unlock();

        if (self.transaction_depth == 0) {
            try sqlite.exec(self.db, "BEGIN IMMEDIATE");
        } else {
            // Use savepoint for nested transaction
            var buf: [32]u8 = undefined;
            const savepoint_sql = std.fmt.bufPrint(&buf, "SAVEPOINT sp_{d}", .{self.transaction_depth}) catch unreachable;
            try sqlite.exec(self.db, savepoint_sql);
        }
        self.transaction_depth += 1;
    }

    /// Commit a transaction (releases SAVEPOINT if nested)
    /// Thread-safe: protected by transaction_mutex
    pub fn commitTransaction(self: *Self) !void {
        self.transaction_mutex.lock();
        defer self.transaction_mutex.unlock();

        if (self.transaction_depth == 0) {
            return error.NoActiveTransaction;
        }
        self.transaction_depth -= 1;
        if (self.transaction_depth == 0) {
            try sqlite.exec(self.db, "COMMIT");
        } else {
            // Release savepoint for nested transaction
            var buf: [32]u8 = undefined;
            const release_sql = std.fmt.bufPrint(&buf, "RELEASE sp_{d}", .{self.transaction_depth}) catch unreachable;
            try sqlite.exec(self.db, release_sql);
        }
    }

    /// Rollback a transaction (rolls back to SAVEPOINT if nested)
    /// Thread-safe: protected by transaction_mutex
    pub fn rollbackTransaction(self: *Self) !void {
        self.transaction_mutex.lock();
        defer self.transaction_mutex.unlock();

        if (self.transaction_depth == 0) {
            return error.NoActiveTransaction;
        }
        self.transaction_depth -= 1;
        if (self.transaction_depth == 0) {
            try sqlite.exec(self.db, "ROLLBACK");
        } else {
            // Rollback to savepoint for nested transaction
            var buf: [48]u8 = undefined;
            const rollback_sql = std.fmt.bufPrint(&buf, "ROLLBACK TO sp_{d}", .{self.transaction_depth}) catch unreachable;
            try sqlite.exec(self.db, rollback_sql);
        }
    }

    /// Check if currently in a transaction
    pub fn inTransaction(self: *Self) bool {
        return self.transaction_depth > 0;
    }

    /// Export all tasks to JSONL format
    pub fn exportToJsonl(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const tasks = try self.loadAllTasks();
        defer {
            for (tasks) |*t| {
                var task = t.*;
                task.deinit(self.allocator);
            }
            self.allocator.free(tasks);
        }

        var writer = file.writer();

        for (tasks) |task| {
            // Write task as JSON line
            try writer.print("{{\"id\":\"{s}\",\"title\":\"{s}\",\"status\":\"{s}\",\"priority\":{d},\"type\":\"{s}\",\"created_at\":{d},\"updated_at\":{d}}}\n", .{
                &task.id,
                task.title,
                task.status.toString(),
                task.priority.toInt(),
                task.task_type.toString(),
                task.created_at,
                task.updated_at,
            });
        }
    }

    /// Get task count
    pub fn getTaskCount(self: *Self) !i64 {
        const stmt = try sqlite.prepare(self.db, "SELECT COUNT(*) FROM tasks");
        defer sqlite.finalize(stmt);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            return sqlite.columnInt64(stmt, 0);
        }
        return 0;
    }

    // ============================================================
    // Phase 1: Query methods for SQLite as single source of truth
    // ============================================================

    /// Check if a task exists
    pub fn taskExists(self: *Self, task_id: TaskId) !bool {
        const stmt = try sqlite.prepare(self.db, "SELECT 1 FROM tasks WHERE id = ? LIMIT 1");
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        const rc = try sqlite.step(stmt);
        return rc == sqlite.SQLITE_ROW;
    }

    /// Get ready task IDs (pending, not blocked, not molecules)
    /// Returns IDs sorted by priority then created_at
    pub fn getReadyTaskIds(self: *Self) ![]TaskId {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.id FROM tasks t
            \\WHERE t.status = 'pending'
            \\  AND t.task_type != 'molecule'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM task_dependencies d
            \\    JOIN tasks blocker ON d.src_id = blocker.id
            \\    WHERE d.dst_id = t.id
            \\      AND d.dep_type = 'blocks'
            \\      AND blocker.status != 'completed'
            \\  )
            \\ORDER BY t.priority ASC, t.created_at ASC
        );
        defer sqlite.finalize(stmt);

        var ids = std.ArrayListUnmanaged(TaskId){};
        errdefer ids.deinit(self.allocator);

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            if (sqlite.columnText(stmt, 0)) |id_text| {
                if (id_text.len >= 8) {
                    var id: TaskId = undefined;
                    @memcpy(&id, id_text[0..8]);
                    try ids.append(self.allocator, id);
                }
            }
        }

        return ids.toOwnedSlice(self.allocator);
    }

    /// Get ready tasks with computed blocked_by_count (uses self.allocator)
    pub fn getReadyTasks(self: *Self) ![]Task {
        return self.getReadyTasksWithAllocator(self.allocator);
    }

    /// Get ready tasks with specified allocator
    pub fn getReadyTasksWithAllocator(self: *Self, alloc: Allocator) ![]Task {
        const ids = try self.getReadyTaskIds();
        defer self.allocator.free(ids);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        for (ids) |id| {
            if (try self.loadTaskWithAllocator(id, alloc)) |task| {
                try tasks.append(alloc, task);
            }
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// Get tasks by IDs (uses self.allocator)
    pub fn getTasksByIds(self: *Self, ids: []const TaskId) ![]Task {
        return self.getTasksByIdsWithAllocator(ids, self.allocator);
    }

    /// Get tasks by IDs with specified allocator
    pub fn getTasksByIdsWithAllocator(self: *Self, ids: []const TaskId, alloc: Allocator) ![]Task {
        if (ids.len == 0) return alloc.alloc(Task, 0);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        // For now, query each task individually
        // TODO: Build IN clause for better performance with large batches
        for (ids) |id| {
            if (try self.loadTaskWithAllocator(id, alloc)) |task| {
                try tasks.append(alloc, task);
            }
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// List tasks with optional filters (uses self.allocator)
    pub fn listTasks(self: *Self, filter: task_store.TaskFilter) ![]Task {
        return self.listTasksWithAllocator(filter, self.allocator);
    }

    /// List tasks with optional filters and specified allocator
    pub fn listTasksWithAllocator(self: *Self, filter: task_store.TaskFilter, alloc: Allocator) ![]Task {
        // Build dynamic WHERE clause (use self.allocator for temp query building)
        var conditions = std.ArrayListUnmanaged([]const u8){};
        defer conditions.deinit(self.allocator);

        if (filter.status) |_| {
            try conditions.append(self.allocator, "status = ?");
        }
        if (filter.priority) |_| {
            try conditions.append(self.allocator, "priority = ?");
        }
        if (filter.task_type) |_| {
            try conditions.append(self.allocator, "task_type = ?");
        }
        if (filter.parent_id) |_| {
            try conditions.append(self.allocator, "parent_id = ?");
        }
        if (filter.search) |_| {
            try conditions.append(self.allocator, "(title LIKE '%' || ? || '%' OR description LIKE '%' || ? || '%')");
        }

        // Build query
        var query = std.ArrayListUnmanaged(u8){};
        defer query.deinit(self.allocator);

        try query.appendSlice(self.allocator,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id,
            \\       started_at_commit, completed_at_commit
            \\FROM tasks
        );

        if (conditions.items.len > 0) {
            try query.appendSlice(self.allocator, " WHERE ");
            for (conditions.items, 0..) |cond, i| {
                if (i > 0) try query.appendSlice(self.allocator, " AND ");
                try query.appendSlice(self.allocator, cond);
            }
        }

        const stmt = try sqlite.prepare(self.db, query.items);
        defer sqlite.finalize(stmt);

        // Bind parameters
        var bind_idx: usize = 1;
        if (filter.status) |s| {
            try sqlite.bindText(stmt, @intCast(bind_idx), s.toString());
            bind_idx += 1;
        }
        if (filter.priority) |p| {
            try sqlite.bindInt64(stmt, @intCast(bind_idx), p.toInt());
            bind_idx += 1;
        }
        if (filter.task_type) |t| {
            try sqlite.bindText(stmt, @intCast(bind_idx), t.toString());
            bind_idx += 1;
        }
        if (filter.parent_id) |pid| {
            try sqlite.bindText(stmt, @intCast(bind_idx), &pid);
            bind_idx += 1;
        }
        if (filter.search) |s| {
            // Bind twice for OR condition (title LIKE and description LIKE)
            try sqlite.bindText(stmt, @intCast(bind_idx), s);
            bind_idx += 1;
            try sqlite.bindText(stmt, @intCast(bind_idx), s);
            bind_idx += 1;
        }

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRowWithAllocator(stmt, alloc);

            // Post-filter for ready_only (requires checking dependencies)
            // Ready means: pending status, no active blockers, and NOT a molecule (containers aren't actionable)
            if (filter.ready_only) {
                const blocked_count = try self.getBlockedByCount(task.id);
                if (blocked_count > 0 or task.status != .pending or task.task_type == .molecule) {
                    task.deinit(alloc);
                    continue;
                }
            }

            // Post-filter for label
            if (filter.label) |lbl| {
                var found = false;
                for (task.labels) |task_lbl| {
                    if (std.mem.eql(u8, task_lbl, lbl)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    task.deinit(alloc);
                    continue;
                }
            }

            // Compute blocked_by_count
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(alloc, task);
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// Get task counts by status
    pub fn getTaskCounts(self: *Self) !task_store.TaskStore.TaskCounts {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT status, COUNT(*) FROM tasks GROUP BY status
        );
        defer sqlite.finalize(stmt);

        var counts = task_store.TaskStore.TaskCounts{};

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            if (sqlite.columnText(stmt, 0)) |status_str| {
                const count: usize = @intCast(sqlite.columnInt64(stmt, 1));
                if (TaskStatus.fromString(status_str)) |status| {
                    switch (status) {
                        .pending => counts.pending = count,
                        .in_progress => counts.in_progress = count,
                        .completed => counts.completed = count,
                        .blocked => counts.blocked = count,
                        .cancelled => {},
                    }
                }
            }
        }

        return counts;
    }

    /// Get tasks by status (uses self.allocator)
    pub fn getTasksByStatus(self: *Self, status: TaskStatus) ![]Task {
        return self.getTasksByStatusWithAllocator(status, self.allocator);
    }

    /// Get tasks by status with specified allocator
    pub fn getTasksByStatusWithAllocator(self: *Self, status: TaskStatus, alloc: Allocator) ![]Task {
        return self.listTasksWithAllocator(.{ .status = status }, alloc);
    }

    /// Get children of a parent task (uses self.allocator)
    pub fn getChildren(self: *Self, parent_id: TaskId) ![]Task {
        return self.getChildrenWithAllocator(parent_id, self.allocator);
    }

    /// Get children of a parent task with specified allocator
    pub fn getChildrenWithAllocator(self: *Self, parent_id: TaskId, alloc: Allocator) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id,
            \\       started_at_commit, completed_at_commit
            \\FROM tasks WHERE parent_id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &parent_id);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRowWithAllocator(stmt, alloc);
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(alloc, task);
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// Get siblings of a task (uses self.allocator)
    pub fn getSiblings(self: *Self, task_id: TaskId) ![]Task {
        return self.getSiblingsWithAllocator(task_id, self.allocator);
    }

    /// Get siblings of a task with specified allocator
    pub fn getSiblingsWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id,
            \\       started_at_commit, completed_at_commit
            \\FROM tasks
            \\WHERE parent_id = (SELECT parent_id FROM tasks WHERE id = ?)
            \\  AND id != ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);
        try sqlite.bindText(stmt, 2, &task_id);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRowWithAllocator(stmt, alloc);
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(alloc, task);
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// Epic summary for molecules
    pub const EpicSummary = struct {
        total_children: usize,
        completed_children: usize,
        blocked_children: usize,
        in_progress_children: usize,
        completion_percent: u8,
    };

    pub fn getEpicSummary(self: *Self, epic_id: TaskId) !EpicSummary {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT status, COUNT(*) FROM tasks
            \\WHERE parent_id = ?
            \\GROUP BY status
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &epic_id);

        var total: usize = 0;
        var completed: usize = 0;
        var blocked: usize = 0;
        var in_progress: usize = 0;

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            if (sqlite.columnText(stmt, 0)) |status_str| {
                const count: usize = @intCast(sqlite.columnInt64(stmt, 1));
                total += count;
                if (TaskStatus.fromString(status_str)) |status| {
                    switch (status) {
                        .completed => completed = count,
                        .blocked => blocked = count,
                        .in_progress => in_progress = count,
                        else => {},
                    }
                }
            }
        }

        const pct: u8 = if (total > 0) @intCast((completed * 100) / total) else 0;

        return EpicSummary{
            .total_children = total,
            .completed_children = completed,
            .blocked_children = blocked,
            .in_progress_children = in_progress,
            .completion_percent = pct,
        };
    }

    /// Count of incomplete tasks blocking this one
    pub fn getBlockedByCount(self: *Self, task_id: TaskId) !usize {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT COUNT(*) FROM task_dependencies d
            \\JOIN tasks blocker ON d.src_id = blocker.id
            \\WHERE d.dst_id = ?
            \\  AND d.dep_type = 'blocks'
            \\  AND blocker.status != 'completed'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            return @intCast(sqlite.columnInt64(stmt, 0));
        }
        return 0;
    }

    /// Get tasks that block this one (incomplete only)
    pub fn getBlockedBy(self: *Self, task_id: TaskId) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.id, t.title, t.description, t.status, t.priority, t.task_type,
            \\       t.labels, t.created_at, t.updated_at, t.completed_at, t.parent_id,
            \\       t.started_at_commit, t.completed_at_commit
            \\FROM tasks t
            \\JOIN task_dependencies d ON d.src_id = t.id
            \\WHERE d.dst_id = ?
            \\  AND d.dep_type = 'blocks'
            \\  AND t.status != 'completed'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(self.allocator);
            tasks.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRow(stmt);
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(self.allocator, task);
        }

        return tasks.toOwnedSlice(self.allocator);
    }

    /// Get tasks blocked by this one
    pub fn getBlocking(self: *Self, task_id: TaskId) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.id, t.title, t.description, t.status, t.priority, t.task_type,
            \\       t.labels, t.created_at, t.updated_at, t.completed_at, t.parent_id,
            \\       t.started_at_commit, t.completed_at_commit
            \\FROM tasks t
            \\JOIN task_dependencies d ON d.dst_id = t.id
            \\WHERE d.src_id = ?
            \\  AND d.dep_type = 'blocks'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(self.allocator);
            tasks.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRow(stmt);
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(self.allocator, task);
        }

        return tasks.toOwnedSlice(self.allocator);
    }

    /// Get IDs of tasks blocked by this one (efficient - no full Task load)
    /// Used for cycle detection in dependency graphs
    pub fn getBlockingTaskIds(self: *Self, task_id: TaskId) ![]TaskId {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT dst_id FROM task_dependencies
            \\WHERE src_id = ? AND dep_type = 'blocks'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        var ids = std.ArrayListUnmanaged(TaskId){};
        errdefer ids.deinit(self.allocator);

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            if (sqlite.columnText(stmt, 0)) |id_text| {
                if (id_text.len >= 8) {
                    var id: TaskId = undefined;
                    @memcpy(&id, id_text[0..8]);
                    try ids.append(self.allocator, id);
                }
            }
        }

        return ids.toOwnedSlice(self.allocator);
    }

    /// Blocker info for list_tasks - includes all blockers (active + completed)
    pub const BlockerInfo = struct {
        id: TaskId,
        title: []const u8, // Owned
        completed: bool,

        pub fn deinit(self: *BlockerInfo, alloc: Allocator) void {
            alloc.free(self.title);
        }
    };

    /// Get all tasks that block this one (both active and completed)
    /// Returns BlockerInfo with id, title, and completion status
    pub fn getAllBlockers(self: *Self, task_id: TaskId) ![]BlockerInfo {
        return self.getAllBlockersWithAllocator(task_id, self.allocator);
    }

    /// Get all tasks that block this one with specified allocator
    pub fn getAllBlockersWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) ![]BlockerInfo {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.id, t.title, t.status
            \\FROM tasks t
            \\JOIN task_dependencies d ON d.src_id = t.id
            \\WHERE d.dst_id = ?
            \\  AND d.dep_type = 'blocks'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        var blockers = std.ArrayListUnmanaged(BlockerInfo){};
        errdefer {
            for (blockers.items) |*b| b.deinit(alloc);
            blockers.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var id: TaskId = undefined;
            if (sqlite.columnText(stmt, 0)) |id_text| {
                if (id_text.len >= 8) {
                    @memcpy(&id, id_text[0..8]);
                } else continue;
            } else continue;

            const title = if (sqlite.columnText(stmt, 1)) |t|
                try alloc.dupe(u8, t)
            else
                try alloc.dupe(u8, "");

            const status_str = sqlite.columnText(stmt, 2) orelse "pending";
            const completed = std.mem.eql(u8, status_str, "completed");

            try blockers.append(alloc, .{
                .id = id,
                .title = title,
                .completed = completed,
            });
        }

        return blockers.toOwnedSlice(alloc);
    }

    /// Get all tasks that this task blocks (will be unblocked when completed)
    /// Returns BlockerInfo with id, title, and completion status
    pub fn getAllBlocking(self: *Self, task_id: TaskId) ![]BlockerInfo {
        return self.getAllBlockingWithAllocator(task_id, self.allocator);
    }

    /// Get all tasks that this task blocks with specified allocator
    pub fn getAllBlockingWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) ![]BlockerInfo {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT t.id, t.title, t.status
            \\FROM tasks t
            \\JOIN task_dependencies d ON d.dst_id = t.id
            \\WHERE d.src_id = ?
            \\  AND d.dep_type = 'blocks'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);

        var blocking = std.ArrayListUnmanaged(BlockerInfo){};
        errdefer {
            for (blocking.items) |*b| b.deinit(alloc);
            blocking.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var id: TaskId = undefined;
            if (sqlite.columnText(stmt, 0)) |id_text| {
                if (id_text.len >= 8) {
                    @memcpy(&id, id_text[0..8]);
                } else continue;
            } else continue;

            const title = if (sqlite.columnText(stmt, 1)) |t|
                try alloc.dupe(u8, t)
            else
                try alloc.dupe(u8, "");

            const status_str = sqlite.columnText(stmt, 2) orelse "pending";
            const completed = std.mem.eql(u8, status_str, "completed");

            try blocking.append(alloc, .{
                .id = id,
                .title = title,
                .completed = completed,
            });
        }

        return blocking.toOwnedSlice(alloc);
    }

    /// Get tasks that become unblocked when completed_id is completed
    /// Returns task IDs where completed_id was the last blocker
    pub fn getNewlyUnblockedTasks(self: *Self, completed_id: TaskId) ![]TaskId {
        // Find tasks where:
        // 1. completed_id blocks them
        // 2. They have no other incomplete blockers
        const stmt = try sqlite.prepare(self.db,
            \\SELECT DISTINCT d.dst_id FROM task_dependencies d
            \\WHERE d.src_id = ?
            \\  AND d.dep_type = 'blocks'
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM task_dependencies d2
            \\    JOIN tasks blocker ON d2.src_id = blocker.id
            \\    WHERE d2.dst_id = d.dst_id
            \\      AND d2.dep_type = 'blocks'
            \\      AND d2.src_id != ?
            \\      AND blocker.status != 'completed'
            \\  )
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &completed_id);
        try sqlite.bindText(stmt, 2, &completed_id);

        var ids = std.ArrayListUnmanaged(TaskId){};
        errdefer ids.deinit(self.allocator);

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            if (sqlite.columnText(stmt, 0)) |id_text| {
                if (id_text.len >= 8) {
                    var id: TaskId = undefined;
                    @memcpy(&id, id_text[0..8]);
                    try ids.append(self.allocator, id);
                }
            }
        }

        return ids.toOwnedSlice(self.allocator);
    }

    /// Get tasks with comments containing a prefix (uses self.allocator)
    pub fn getTasksWithCommentPrefix(self: *Self, prefix: []const u8) ![]Task {
        return self.getTasksWithCommentPrefixWithAllocator(prefix, self.allocator);
    }

    /// Get tasks with comments containing a prefix with specified allocator
    pub fn getTasksWithCommentPrefixWithAllocator(self: *Self, prefix: []const u8, alloc: Allocator) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT DISTINCT t.id, t.title, t.description, t.status, t.priority, t.task_type,
            \\       t.labels, t.created_at, t.updated_at, t.completed_at, t.parent_id,
            \\       t.started_at_commit, t.completed_at_commit
            \\FROM tasks t
            \\JOIN task_comments c ON c.task_id = t.id
            \\WHERE c.content LIKE ? || '%'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, prefix);

        var tasks = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (tasks.items) |*t| t.deinit(alloc);
            tasks.deinit(alloc);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            var task = try self.taskFromRowWithAllocator(stmt, alloc);
            task.blocked_by_count = try self.getBlockedByCount(task.id);
            try tasks.append(alloc, task);
        }

        return tasks.toOwnedSlice(alloc);
    }

    /// Get last comment from a specific agent
    pub fn getLastCommentFrom(self: *Self, task_id: TaskId, agent: []const u8) !?Comment {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT agent, content, timestamp FROM task_comments
            \\WHERE task_id = ? AND agent = ?
            \\ORDER BY timestamp DESC LIMIT 1
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);
        try sqlite.bindText(stmt, 2, agent);

        const rc = try sqlite.step(stmt);
        if (rc != sqlite.SQLITE_ROW) return null;

        const agent_out = if (sqlite.columnText(stmt, 0)) |a|
            try self.allocator.dupe(u8, a)
        else
            try self.allocator.dupe(u8, "unknown");

        const content = if (sqlite.columnText(stmt, 1)) |c|
            try self.allocator.dupe(u8, c)
        else
            try self.allocator.dupe(u8, "");

        return Comment{
            .agent = agent_out,
            .content = content,
            .timestamp = sqlite.columnInt64(stmt, 2),
        };
    }

    /// Count comments from agent with prefix
    pub fn countCommentsWithPrefix(self: *Self, task_id: TaskId, agent: []const u8, prefix: []const u8) !usize {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT COUNT(*) FROM task_comments
            \\WHERE task_id = ? AND agent = ? AND content LIKE ? || '%'
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, &task_id);
        try sqlite.bindText(stmt, 2, agent);
        try sqlite.bindText(stmt, 3, prefix);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            return @intCast(sqlite.columnInt64(stmt, 0));
        }
        return 0;
    }

    // ============================================================
    // Update methods
    // ============================================================

    /// Update task status
    pub fn updateTaskStatus(self: *Self, task_id: TaskId, status: TaskStatus, completed_at: ?i64) !void {
        const now = std.time.timestamp();
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE tasks SET status = ?, updated_at = ?, completed_at = ?
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, status.toString());

        try sqlite.bindInt64(stmt, 2, now);

        if (completed_at) |ca| {
            try sqlite.bindInt64(stmt, 3, ca);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        try sqlite.bindText(stmt, 4, &task_id);

        _ = try sqlite.step(stmt);
    }

    /// Update task priority
    pub fn updateTaskPriority(self: *Self, task_id: TaskId, priority: TaskPriority) !void {
        const now = std.time.timestamp();
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE tasks SET priority = ?, updated_at = ? WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, priority.toInt());
        try sqlite.bindInt64(stmt, 2, now);

        try sqlite.bindText(stmt, 3, &task_id);

        _ = try sqlite.step(stmt);
    }

    /// Update task title
    pub fn updateTaskTitle(self: *Self, task_id: TaskId, title: []const u8) !void {
        const now = std.time.timestamp();
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE tasks SET title = ?, updated_at = ? WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, title);

        try sqlite.bindInt64(stmt, 2, now);

        try sqlite.bindText(stmt, 3, &task_id);

        _ = try sqlite.step(stmt);
    }

    /// Update task type
    pub fn updateTaskType(self: *Self, task_id: TaskId, task_type: TaskType) !void {
        const now = std.time.timestamp();
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE tasks SET task_type = ?, updated_at = ? WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, task_type.toString());

        try sqlite.bindInt64(stmt, 2, now);

        try sqlite.bindText(stmt, 3, &task_id);

        _ = try sqlite.step(stmt);
    }

    /// Update commit tracking fields
    pub fn updateCommitTracking(self: *Self, task_id: TaskId, started: ?[]const u8, completed: ?[]const u8) !void {
        const now = std.time.timestamp();
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE tasks SET started_at_commit = ?, completed_at_commit = ?, updated_at = ?
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        if (started) |s| {
            try sqlite.bindText(stmt, 1, s);
        } else {
            try sqlite.bindNull(stmt, 1);
        }

        if (completed) |c| {
            try sqlite.bindText(stmt, 2, c);
        } else {
            try sqlite.bindNull(stmt, 2);
        }

        try sqlite.bindInt64(stmt, 3, now);

        try sqlite.bindText(stmt, 4, &task_id);

        _ = try sqlite.step(stmt);
    }

    // ============================================================
    // Session state
    // ============================================================

    /// Save session state for cold-start recovery
    pub fn saveSessionState(self: *Self, session_id: []const u8, current_task_id: ?TaskId, started_at: i64) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO session_state (id, session_id, current_task_id, started_at)
            \\VALUES (1, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, session_id);

        if (current_task_id) |tid| {
            try sqlite.bindText(stmt, 2, &tid);
        } else {
            try sqlite.bindNull(stmt, 2);
        }

        try sqlite.bindInt64(stmt, 3, started_at);

        _ = try sqlite.step(stmt);
    }

    /// Load session state
    pub fn loadSessionState(self: *Self) !?task_store.SessionState {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT session_id, current_task_id, started_at FROM session_state WHERE id = 1
        );
        defer sqlite.finalize(stmt);

        const rc = try sqlite.step(stmt);
        if (rc != sqlite.SQLITE_ROW) return null;

        const session_id = if (sqlite.columnText(stmt, 0)) |s|
            try self.allocator.dupe(u8, s)
        else
            return null;

        var current_task_id: ?TaskId = null;
        if (sqlite.columnType(stmt, 1) != sqlite.SQLITE_NULL) {
            if (sqlite.columnText(stmt, 1)) |tid_text| {
                if (tid_text.len >= 8) {
                    var tid: TaskId = undefined;
                    @memcpy(&tid, tid_text[0..8]);
                    current_task_id = tid;
                }
            }
        }

        return task_store.SessionState{
            .session_id = session_id,
            .current_task_id = current_task_id,
            .started_at = sqlite.columnInt64(stmt, 2),
        };
    }
};
