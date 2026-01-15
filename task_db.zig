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

pub const TaskDB = struct {
    db: *sqlite.Db,
    allocator: Allocator,

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

    /// Create database schema
    fn createSchema(self: *Self) !void {
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

        // Comments table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS task_comments (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    task_id TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    author TEXT,
            \\    created_at INTEGER NOT NULL,
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

        // Set schema version
        try self.setMetadata("schema_version", "1");
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

        const labels_str = try self.allocator.dupeZ(u8, labels_json.items);
        defer self.allocator.free(labels_str);

        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO tasks (
            \\    id, title, description, status, priority, task_type,
            \\    labels, created_at, updated_at, completed_at, parent_id
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        // Bind task ID
        const id_str = try self.allocator.dupeZ(u8, &task.id);
        defer self.allocator.free(id_str);
        try sqlite.bindText(stmt, 1, id_str);

        // Bind title
        const title_z = try self.allocator.dupeZ(u8, task.title);
        defer self.allocator.free(title_z);
        try sqlite.bindText(stmt, 2, title_z);

        // Bind description
        if (task.description) |desc| {
            const desc_z = try self.allocator.dupeZ(u8, desc);
            defer self.allocator.free(desc_z);
            try sqlite.bindText(stmt, 3, desc_z);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        // Bind status
        const status_str = try self.allocator.dupeZ(u8, task.status.toString());
        defer self.allocator.free(status_str);
        try sqlite.bindText(stmt, 4, status_str);

        // Bind priority
        try sqlite.bindInt64(stmt, 5, task.priority.toInt());

        // Bind task_type
        const type_str = try self.allocator.dupeZ(u8, task.task_type.toString());
        defer self.allocator.free(type_str);
        try sqlite.bindText(stmt, 6, type_str);

        // Bind labels JSON
        try sqlite.bindText(stmt, 7, labels_str);

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
            const pid_str = try self.allocator.dupeZ(u8, &pid);
            defer self.allocator.free(pid_str);
            try sqlite.bindText(stmt, 11, pid_str);
        } else {
            try sqlite.bindNull(stmt, 11);
        }

        _ = try sqlite.step(stmt);
    }

    /// Load a task from the database by ID
    pub fn loadTask(self: *Self, task_id: TaskId) !?Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id
            \\FROM tasks WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        const id_str = try self.allocator.dupeZ(u8, &task_id);
        defer self.allocator.free(id_str);
        try sqlite.bindText(stmt, 1, id_str);

        const rc = try sqlite.step(stmt);
        if (rc != sqlite.SQLITE_ROW) {
            return null;
        }

        return try self.taskFromRow(stmt);
    }

    /// Load all tasks from the database
    pub fn loadAllTasks(self: *Self) ![]Task {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, title, description, status, priority, task_type,
            \\       labels, created_at, updated_at, completed_at, parent_id
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

    /// Parse a task from a SQLite row
    fn taskFromRow(self: *Self, stmt: *sqlite.Stmt) !Task {
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
            try self.allocator.dupe(u8, t)
        else
            return error.InvalidTaskData;

        // Description (column 2)
        const description = if (sqlite.columnType(stmt, 2) != sqlite.SQLITE_NULL)
            if (sqlite.columnText(stmt, 2)) |d|
                try self.allocator.dupe(u8, d)
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
                            const label = try self.allocator.dupe(u8, labels_json[s..i]);
                            try labels.append(self.allocator, label);
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

        return Task{
            .id = id,
            .title = title,
            .description = description,
            .status = status,
            .priority = priority,
            .task_type = task_type,
            .labels = try labels.toOwnedSlice(self.allocator),
            .created_at = created_at,
            .updated_at = updated_at,
            .completed_at = completed_at,
            .parent_id = parent_id,
            .blocked_by_count = 0, // Will be recalculated when loading dependencies
        };
    }

    /// Delete a task from the database
    pub fn deleteTask(self: *Self, task_id: TaskId) !void {
        const stmt = try sqlite.prepare(self.db, "DELETE FROM tasks WHERE id = ?");
        defer sqlite.finalize(stmt);

        const id_str = try self.allocator.dupeZ(u8, &task_id);
        defer self.allocator.free(id_str);
        try sqlite.bindText(stmt, 1, id_str);

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

        const src_str = try self.allocator.dupeZ(u8, &dep.src_id);
        defer self.allocator.free(src_str);
        try sqlite.bindText(stmt, 1, src_str);

        const dst_str = try self.allocator.dupeZ(u8, &dep.dst_id);
        defer self.allocator.free(dst_str);
        try sqlite.bindText(stmt, 2, dst_str);

        const type_str = try self.allocator.dupeZ(u8, dep.dep_type.toString());
        defer self.allocator.free(type_str);
        try sqlite.bindText(stmt, 3, type_str);

        // Bind weight as text since we need to handle floats
        var weight_buf: [32]u8 = undefined;
        const weight_str = try std.fmt.bufPrint(&weight_buf, "{d:.2}", .{dep.weight});
        const weight_z = try self.allocator.dupeZ(u8, weight_str);
        defer self.allocator.free(weight_z);
        try sqlite.bindText(stmt, 4, weight_z);

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
    pub fn deleteDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        const stmt = try sqlite.prepare(self.db,
            \\DELETE FROM task_dependencies WHERE src_id = ? AND dst_id = ? AND dep_type = ?
        );
        defer sqlite.finalize(stmt);

        const src_str = try self.allocator.dupeZ(u8, &src_id);
        defer self.allocator.free(src_str);
        try sqlite.bindText(stmt, 1, src_str);

        const dst_str = try self.allocator.dupeZ(u8, &dst_id);
        defer self.allocator.free(dst_str);
        try sqlite.bindText(stmt, 2, dst_str);

        const type_str = try self.allocator.dupeZ(u8, dep_type.toString());
        defer self.allocator.free(type_str);
        try sqlite.bindText(stmt, 3, type_str);

        _ = try sqlite.step(stmt);
    }

    /// Set a metadata key-value pair
    fn setMetadata(self: *Self, key: []const u8, value: []const u8) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO task_db_metadata (key, value) VALUES (?, ?)
        );
        defer sqlite.finalize(stmt);

        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        try sqlite.bindText(stmt, 1, key_z);

        const value_z = try self.allocator.dupeZ(u8, value);
        defer self.allocator.free(value_z);
        try sqlite.bindText(stmt, 2, value_z);

        _ = try sqlite.step(stmt);
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "BEGIN TRANSACTION");
    }

    /// Commit a transaction
    pub fn commitTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "COMMIT");
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "ROLLBACK");
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

    /// Load all tasks and dependencies from SQLite directly into a TaskStore
    /// Returns the number of tasks loaded
    pub fn loadIntoStore(self: *Self, store: *task_store.TaskStore) !usize {
        var count: usize = 0;

        // Load all tasks
        const tasks = try self.loadAllTasks();
        defer self.allocator.free(tasks);

        for (tasks) |task| {
            // Skip if task already exists (collision check)
            if (store.tasks.contains(task.id)) {
                // Free the task's owned memory since we're not using it
                var t = task;
                t.deinit(self.allocator);
                continue;
            }

            // Transfer ownership to store
            try store.tasks.put(task.id, task);
            count += 1;
        }

        // Load all dependencies
        const deps = try self.loadAllDependencies();
        defer self.allocator.free(deps);

        for (deps) |dep| {
            // Only add if both tasks exist in store
            if (store.tasks.contains(dep.src_id) and store.tasks.contains(dep.dst_id)) {
                try store.dependencies.append(store.allocator, dep);

                // Update blocked_by_count for blocking dependencies
                if (dep.dep_type.isBlocking()) {
                    if (store.tasks.getPtr(dep.dst_id)) |dst_task| {
                        dst_task.blocked_by_count += 1;
                    }
                }
            }
        }

        // Invalidate ready cache since we loaded tasks
        store.ready_cache_valid = false;

        return count;
    }

    /// Save all tasks and dependencies from a TaskStore to SQLite
    pub fn saveFromStore(self: *Self, store: *task_store.TaskStore) !void {
        // Use a transaction for atomicity
        try self.beginTransaction();
        errdefer self.rollbackTransaction() catch {};

        // Save all tasks
        var task_iter = store.tasks.valueIterator();
        while (task_iter.next()) |task| {
            try self.saveTask(task);
        }

        // Save all dependencies
        for (store.dependencies.items) |dep| {
            try self.saveDependency(&dep);
        }

        try self.commitTransaction();
    }
};
