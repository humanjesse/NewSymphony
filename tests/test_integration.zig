// Integration Test Suite - Cross-component functionality
// Run with: zig build test-integration
//
// Tests how components work together:
// 1. Task Lifecycle: Create → Start → Complete (task_store + task_db)
// 2. Dependency State: Add dependency → Ready state updates (dependency logic)
// 3. JSONL Sync: Export → Import → Data integrity (git_sync + task_db)

const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const task_store = @import("task_store");
const task_db = @import("task_db");
const git_sync = @import("git_sync");

const TaskStore = task_store.TaskStore;
const TaskDB = task_db.TaskDB;
const Task = task_store.Task;
const TaskId = task_store.TaskId;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;
const CreateTaskParams = task_store.CreateTaskParams;
const DependencyType = task_store.DependencyType;
const GitSync = git_sync.GitSync;

// ============================================================
// Test Fixture
// ============================================================

/// Test context that manages DB, Store, and GitSync lifecycle
const IntegrationFixture = struct {
    allocator: std.mem.Allocator,
    db: *TaskDB,
    store: *TaskStore,
    git_sync: ?*GitSync,
    temp_dir: ?[]const u8,

    fn init(allocator: std.mem.Allocator) !IntegrationFixture {
        // Create TaskDB with in-memory SQLite
        const db = try allocator.create(TaskDB);
        errdefer allocator.destroy(db);
        db.* = try TaskDB.init(allocator, ":memory:");
        errdefer db.deinit();

        // Create TaskStore that wraps the DB
        const store = try allocator.create(TaskStore);
        store.* = TaskStore.init(allocator, db);

        return IntegrationFixture{
            .allocator = allocator,
            .db = db,
            .store = store,
            .git_sync = null,
            .temp_dir = null,
        };
    }

    /// Initialize with GitSync for export/import tests
    fn initWithGitSync(allocator: std.mem.Allocator) !IntegrationFixture {
        var fixture = try init(allocator);
        errdefer fixture.deinit();

        // Create a unique temp directory for this test
        const timestamp = std.time.timestamp();
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/test_integration_{d}", .{timestamp});
        errdefer allocator.free(temp_dir);

        // Create the temp directory
        fs.cwd().makeDir(temp_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create GitSync
        const sync = try allocator.create(GitSync);
        errdefer allocator.destroy(sync);
        sync.* = try GitSync.init(allocator, temp_dir);

        fixture.git_sync = sync;
        fixture.temp_dir = temp_dir;

        return fixture;
    }

    fn deinit(self: *IntegrationFixture) void {
        // Clean up GitSync
        if (self.git_sync) |sync| {
            sync.deinit();
            self.allocator.destroy(sync);
        }

        // Clean up temp directory
        if (self.temp_dir) |dir| {
            // Remove .tasks directory and its contents
            const tasks_dir = std.fmt.allocPrint(self.allocator, "{s}/.tasks", .{dir}) catch {
                self.allocator.free(dir);
                self.store.deinit();
                self.allocator.destroy(self.store);
                self.db.deinit();
                self.allocator.destroy(self.db);
                return;
            };
            defer self.allocator.free(tasks_dir);

            // Delete files in .tasks/
            if (fs.cwd().openDir(tasks_dir, .{ .iterate = true })) |*d| {
                var dir_handle = d.*;
                var iter = dir_handle.iterate();
                while (iter.next() catch null) |entry| {
                    dir_handle.deleteFile(entry.name) catch {};
                }
                dir_handle.close();
                fs.cwd().deleteDir(tasks_dir) catch {};
            } else |_| {}

            // Delete temp directory
            fs.cwd().deleteDir(dir) catch {};
            self.allocator.free(dir);
        }

        self.store.deinit();
        self.allocator.destroy(self.store);
        self.db.deinit();
        self.allocator.destroy(self.db);
    }
};

// ============================================================
// Integration Test 1: Task Lifecycle
// Create task → Start task → Complete task
// ============================================================

test "Integration: Full task lifecycle - create, start, complete" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    // Start a session
    try fixture.store.startSession();
    try testing.expect(fixture.store.getSessionId() != null);

    // Step 1: Create a task
    const task_id = try fixture.store.createTask(.{
        .title = "Implement feature X",
        .description = "Full implementation of feature X with tests",
        .priority = .high,
        .task_type = .feature,
    });

    // Verify task was created with pending status
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);

        try testing.expectEqualStrings("Implement feature X", task.title);
        try testing.expectEqual(TaskStatus.pending, task.status);
        try testing.expectEqual(TaskPriority.high, task.priority);
        try testing.expectEqual(TaskType.feature, task.task_type);
        try testing.expect(task.completed_at == null);
    }

    // Verify task count in DB
    try testing.expectEqual(@as(usize, 1), try fixture.store.count());

    // Verify task is in ready queue
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 1), ready.len);
        try testing.expectEqual(task_id, ready[0].id);
    }

    // Step 2: Start the task
    try fixture.store.setCurrentTask(task_id);

    // Verify task is now in_progress
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);

        try testing.expectEqual(TaskStatus.in_progress, task.status);
    }

    // Verify it's no longer in ready queue
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 0), ready.len);
    }

    // Verify it's the current task
    try testing.expectEqual(task_id, fixture.store.getCurrentTaskId().?);

    // Add a comment while working
    try fixture.store.addComment(task_id, "Developer", "Started implementation");

    // Step 3: Complete the task
    const result = try fixture.store.completeTask(task_id);
    defer allocator.free(result.unblocked);

    // Verify task is completed
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);

        try testing.expectEqual(TaskStatus.completed, task.status);
        try testing.expect(task.completed_at != null);

        // Verify comment was preserved
        try testing.expectEqual(@as(usize, 1), task.comments.len);
        try testing.expectEqualStrings("Developer", task.comments[0].agent);
    }

    // Verify current task was cleared
    try testing.expect(fixture.store.getCurrentTaskId() == null);

    // Verify task counts
    const counts = try fixture.store.getTaskCounts();
    try testing.expectEqual(@as(usize, 0), counts.pending);
    try testing.expectEqual(@as(usize, 0), counts.in_progress);
    try testing.expectEqual(@as(usize, 1), counts.completed);
}

