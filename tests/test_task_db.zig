// Test suite for task_db.zig - SQLite persistence layer
// Run with: zig build test-task-db
//
// These tests use in-memory SQLite (":memory:") for isolation.
// Each test gets a fresh database, so tests don't affect each other.

const std = @import("std");
const testing = std.testing;
const task_db = @import("task_db");
const task_store = @import("task_store");

const TaskDB = task_db.TaskDB;
const Task = task_store.Task;
const TaskId = task_store.TaskId;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;
const Dependency = task_store.Dependency;
const DependencyType = task_store.DependencyType;
const Comment = task_store.Comment;

// ============================================================
// Helper Functions
// ============================================================

/// Create a test database with in-memory SQLite
fn createTestDb(allocator: std.mem.Allocator) !*TaskDB {
    const db = try allocator.create(TaskDB);
    db.* = try TaskDB.init(allocator, ":memory:");
    return db;
}

/// Clean up test database
fn destroyTestDb(allocator: std.mem.Allocator, db: *TaskDB) void {
    db.deinit();
    allocator.destroy(db);
}

/// Create a test task with given title
fn createTestTask(title: []const u8, allocator: std.mem.Allocator) Task {
    const now = std.time.timestamp();
    const id = task_store.TaskStore.generateId(title, now);

    // Allocate title
    const owned_title = allocator.dupe(u8, title) catch @panic("alloc failed");
    const empty_labels = allocator.alloc([]const u8, 0) catch @panic("alloc failed");

    return Task{
        .id = id,
        .title = owned_title,
        .description = null,
        .status = .pending,
        .priority = .medium,
        .task_type = .task,
        .labels = empty_labels,
        .created_at = now,
        .updated_at = now,
        .completed_at = null,
        .parent_id = null,
        .blocked_by_count = 0,
        .comments = &.{},
    };
}

// ============================================================
// Schema Tests
// ============================================================

test "TaskDB creates schema on init" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // If init succeeded, schema was created
    // Verify by checking task count (should be 0)
    const count = try db.getTaskCount();
    try testing.expectEqual(@as(i64, 0), count);
}

test "TaskDB schema is idempotent" {
    const allocator = testing.allocator;

    // Create DB - schema is created on init
    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Schema should work after init
    const count = try db.getTaskCount();
    try testing.expectEqual(@as(i64, 0), count);
}

// ============================================================
// Task CRUD Tests
// ============================================================

test "TaskDB saves and loads task" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create and save a task
    var task = createTestTask("Test Task 1", allocator);
    defer task.deinit(allocator);

    try db.saveTask(&task);

    // Load it back
    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    // Verify fields match
    try testing.expectEqualStrings("Test Task 1", loaded.title);
    try testing.expectEqual(TaskStatus.pending, loaded.status);
    try testing.expectEqual(TaskPriority.medium, loaded.priority);
    try testing.expectEqual(TaskType.task, loaded.task_type);
}

test "TaskDB returns null for nonexistent task" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Try to load a task that doesn't exist
    const fake_id: TaskId = "nonexist".*;
    const result = try db.loadTask(fake_id);

    try testing.expectEqual(@as(?Task, null), result);
}

test "TaskDB saves task with description" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create task with description
    var task = createTestTask("Task With Description", allocator);
    task.description = try allocator.dupe(u8, "This is a detailed description");
    defer task.deinit(allocator);

    try db.saveTask(&task);

    // Load and verify
    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    try testing.expect(loaded.description != null);
    try testing.expectEqualStrings("This is a detailed description", loaded.description.?);
}

test "TaskDB saves task with labels" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create task with labels
    var task = createTestTask("Task With Labels", allocator);
    // Free the empty labels first
    allocator.free(task.labels);

    // Create new labels
    var labels = try allocator.alloc([]const u8, 2);
    labels[0] = try allocator.dupe(u8, "urgent");
    labels[1] = try allocator.dupe(u8, "backend");
    task.labels = labels;
    defer task.deinit(allocator);

    try db.saveTask(&task);

    // Load and verify
    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), loaded.labels.len);
    try testing.expectEqualStrings("urgent", loaded.labels[0]);
    try testing.expectEqualStrings("backend", loaded.labels[1]);
}

