// Test suite for task_store.zig - Business logic layer
// Run with: zig build test-task-store
//
// These tests verify the facade layer that provides:
// - Task state transitions
// - Ready queue computation
// - Dependency cycle detection
// - Cascade unblocking
// - Session management

const std = @import("std");
const testing = std.testing;
const task_store = @import("task_store");
const task_db = @import("task_db");

const TaskStore = task_store.TaskStore;
const TaskDB = task_db.TaskDB;
const Task = task_store.Task;
const TaskId = task_store.TaskId;
const TaskStatus = task_store.TaskStatus;
const TaskPriority = task_store.TaskPriority;
const TaskType = task_store.TaskType;
const CreateTaskParams = task_store.CreateTaskParams;
const DependencyType = task_store.DependencyType;

// ============================================================
// Test Fixture
// ============================================================

/// Test context that manages both DB and Store lifecycle
const TestFixture = struct {
    allocator: std.mem.Allocator,
    db: *TaskDB,
    store: *TaskStore,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        // Create TaskDB with in-memory SQLite
        const db = try allocator.create(TaskDB);
        errdefer allocator.destroy(db);
        db.* = try TaskDB.init(allocator, ":memory:");
        errdefer db.deinit();

        // Create TaskStore that wraps the DB
        const store = try allocator.create(TaskStore);
        store.* = TaskStore.init(allocator, db);

        return TestFixture{
            .allocator = allocator,
            .db = db,
            .store = store,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.store.deinit();
        self.allocator.destroy(self.store);
        self.db.deinit();
        self.allocator.destroy(self.db);
    }
};

// ============================================================
// Task Creation Tests
// ============================================================

test "TaskStore creates task with valid ID" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{
        .title = "My First Task",
    });

    // ID should be 8 characters
    try testing.expectEqual(@as(usize, 8), task_id.len);

    // Task should exist
    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);

    try testing.expectEqualStrings("My First Task", task.title);
    try testing.expectEqual(TaskStatus.pending, task.status);
    try testing.expectEqual(TaskPriority.medium, task.priority);
}

test "TaskStore generates unique IDs for different titles" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create tasks with different titles
    const id1 = try fixture.store.createTask(.{ .title = "Task Alpha" });
    const id2 = try fixture.store.createTask(.{ .title = "Task Beta" });
    const id3 = try fixture.store.createTask(.{ .title = "Task Gamma" });

    // All IDs should be different
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
    try testing.expect(!std.mem.eql(u8, &id1, &id3));
    try testing.expect(!std.mem.eql(u8, &id2, &id3));

    // All tasks should exist independently
    try testing.expectEqual(@as(usize, 3), try fixture.store.count());
}

test "TaskStore rejects duplicate title within same second" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create first task
    _ = try fixture.store.createTask(.{ .title = "Duplicate Title" });

    // Same title in same second should collide (ID is hash of title + timestamp)
    const result = fixture.store.createTask(.{ .title = "Duplicate Title" });
    try testing.expectError(error.TaskIdCollision, result);
}

test "TaskStore creates task with all parameters" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const labels = [_][]const u8{ "urgent", "frontend" };
    const task_id = try fixture.store.createTask(.{
        .title = "Full Featured Task",
        .description = "A comprehensive task",
        .priority = .high,
        .task_type = .feature,
        .labels = &labels,
    });

    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);

    try testing.expectEqualStrings("Full Featured Task", task.title);
    try testing.expectEqualStrings("A comprehensive task", task.description.?);
    try testing.expectEqual(TaskPriority.high, task.priority);
    try testing.expectEqual(TaskType.feature, task.task_type);
    try testing.expectEqual(@as(usize, 2), task.labels.len);
}