test "Integration: Task lifecycle with updateTask batch operations" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    // Create task
    const task_id = try fixture.store.createTask(.{
        .title = "Original Task",
        .priority = .low,
    });

    // Batch update: change title, priority, and status to in_progress
    _ = try fixture.store.updateTask(task_id, .{
        .title = "Renamed Task",
        .priority = .critical,
        .status = .in_progress,
    });

    // Verify all changes applied atomically
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);

        try testing.expectEqualStrings("Renamed Task", task.title);
        try testing.expectEqual(TaskPriority.critical, task.priority);
        try testing.expectEqual(TaskStatus.in_progress, task.status);
    }

    // Complete via updateTask
    const result = try fixture.store.updateTask(task_id, .{
        .status = .completed,
    });

    try testing.expect(result != null);
    defer if (result) |r| allocator.free(r.unblocked);

    // Verify completed
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.completed, task.status);
        try testing.expect(task.completed_at != null);
    }
}

// ============================================================
// Integration Test 2: Dependency State Updates
// Add dependency → Check ready state updates
// ============================================================

test "Integration: Dependency chain with cascade unblocking" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    // Create a dependency chain: A blocks B, B blocks C
    const task_a = try fixture.store.createTask(.{ .title = "Task A - Foundation" });
    const task_b = try fixture.store.createTask(.{ .title = "Task B - Building" });
    const task_c = try fixture.store.createTask(.{ .title = "Task C - Final" });

    // Initially all tasks are pending and ready (no dependencies yet)
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 3), ready.len);
    }

    // Add dependency: A blocks B
    try fixture.store.addDependency(task_a, task_b, .blocks);

    // Verify: A is ready, B is blocked, C is ready
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 2), ready.len);

        // Check B is blocked
        var task_b_loaded = (try fixture.store.getTask(task_b)).?;
        defer task_b_loaded.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task_b_loaded.status);
    }

    // Add dependency: B blocks C
    try fixture.store.addDependency(task_b, task_c, .blocks);

    // Verify: A is ready, B is blocked, C is blocked
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 1), ready.len);
        try testing.expectEqualStrings("Task A - Foundation", ready[0].title);

        // Verify blocked counts
        const counts = try fixture.store.getTaskCounts();
        try testing.expectEqual(@as(usize, 1), counts.pending); // A
        try testing.expectEqual(@as(usize, 2), counts.blocked); // B, C
    }

    // Complete A - should unblock B only (not C yet)
    const result_a = try fixture.store.completeTask(task_a);
    defer allocator.free(result_a.unblocked);

    try testing.expectEqual(@as(usize, 1), result_a.unblocked.len);
    try testing.expectEqual(task_b, result_a.unblocked[0]);

    // Verify: B is now pending/ready, C is still blocked
    {
        var task_b_loaded = (try fixture.store.getTask(task_b)).?;
        defer task_b_loaded.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task_b_loaded.status);

        var task_c_loaded = (try fixture.store.getTask(task_c)).?;
        defer task_c_loaded.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task_c_loaded.status);
    }

    // Complete B - should unblock C
    const result_b = try fixture.store.completeTask(task_b);
    defer allocator.free(result_b.unblocked);

    try testing.expectEqual(@as(usize, 1), result_b.unblocked.len);
    try testing.expectEqual(task_c, result_b.unblocked[0]);

    // Verify: C is now pending/ready
    {
        var task_c_loaded = (try fixture.store.getTask(task_c)).?;
        defer task_c_loaded.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task_c_loaded.status);

        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 1), ready.len);
        try testing.expectEqualStrings("Task C - Final", ready[0].title);
    }
}

