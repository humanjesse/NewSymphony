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

// Response structs for JSON serialization
const ReadyTask = struct {
    id: []const u8,
    title: []const u8,
    priority: u8,
    type: []const u8,
};

const Response = struct {
    ready: []const ReadyTask,
    ready_count: usize,
    total_pending: usize,
    total_blocked: usize,
};

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

    // Get ready tasks using arena allocator (auto-freed when tool returns)
    const task_alloc = if (context.task_arena) |a| a.allocator() else allocator;
    const ready_tasks = store.getReadyTasksWithAllocator(task_alloc) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get ready tasks", start_time);
    };
    // No defer needed - arena handles cleanup

    // Build ready tasks array
    var ready_array = std.ArrayListUnmanaged(ReadyTask){};
    defer ready_array.deinit(allocator);

    for (ready_tasks) |task| {
        try ready_array.append(allocator, .{
            .id = &task.id,
            .title = task.title,
            .priority = task.priority.toInt(),
            .type = task.task_type.toString(),
        });
    }

    const counts = try store.getTaskCounts();

    const response = Response{
        .ready = ready_array.items,
        .ready_count = ready_tasks.len,
        .total_pending = counts.pending,
        .total_blocked = counts.blocked,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
