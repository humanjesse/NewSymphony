// Get Current Task Tool - Returns the task you're currently working on
// Auto-assigns from ready queue if no current task is set
// Captures started_at_commit for commit tracking (Phase 2)
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const git_utils = @import("git_utils");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Response structs for JSON serialization
const Comment = struct {
    agent: []const u8,
    content: []const u8,
    timestamp: i64,
};

const TaskInfo = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: []const u8,
    type: []const u8,
    description: ?[]const u8 = null,
    blocked_by_count: usize,
    comments: []const Comment,
    started_at_commit: ?[]const u8 = null,
};

const ParentContext = struct {
    id: []const u8,
    title: []const u8,
    type: []const u8,
    description: ?[]const u8 = null,
};

const Response = struct {
    current_task: ?TaskInfo = null,
    parent_context: ?ParentContext = null,
    ready_count: usize,
    blocked_count: usize,
    message: ?[]const u8 = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_current_task"),
                .description = try allocator.dupe(u8, "Get the task you're currently working on. Auto-assigns from ready queue if none set. Includes parent_context when task is a subtask of a molecule."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {}
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_current_task",
            .description = "Get current task",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, _: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Get current task using arena allocator (auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const current_task = store.getCurrentTaskWithAllocator(task_alloc) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get current task", start_time);
    };
    // No defer needed - arena handles cleanup

    // Capture started_at_commit if task exists and doesn't have one yet (Phase 2 commit tracking)
    if (current_task) |task| {
        if (task.started_at_commit == null) {
            // Get current HEAD commit hash
            const head = git_utils.getCurrentHead(allocator, null) catch |err| blk: {
                std.log.warn("Failed to get HEAD commit for task tracking: {}", .{err});
                break :blk null;
            };
            if (head) |h| {
                store.setTaskStartedCommit(task.id, h) catch |err| {
                    std.log.warn("Failed to set started_at_commit: {}", .{err});
                };
                allocator.free(h);
            }
        }
    }

    const counts = try store.getTaskCounts();

    if (current_task) |task| {
        // Build comments array
        var comments = std.ArrayListUnmanaged(Comment){};
        defer comments.deinit(allocator);

        for (task.comments) |comment| {
            try comments.append(allocator, .{
                .agent = comment.agent,
                .content = comment.content,
                .timestamp = comment.timestamp,
            });
        }

        const prio_str = switch (task.priority) {
            .critical => "critical",
            .high => "high",
            .medium => "medium",
            .low => "low",
            .wishlist => "wishlist",
        };

        const task_info = TaskInfo{
            .id = &task.id,
            .title = task.title,
            .status = task.status.toString(),
            .priority = prio_str,
            .type = task.task_type.toString(),
            .description = task.description,
            .blocked_by_count = task.blocked_by_count,
            .comments = comments.items,
            .started_at_commit = task.started_at_commit,
        };

        // Build parent context if task has a parent (using arena - auto-freed when tool returns)
        var parent_context: ?ParentContext = null;
        var parent_task_obj: ?task_store.Task = null;
        // No defer needed - arena handles cleanup
        if (task.parent_id) |parent_id| {
            if (try store.getTaskWithAllocator(parent_id, task_alloc)) |parent| {
                parent_task_obj = parent;
                parent_context = .{
                    .id = &parent_id,
                    .title = parent.title,
                    .type = parent.task_type.toString(),
                    .description = parent.description,
                };
            }
        }

        const response = Response{
            .current_task = task_info,
            .parent_context = parent_context,
            .ready_count = counts.pending,
            .blocked_count = counts.blocked,
            .message = null,
        };

        const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
        defer allocator.free(result);

        return ToolResult.ok(allocator, result, start_time, null);
    } else {
        // No tasks ready
        const message = try std.fmt.allocPrint(allocator, "No tasks ready. {d} tasks blocked - review dependencies.", .{counts.blocked});
        defer allocator.free(message);

        const response = Response{
            .current_task = null,
            .parent_context = null,
            .ready_count = 0,
            .blocked_count = counts.blocked,
            .message = message,
        };

        const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
        defer allocator.free(result);

        return ToolResult.ok(allocator, result, start_time, null);
    }
}