test "Integration: Multiple blockers - task unblocks only when ALL blockers complete" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    // Create tasks: blocker1 and blocker2 both block target
    const blocker1 = try fixture.store.createTask(.{ .title = "Blocker 1" });
    const blocker2 = try fixture.store.createTask(.{ .title = "Blocker 2" });
    const target = try fixture.store.createTask(.{ .title = "Target Task" });

    // Add both dependencies
    try fixture.store.addDependency(blocker1, target, .blocks);
    try fixture.store.addDependency(blocker2, target, .blocks);

    // Verify target is blocked with count of 2
    {
        const blocked_count = try fixture.db.getBlockedByCount(target);
        try testing.expectEqual(@as(usize, 2), blocked_count);

        var task = (try fixture.store.getTask(target)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Complete blocker1 - target should still be blocked
    const result1 = try fixture.store.completeTask(blocker1);
    defer allocator.free(result1.unblocked);

    try testing.expectEqual(@as(usize, 0), result1.unblocked.len);

    {
        const blocked_count = try fixture.db.getBlockedByCount(target);
        try testing.expectEqual(@as(usize, 1), blocked_count);

        var task = (try fixture.store.getTask(target)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Complete blocker2 - now target should unblock
    const result2 = try fixture.store.completeTask(blocker2);
    defer allocator.free(result2.unblocked);

    try testing.expectEqual(@as(usize, 1), result2.unblocked.len);
    try testing.expectEqual(target, result2.unblocked[0]);

    {
        var task = (try fixture.store.getTask(target)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

test "Integration: Remove dependency unblocks task immediately" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    const blocker = try fixture.store.createTask(.{ .title = "Blocker" });
    const blocked = try fixture.store.createTask(.{ .title = "Blocked" });

    // Add dependency
    try fixture.store.addDependency(blocker, blocked, .blocks);

    // Verify blocked
    {
        var task = (try fixture.store.getTask(blocked)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Remove dependency
    try fixture.store.removeDependency(blocker, blocked, .blocks);

    // Verify immediately unblocked (without completing blocker)
    {
        var task = (try fixture.store.getTask(blocked)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }

    // Both should be in ready queue
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 2), ready.len);
    }
}

test "Integration: Ready queue respects priority ordering" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.init(allocator);
    defer fixture.deinit();

    // Create blocker
    const blocker = try fixture.store.createTask(.{
        .title = "Blocker",
        .priority = .wishlist, // Lowest priority
    });

    // Create blocked tasks with different priorities
    const high_prio = try fixture.store.createTask(.{
        .title = "High Priority",
        .priority = .high,
    });
    const critical_prio = try fixture.store.createTask(.{
        .title = "Critical Priority",
        .priority = .critical,
    });

    // Block both
    try fixture.store.addDependency(blocker, high_prio, .blocks);
    try fixture.store.addDependency(blocker, critical_prio, .blocks);

    // Only blocker is ready
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 1), ready.len);
        try testing.expectEqualStrings("Blocker", ready[0].title);
    }

    // Complete blocker - both should unblock
    const result = try fixture.store.completeTask(blocker);
    defer allocator.free(result.unblocked);

    try testing.expectEqual(@as(usize, 2), result.unblocked.len);

    // Verify ready queue is sorted by priority (critical first)
    {
        const ready = try fixture.store.getReadyTasks();
        defer {
            for (ready) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(ready);
        }
        try testing.expectEqual(@as(usize, 2), ready.len);
        try testing.expectEqual(TaskPriority.critical, ready[0].priority);
        try testing.expectEqual(TaskPriority.high, ready[1].priority);
    }
}

// ============================================================
// Integration Test 3: JSONL Export/Import
// Export to JSONL → Import back → Data matches
// ============================================================

test "Integration: Export tasks to JSONL and import back" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.initWithGitSync(allocator);
    defer fixture.deinit();

    const sync = fixture.git_sync.?;

    // Create various tasks with different attributes
    const task1_id = try fixture.store.createTask(.{
        .title = "Task One",
        .description = "First task description",
        .priority = .critical,
        .task_type = .bug,
    });

    const task2_id = try fixture.store.createTask(.{
        .title = "Task Two",
        .priority = .low,
        .task_type = .feature,
    });

    const labels = [_][]const u8{ "backend", "urgent" };
    const task3_id = try fixture.store.createTask(.{
        .title = "Task Three With Labels",
        .labels = &labels,
    });

    // Add comments to task1
    try fixture.store.addComment(task1_id, "Developer", "Started working on this");
    try fixture.store.addComment(task1_id, "Reviewer", "Needs more tests");

    // Complete task2
    _ = try fixture.store.completeTask(task2_id);

    // Export tasks to JSONL
    try sync.exportTasks(fixture.store);

    // Verify file was created
    const tasks_path = try std.fmt.allocPrint(allocator, "{s}/.tasks/tasks.jsonl", .{fixture.temp_dir.?});
    defer allocator.free(tasks_path);

    const file = try fs.cwd().openFile(tasks_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify JSONL has 3 lines (one per task)
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), line_count);

    // Now test import: Create a fresh DB and import
    var import_db = try TaskDB.init(allocator, ":memory:");
    defer import_db.deinit();

    const imported = try sync.importTasks(&import_db);
    try testing.expectEqual(@as(usize, 3), imported);

    // Verify imported tasks match original
    {
        var task1 = (try import_db.loadTask(task1_id)).?;
        defer task1.deinit(allocator);

        try testing.expectEqualStrings("Task One", task1.title);
        try testing.expectEqualStrings("First task description", task1.description.?);
        try testing.expectEqual(TaskPriority.critical, task1.priority);
        try testing.expectEqual(TaskType.bug, task1.task_type);

        // Verify comments were preserved
        try testing.expectEqual(@as(usize, 2), task1.comments.len);
        try testing.expectEqualStrings("Developer", task1.comments[0].agent);
        try testing.expectEqualStrings("Reviewer", task1.comments[1].agent);
    }

    {
        var task2 = (try import_db.loadTask(task2_id)).?;
        defer task2.deinit(allocator);

        try testing.expectEqual(TaskStatus.completed, task2.status);
        try testing.expect(task2.completed_at != null);
    }

    {
        var task3 = (try import_db.loadTask(task3_id)).?;
        defer task3.deinit(allocator);

        try testing.expectEqual(@as(usize, 2), task3.labels.len);
        try testing.expectEqualStrings("backend", task3.labels[0]);
        try testing.expectEqualStrings("urgent", task3.labels[1]);
    }
}

