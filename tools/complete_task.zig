// Complete Task Tool - Mark task as done, cascade to dependents, auto-advance
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
const TaskStore = task_store.TaskStore;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "complete_task"),
                .description = try allocator.dupe(u8, "Complete a task. Defaults to current task. Auto-advances to next ready task."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to complete. Defaults to current task if not specified."
                    \\    },
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Brief summary of what was done"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "complete_task",
            .description = "Complete a task",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    var task_id: task_store.TaskId = undefined;
    var summary: ?[]const u8 = null;
    var was_current_task = false;

    if (arguments.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();

            // Get task_id - either from args or current task
            if (p.value.object.get("task_id")) |v| {
                if (v == .string and v.string.len == 8) {
                    @memcpy(&task_id, v.string[0..8]);
                } else {
                    return ToolResult.err(allocator, .invalid_arguments, "task_id must be 8 characters", start_time);
                }
            } else {
                // Use current task
                if (store.getCurrentTaskId()) |cid| {
                    task_id = cid;
                    was_current_task = true;
                } else {
                    return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
                }
            }

            // Get optional summary
            if (p.value.object.get("summary")) |v| {
                if (v == .string) summary = v.string;
            }
        } else {
            // No args provided, use current task
            if (store.getCurrentTaskId()) |cid| {
                task_id = cid;
                was_current_task = true;
            } else {
                return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
            }
        }
    } else {
        // No args provided, use current task
        if (store.getCurrentTaskId()) |cid| {
            task_id = cid;
            was_current_task = true;
        } else {
            return ToolResult.err(allocator, .invalid_arguments, "No current task. Specify task_id explicitly.", start_time);
        }
    }

    // Get task title before completion
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .not_found, "Task not found", start_time);
    };

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

    // Complete the task
    const result = store.completeTask(task_id) catch |err| {
        const msg = switch (err) {
            error.TaskNotFound => "Task not found",
            else => "Failed to complete task",
        };
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer allocator.free(result.unblocked);

    // Persist to database if available
    if (context.task_db) |db| {
        if (store.getTask(task_id)) |t| {
            db.saveTask(t) catch |err| {
                std.log.warn("Failed to persist completed task to SQLite: {}", .{err});
            };
        }
    }

    // Build JSON response
    var result_json = std.ArrayListUnmanaged(u8){};
    defer result_json.deinit(allocator);

    try result_json.writer(allocator).print(
        "{{\"completed\": true, \"task\": {{\"id\": \"{s}\", \"title\": \"{s}\"}}, \"unblocked\": [",
        .{ &task_id, escaped_title.items },
    );

    for (result.unblocked, 0..) |unblocked_id, i| {
        if (i > 0) try result_json.append(allocator, ',');
        try result_json.writer(allocator).print("\"{s}\"", .{&unblocked_id});
    }

    try result_json.writer(allocator).print("], \"unblocked_count\": {d}", .{result.unblocked.len});

    // Include summary if provided
    if (summary) |s| {
        var escaped_summary = std.ArrayListUnmanaged(u8){};
        defer escaped_summary.deinit(allocator);
        for (s) |c| {
            switch (c) {
                '"' => try escaped_summary.appendSlice(allocator, "\\\""),
                '\\' => try escaped_summary.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_summary.appendSlice(allocator, "\\n"),
                else => try escaped_summary.append(allocator, c),
            }
        }
        try result_json.writer(allocator).print(", \"summary\": \"{s}\"", .{escaped_summary.items});
    }

    // Auto-advance: show next ready task
    const ready_tasks = store.getReadyTasks() catch &[_]task_store.Task{};
    defer allocator.free(ready_tasks);

    if (ready_tasks.len > 0) {
        const next = ready_tasks[0];
        var escaped_next_title = std.ArrayListUnmanaged(u8){};
        defer escaped_next_title.deinit(allocator);
        for (next.title) |c| {
            switch (c) {
                '"' => try escaped_next_title.appendSlice(allocator, "\\\""),
                '\\' => try escaped_next_title.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_next_title.appendSlice(allocator, "\\n"),
                else => try escaped_next_title.append(allocator, c),
            }
        }
        try result_json.writer(allocator).print(
            ", \"next_task\": {{\"id\": \"{s}\", \"title\": \"{s}\", \"priority\": {d}}}",
            .{ &next.id, escaped_next_title.items, next.priority.toInt() },
        );
    } else {
        try result_json.appendSlice(allocator, ", \"next_task\": null");
    }

    try result_json.appendSlice(allocator, "}");

    const json_result = try allocator.dupe(u8, result_json.items);
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
