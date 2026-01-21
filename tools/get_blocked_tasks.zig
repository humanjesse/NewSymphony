// Get Blocked Tasks Tool - Find tasks that are blocked with reasons
// Used by planner to query which tasks need decomposition
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
                .name = try allocator.dupe(u8, "get_blocked_tasks"),
                .description = try allocator.dupe(u8, "Get tasks that are blocked with reasons. Returns tasks that need decomposition by planner."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {}
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_blocked_tasks",
            .description = "Get blocked tasks with reasons",
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

    // Get tasks with BLOCKED: comments using arena allocator (auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const blocked_tasks = store.getTasksWithCommentPrefixWithAllocator("BLOCKED:", task_alloc) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get blocked tasks", start_time);
    };
    // No defer needed - arena handles cleanup

    // Response structs for JSON serialization
    const BlockedTaskInfo = struct {
        id: []const u8,
        title: []const u8,
        priority: u8,
        @"type": []const u8,
        blocked_reason: []const u8,
    };

    const Response = struct {
        blocked: []const BlockedTaskInfo,
        count: usize,
    };

    // Build blocked task info array
    var task_infos = std.ArrayListUnmanaged(BlockedTaskInfo){};
    defer task_infos.deinit(allocator);

    var id_bufs = try allocator.alloc([8]u8, blocked_tasks.len);
    defer allocator.free(id_bufs);

    for (blocked_tasks, 0..) |task, i| {
        @memcpy(&id_bufs[i], &task.id);

        // Find the most recent BLOCKED: comment to extract reason
        var blocked_reason: []const u8 = "";
        var j = task.comments.len;
        while (j > 0) {
            j -= 1;
            if (std.mem.startsWith(u8, task.comments[j].content, "BLOCKED:")) {
                blocked_reason = task.comments[j].content[8..];
                while (blocked_reason.len > 0 and blocked_reason[0] == ' ') {
                    blocked_reason = blocked_reason[1..];
                }
                break;
            }
        }

        try task_infos.append(allocator, .{
            .id = &id_bufs[i],
            .title = task.title,
            .priority = task.priority.toInt(),
            .@"type" = task.task_type.toString(),
            .blocked_reason = blocked_reason,
        });
    }

    const response = Response{
        .blocked = task_infos.items,
        .count = blocked_tasks.len,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