test "TaskStore count returns correct number of tasks" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try testing.expectEqual(@as(usize, 0), try fixture.store.count());

    _ = try fixture.store.createTask(.{ .title = "Task 1" });
    _ = try fixture.store.createTask(.{ .title = "Task 2" });
    _ = try fixture.store.createTask(.{ .title = "Task 3" });

    try testing.expectEqual(@as(usize, 3), try fixture.store.count());
}

// ============================================================
// Task State Transition Tests
// ============================================================

test "TaskStore updateStatus changes task status" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Status Test" });

    // Initial status is pending
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }

    // Update to in_progress
    try fixture.store.updateStatus(task_id, .in_progress);
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.in_progress, task.status);
    }

    // Update to completed
    try fixture.store.updateStatus(task_id, .completed);
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.completed, task.status);
        try testing.expect(task.completed_at != null);
    }
}

test "TaskStore updateStatus returns error for nonexistent task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const fake_id: TaskId = "nonexist".*;
    const result = fixture.store.updateStatus(fake_id, .in_progress);

    try testing.expectError(error.TaskNotFound, result);
}

// ============================================================
// Task Completion Tests
// ============================================================

test "TaskStore completeTask marks task as completed" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Complete Me" });

    const result = try fixture.store.completeTask(task_id);
    defer allocator.free(result.unblocked);

    try testing.expectEqual(task_id, result.task_id);

    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);

    try testing.expectEqual(TaskStatus.completed, task.status);
    try testing.expect(task.completed_at != null);
}

test "TaskStore completeTask cascades to unblock dependent tasks" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create blocker task
    const blocker_id = try fixture.store.createTask(.{ .title = "Blocker" });

    // Create blocked task
    const blocked_id = try fixture.store.createTask(.{ .title = "Blocked" });

    // Add blocking dependency
    try fixture.store.addDependency(blocker_id, blocked_id, .blocks);

    // Verify blocked task is blocked
    {
        const blocked_by_count = try fixture.db.getBlockedByCount(blocked_id);
        try testing.expectEqual(@as(usize, 1), blocked_by_count);
    }

    // Complete the blocker
    const result = try fixture.store.completeTask(blocker_id);
    defer allocator.free(result.unblocked);

    // Blocked task should now be unblocked
    try testing.expectEqual(@as(usize, 1), result.unblocked.len);
    try testing.expectEqual(blocked_id, result.unblocked[0]);

    // Verify status changed to pending
    {
        var task = (try fixture.store.getTask(blocked_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

// ============================================================
// Ready Queue Tests
// ============================================================

test "TaskStore getReadyTasks returns only pending unblocked tasks" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create various tasks
    _ = try fixture.store.createTask(.{ .title = "Ready Task 1" });
    _ = try fixture.store.createTask(.{ .title = "Ready Task 2" });

    const in_progress_id = try fixture.store.createTask(.{ .title = "In Progress" });
    try fixture.store.updateStatus(in_progress_id, .in_progress);

    const completed_id = try fixture.store.createTask(.{ .title = "Completed" });
    _ = try fixture.store.completeTask(completed_id);

    // Get ready tasks
    const ready = try fixture.store.getReadyTasks();
    defer {
        for (ready) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    // Should only have the 2 pending tasks
    try testing.expectEqual(@as(usize, 2), ready.len);
}

test "TaskStore getReadyTasks excludes blocked tasks" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create blocker
    const blocker_id = try fixture.store.createTask(.{ .title = "Blocker" });

    // Create blocked task
    const blocked_id = try fixture.store.createTask(.{ .title = "Blocked" });
    try fixture.store.addDependency(blocker_id, blocked_id, .blocks);

    // Get ready tasks
    const ready = try fixture.store.getReadyTasks();
    defer {
        for (ready) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    // Only blocker should be ready
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("Blocker", ready[0].title);
}

test "TaskStore getReadyTasks sorts by priority" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create tasks with different priorities (in wrong order)
    _ = try fixture.store.createTask(.{
        .title = "Low Priority",
        .priority = .low,
    });
    _ = try fixture.store.createTask(.{
        .title = "Critical Priority",
        .priority = .critical,
    });
    _ = try fixture.store.createTask(.{
        .title = "High Priority",
        .priority = .high,
    });

    const ready = try fixture.store.getReadyTasks();
    defer {
        for (ready) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    // Should be sorted by priority (critical = 0, high = 1, low = 3)
    try testing.expectEqual(@as(usize, 3), ready.len);
    try testing.expectEqual(TaskPriority.critical, ready[0].priority);
    try testing.expectEqual(TaskPriority.high, ready[1].priority);
    try testing.expectEqual(TaskPriority.low, ready[2].priority);
}

// ============================================================
// Dependency Tests
// ============================================================

test "TaskStore addDependency creates blocking relationship" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task1_id = try fixture.store.createTask(.{ .title = "Task 1" });
    const task2_id = try fixture.store.createTask(.{ .title = "Task 2" });

    try fixture.store.addDependency(task1_id, task2_id, .blocks);

    // Task 2 should be blocked by Task 1
    const blocked_by = try fixture.store.getBlockedBy(task2_id);
    defer {
        for (blocked_by) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(blocked_by);
    }

    try testing.expectEqual(@as(usize, 1), blocked_by.len);
    try testing.expectEqual(task1_id, blocked_by[0].id);
}

test "TaskStore addDependency prevents self-dependency" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Self Reference" });

    const result = fixture.store.addDependency(task_id, task_id, .blocks);
    try testing.expectError(error.SelfDependency, result);
}

test "TaskStore addDependency detects circular dependency" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create chain: A -> B -> C
    const task_a = try fixture.store.createTask(.{ .title = "Task A" });
    const task_b = try fixture.store.createTask(.{ .title = "Task B" });
    const task_c = try fixture.store.createTask(.{ .title = "Task C" });

    try fixture.store.addDependency(task_a, task_b, .blocks);
    try fixture.store.addDependency(task_b, task_c, .blocks);

    // Try to add C -> A (would create cycle)
    const result = fixture.store.addDependency(task_c, task_a, .blocks);
    try testing.expectError(error.CircularDependency, result);
}