test "Integration: Export and import dependencies" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.initWithGitSync(allocator);
    defer fixture.deinit();

    const sync = fixture.git_sync.?;

    // Create tasks with dependencies
    const parent = try fixture.store.createTask(.{
        .title = "Parent Task",
        .task_type = .molecule,
    });
    const child = try fixture.store.createTask(.{
        .title = "Child Task",
        .parent_id = parent,
    });

    const blocker = try fixture.store.createTask(.{ .title = "Blocker" });
    const blocked = try fixture.store.createTask(.{ .title = "Blocked" });

    try fixture.store.addDependency(blocker, blocked, .blocks);

    // Export both tasks and dependencies
    try sync.exportTasks(fixture.store);
    try sync.exportDependencies(fixture.store);

    // Verify dependencies file
    const deps_path = try std.fmt.allocPrint(allocator, "{s}/.tasks/dependencies.jsonl", .{fixture.temp_dir.?});
    defer allocator.free(deps_path);

    const file = try fs.cwd().openFile(deps_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Should have 1 blocking dependency
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), line_count);

    // Import into fresh DB
    var import_db = try TaskDB.init(allocator, ":memory:");
    defer import_db.deinit();

    _ = try sync.importTasks(&import_db);

    // Verify parent-child relationship via parent_id
    {
        var child_task = (try import_db.loadTask(child)).?;
        defer child_task.deinit(allocator);
        try testing.expect(child_task.parent_id != null);
        try testing.expectEqual(parent, child_task.parent_id.?);
    }

    // Verify blocked count
    // Note: After importing deps, blocked should have 1 blocker
    const blocked_count = try import_db.getBlockedByCount(blocked);
    try testing.expectEqual(@as(usize, 1), blocked_count);
}

