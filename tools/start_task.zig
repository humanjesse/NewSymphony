// Start Task Tool - Explicitly switch to working on a specific task
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
                .name = try allocator.dupe(u8, "start_task"),
                .description = try allocator.dupe(u8, "Explicitly switch to working on a specific task. Sets it as current and marks as in_progress."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "The 8-character task ID to start working on"
                    \\    }
                    \\  },
                    \\  "required": ["task_id"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "start_task",
            .description = "Start working on a task",
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

    const task_id_str = if (parsed.value.object.get("task_id")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (task_id_str == null or task_id_str.?.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "task_id must be an 8-character string", start_time);
    }

    var task_id: task_store.TaskId = undefined;
    @memcpy(&task_id, task_id_str.?[0..8]);

    // Set as current task
    store.setCurrentTask(task_id) catch {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };

    // Get the task for response
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .internal_error, "Task disappeared after setting as current", start_time);
    };

    // Persist to database if available
    if (context.task_db) |db| {
        db.saveTask(task) catch |err| {
            std.log.warn("Failed to persist started task to SQLite: {}", .{err});
        };
    }

    // Build JSON response
    var result_json = std.ArrayListUnmanaged(u8){};
    defer result_json.deinit(allocator);

    // Escape title
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
        "{{\"started\": true, \"task\": {{\"id\": \"{s}\", \"title\": \"{s}\", \"status\": \"{s}\", \"priority\": {d}}}}}",
        .{
            &task.id,
            escaped_title.items,
            task.status.toString(),
            task.priority.toInt(),
        },
    );

    const result = try allocator.dupe(u8, result_json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
