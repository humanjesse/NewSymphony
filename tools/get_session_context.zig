// Get Session Context Tool - Cold start recovery
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const git_sync = @import("git_sync");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_session_context"),
                .description = try allocator.dupe(u8, "Get context for cold start recovery. Returns session state, current task, ready queue, and notes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "depth": {
                    \\      "type": "integer",
                    \\      "description": "How many recent completed tasks to include (default 3)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_session_context",
            .description = "Get session context for cold start",
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
    var depth: usize = 3;
    if (args_json.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("depth")) |v| {
                if (v == .integer) {
                    depth = @intCast(@max(1, @min(10, v.integer)));
                }
            }
        }
    }

    // Build comprehensive context
    var result_json = std.ArrayListUnmanaged(u8){};
    defer result_json.deinit(allocator);

    try result_json.appendSlice(allocator, "{");

    // Session info
    if (store.session_id) |sid| {
        try result_json.writer(allocator).print("\"session_id\": \"{s}\", ", .{sid});
    }

    // Current task
    try result_json.appendSlice(allocator, "\"current_task\": ");
    if (store.getCurrentTaskId()) |cid| {
        if (store.tasks.get(cid)) |task| {
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
                "{{\"id\": \"{s}\", \"title\": \"{s}\", \"status\": \"{s}\", \"priority\": {d}}}",
                .{ &task.id, escaped_title.items, task.status.toString(), task.priority.toInt() },
            );
        } else {
            try result_json.appendSlice(allocator, "null");
        }
    } else {
        try result_json.appendSlice(allocator, "null");
    }

    // Ready queue
    try result_json.appendSlice(allocator, ", \"ready_tasks\": [");
    const ready = store.getReadyTasks() catch &[_]task_store.Task{};
    defer allocator.free(ready);

    for (ready, 0..) |task, i| {
        if (i > 0) try result_json.append(allocator, ',');
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
            "{{\"id\": \"{s}\", \"title\": \"{s}\", \"priority\": {d}}}",
            .{ &task.id, escaped_title.items, task.priority.toInt() },
        );
    }
    try result_json.appendSlice(allocator, "]");

    // Recently completed
    try result_json.appendSlice(allocator, ", \"recently_completed\": [");
    var completed_tasks = std.ArrayListUnmanaged(task_store.Task){};
    defer completed_tasks.deinit(allocator);

    var iter = store.tasks.valueIterator();
    while (iter.next()) |task| {
        if (task.status == .completed and task.completed_at != null) {
            try completed_tasks.append(allocator, task.*);
        }
    }

    // Sort by completion time (most recent first)
    std.mem.sort(task_store.Task, completed_tasks.items, {}, struct {
        fn cmp(_: void, a: task_store.Task, b: task_store.Task) bool {
            return (a.completed_at orelse 0) > (b.completed_at orelse 0);
        }
    }.cmp);

    const show_count = @min(depth, completed_tasks.items.len);
    for (completed_tasks.items[0..show_count], 0..) |task, i| {
        if (i > 0) try result_json.append(allocator, ',');
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
            "{{\"id\": \"{s}\", \"title\": \"{s}\", \"completed_at\": {d}}}",
            .{ &task.id, escaped_title.items, task.completed_at orelse 0 },
        );
    }
    try result_json.appendSlice(allocator, "]");

    // Counts
    const counts = store.getTaskCounts();
    try result_json.writer(allocator).print(
        ", \"counts\": {{\"pending\": {d}, \"in_progress\": {d}, \"completed\": {d}, \"blocked\": {d}}}",
        .{ counts.pending, counts.in_progress, counts.completed, counts.blocked },
    );

    // Session notes from git_sync if available
    if (context.git_sync) |gs| {
        if (try gs.parseSessionState()) |parsed_state| {
            var mutable_state = parsed_state;
            defer mutable_state.deinit(allocator);
            if (mutable_state.notes) |notes| {
                var escaped_notes = std.ArrayListUnmanaged(u8){};
                defer escaped_notes.deinit(allocator);
                for (notes) |c| {
                    switch (c) {
                        '"' => try escaped_notes.appendSlice(allocator, "\\\""),
                        '\\' => try escaped_notes.appendSlice(allocator, "\\\\"),
                        '\n' => try escaped_notes.appendSlice(allocator, "\\n"),
                        else => try escaped_notes.append(allocator, c),
                    }
                }
                try result_json.writer(allocator).print(", \"notes\": \"{s}\"", .{escaped_notes.items});
            }
        }
    }

    try result_json.appendSlice(allocator, "}");

    const result = try allocator.dupe(u8, result_json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