test "TaskStore removeDependency unblocks task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const blocker_id = try fixture.store.createTask(.{ .title = "Blocker" });
    const blocked_id = try fixture.store.createTask(.{ .title = "Blocked" });

    try fixture.store.addDependency(blocker_id, blocked_id, .blocks);

    // Verify blocked
    {
        var task = (try fixture.store.getTask(blocked_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Remove dependency
    try fixture.store.removeDependency(blocker_id, blocked_id, .blocks);

    // Should be unblocked
    {
        var task = (try fixture.store.getTask(blocked_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

// ============================================================
// Session Management Tests
// ============================================================

test "TaskStore startSession creates session ID" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    try testing.expect(fixture.store.getSessionId() != null);
    try testing.expect(fixture.store.getSessionStartedAt() != null);
}

test "TaskStore setCurrentTask sets and persists current task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    const task_id = try fixture.store.createTask(.{ .title = "Current Task" });

    try fixture.store.setCurrentTask(task_id);

    try testing.expect(fixture.store.getCurrentTaskId() != null);
    try testing.expectEqual(task_id, fixture.store.getCurrentTaskId().?);

    // Task should be marked as in_progress
    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);
    try testing.expectEqual(TaskStatus.in_progress, task.status);
}

test "TaskStore getCurrentTask requires explicit start_task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create a task but don't set it as current
    const task_id = try fixture.store.createTask(.{
        .title = "Model Selected Task",
        .priority = .critical,
    });

    // getCurrentTask should return null - no auto-assignment
    const no_task = try fixture.store.getCurrentTask();
    try testing.expectEqual(@as(?Task, null), no_task);

    // Explicitly set current task (simulating start_task tool)
    try fixture.store.setCurrentTask(task_id);

    // Now getCurrentTask should return the task
    var task = (try fixture.store.getCurrentTask()).?;
    defer task.deinit(allocator);

    try testing.expectEqual(task_id, task.id);
    try testing.expectEqual(TaskStatus.in_progress, task.status);
}

test "TaskStore getCurrentTask returns null when no tasks" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    const task = try fixture.store.getCurrentTask();
    try testing.expectEqual(@as(?Task, null), task);
}

test "TaskStore clearCurrentTask clears current task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    const task_id = try fixture.store.createTask(.{ .title = "Clear Me" });
    try fixture.store.setCurrentTask(task_id);

    try testing.expect(fixture.store.getCurrentTaskId() != null);

    fixture.store.clearCurrentTask();

    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());
}

