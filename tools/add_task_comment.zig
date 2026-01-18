// Add Task Comment Tool - Append a comment to a task's audit trail (Beads philosophy)
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
                .name = try allocator.dupe(u8, "add_task_comment"),
                .description = try allocator.dupe(u8, "Add a comment to a task's audit trail. Use prefixes like 'BLOCKED:', 'REJECTED:', 'APPROVED:', 'SUMMARY:' for structured communication between agents."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to comment on. Defaults to current task if not specified."
                    \\    },
                    \\    "comment": {
                    \\      "type": "string",
                    \\      "description": "The comment to add. Use prefixes for structured feedback: BLOCKED:, REJECTED:, APPROVED:, SUMMARY:"
                    \\    }
                    \\  },
                    \\  "required": ["comment"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "add_task_comment",
            .description = "Add comment to task",
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

    const comment = if (parsed.value.object.get("comment")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (comment == null) {
        return ToolResult.err(allocator, .invalid_arguments, "comment is required", start_time);
    }

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

    // Get the task (verify it exists)
    const task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };

    // Determine agent name from context (default to "unknown")
    const agent_name = context.current_agent_name orelse "unknown";

    // Add the comment
    store.addComment(task_id, agent_name, comment.?) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to add comment", start_time);
    };

    // Get the updated task to access the newly added comment
    const updated_task = store.getTask(task_id) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found after adding comment", start_time);
    };

    // Persist comment to database if available (O(1) append instead of O(n) replace)
    if (context.task_db) |db| {
        if (updated_task.comments.len > 0) {
            const new_comment = updated_task.comments[updated_task.comments.len - 1];
            db.appendComment(&task_id, new_comment) catch |err| {
                std.log.warn("Failed to persist comment to SQLite: {}", .{err});
            };
        }
    }

    // Build response
    var result_json = std.ArrayListUnmanaged(u8){};
    defer result_json.deinit(allocator);

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

    // Escape comment for JSON
    var escaped_comment = std.ArrayListUnmanaged(u8){};
    defer escaped_comment.deinit(allocator);
    for (comment.?) |c| {
        switch (c) {
            '"' => try escaped_comment.appendSlice(allocator, "\\\""),
            '\\' => try escaped_comment.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_comment.appendSlice(allocator, "\\n"),
            '\r' => try escaped_comment.appendSlice(allocator, "\\r"),
            '\t' => try escaped_comment.appendSlice(allocator, "\\t"),
            else => try escaped_comment.append(allocator, c),
        }
    }

    try result_json.writer(allocator).print(
        "{{\"success\": true, \"task\": {{\"id\": \"{s}\", \"title\": \"{s}\"}}, \"agent\": \"{s}\", \"comment\": \"{s}\", \"total_comments\": {d}}}",
        .{
            &task_id,
            escaped_title.items,
            agent_name,
            escaped_comment.items,
            updated_task.comments.len,
        },
    );

    const result = try allocator.dupe(u8, result_json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
