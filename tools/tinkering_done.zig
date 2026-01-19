// Tinkering Done Tool - Signal that implementation is complete and ready for review
// When called, sets executor's tinkering_complete flag via pointer
// This causes the orchestrator to trigger the Judge agent for review
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
                .name = try allocator.dupe(u8, "tinkering_done"),
                .description = try allocator.dupe(u8, "Signal that implementation is complete and ready for review. Call this after you have finished making changes and staged them with git_add. This triggers the Judge agent to review your work."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Brief summary of what was implemented (required)"
                    \\    }
                    \\  },
                    \\  "required": ["summary"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "tinkering_done",
            .description = "Signal implementation ready for review",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse summary from arguments
    var summary: []const u8 = "No summary provided";
    if (arguments.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("summary")) |v| {
                    if (v == .string) {
                        summary = v.string;
                    }
                }
            }
        }
    }

    // Set the flag to signal completion (directly on executor via pointer)
    if (context.tinkering_complete_ptr) |ptr| {
        ptr.* = true;
    }

    // Add a SUMMARY comment to the current task's audit trail (Beads philosophy)
    if (context.task_store) |store| {
        if (store.getCurrentTaskId()) |task_id| {
            const agent_name = context.current_agent_name orelse "tinkerer";
            const summary_comment = try std.fmt.allocPrint(allocator, "SUMMARY: {s}", .{summary});
            defer allocator.free(summary_comment);

            store.addComment(task_id, agent_name, summary_comment) catch |err| {
                std.log.warn("Failed to add summary comment: {}", .{err});
            };
        }
    }

    // Response struct for JSON serialization
    const Response = struct {
        tinkering_done: bool,
        message: []const u8,
        summary: []const u8,
    };

    const response = Response{
        .tinkering_done = true,
        .message = "Implementation complete. Submitting for review.",
        .summary = summary,
    };

    const json_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