// ============================================================
// Comment Tests
// ============================================================

test "TaskStore addComment adds comment to task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Commented Task" });

    try fixture.store.addComment(task_id, "Tester", "This is my comment");

    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), task.comments.len);
    try testing.expectEqualStrings("Tester", task.comments[0].agent);
    try testing.expectEqualStrings("This is my comment", task.comments[0].content);
}

test "TaskStore getLastCommentFrom returns latest" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Multi Comment" });

    // Use explicit timestamps to ensure ordering
    // (addComment uses current time, which could be same second for both)
    try fixture.db.appendComment(&task_id, .{
        .agent = "Judge",
        .content = "First feedback",
        .timestamp = 1000,
    });
    try fixture.db.appendComment(&task_id, .{
        .agent = "Judge",
        .content = "Second feedback",
        .timestamp = 2000,
    });

    const comment = (try fixture.store.getLastCommentFrom(task_id, "Judge")).?;
    defer {
        allocator.free(comment.agent);
        allocator.free(comment.content);
    }

    try testing.expectEqualStrings("Second feedback", comment.content);
}

// ============================================================
// Update Task Tests
// ============================================================

test "TaskStore updateTask batch updates properties" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const task_id = try fixture.store.createTask(.{ .title = "Original" });

    _ = try fixture.store.updateTask(task_id, .{
        .title = "Updated Title",
        .priority = .critical,
    });

    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);

    try testing.expectEqualStrings("Updated Title", task.title);
    try testing.expectEqual(TaskPriority.critical, task.priority);
}

test "TaskStore updateTask with completed status returns unblocked" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    const blocker_id = try fixture.store.createTask(.{ .title = "Blocker" });
    const blocked_id = try fixture.store.createTask(.{ .title = "Blocked" });

    try fixture.store.addDependency(blocker_id, blocked_id, .blocks);

    // Complete via updateTask
    const result = (try fixture.store.updateTask(blocker_id, .{
        .status = .completed,
    })).?;
    defer allocator.free(result.unblocked);

    try testing.expectEqual(@as(usize, 1), result.unblocked.len);
}

// ============================================================
// ID Generation Tests
// ============================================================

test "TaskStore generateId produces consistent IDs" {
    // Same input should produce same ID
    const id1 = TaskStore.generateId("Test Task", 1700000000);
    const id2 = TaskStore.generateId("Test Task", 1700000000);

    try testing.expectEqual(id1, id2);
}

test "TaskStore generateId produces different IDs for different inputs" {
    const id1 = TaskStore.generateId("Task A", 1700000000);
    const id2 = TaskStore.generateId("Task B", 1700000000);
    const id3 = TaskStore.generateId("Task A", 1700000001);

    try testing.expect(!std.mem.eql(u8, &id1, &id2));
    try testing.expect(!std.mem.eql(u8, &id1, &id3));
}

test "TaskStore parseId parses valid ID" {
    const id_str = "abcd1234";
    const id = try TaskStore.parseId(id_str);

    try testing.expectEqualStrings(id_str, &id);
}

test "TaskStore parseId rejects invalid length" {
    const result = TaskStore.parseId("short");
    try testing.expectError(error.InvalidTaskId, result);
}