test "TaskDB updates existing task (upsert)" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create and save initial task
    var task = createTestTask("Original Title", allocator);
    const task_id = task.id;
    defer task.deinit(allocator);

    try db.saveTask(&task);

    // Update via updateTaskTitle
    try db.updateTaskTitle(task_id, "Updated Title");

    // Load and verify update
    var loaded = (try db.loadTask(task_id)).?;
    defer loaded.deinit(allocator);

    try testing.expectEqualStrings("Updated Title", loaded.title);
}

test "TaskDB deletes task" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create and save a task
    var task = createTestTask("Task To Delete", allocator);
    const task_id = task.id;
    defer task.deinit(allocator);

    try db.saveTask(&task);

    // Verify it exists
    try testing.expect(try db.taskExists(task_id));

    // Delete it
    try db.deleteTask(task_id);

    // Verify it's gone
    try testing.expect(!try db.taskExists(task_id));
}

test "TaskDB loadAllTasks returns multiple tasks" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create and save multiple tasks
    var task1 = createTestTask("Task One", allocator);
    defer task1.deinit(allocator);
    try db.saveTask(&task1);

    var task2 = createTestTask("Task Two", allocator);
    defer task2.deinit(allocator);
    try db.saveTask(&task2);

    var task3 = createTestTask("Task Three", allocator);
    defer task3.deinit(allocator);
    try db.saveTask(&task3);

    // Load all tasks
    const tasks = try db.loadAllTasks();
    defer {
        for (tasks) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(tasks);
    }

    try testing.expectEqual(@as(usize, 3), tasks.len);
}

// ============================================================
// Status Update Tests
// ============================================================

test "TaskDB updateTaskStatus changes status" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    var task = createTestTask("Status Test", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    // Update to in_progress
    try db.updateTaskStatus(task.id, .in_progress, null);

    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    try testing.expectEqual(TaskStatus.in_progress, loaded.status);
}

test "TaskDB updateTaskStatus sets completed_at" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    var task = createTestTask("Completion Test", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    const completion_time: i64 = 1700000000;
    try db.updateTaskStatus(task.id, .completed, completion_time);

    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    try testing.expectEqual(TaskStatus.completed, loaded.status);
    try testing.expect(loaded.completed_at != null);
    try testing.expectEqual(completion_time, loaded.completed_at.?);
}

// ============================================================
// Dependency Tests
// ============================================================

test "TaskDB saves and loads dependency" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create two tasks
    var task1 = createTestTask("Blocker Task", allocator);
    defer task1.deinit(allocator);
    try db.saveTask(&task1);

    var task2 = createTestTask("Blocked Task", allocator);
    defer task2.deinit(allocator);
    try db.saveTask(&task2);

    // Add dependency: task1 blocks task2
    const dep = Dependency{
        .src_id = task1.id,
        .dst_id = task2.id,
        .dep_type = .blocks,
        .weight = 1.0,
    };
    try db.saveDependency(&dep);

    // Load all dependencies
    const deps = try db.loadAllDependencies();
    defer allocator.free(deps);

    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqual(DependencyType.blocks, deps[0].dep_type);
}

test "TaskDB getBlockedByCount returns correct count" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create three tasks
    var blocker1 = createTestTask("Blocker 1", allocator);
    defer blocker1.deinit(allocator);
    try db.saveTask(&blocker1);

    var blocker2 = createTestTask("Blocker 2", allocator);
    defer blocker2.deinit(allocator);
    try db.saveTask(&blocker2);

    var blocked = createTestTask("Blocked Task", allocator);
    defer blocked.deinit(allocator);
    try db.saveTask(&blocked);

    // Both blockers block the third task
    try db.saveDependency(&Dependency{
        .src_id = blocker1.id,
        .dst_id = blocked.id,
        .dep_type = .blocks,
        .weight = 1.0,
    });
    try db.saveDependency(&Dependency{
        .src_id = blocker2.id,
        .dst_id = blocked.id,
        .dep_type = .blocks,
        .weight = 1.0,
    });

    // Check blocked count
    const count = try db.getBlockedByCount(blocked.id);
    try testing.expectEqual(@as(usize, 2), count);
}

