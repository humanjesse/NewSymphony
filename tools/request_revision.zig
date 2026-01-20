// Request Revision Tool - Judge rejects work and sends back to Tinkerer
// Sets revision feedback on the task so Tinkerer can see what needs fixing
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store_module = @import("task_store");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "request_revision"),
                .description = try allocator.dupe(u8, "Reject the current implementation and request revisions from Tinkerer. Use this when the work doesn't meet requirements, has bugs, or fails tests. Provide specific feedback on what needs to be fixed."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "The task ID being rejected"
                    \\    },
                    \\    "feedback": {
                    \\      "type": "string",
                    \\      "description": "Detailed feedback explaining what's wrong and how to fix it. Include test failures, specific issues, and guidance."
                    \\    }
                    \\  },
                    \\  "required": ["task_id", "feedback"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "request_revision",
            .description = "Reject implementation and request revisions",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        task_id: ?[]const u8 = null,
        feedback: ?[]const u8 = null,
    };

    const parsed = json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Invalid JSON arguments: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Validate required fields
    const task_id_str = args.task_id orelse {
        return ToolResult.err(allocator, .invalid_arguments, "task_id is required", start_time);
    };

    const feedback = args.feedback orelse {
        return ToolResult.err(allocator, .invalid_arguments, "feedback is required", start_time);
    };

    // Get task store
    const task_store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not available", start_time);
    };

    // Parse task ID
    if (task_id_str.len != 8) {
        return ToolResult.err(allocator, .invalid_arguments, "Invalid task ID format (expected 8 hex chars)", start_time);
    }

    var task_id: task_store_module.TaskId = undefined;
    for (task_id_str, 0..) |c, i| {
        task_id[i] = c;
    }

    // Add a REJECTED comment to the task's audit trail (Beads philosophy)
    const agent_name = context.current_agent_name orelse "judge";
    const rejection_comment = try std.fmt.allocPrint(allocator, "REJECTED: {s}", .{feedback});
    defer allocator.free(rejection_comment);

    task_store.addComment(task_id, agent_name, rejection_comment) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to add rejection comment: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Get rejection count from comments
    const rejection_count = task_store.countCommentsWithPrefix(task_id, agent_name, "REJECTED:");

    // Response struct for JSON serialization
    const Response = struct {
        revision_requested: bool,
        task_id: []const u8,
        rejection_count: usize,
        message: []const u8,
    };

    const response = Response{
        .revision_requested = true,
        .task_id = task_id_str,
        .rejection_count = rejection_count,
        .message = "Revision requested. Tinkerer will receive your feedback.",
    };

    const json_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