// ============================================================
// Molecule Blocking Tests
// ============================================================

test "TaskStore auto-unblocks task when converted to molecule" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create a task and set it to blocked status
    const task_id = try fixture.store.createTask(.{
        .title = "Blocked Task",
        .task_type = .task,
    });
    try fixture.store.updateStatus(task_id, .blocked);

    // Verify it's blocked
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
        try testing.expectEqual(TaskType.task, task.task_type);
    }

    // Convert to molecule - should auto-unblock
    _ = try fixture.store.updateTask(task_id, .{
        .task_type = .molecule,
    });

    // Verify it's now a molecule and pending (not blocked)
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskType.molecule, task.task_type);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

test "TaskStore updateStatus rejects blocking a molecule" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create a molecule
    const task_id = try fixture.store.createTask(.{
        .title = "My Molecule",
        .task_type = .molecule,
    });

    // Verify it's a molecule
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskType.molecule, task.task_type);
    }

    // Attempt to block the molecule - should fail
    const result = fixture.store.updateStatus(task_id, .blocked);
    try testing.expectError(error.CannotBlockMolecule, result);

    // Verify status unchanged
    {
        var task = (try fixture.store.getTask(task_id)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

test "TaskStore getCurrentTask returns null when current task is a molecule" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create a regular task and set it as current
    const task_id = try fixture.store.createTask(.{
        .title = "Task to become molecule",
    });

    try fixture.store.setCurrentTask(task_id);

    // Verify it's the current task
    {
        var task = (try fixture.store.getCurrentTask()).?;
        defer task.deinit(allocator);
        try testing.expectEqual(task_id, task.id);
        try testing.expectEqual(TaskStatus.in_progress, task.status);
    }

    // Convert it to a molecule
    _ = try fixture.store.updateTask(task_id, .{ .task_type = .molecule });

    // Create subtasks under it
    std.Thread.sleep(1 * std.time.ns_per_ms);
    _ = try fixture.store.createTask(.{
        .title = "Subtask 1",
        .parent_id = task_id,
    });

    // Now getCurrentTask should return null - molecules aren't directly workable
    // Model must use list_tasks(ready_only=true) + start_task to select a subtask
    const task = try fixture.store.getCurrentTask();
    try testing.expectEqual(@as(?Task, null), task);

    // Current task ID should have been cleared
    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());
}

test "TaskStore getCurrentTask returns null when current task is cancelled" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create two tasks
    const task1 = try fixture.store.createTask(.{
        .title = "Task 1",
    });

    std.Thread.sleep(1 * std.time.ns_per_ms);

    _ = try fixture.store.createTask(.{
        .title = "Task 2",
    });

    // Set task1 as current
    try fixture.store.setCurrentTask(task1);

    // Verify task1 is current
    try testing.expectEqual(task1, fixture.store.getCurrentTaskId().?);

    // Cancel task1
    try fixture.store.updateStatus(task1, .cancelled);

    // current_task_id should be cleared immediately
    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());

    // getCurrentTask returns null - model must explicitly select next task
    const task = try fixture.store.getCurrentTask();
    try testing.expectEqual(@as(?Task, null), task);
}

test "TaskStore getCurrentTask returns null when current task is cancelled via updateTask" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create two tasks
    const task1 = try fixture.store.createTask(.{
        .title = "Task 1",
    });

    std.Thread.sleep(1 * std.time.ns_per_ms);

    _ = try fixture.store.createTask(.{
        .title = "Task 2",
    });

    // Set task1 as current
    try fixture.store.setCurrentTask(task1);
    try testing.expectEqual(task1, fixture.store.getCurrentTaskId().?);

    // Cancel task1 via updateTask
    _ = try fixture.store.updateTask(task1, .{ .status = .cancelled });

    // current_task_id should be cleared immediately
    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());

    // getCurrentTask returns null - model must explicitly select next task
    const task = try fixture.store.getCurrentTask();
    try testing.expectEqual(@as(?Task, null), task);
}