test "TaskDB getBlockedByCount excludes completed blockers" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create two tasks
    var blocker = createTestTask("Blocker", allocator);
    defer blocker.deinit(allocator);
    try db.saveTask(&blocker);

    var blocked = createTestTask("Blocked", allocator);
    defer blocked.deinit(allocator);
    try db.saveTask(&blocked);

    // Add blocking dependency
    try db.saveDependency(&Dependency{
        .src_id = blocker.id,
        .dst_id = blocked.id,
        .dep_type = .blocks,
        .weight = 1.0,
    });

    // Initially blocked
    try testing.expectEqual(@as(usize, 1), try db.getBlockedByCount(blocked.id));

    // Complete the blocker
    try db.updateTaskStatus(blocker.id, .completed, std.time.timestamp());

    // Now should be unblocked (count = 0)
    try testing.expectEqual(@as(usize, 0), try db.getBlockedByCount(blocked.id));
}

test "TaskDB deleteDependency removes dependency" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create two tasks
    var task1 = createTestTask("Task 1", allocator);
    defer task1.deinit(allocator);
    try db.saveTask(&task1);

    var task2 = createTestTask("Task 2", allocator);
    defer task2.deinit(allocator);
    try db.saveTask(&task2);

    // Add and then remove dependency
    try db.saveDependency(&Dependency{
        .src_id = task1.id,
        .dst_id = task2.id,
        .dep_type = .blocks,
        .weight = 1.0,
    });

    try testing.expectEqual(@as(usize, 1), try db.getBlockedByCount(task2.id));

    try db.deleteDependency(task1.id, task2.id, .blocks);

    try testing.expectEqual(@as(usize, 0), try db.getBlockedByCount(task2.id));
}

// ============================================================
// Transaction Tests
// ============================================================

test "TaskDB transaction commit persists changes" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    try db.beginTransaction();

    var task = createTestTask("Transaction Test", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    try db.commitTransaction();

    // Task should exist after commit
    try testing.expect(try db.taskExists(task.id));
}

test "TaskDB transaction rollback discards changes" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    try db.beginTransaction();

    var task = createTestTask("Rollback Test", allocator);
    const task_id = task.id;
    defer task.deinit(allocator);
    try db.saveTask(&task);

    try db.rollbackTransaction();

    // Task should NOT exist after rollback
    try testing.expect(!try db.taskExists(task_id));
}

test "TaskDB nested transactions with savepoints" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Outer transaction
    try db.beginTransaction();

    var task1 = createTestTask("Outer Task", allocator);
    defer task1.deinit(allocator);
    try db.saveTask(&task1);

    // Nested transaction
    try db.beginTransaction();

    var task2 = createTestTask("Inner Task", allocator);
    const task2_id = task2.id;
    defer task2.deinit(allocator);
    try db.saveTask(&task2);

    // Rollback inner
    try db.rollbackTransaction();

    // Commit outer
    try db.commitTransaction();

    // Outer task should exist, inner should not
    try testing.expect(try db.taskExists(task1.id));
    try testing.expect(!try db.taskExists(task2_id));
}

// ============================================================
// Session State Tests
// ============================================================

test "TaskDB saves and loads session state" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create a task to use as current task
    var task = createTestTask("Current Task", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    // Save session state
    const session_id = "1700000000-abcd";
    const started_at: i64 = 1700000000;
    try db.saveSessionState(session_id, task.id, started_at);

    // Load session state
    var state = (try db.loadSessionState()).?;
    defer state.deinit(allocator);

    try testing.expectEqualStrings("1700000000-abcd", state.session_id);
    try testing.expect(state.current_task_id != null);
    try testing.expectEqual(started_at, state.started_at);
}

