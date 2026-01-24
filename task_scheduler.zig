// Task Scheduler - Scheduling and session management extracted from TaskStore
// Provides ready queue computation, depth-first scheduling, and current task tracking
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const task_store = @import("task_store");
pub const TaskId = task_store.TaskId;
pub const TaskStatus = task_store.TaskStatus;
pub const TaskType = task_store.TaskType;
pub const Task = task_store.Task;
pub const DependencyType = task_store.DependencyType;

const task_db_module = @import("task_db");
pub const TaskDB = task_db_module.TaskDB;

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

/// Task scheduler - manages ready queue, session state, and task scheduling
/// Separated from TaskStore to follow Single Responsibility Principle
pub const TaskScheduler = struct {
    allocator: Allocator,
    db: *TaskDB,
    ready_cache_valid: bool,
    ready_cache: std.ArrayListUnmanaged(TaskId),

    // Session state for current task tracking
    current_task_id: ?TaskId = null,
    session_id: ?[]const u8 = null,
    session_started_at: ?i64 = null,

    const Self = @This();

    pub fn init(allocator: Allocator, db: *TaskDB) Self {
        return .{
            .allocator = allocator,
            .db = db,
            .ready_cache_valid = false,
            .ready_cache = .{},
            .current_task_id = null,
            .session_id = null,
            .session_started_at = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ready_cache.deinit(self.allocator);

        // Free session state
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
    }

    /// Invalidate the ready cache (called when task state changes)
    pub fn invalidateCache(self: *Self) void {
        self.ready_cache_valid = false;
    }

    /// Initialize a new session with a unique ID (transaction-safe)
    pub fn startSession(self: *Self) !void {
        // Clean up old session if any
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }

        // Wrap in transaction for atomicity
        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
            };
        }

        self.session_id = try generateSessionId(self.allocator);
        self.session_started_at = std.time.timestamp();
        self.current_task_id = null;

        // Persist to SQLite
        try self.db.saveSessionState(self.session_id.?, null, self.session_started_at.?);

        try self.db.commitTransaction();
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

    /// REQUIRE: task exists and is not a molecule
    /// ENSURE: task.status == .in_progress after success (if task was pending or in_progress)
    /// ENSURE: returns error.TaskNotStartable if task is blocked/completed/cancelled
    /// Set the current task explicitly (for start_task) - transaction-safe
    pub fn setCurrentTask(self: *Self, task_id: TaskId) !void {
        // Load task to verify existence, type, and status
        const task = try self.db.loadTask(task_id) orelse return error.TaskNotFound;
        defer {
            var t = task;
            t.deinit(self.allocator);
        }

        // Molecules cannot be set as current task
        if (task.task_type == .molecule) {
            return error.CannotSetMoleculeAsCurrent;
        }

        // Only pending or in_progress tasks can be started
        if (task.status != .pending and task.status != .in_progress) {
            return error.TaskNotStartable;
        }

        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
            };
        }

        self.current_task_id = task_id;

        // Update task status to in_progress if pending
        if (task.status == .pending) {
            try self.db.updateTaskStatus(task_id, .in_progress, null);
            self.ready_cache_valid = false;
        }

        // Persist session state
        if (self.session_id) |sid| {
            try self.db.saveSessionState(sid, self.current_task_id, self.session_started_at orelse std.time.timestamp());
        }

        try self.db.commitTransaction();
    }

    /// Pure query - returns current task without side effects
    /// IMPORTANT: Caller must free the returned Task via task.deinit(allocator)
    pub fn getCurrentTask(self: *Self) !?Task {
        return self.getCurrentTaskWithAllocator(self.allocator);
    }

    /// Pure query - returns current task if valid, null otherwise
    /// Does NOT modify current_task_id (CQS: query has no side effects)
    /// Call validateCurrentTask() first if you need to clean up stale state
    pub fn getCurrentTaskWithAllocator(self: *Self, alloc: Allocator) !?Task {
        const cid = self.current_task_id orelse return null;

        const task = try self.db.loadTaskWithAllocator(cid, alloc) orelse return null;

        // Only return if task is still workable and not a molecule
        if ((task.status == .in_progress or task.status == .pending) and
            task.task_type != .molecule)
        {
            return task;
        }

        // Task not valid for current - free and return null
        var t = task;
        t.deinit(alloc);
        return null;
    }

    /// Command - validate and clean up stale current task
    /// Sets current_task_id to null if task no longer exists, completed, or is a molecule
    pub fn validateCurrentTask(self: *Self) !void {
        const cid = self.current_task_id orelse return;

        if (try self.db.loadTask(cid)) |task| {
            defer {
                var t = task;
                t.deinit(self.allocator);
            }

            // Clear if task is no longer workable or is a molecule
            if (task.status != .in_progress and task.status != .pending) {
                self.current_task_id = null;
            } else if (task.task_type == .molecule) {
                self.current_task_id = null;
            }
        } else {
            // Task no longer exists
            self.current_task_id = null;
        }
    }

    /// Command - adopt an orphaned in_progress task as current
    /// Returns the adopted task ID if found, null otherwise
    pub fn adoptOrphanedTask(self: *Self) !?TaskId {
        // Only adopt if we don't already have a current task
        if (self.current_task_id != null) return null;

        const tasks = try self.db.listTasksWithAllocator(.{ .status = .in_progress }, self.allocator);
        defer {
            for (tasks) |*t| {
                var task = t.*;
                task.deinit(self.allocator);
            }
            self.allocator.free(tasks);
        }

        // Find first non-molecule in_progress task
        for (tasks) |task| {
            if (task.task_type != .molecule) {
                self.current_task_id = task.id;
                return task.id;
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

    /// ENSURE: Returns false for valid DAGs, true for cycles
    /// Check if adding a blocks dependency from src_id to dst_id would create a cycle
    /// Uses DFS: starts from dst_id and follows .blocks edges forward
    /// If we reach src_id, adding src->dst would create a cycle
    pub fn wouldCreateCycle(self: *Self, src_id: TaskId, dst_id: TaskId) !bool {
        // DFS from dst_id following .blocks edges
        // If we can reach src_id, adding src->dst would create a cycle
        var visited = std.AutoHashMap(TaskId, void).init(self.allocator);
        defer visited.deinit();

        var stack = std.ArrayListUnmanaged(TaskId){};
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, dst_id);

        while (stack.items.len > 0) {
            const last_idx = stack.items.len - 1;
            const current = stack.items[last_idx];
            _ = stack.orderedRemove(last_idx);

            // If we reached src_id, we found a cycle
            if (mem.eql(u8, &current, &src_id)) {
                return true;
            }

            if (visited.contains(current)) continue;
            try visited.put(current, {});

            // Get all tasks that current blocks (follow edges forward)
            const blocked_ids = try self.db.getBlockingTaskIds(current);
            defer self.allocator.free(blocked_ids);

            for (blocked_ids) |blocked_id| {
                if (!visited.contains(blocked_id)) {
                    try stack.append(self.allocator, blocked_id);
                }
            }
        }

        return false;
    }

    /// Get all ready tasks (pending with no blockers), sorted by priority
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getReadyTasks(self: *Self) ![]Task {
        return self.getReadyTasksWithAllocator(self.allocator);
    }

    /// Get all ready tasks with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getReadyTasksWithAllocator(self: *Self, alloc: Allocator) ![]Task {
        // Use cache if valid
        if (self.ready_cache_valid) {
            // Rebuild tasks from cached IDs
            return try self.db.getTasksByIdsWithAllocator(self.ready_cache.items, alloc);
        }

        // Cache miss: query SQLite for ready tasks
        const tasks = try self.db.getReadyTasksWithAllocator(alloc);

        // Update cache with IDs
        self.ready_cache.clearRetainingCapacity();
        for (tasks) |t| {
            try self.ready_cache.append(self.allocator, t.id);
        }
        self.ready_cache_valid = true;

        return tasks;
    }

    /// Handle current task clearing when task status changes to completed/cancelled/molecule
    pub fn handleTaskStatusChange(self: *Self, task_id: TaskId, new_status: TaskStatus, new_type: ?TaskType) void {
        // Clear current task if it was completed, cancelled, or converted to molecule
        if (self.current_task_id) |cid| {
            if (mem.eql(u8, &cid, &task_id)) {
                if (new_status == .completed or new_status == .cancelled) {
                    self.current_task_id = null;
                }
                if (new_type) |t| {
                    if (t == .molecule) {
                        self.current_task_id = null;
                    }
                }
            }
        }
        self.ready_cache_valid = false;
    }
};