test "TaskStore clears current task when converted to molecule via updateTask" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create a task and set it as current
    const task_id = try fixture.store.createTask(.{
        .title = "Task to become molecule",
    });

    try fixture.store.setCurrentTask(task_id);
    try testing.expectEqual(task_id, fixture.store.getCurrentTaskId().?);

    // Convert to molecule via updateTask
    _ = try fixture.store.updateTask(task_id, .{ .task_type = .molecule });

    // current_task_id should be cleared immediately (molecules are not directly workable)
    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());
}

test "TaskStore clears current task when converted to molecule via updateTaskType" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create a task and set it as current
    const task_id = try fixture.store.createTask(.{
        .title = "Task to become molecule",
    });

    try fixture.store.setCurrentTask(task_id);
    try testing.expectEqual(task_id, fixture.store.getCurrentTaskId().?);

    // Convert to molecule via updateTaskType
    try fixture.store.updateTaskType(task_id, .molecule);

    // current_task_id should be cleared immediately (molecules are not directly workable)
    try testing.expectEqual(@as(?TaskId, null), fixture.store.getCurrentTaskId());
}

// ============================================================
// Molecule Blocking Invariant Tests
// ============================================================

test "TaskStore rejects setting molecule to blocked status" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create a molecule directly
    const molecule_id = try fixture.store.createTask(.{
        .title = "Test Molecule",
        .task_type = .molecule,
    });

    // Attempt to block the molecule should fail
    const result = fixture.store.updateStatus(molecule_id, .blocked);
    try testing.expectError(error.CannotBlockMolecule, result);
}

test "TaskStore getReadyTasks excludes molecules" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create a molecule (pending, no blockers)
    _ = try fixture.store.createTask(.{
        .title = "Pending Molecule",
        .task_type = .molecule,
    });

    // Create a regular task (pending, no blockers)
    _ = try fixture.store.createTask(.{
        .title = "Regular Task",
        .task_type = .task,
    });

    // Get ready tasks - molecules should be excluded
    const ready = try fixture.store.getReadyTasks();
    defer {
        for (ready) |*t| {
            var task = t.*;
            task.deinit(allocator);
        }
        allocator.free(ready);
    }

    // Only the regular task should be in ready queue
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("Regular Task", ready[0].title);
    try testing.expectEqual(TaskType.task, ready[0].task_type);
}

// ============================================================
// Cycle Detection Tests
// ============================================================

