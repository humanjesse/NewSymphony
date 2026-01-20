// Planning Done Tool - Signal that planning phase is complete
// When called, sets executor's planning_complete flag via pointer
// This causes the agent executor to return .complete instead of .needs_input
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "planning_done"),
                .description = try allocator.dupe(u8, "Signal that planning is complete. Call this when you have finished creating tasks and the user has confirmed the plan. This ends your session and triggers the next phase."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Brief summary of what was planned (optional)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "planning_done",
            .description = "Signal planning phase is complete",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse optional summary from arguments
    var summary: ?[]const u8 = null;
    if (arguments.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("summary")) |v| {
                    if (v == .string) {
                        // Dupe the string before parsed JSON is freed
                        summary = try allocator.dupe(u8, v.string);
                    }
                }
            }
        }
    }
    defer if (summary) |s| allocator.free(s);

    // Set the flag to signal completion (directly on executor via pointer)
    if (context.planning_complete_ptr) |ptr| {
        ptr.* = true;
    }

    // Response struct for JSON serialization
    const Response = struct {
        planning_done: bool,
        message: []const u8,
        summary: ?[]const u8 = null,
    };

    const response = Response{
        .planning_done = true,
        .message = "Planning phase complete. Transitioning to task evaluation.",
        .summary = summary,
    };

    const json_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
