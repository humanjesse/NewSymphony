// Approve Task Tool - Mark a task as approved for execution
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
const ApprovedTask = struct {
    id: []const u8,
    title: []const u8,
};

const Response = struct {
    approved: bool,
    task: ApprovedTask,
    reason: []const u8,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "approve_task"),
                .description = try allocator.dupe(u8, "Approve a task as ready for execution. Use this when a task is clear, actionable, and appropriately sized."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "Task to approve. Defaults to current task if not specified."
                    \\    },
                    \\    "reason": {
                    \\      "type": "string",
                    \\      "description": "Why this task is approved (e.g., 'Task is clear, bite-sized, and actionable')"
                    \\    }
                    \\  },
                    \\  "required": ["reason"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "approve_task",
            .description = "Approve a task for execution",
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

    const reason = if (parsed.value.object.get("reason")) |v|
        if (v == .string) v.string else null
    else
        null;

    if (reason == null) {
        return ToolResult.err(allocator, .invalid_arguments, "reason is required", start_time);
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

    // Get the task (using arena - auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const task = (try store.getTaskWithAllocator(task_id, task_alloc)) orelse {
        return ToolResult.err(allocator, .internal_error, "Task not found", start_time);
    };
    // No defer needed - arena handles cleanup

    // Add a comment with the approval reason (Beads philosophy)
    const agent_name = context.current_agent_name orelse "unknown";
    const approve_comment = try std.fmt.allocPrint(allocator, "APPROVED: {s}", .{reason.?});
    defer allocator.free(approve_comment);
    store.addComment(task_id, agent_name, approve_comment) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to add approval comment", start_time);
    };

    // Note: We don't change task status - it remains in_progress, ready for Tinkerer

    // Build response
    const response = Response{
        .approved = true,
        .task = .{
            .id = &task_id,
            .title = task.title,
        },
        .reason = reason.?,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
