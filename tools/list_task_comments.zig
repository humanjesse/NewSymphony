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
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };

    // Build response
    var result_json = std.ArrayListUnmanaged(u8){};
    defer result_json.deinit(allocator);

    // Escape title for JSON
    var escaped_title = std.ArrayListUnmanaged(u8){};
    defer escaped_title.deinit(allocator);
    for (task.title) |c| {
        switch (c) {
            '"' => try escaped_title.appendSlice(allocator, "\\\""),
            '\\' => try escaped_title.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_title.appendSlice(allocator, "\\n"),
            else => try escaped_title.append(allocator, c),
        }
    }

    try result_json.writer(allocator).print(
        "{{\"task_id\": \"{s}\", \"task_title\": \"{s}\", \"comments\": [",
        .{ &task_id, escaped_title.items },
    );

    // Add each comment
    for (task.comments, 0..) |comment, i| {
        if (i > 0) try result_json.appendSlice(allocator, ", ");

        // Escape comment content for JSON
        var escaped_content = std.ArrayListUnmanaged(u8){};
        defer escaped_content.deinit(allocator);
        for (comment.content) |c| {
            switch (c) {
                '"' => try escaped_content.appendSlice(allocator, "\\\""),
                '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_content.appendSlice(allocator, "\\n"),
                '\r' => try escaped_content.appendSlice(allocator, "\\r"),
                '\t' => try escaped_content.appendSlice(allocator, "\\t"),
                else => try escaped_content.append(allocator, c),
            }
        }

        try result_json.writer(allocator).print(
            "{{\"agent\": \"{s}\", \"content\": \"{s}\", \"timestamp\": {d}}}",
            .{ comment.agent, escaped_content.items, comment.timestamp },
        );
    }

    try result_json.writer(allocator).print("], \"count\": {d}}}", .{task.comments.len});

    const result = try allocator.dupe(u8, result_json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
