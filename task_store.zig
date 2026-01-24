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
    // Commit tracking for Tinkerer/Judge workflow
    started_at_commit: ?[]const u8 = null, // Captured when task is picked up (owned)
    completed_at_commit: ?[]const u8 = null, // Captured when submit_work is called (owned)

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
        // Free commit tracking fields
        if (self.started_at_commit) |c| allocator.free(c);
        if (self.completed_at_commit) |c| allocator.free(c);
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
    search: ?[]const u8 = null, // Text search in title/description (case-insensitive LIKE)
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

// Forward import for TaskDB
const task_db_module = @import("task_db");
pub const TaskDB = task_db_module.TaskDB;

// Import TaskScheduler for composition
const task_scheduler = @import("task_scheduler");
pub const TaskScheduler = task_scheduler.TaskScheduler;

/// Task store - thin facade over SQLite (single source of truth)
/// Composes TaskScheduler for scheduling logic (Single Responsibility Principle)
pub const TaskStore = struct {
    allocator: Allocator,
    db: *TaskDB, // Required reference to SQLite database
    scheduler: TaskScheduler, // Handles ready queue, session state, current task

    // Expose session state for backwards compatibility
    // Note: These accessors allow existing code using store.session_id to work
    // by providing getter methods that delegate to the scheduler
    pub fn getSessionId(self: *const Self) ?[]const u8 {
        return self.scheduler.session_id;
    }

    pub fn getSessionStartedAt(self: *const Self) ?i64 {
        return self.scheduler.session_started_at;
    }

    // Setter for session_id (used during session restore)
    pub fn setSessionIdDirect(self: *Self, sid: []const u8) !void {
        if (self.scheduler.session_id) |old| {
            self.allocator.free(old);
        }
        self.scheduler.session_id = try self.allocator.dupe(u8, sid);
    }

    const Self = @This();

    pub fn init(allocator: Allocator, db: *TaskDB) Self {
        return .{
            .allocator = allocator,
            .db = db,
            .scheduler = TaskScheduler.init(allocator, db),
        };
    }

    pub fn deinit(self: *Self) void {
        self.scheduler.deinit();
        // Note: TaskDB is owned by app.zig, not freed here
    }

    /// Initialize a new session with a unique ID (transaction-safe)
    pub fn startSession(self: *Self) !void {
        try self.scheduler.startSession();
    }

    /// Restore session state from cold start
    pub fn restoreSession(self: *Self, session_id: []const u8, current_task_id_param: ?TaskId, started_at: i64) !void {
        try self.scheduler.restoreSession(session_id, current_task_id_param, started_at);
    }

    /// Set the current task explicitly (for start_task) - transaction-safe
    pub fn setCurrentTask(self: *Self, task_id: TaskId) !void {
        try self.scheduler.setCurrentTask(task_id);
    }

    /// Set the started_at_commit for a task (commit tracking for Tinkerer workflow)
    pub fn setTaskStartedCommit(self: *Self, task_id: TaskId, commit_hash: []const u8) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }

        // Load current task to preserve completed_at_commit
        if (try self.db.loadTask(task_id)) |task| {
            defer {
                var t = task;
                t.deinit(self.allocator);
            }
            try self.db.updateCommitTracking(task_id, commit_hash, task.completed_at_commit);
        } else {
            try self.db.updateCommitTracking(task_id, commit_hash, null);
        }
    }

    /// Set the completed_at_commit for a task (commit tracking for submit_work)
    pub fn setTaskCompletedCommit(self: *Self, task_id: TaskId, commit_hash: []const u8) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }

        // Load current task to preserve started_at_commit
        if (try self.db.loadTask(task_id)) |task| {
            defer {
                var t = task;
                t.deinit(self.allocator);
            }
            try self.db.updateCommitTracking(task_id, task.started_at_commit, commit_hash);
        } else {
            try self.db.updateCommitTracking(task_id, null, commit_hash);
        }
    }

    /// Get the current task, with validation and orphan adoption for backwards compatibility
    /// Returns null if no tasks are ready
    /// IMPORTANT: Caller must free the returned Task via task.deinit(allocator)
    pub fn getCurrentTask(self: *Self) !?Task {
        // Validate and adopt for backwards compatibility (maintains original behavior)
        try self.scheduler.validateCurrentTask();
        _ = try self.scheduler.adoptOrphanedTask();
        return self.scheduler.getCurrentTask();
    }

    /// Get current task with specified allocator
    /// Validates and adopts orphaned tasks for backwards compatibility
    pub fn getCurrentTaskWithAllocator(self: *Self, alloc: Allocator) !?Task {
        // Validate and adopt for backwards compatibility (maintains original behavior)
        try self.scheduler.validateCurrentTask();
        _ = try self.scheduler.adoptOrphanedTask();
        return self.scheduler.getCurrentTaskWithAllocator(alloc);
    }

    /// Clear the current task (called before auto-advance)
    pub fn clearCurrentTask(self: *Self) void {
        self.scheduler.clearCurrentTask();
    }

    /// Get current task ID without auto-assignment
    pub fn getCurrentTaskId(self: *Self) ?TaskId {
        return self.scheduler.getCurrentTaskId();
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

    /// Create a new task (transaction-safe)
    pub fn createTask(self: *Self, params: CreateTaskParams) !TaskId {
        const now = std.time.timestamp();
        const id = generateId(params.title, now);

        // Check for ID collision (very rare) via SQLite
        if (try self.db.taskExists(id)) {
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

        var task = Task{
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

        // Start transaction for atomic task + dependency creation
        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
                // Don't panic - propagate original error, caller can handle recovery
            };
        }

        // Save to SQLite
        try self.db.saveTask(&task);

        // Free the task memory since SQLite owns the data now
        task.deinit(self.allocator);

        // Add blocking dependencies if specified (using internal method within transaction)
        if (params.blocks) |blocked_ids| {
            for (blocked_ids) |blocked_id| {
                try self.addDependencyInternal(id, blocked_id, .blocks);
            }
        }

        try self.db.commitTransaction();

        // Invalidate ready cache
        self.scheduler.invalidateCache();

        return id;
    }

    /// Get a task by ID (uses self.allocator)
    /// IMPORTANT: Caller must free the returned Task via task.deinit(allocator)
    /// When context.task_arena is set, prefer using getTaskWithAllocator with arena
    pub fn getTask(self: *Self, task_id: TaskId) !?Task {
        return try self.db.loadTask(task_id);
    }

    /// Get a task by ID with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getTaskWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) !?Task {
        return try self.db.loadTaskWithAllocator(task_id, alloc);
    }

    /// Update a task's status
    pub fn updateStatus(self: *Self, task_id: TaskId, new_status: TaskStatus) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }

        // Molecules can't be blocked - they're containers
        if (new_status == .blocked) {
            if (try self.db.loadTask(task_id)) |task| {
                defer {
                    var t = task;
                    t.deinit(self.allocator);
                }
                if (task.task_type == .molecule) {
                    return error.CannotBlockMolecule;
                }
            }
        }

        const completed_at: ?i64 = if (new_status == .completed) std.time.timestamp() else null;
        try self.db.updateTaskStatus(task_id, new_status, completed_at);

        // Notify scheduler of status change
        self.scheduler.handleTaskStatusChange(task_id, new_status, null);
    }

    /// Update task priority
    pub fn updatePriority(self: *Self, task_id: TaskId, new_priority: TaskPriority) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }
        try self.db.updateTaskPriority(task_id, new_priority);
    }

    /// Update task title
    pub fn updateTitle(self: *Self, task_id: TaskId, new_title: []const u8) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }
        try self.db.updateTaskTitle(task_id, new_title);
        self.scheduler.invalidateCache();
    }

    /// Update task type (cannot change to/from wisp)
    pub fn updateTaskType(self: *Self, task_id: TaskId, new_type: TaskType) !void {
        if (try self.db.loadTask(task_id)) |task| {
            defer {
                var t = task;
                t.deinit(self.allocator);
            }
            // Wisps are immutable - cannot change to or from wisp
            if (task.task_type == .wisp or new_type == .wisp) {
                return error.CannotChangeWispType;
            }
            try self.db.updateTaskType(task_id, new_type);

            // Notify scheduler of type change (clears current if molecule)
            self.scheduler.handleTaskStatusChange(task_id, task.status, new_type);
        } else {
            return error.TaskNotFound;
        }
    }

    /// Parameters for batch task update
    pub const UpdateTaskParams = struct {
        title: ?[]const u8 = null,
        priority: ?TaskPriority = null,
        task_type: ?TaskType = null,
        status: ?TaskStatus = null,
    };

    /// Batch update task properties in a single transaction
    /// Returns CompleteResult if status was changed to completed (with unblocked tasks), null otherwise
    pub fn updateTask(self: *Self, task_id: TaskId, params: UpdateTaskParams) !?CompleteResult {
        // Verify task exists and check wisp guard
        const task = (try self.db.loadTask(task_id)) orelse return error.TaskNotFound;
        defer {
            var t = task;
            t.deinit(self.allocator);
        }

        // Wisp guard - cannot update wisps
        if (task.task_type == .wisp) {
            return error.CannotUpdateWisp;
        }

        // Cannot change to/from wisp
        if (params.task_type) |new_type| {
            if (new_type == .wisp) {
                return error.CannotChangeWispType;
            }
        }

        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
                // Don't panic - propagate original error, caller can handle recovery
            };
        }

        // Apply updates
        if (params.title) |new_title| {
            try self.db.updateTaskTitle(task_id, new_title);
        }

        if (params.priority) |new_priority| {
            try self.db.updateTaskPriority(task_id, new_priority);
        }

        if (params.task_type) |new_type| {
            try self.db.updateTaskType(task_id, new_type);

            // Molecules can't be blocked - auto-unblock when converting
            if (new_type == .molecule and task.status == .blocked) {
                try self.db.updateTaskStatus(task_id, .pending, null);
            }

            // Notify scheduler of type change (clears current if molecule)
            self.scheduler.handleTaskStatusChange(task_id, task.status, new_type);
        }

        var result: ?CompleteResult = null;

        if (params.status) |new_status| {
            if (new_status == .completed) {
                // Handle completion with cascade unblocking
                const now = std.time.timestamp();
                try self.db.updateTaskStatus(task_id, .completed, now);

                // Notify scheduler of status change
                self.scheduler.handleTaskStatusChange(task_id, new_status, null);

                // Find tasks that become unblocked
                const unblocked_ids = try self.db.getNewlyUnblockedTasks(task_id);
                errdefer self.allocator.free(unblocked_ids);

                // Update unblocked tasks to pending
                for (unblocked_ids) |uid| {
                    try self.db.updateTaskStatus(uid, .pending, null);
                }

                result = .{
                    .task_id = task_id,
                    .unblocked = unblocked_ids,
                };
            } else {
                const completed_at: ?i64 = null;
                try self.db.updateTaskStatus(task_id, new_status, completed_at);

                // Notify scheduler of status change
                self.scheduler.handleTaskStatusChange(task_id, new_status, null);
            }
        }

        try self.db.commitTransaction();
        self.scheduler.invalidateCache();

        return result;
    }

    /// Add a comment to a task (Beads philosophy - append-only audit trail)
    pub fn addComment(self: *Self, task_id: TaskId, agent: []const u8, content: []const u8) !void {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }

        const comment = Comment{
            .agent = try self.allocator.dupe(u8, agent),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
        };
        defer {
            self.allocator.free(comment.agent);
            self.allocator.free(comment.content);
        }

        try self.db.appendComment(&task_id, comment);
    }

    /// Get the last comment from a specific agent (useful for checking latest feedback)
    /// IMPORTANT: Caller must free the returned Comment's agent and content fields
    pub fn getLastCommentFrom(self: *Self, task_id: TaskId, agent: []const u8) !?Comment {
        return try self.db.getLastCommentFrom(task_id, agent);
    }

    /// Get tasks that have comments containing a specific prefix (e.g., "BLOCKED:", "REJECTED:")
    /// Used by orchestration to find tasks needing attention
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getTasksWithCommentPrefix(self: *Self, prefix: []const u8) ![]Task {
        return try self.db.getTasksWithCommentPrefix(prefix);
    }

    /// Get tasks with comments containing a prefix with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getTasksWithCommentPrefixWithAllocator(self: *Self, prefix: []const u8, alloc: Allocator) ![]Task {
        return try self.db.getTasksWithCommentPrefixWithAllocator(prefix, alloc);
    }

    /// Count comments from a specific agent with a prefix (e.g., count rejections)
    pub fn countCommentsWithPrefix(self: *Self, task_id: TaskId, agent: []const u8, prefix: []const u8) !usize {
        return try self.db.countCommentsWithPrefix(task_id, agent, prefix);
    }

    /// Check if adding a blocks dependency from src_id to dst_id would create a cycle
    /// Delegates to TaskScheduler
    fn wouldCreateCycle(self: *Self, src_id: TaskId, dst_id: TaskId) !bool {
        return self.scheduler.wouldCreateCycle(src_id, dst_id);
    }

    /// Internal: Add a dependency between tasks (for use within existing transactions)
    /// Does NOT start a transaction - caller must manage transactions
    fn addDependencyInternal(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        // Verify both tasks exist
        if (!try self.db.taskExists(src_id)) return error.SourceTaskNotFound;
        if (!try self.db.taskExists(dst_id)) return error.DestTaskNotFound;

        // Prevent self-dependency
        if (mem.eql(u8, &src_id, &dst_id)) return error.SelfDependency;

        // Check for cycles (only for blocking dependencies)
        if (dep_type == .blocks) {
            if (try self.wouldCreateCycle(src_id, dst_id)) {
                return error.CircularDependency;
            }
        }

        // Save dependency to SQLite (handles duplicate check via UNIQUE constraint)
        const dep = Dependency{
            .src_id = src_id,
            .dst_id = dst_id,
            .dep_type = dep_type,
            .weight = 1.0,
        };
        self.db.saveDependency(&dep) catch |err| {
            // SQLite UNIQUE constraint violation = duplicate
            if (err == error.ConstraintViolation or err == error.SQLiteError) {
                return error.DependencyExists;
            }
            return err;
        };

        // Update destination task status if blocking
        if (dep_type.isBlocking()) {
            if (try self.db.loadTask(dst_id)) |task| {
                defer {
                    var t = task;
                    t.deinit(self.allocator);
                }
                if (task.status == .pending) {
                    try self.db.updateTaskStatus(dst_id, .blocked, null);
                }
            }
        }

        self.scheduler.invalidateCache();
    }

    /// Add a dependency between tasks (public API - transaction-safe)
    pub fn addDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
                // Don't panic - propagate original error, caller can handle recovery
            };
        }

        try self.addDependencyInternal(src_id, dst_id, dep_type);

        try self.db.commitTransaction();
    }

    /// Remove a dependency (transaction-safe)
    pub fn removeDependency(self: *Self, src_id: TaskId, dst_id: TaskId, dep_type: DependencyType) !void {
        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(err)});
                // Don't panic - propagate original error, caller can handle recovery
            };
        }

        // Delete from SQLite
        try self.db.deleteDependency(src_id, dst_id, dep_type);

        // Check if destination task should be unblocked
        if (dep_type.isBlocking()) {
            const blocked_count = try self.db.getBlockedByCount(dst_id);
            if (blocked_count == 0) {
                if (try self.db.loadTask(dst_id)) |task| {
                    defer {
                        var t = task;
                        t.deinit(self.allocator);
                    }
                    if (task.status == .blocked) {
                        try self.db.updateTaskStatus(dst_id, .pending, null);
                    }
                }
            }
        }

        try self.db.commitTransaction();
        self.scheduler.invalidateCache();
    }

    /// Complete a task and cascade to dependents
    /// If this was the current task, clears it (call getCurrentTask for auto-advance)
    pub fn completeTask(self: *Self, task_id: TaskId) !CompleteResult {
        if (!try self.db.taskExists(task_id)) {
            return error.TaskNotFound;
        }

        // Use transaction for atomicity
        try self.db.beginTransaction();
        errdefer {
            self.db.rollbackTransaction() catch |rollback_err| {
                std.log.err("CRITICAL: Rollback failed: {s}. Database may be in inconsistent state.", .{@errorName(rollback_err)});
                // Don't panic - propagate original error, caller can handle recovery
            };
        }

        const now = std.time.timestamp();

        // Mark task as completed
        try self.db.updateTaskStatus(task_id, .completed, now);

        // Notify scheduler of status change
        self.scheduler.handleTaskStatusChange(task_id, .completed, null);

        // Find tasks that become unblocked (no need to delete deps, filter at query time)
        const unblocked_ids = try self.db.getNewlyUnblockedTasks(task_id);
        errdefer self.allocator.free(unblocked_ids);

        // Update unblocked tasks to pending
        for (unblocked_ids) |uid| {
            try self.db.updateTaskStatus(uid, .pending, null);
        }

        try self.db.commitTransaction();

        self.scheduler.invalidateCache();

        return .{
            .task_id = task_id,
            .unblocked = unblocked_ids,
        };
    }

    /// Get tasks matching filter criteria
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn listTasks(self: *Self, filter: TaskFilter) ![]Task {
        return try self.db.listTasks(filter);
    }

    /// List tasks with optional filter using specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn listTasksWithAllocator(self: *Self, filter: TaskFilter, alloc: Allocator) ![]Task {
        return try self.db.listTasksWithAllocator(filter, alloc);
    }

    /// Get the current in_progress task (if any)
    /// IMPORTANT: Caller must free the returned Task via task.deinit(allocator)
    pub fn getCurrentInProgressTask(self: *Self) !?Task {
        return self.getCurrentInProgressTaskWithAllocator(self.allocator);
    }

    /// Get the current in_progress task with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getCurrentInProgressTaskWithAllocator(self: *Self, alloc: Allocator) !?Task {
        const tasks = try self.db.listTasksWithAllocator(.{ .status = .in_progress }, alloc);
        defer {
            // Free all except first (when not using arena, this matters)
            if (tasks.len > 1) {
                for (tasks[1..]) |*t| {
                    var task = t.*;
                    task.deinit(alloc);
                }
            }
            alloc.free(tasks);
        }

        if (tasks.len > 0) {
            // Return first, caller owns it
            return tasks[0];
        }
        return null;
    }

    /// Get all ready tasks (pending with no blockers), sorted by priority
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getReadyTasks(self: *Self) ![]Task {
        return self.scheduler.getReadyTasks();
    }

    /// Get all ready tasks with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getReadyTasksWithAllocator(self: *Self, alloc: Allocator) ![]Task {
        return self.scheduler.getReadyTasksWithAllocator(alloc);
    }

    /// Get count of tasks by status
    pub const TaskCounts = struct {
        pending: usize = 0,
        in_progress: usize = 0,
        completed: usize = 0,
        blocked: usize = 0,
    };

    pub fn getTaskCounts(self: *Self) !TaskCounts {
        return try self.db.getTaskCounts();
    }

    /// Get children of a molecule/epic (uses self.allocator)
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getChildren(self: *Self, parent_id: TaskId) ![]Task {
        return try self.db.getChildren(parent_id);
    }

    /// Get children of a molecule/epic with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getChildrenWithAllocator(self: *Self, parent_id: TaskId, alloc: Allocator) ![]Task {
        return try self.db.getChildrenWithAllocator(parent_id, alloc);
    }

    /// Get total task count
    pub fn count(self: *Self) !usize {
        const cnt = try self.db.getTaskCount();
        return @intCast(cnt);
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

    /// Get siblings (tasks with the same parent) - uses self.allocator
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getSiblings(self: *Self, task_id: TaskId) ![]Task {
        return try self.db.getSiblings(task_id);
    }

    /// Get siblings with specified allocator
    /// When used with arena allocator, no manual cleanup is needed
    pub fn getSiblingsWithAllocator(self: *Self, task_id: TaskId, alloc: Allocator) ![]Task {
        return try self.db.getSiblingsWithAllocator(task_id, alloc);
    }

    /// Get tasks that block a given task
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getBlockedBy(self: *Self, task_id: TaskId) ![]Task {
        return try self.db.getBlockedBy(task_id);
    }

    /// Get tasks that are blocked by a given task
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getBlocking(self: *Self, task_id: TaskId) ![]Task {
        return try self.db.getBlocking(task_id);
    }

    /// Traverse the dependency graph using BFS
    /// Returns all reachable tasks up to max_depth
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn traverseDependencies(self: *Self, start_id: TaskId, max_depth: usize, edge_type: ?[]const u8) ![]Task {
        // Load all dependencies from SQLite for BFS traversal
        const deps = try self.db.loadAllDependencies();
        defer self.allocator.free(deps);

        var result = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (result.items) |*t| t.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        var visited = std.AutoHashMap(TaskId, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayListUnmanaged(struct { id: TaskId, depth: usize }){};
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, .{ .id = start_id, .depth = 0 });
        try visited.put(start_id, {});

        if (try self.db.loadTask(start_id)) |t| {
            try result.append(self.allocator, t);
        }

        var idx: usize = 0;
        while (idx < queue.items.len) : (idx += 1) {
            const current = queue.items[idx];
            if (current.depth >= max_depth) continue;

            for (deps) |dep| {
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
                    if (try self.db.loadTask(neighbor_id)) |t| {
                        try result.append(self.allocator, t);
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

    /// IMPORTANT: Caller must free the returned EpicSummary.task via task.deinit(allocator)
    pub fn getEpicSummary(self: *Self, epic_id: TaskId) !?EpicSummary {
        const epic = try self.db.loadTask(epic_id) orelse return null;
        errdefer {
            var t = epic;
            t.deinit(self.allocator);
        }

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

        const summary = try self.db.getEpicSummary(epic_id);

        return EpicSummary{
            .task = epic,
            .total_children = summary.total_children,
            .completed_children = summary.completed_children,
            .blocked_children = summary.blocked_children,
            .in_progress_children = summary.in_progress_children,
            .completion_percent = summary.completion_percent,
        };
    }

    /// Get open tasks at a given depth from root (uses self.allocator)
    /// IMPORTANT: Caller must free each returned Task via task.deinit(allocator)
    pub fn getOpenAtDepth(self: *Self, max_depth: usize) ![]Task {
        return self.getOpenAtDepthWithAllocator(self.allocator, max_depth);
    }

    /// Get open tasks at a given depth from root with specified allocator
    /// When used with an arena allocator, no manual cleanup is needed - just deinit the arena
    /// This is the recommended approach for safer memory management
    pub fn getOpenAtDepthWithAllocator(self: *Self, alloc: Allocator, max_depth: usize) ![]Task {
        var result = std.ArrayListUnmanaged(Task){};
        errdefer {
            for (result.items) |*t| t.deinit(alloc);
            result.deinit(alloc);
        }

        // Find root molecules (no parent)
        // Note: loadAllTasks uses self.allocator internally for query temps,
        // but task data is allocated with the provided allocator
        const all_tasks = try self.db.loadAllTasks();
        defer {
            for (all_tasks) |*t| {
                var task = t.*;
                task.deinit(self.allocator);
            }
            self.allocator.free(all_tasks);
        }

        var roots = std.ArrayListUnmanaged(TaskId){};
        defer roots.deinit(alloc);

        for (all_tasks) |task| {
            if (task.parent_id == null and task.task_type == .molecule) {
                try roots.append(alloc, task.id);
            }
        }

        // BFS from roots to find open tasks at depth
        var visited = std.AutoHashMap(TaskId, void).init(alloc);
        defer visited.deinit();

        var queue = std.ArrayListUnmanaged(struct { id: TaskId, depth: usize }){};
        defer queue.deinit(alloc);

        for (roots.items) |root_id| {
            try queue.append(alloc, .{ .id = root_id, .depth = 0 });
            try visited.put(root_id, {});
        }

        var idx: usize = 0;
        while (idx < queue.items.len) : (idx += 1) {
            const current = queue.items[idx];

            if (current.depth <= max_depth) {
                if (try self.db.loadTaskWithAllocator(current.id, alloc)) |task| {
                    if (task.status == .pending or task.status == .in_progress) {
                        if (task.task_type != .molecule or current.depth == max_depth) {
                            try result.append(alloc, task);
                        } else {
                            var t = task;
                            t.deinit(alloc);
                        }
                    } else {
                        var t = task;
                        t.deinit(alloc);
                    }
                }
            }

            if (current.depth < max_depth) {
                // Get children
                const children = try self.getChildrenWithAllocator(current.id, alloc);
                defer {
                    for (children) |*c| {
                        var child = c.*;
                        child.deinit(alloc);
                    }
                    alloc.free(children);
                }

                for (children) |child| {
                    if (!visited.contains(child.id)) {
                        try visited.put(child.id, {});
                        try queue.append(alloc, .{ .id = child.id, .depth = current.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(alloc);
    }
};

// Tests require TaskDB (SQLite) - these are integration tests
// Run with: zig build test-integration
// TODO: Convert to integration tests with temp database
//
// test "TaskStore basic operations" {
//     const allocator = std.testing.allocator;
//     // Need to create TaskDB with temp file for testing
// }
//
// test "TaskStore dependencies" {
//     const allocator = std.testing.allocator;
//     // Need to create TaskDB with temp file for testing
// }
//
// test "TaskStore ready query" {
//     const allocator = std.testing.allocator;
//     // Need to create TaskDB with temp file for testing
// }
