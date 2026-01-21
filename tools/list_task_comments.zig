// List Task Comments Tool - List all comments on a task's audit trail (Beads philosophy)
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Response structs for JSON serialization
const Comment = struct {
    agent: []const u8,
    content: []const u8,
    timestamp: i64,
};

const Response = struct {
    task_id: []const u8,
    task_title: []const u8,
    comments: []const Comment,
    count: usize,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "list_task_comments"),
                .description = try allocator.dupe(u8, "List all comments on a task's audit trail. Returns the full comment history with agent attribution and timestamps."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to get comments for. Defaults to current task if not specified."
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "list_task_comments",
            .description = "List comments on a task",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, args_json: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Get task_id - either from args or current task
    var task_id: task_store.TaskId = undefined;

    if (parsed.value.object.get("task_id")) |v| {
        if (v == .string and v.string.len == 8) {
            @memcpy(&task_id, v.string[0..8]);
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "task_id must be 8 characters", start_time);
        }
    } else {
        // Use current task
        if (store.getCurrentTaskId()) |cid| {
            task_id = cid;
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
        }
    }

    // Get the task
    const task = (try store.getTask(task_id)) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };
    defer {
        var t = task;
        t.deinit(allocator);
    }

    // Build comments array
    var comments_array = std.ArrayListUnmanaged(Comment){};
    defer comments_array.deinit(allocator);

    for (task.comments) |comment| {
        try comments_array.append(allocator, .{
            .agent = comment.agent,
            .content = comment.content,
            .timestamp = comment.timestamp,
        });
    }

    const response = Response{
        .task_id = &task_id,
        .task_title = task.title,
        .comments = comments_array.items,
        .count = task.comments.len,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