test "Integration: Full sync cycle preserves all data" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.initWithGitSync(allocator);
    defer fixture.deinit();

    const sync = fixture.git_sync.?;

    // Create a complex task graph
    try fixture.store.startSession();

    const epic = try fixture.store.createTask(.{
        .title = "Epic: Implement Auth System",
        .task_type = .molecule,
        .priority = .high,
    });

    const subtask1 = try fixture.store.createTask(.{
        .title = "Design auth API",
        .parent_id = epic,
        .task_type = .task,
    });

    const subtask2 = try fixture.store.createTask(.{
        .title = "Implement login",
        .parent_id = epic,
    });

    // subtask1 blocks subtask2
    try fixture.store.addDependency(subtask1, subtask2, .blocks);

    // Start subtask1
    try fixture.store.setCurrentTask(subtask1);

    // Add comments
    try fixture.store.addComment(subtask1, "Architect", "Using JWT tokens");

    // Full sync
    try sync.syncAll(fixture.store);

    // Import into fresh DB and Store
    var import_db = try TaskDB.init(allocator, ":memory:");
    defer import_db.deinit();

    var import_store_ptr = try allocator.create(TaskStore);
    defer {
        import_store_ptr.deinit();
        allocator.destroy(import_store_ptr);
    }
    import_store_ptr.* = TaskStore.init(allocator, &import_db);

    _ = try sync.importTasks(&import_db);

    // Verify epic structure
    {
        const children = try import_db.getChildren(epic);
        defer {
            for (children) |*c| {
                var child = c.*;
                child.deinit(allocator);
            }
            allocator.free(children);
        }
        try testing.expectEqual(@as(usize, 2), children.len);
    }

    // Verify task statuses
    {
        var task1 = (try import_db.loadTask(subtask1)).?;
        defer task1.deinit(allocator);
        try testing.expectEqual(TaskStatus.in_progress, task1.status);
        try testing.expectEqual(@as(usize, 1), task1.comments.len);
    }

    {
        var task2 = (try import_db.loadTask(subtask2)).?;
        defer task2.deinit(allocator);
        // Blocked because subtask1 is not completed
        const blocked_count = try import_db.getBlockedByCount(subtask2);
        try testing.expectEqual(@as(usize, 1), blocked_count);
    }

    // Verify epic summary via import_db
    const summary = try import_db.getEpicSummary(epic);
    try testing.expectEqual(@as(usize, 2), summary.total_children);
    try testing.expectEqual(@as(usize, 0), summary.completed_children);
    try testing.expectEqual(@as(usize, 1), summary.in_progress_children);
}

// ============================================================
// Edge Case Tests
// ============================================================

test "Integration: Import skips duplicate tasks" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.initWithGitSync(allocator);
    defer fixture.deinit();

    const sync = fixture.git_sync.?;

    // Create and export a task
    _ = try fixture.store.createTask(.{ .title = "Unique Task" });
    try sync.exportTasks(fixture.store);

    // Import into a DB that already has the task
    const first_import = try sync.importTasks(fixture.db);
    try testing.expectEqual(@as(usize, 0), first_import); // Already exists

    // Create new DB and import
    var fresh_db = try TaskDB.init(allocator, ":memory:");
    defer fresh_db.deinit();

    const second_import = try sync.importTasks(&fresh_db);
    try testing.expectEqual(@as(usize, 1), second_import);

    // Import again into same fresh DB
    const third_import = try sync.importTasks(&fresh_db);
    try testing.expectEqual(@as(usize, 0), third_import); // Now duplicate
}

test "Integration: Session state roundtrip" {
    const allocator = testing.allocator;

    var fixture = try IntegrationFixture.initWithGitSync(allocator);
    defer fixture.deinit();

    const sync = fixture.git_sync.?;

    // Create session state
    try fixture.store.startSession();

    const task_id = try fixture.store.createTask(.{
        .title = "Current Task",
        .priority = .critical,
    });
    try fixture.store.setCurrentTask(task_id);

    // Create some ready tasks
    _ = try fixture.store.createTask(.{ .title = "Ready 1" });
    _ = try fixture.store.createTask(.{ .title = "Ready 2" });

    // Write session state
    try sync.writeSessionState(fixture.store);

    // Parse it back
    const state = (try sync.parseSessionState()).?;
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try testing.expect(state.session_id != null);
    try testing.expect(state.current_task_id != null);
    try testing.expectEqual(task_id, state.current_task_id.?);
    try testing.expectEqual(@as(usize, 2), state.ready_count); // Ready 1 and Ready 2
}
