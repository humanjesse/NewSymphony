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

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_current_task"),
                .description = try allocator.dupe(u8, "Get the task you're currently working on. Auto-assigns from ready queue if none set."),
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

    // Get current task (with auto-assignment)
    const current_task = store.getCurrentTask() catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get current task", start_time);
    };

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

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    if (current_task) |task| {
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

        // Escape description if present
        var escaped_desc = std.ArrayListUnmanaged(u8){};
        defer escaped_desc.deinit(allocator);
        if (task.description) |desc| {
            for (desc) |c| {
                switch (c) {
                    '"' => try escaped_desc.appendSlice(allocator, "\\\""),
                    '\\' => try escaped_desc.appendSlice(allocator, "\\\\"),
                    '\n' => try escaped_desc.appendSlice(allocator, "\\n"),
                    '\r' => try escaped_desc.appendSlice(allocator, "\\r"),
                    '\t' => try escaped_desc.appendSlice(allocator, "\\t"),
                    else => try escaped_desc.append(allocator, c),
                }
            }
        }

        const prio_str = switch (task.priority) {
            .critical => "critical",
            .high => "high",
            .medium => "medium",
            .low => "low",
            .wishlist => "wishlist",
        };

        try json.appendSlice(allocator, "{\"current_task\": {");
        try json.writer(allocator).print(
            "\"id\": \"{s}\", \"title\": \"{s}\", \"status\": \"{s}\", \"priority\": \"{s}\", \"type\": \"{s}\"",
            .{
                &task.id,
                escaped_title.items,
                task.status.toString(),
                prio_str,
                task.task_type.toString(),
            },
        );

        if (task.description != null) {
            try json.writer(allocator).print(", \"description\": \"{s}\"", .{escaped_desc.items});
        }

        // Add blocked_by count
        try json.writer(allocator).print(", \"blocked_by_count\": {d}", .{task.blocked_by_count});

        // Add comments (Beads audit trail)
        try json.writer(allocator).print(", \"comments\": [", .{});
        for (task.comments, 0..) |comment, i| {
            if (i > 0) try json.writer(allocator).print(",", .{});

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

            try json.writer(allocator).print(
                "{{\"agent\": \"{s}\", \"content\": \"{s}\", \"timestamp\": {d}}}",
                .{ comment.agent, escaped_content.items, comment.timestamp },
            );
        }
        try json.writer(allocator).print("]", .{});

        // Add started_at_commit for Judge workflow (Phase 2 commit tracking)
        if (task.started_at_commit) |commit| {
            try json.writer(allocator).print(", \"started_at_commit\": \"{s}\"", .{commit});
        } else {
            try json.writer(allocator).print(", \"started_at_commit\": null", .{});
        }

        // Get ready count for context
        const counts = store.getTaskCounts();
        try json.writer(allocator).print("}}, \"ready_count\": {d}, \"blocked_count\": {d}}}", .{
            counts.pending,
            counts.blocked,
        });
    } else {
        // No tasks ready
        const counts = store.getTaskCounts();
        try json.writer(allocator).print(
            "{{\"current_task\": null, \"ready_count\": 0, \"blocked_count\": {d}, \"message\": \"No tasks ready. {d} tasks blocked - review dependencies.\"}}",
            .{ counts.blocked, counts.blocked },
        );
    }

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
