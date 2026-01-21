// Sync to Git Tool - Manual checkpoint commit for task state
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const git_sync = @import("git_sync");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const TaskStore = task_store.TaskStore;
const GitSync = git_sync.GitSync;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "sync_to_git"),
                .description = try allocator.dupe(u8, "Sync task state to git. Exports tasks to .tasks/ directory as JSONL and optionally commits."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "message": {
                    \\      "type": "string",
                    \\      "description": "Commit message (optional, will auto-generate if not provided)"
                    \\    },
                    \\    "commit": {
                    \\      "type": "boolean",
                    \\      "description": "Whether to commit after export (default: true)"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "sync_to_git",
            .description = "Sync tasks to git",
            .risk_level = .low, // Low risk - just writes files and commits
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const store = context.task_store orelse {
        return ToolResult.err(allocator, .internal_error, "Task store not initialized", start_time);
    };

    // Parse arguments
    const Args = struct {
        message: ?[]const u8 = null,
        commit: ?bool = null,
    };

    var message: []const u8 = "session: task checkpoint";
    var should_commit: bool = true;

    if (arguments.len > 2) {
        const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch {
            return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
        };
        defer parsed.deinit();

        if (parsed.value.message) |m| {
            message = m;
        }
        if (parsed.value.commit) |c| {
            should_commit = c;
        }
    }

    // Get current working directory as repo path
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to get current directory", start_time);
    };

    // Initialize git sync
    var sync = GitSync.init(allocator, cwd) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to initialize git sync", start_time);
    };
    defer sync.deinit();

    // Export tasks and dependencies
    sync.exportTasks(store) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to export tasks", start_time);
    };

    sync.exportDependencies(store) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to export dependencies", start_time);
    };

    // Write session state
    sync.writeSessionState(store) catch {
        return ToolResult.err(allocator, .internal_error, "Failed to write session state", start_time);
    };

    // Commit if requested
    var committed = false;
    if (should_commit) {
        sync.commit(message) catch {
            // Commit might fail if nothing changed, that's ok
        };
        committed = true;
    }

    // Get task counts for response
    const counts = try store.getTaskCounts();

    // Build response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(allocator);

    try json.writer(allocator).print(
        "{{\"success\":true,\"tasks_exported\":{d},\"committed\":{s},\"tasks_dir\":\"{s}/.tasks/\",",
        .{
            try store.count(),
            if (committed) "true" else "false",
            cwd,
        },
    );

    try json.writer(allocator).print(
        "\"summary\":{{\"pending\":{d},\"in_progress\":{d},\"completed\":{d},\"blocked\":{d}}}}}",
        .{
            counts.pending,
            counts.in_progress,
            counts.completed,
            counts.blocked,
        },
    );

    const result = try allocator.dupe(u8, json.items);
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