test "TaskStore detects 3-node cycle A->B->C->A" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create chain: A blocks B, B blocks C
    const task_a = try fixture.store.createTask(.{ .title = "Task A" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task_b = try fixture.store.createTask(.{ .title = "Task B" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task_c = try fixture.store.createTask(.{ .title = "Task C" });

    // A blocks B (B depends on A)
    try fixture.store.addDependency(task_a, task_b, .blocks);
    // B blocks C (C depends on B)
    try fixture.store.addDependency(task_b, task_c, .blocks);

    // Attempting C blocks A would create cycle: A->B->C->A
    const result = fixture.store.addDependency(task_c, task_a, .blocks);
    try testing.expectError(error.CircularDependency, result);
}

test "TaskStore allows valid DAG dependencies" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create tasks
    const task_a = try fixture.store.createTask(.{ .title = "Task A" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task_b = try fixture.store.createTask(.{ .title = "Task B" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task_c = try fixture.store.createTask(.{ .title = "Task C" });

    // Build valid DAG: A->B, A->C, B->C (diamond shape)
    try fixture.store.addDependency(task_a, task_b, .blocks); // A blocks B
    try fixture.store.addDependency(task_a, task_c, .blocks); // A blocks C
    try fixture.store.addDependency(task_b, task_c, .blocks); // B blocks C

    // Verify C is blocked by both A and B
    const blocked_by_count = try fixture.db.getBlockedByCount(task_c);
    try testing.expectEqual(@as(usize, 2), blocked_by_count);

    // Verify B is blocked by A only
    const b_blocked_by = try fixture.db.getBlockedByCount(task_b);
    try testing.expectEqual(@as(usize, 1), b_blocked_by);
}

// ============================================================
// Blocking State Machine Tests
// ============================================================

test "TaskStore handles multiple blockers" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create blockers and blocked task
    const blocker_a = try fixture.store.createTask(.{ .title = "Blocker A" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const blocker_b = try fixture.store.createTask(.{ .title = "Blocker B" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const blocked_task = try fixture.store.createTask(.{ .title = "Blocked Task" });

    // Both A and B block the task
    try fixture.store.addDependency(blocker_a, blocked_task, .blocks);
    try fixture.store.addDependency(blocker_b, blocked_task, .blocks);

    // Verify task is blocked
    {
        var task = (try fixture.store.getTask(blocked_task)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Complete A - task should still be blocked (B is still pending)
    const result_a = try fixture.store.completeTask(blocker_a);
    defer allocator.free(result_a.unblocked);
    try testing.expectEqual(@as(usize, 0), result_a.unblocked.len);

    {
        var task = (try fixture.store.getTask(blocked_task)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.blocked, task.status);
    }

    // Complete B - task should now be unblocked
    const result_b = try fixture.store.completeTask(blocker_b);
    defer allocator.free(result_b.unblocked);
    try testing.expectEqual(@as(usize, 1), result_b.unblocked.len);
    try testing.expectEqual(blocked_task, result_b.unblocked[0]);

    {
        var task = (try fixture.store.getTask(blocked_task)).?;
        defer task.deinit(allocator);
        try testing.expectEqual(TaskStatus.pending, task.status);
    }
}

test "TaskStore cascade unblock updates all dependents" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    // Create chain: blocker -> [task1, task2, task3]
    const blocker = try fixture.store.createTask(.{ .title = "Single Blocker" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task1 = try fixture.store.createTask(.{ .title = "Dependent 1" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task2 = try fixture.store.createTask(.{ .title = "Dependent 2" });
    std.Thread.sleep(1 * std.time.ns_per_ms);
    const task3 = try fixture.store.createTask(.{ .title = "Dependent 3" });

    // Blocker blocks all three tasks
    try fixture.store.addDependency(blocker, task1, .blocks);
    try fixture.store.addDependency(blocker, task2, .blocks);
    try fixture.store.addDependency(blocker, task3, .blocks);

    // Verify all are blocked
    {
        var t1 = (try fixture.store.getTask(task1)).?;
        defer t1.deinit(allocator);
        var t2 = (try fixture.store.getTask(task2)).?;
        defer t2.deinit(allocator);
        var t3 = (try fixture.store.getTask(task3)).?;
        defer t3.deinit(allocator);

        try testing.expectEqual(TaskStatus.blocked, t1.status);
        try testing.expectEqual(TaskStatus.blocked, t2.status);
        try testing.expectEqual(TaskStatus.blocked, t3.status);
    }

    // Complete blocker - all three should be unblocked atomically
    const result = try fixture.store.completeTask(blocker);
    defer allocator.free(result.unblocked);

    try testing.expectEqual(@as(usize, 3), result.unblocked.len);

    // Verify all are now pending
    {
        var t1 = (try fixture.store.getTask(task1)).?;
        defer t1.deinit(allocator);
        var t2 = (try fixture.store.getTask(task2)).?;
        defer t2.deinit(allocator);
        var t3 = (try fixture.store.getTask(task3)).?;
        defer t3.deinit(allocator);

        try testing.expectEqual(TaskStatus.pending, t1.status);
        try testing.expectEqual(TaskStatus.pending, t2.status);
        try testing.expectEqual(TaskStatus.pending, t3.status);
    }
}
