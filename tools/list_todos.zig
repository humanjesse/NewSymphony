// List Todos Tool - Lists all current todos with status
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Response struct for JSON serialization
const TodoItem = struct {
    todo_id: []const u8,
    status: []const u8,
    content: []const u8,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "list_todos"),
                .description = try allocator.dupe(u8, "List all todos with their IDs and statuses."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {},
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "list_todos",
            .description = "List all todos",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments;
    const start_time = std.time.milliTimestamp();

    const todos = context.state.getTodos();
    if (todos.len == 0) {
        // Return empty JSON array
        const msg = try allocator.dupe(u8, "[]");
        defer allocator.free(msg);
        return ToolResult.ok(allocator, msg, start_time, null);
    }

    // Build todos array
    var todos_array = std.ArrayListUnmanaged(TodoItem){};
    defer todos_array.deinit(allocator);

    for (todos) |todo| {
        const status_str = switch (todo.status) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };

        try todos_array.append(allocator, .{
            .todo_id = todo.id,
            .status = status_str,
            .content = todo.content,
        });
    }

    const result_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(todos_array.items, .{})});
    defer allocator.free(result_str);
    return ToolResult.ok(allocator, result_str, start_time, null);
}
