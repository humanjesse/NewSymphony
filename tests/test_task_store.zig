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

    try testing.expect(fixture.store.session_id != null);
    try testing.expect(fixture.store.session_started_at != null);
}

test "TaskStore setCurrentTask sets and persists current task" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    const task_id = try fixture.store.createTask(.{ .title = "Current Task" });

    try fixture.store.setCurrentTask(task_id);

    try testing.expect(fixture.store.current_task_id != null);
    try testing.expectEqual(task_id, fixture.store.current_task_id.?);

    // Task should be marked as in_progress
    var task = (try fixture.store.getTask(task_id)).?;
    defer task.deinit(allocator);
    try testing.expectEqual(TaskStatus.in_progress, task.status);
}

test "TaskStore getCurrentTask auto-assigns from ready queue" {
    const allocator = testing.allocator;

    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();

    try fixture.store.startSession();

    // Create a task but don't set it as current
    const task_id = try fixture.store.createTask(.{
        .title = "Auto Assign Task",
        .priority = .critical,
    });

    // getCurrentTask should auto-assign
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

    try testing.expect(fixture.store.current_task_id != null);

    fixture.store.clearCurrentTask();

    try testing.expectEqual(@as(?TaskId, null), fixture.store.current_task_id);
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