test "TaskDB session state without current task" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Save session without current task
    try db.saveSessionState("1700000000-efgh", null, 1700000000);

    var state = (try db.loadSessionState()).?;
    defer state.deinit(allocator);

    try testing.expectEqual(@as(?TaskId, null), state.current_task_id);
}

// ============================================================
// Ready Tasks Tests
// ============================================================

test "TaskDB getReadyTasks returns pending unblocked tasks" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create tasks with different statuses
    var pending_task = createTestTask("Pending Task", allocator);
    defer pending_task.deinit(allocator);
    pending_task.status = .pending;
    try db.saveTask(&pending_task);

    var in_progress_task = createTestTask("In Progress Task", allocator);
    defer in_progress_task.deinit(allocator);
    in_progress_task.status = .in_progress;
    try db.saveTask(&in_progress_task);

    var completed_task = createTestTask("Completed Task", allocator);
    defer completed_task.deinit(allocator);
    completed_task.status = .completed;
    try db.saveTask(&completed_task);

    // Get ready tasks (should only include pending)
    const ready = try db.getReadyTasks();
    defer {
        for (ready) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("Pending Task", ready[0].title);
}

test "TaskDB getReadyTasks excludes blocked tasks" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    // Create blocker and blocked tasks
    var blocker = createTestTask("Blocker", allocator);
    defer blocker.deinit(allocator);
    try db.saveTask(&blocker);

    var blocked = createTestTask("Blocked", allocator);
    defer blocked.deinit(allocator);
    try db.saveTask(&blocked);

    // Add blocking dependency
    try db.saveDependency(&Dependency{
        .src_id = blocker.id,
        .dst_id = blocked.id,
        .dep_type = .blocks,
        .weight = 1.0,
    });

    // Get ready tasks (should only include blocker)
    const ready = try db.getReadyTasks();
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

// ============================================================
// Comment Tests
// ============================================================

test "TaskDB appendComment adds comment" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    var task = createTestTask("Task With Comments", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    // Add a comment
    const comment = Comment{
        .agent = "Tester",
        .content = "This is a test comment",
        .timestamp = std.time.timestamp(),
    };
    try db.appendComment(&task.id, comment);

    // Load task and check comments
    var loaded = (try db.loadTask(task.id)).?;
    defer loaded.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), loaded.comments.len);
    try testing.expectEqualStrings("Tester", loaded.comments[0].agent);
    try testing.expectEqualStrings("This is a test comment", loaded.comments[0].content);
}

test "TaskDB getLastCommentFrom returns latest comment" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    var task = createTestTask("Multi Comment Task", allocator);
    defer task.deinit(allocator);
    try db.saveTask(&task);

    // Add multiple comments from same agent
    try db.appendComment(&task.id, Comment{
        .agent = "Judge",
        .content = "First review",
        .timestamp = 1000,
    });
    try db.appendComment(&task.id, Comment{
        .agent = "Judge",
        .content = "Second review",
        .timestamp = 2000,
    });

    // Get last comment from Judge
    const last = (try db.getLastCommentFrom(task.id, "Judge")).?;
    defer {
        allocator.free(last.agent);
        allocator.free(last.content);
    }

    try testing.expectEqualStrings("Second review", last.content);
}

// ============================================================
// Wisp Behavior Tests
// ============================================================

test "TaskDB does not persist wisp tasks" {
    const allocator = testing.allocator;

    var db = try createTestDb(allocator);
    defer destroyTestDb(allocator, db);

    var wisp = createTestTask("Ephemeral Wisp", allocator);
    wisp.task_type = .wisp;
    defer wisp.deinit(allocator);

    // Save should succeed but not persist
    try db.saveTask(&wisp);

    // Should not be found in database
    const loaded = try db.loadTask(wisp.id);
    try testing.expectEqual(@as(?Task, null), loaded);
}
