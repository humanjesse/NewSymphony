// Get Ready Tasks Tool - Find tasks ready for work (no blockers)
const std = @import("std");
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
                .name = try allocator.dupe(u8, "get_ready_tasks"),
                .description = try allocator.dupe(u8, "Get tasks ready for work. Returns pending tasks with no blockers, sorted by priority (highest first)."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {}
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_ready_tasks",
            .description = "Get ready tasks",
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

    // Get ready tasks (sorted by priority)
    const ready_tasks = store.getReadyTasks() catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get ready tasks", start_time);
    };
    defer allocator.free(ready_tasks);

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"ready\": [");

    for (ready_tasks, 0..) |task, i| {
        if (i > 0) try json.append(allocator, ',');

        // Escape title for JSON
        var escaped_title = std.ArrayListUnmanaged(u8){};
        defer escaped_title.deinit(allocator);
        for (task.title) |c| {
            switch (c) {
                '"' => try escaped_title.appendSlice(allocator, "\\\""),
                '\\' => try escaped_title.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_title.appendSlice(allocator, "\\n"),
                '\r' => try escaped_title.appendSlice(allocator, "\\r"),
                '\t' => try escaped_title.appendSlice(allocator, "\\t"),
                else => try escaped_title.append(allocator, c),
            }
        }

        try json.writer(allocator).print(
            "{{\"id\":\"{s}\",\"title\":\"{s}\",\"priority\":{d},\"type\":\"{s}\"}}",
            .{
                &task.id,
                escaped_title.items,
                task.priority.toInt(),
                task.task_type.toString(),
            },
        );
    }

    // Add counts
    const counts = store.getTaskCounts();
    try json.writer(allocator).print("], \"ready_count\": {d}, \"total_pending\": {d}, \"total_blocked\": {d}}}", .{
        ready_tasks.len,
        counts.pending,
        counts.blocked,
    });

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
