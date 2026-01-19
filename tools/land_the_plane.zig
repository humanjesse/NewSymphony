// Land The Plane Tool - End session cleanly with git sync
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store = @import("task_store");
const git_sync = @import("git_sync");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Response struct for JSON serialization
const Response = struct {
    landed: bool,
    summary: ?[]const u8 = null,
    tasks_saved: usize,
    completed: usize,
    pending: usize,
    blocked: usize,
    warning: ?[]const u8 = null,
    git_warning: ?[]const u8 = null,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "land_the_plane"),
                .description = try allocator.dupe(u8, "End session cleanly: export tasks, generate SESSION_STATE.md, and commit to git."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Summary of what was accomplished this session"
                    \\    },
                    \\    "notes": {
                    \\      "type": "string",
                    \\      "description": "Notes for the next session"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "land_the_plane",
            .description = "End session and commit to git",
            .risk_level = .medium,
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

    const gs = context.git_sync orelse {
        return ToolResult.err(allocator, .internal_error, "Git sync not initialized. Are you in a git repository?", start_time);
    };

    // Parse arguments
    var summary: ?[]const u8 = null;
    var notes: ?[]const u8 = null;

    if (args_json.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("summary")) |v| {
                if (v == .string) summary = v.string;
            }
            if (p.value.object.get("notes")) |v| {
                if (v == .string) notes = v.string;
            }
        }
    }

    // Check for uncommitted code changes
    var code_warning: ?[]const u8 = null;
    if (gs.hasUncommittedCodeChanges()) |has_changes| {
        if (has_changes) {
            code_warning = "Warning: You have uncommitted code changes. Consider committing your code separately.";
        }
    } else |_| {}

    // Build combined notes for SESSION_STATE.md
    var session_notes = std.ArrayListUnmanaged(u8){};
    defer session_notes.deinit(allocator);

    if (summary) |s| {
        try session_notes.appendSlice(allocator, "Session summary: ");
        try session_notes.appendSlice(allocator, s);
        try session_notes.appendSlice(allocator, "\n");
    }
    if (notes) |n| {
        try session_notes.appendSlice(allocator, "Next session: ");
        try session_notes.appendSlice(allocator, n);
    }

    const notes_str = if (session_notes.items.len > 0)
        try allocator.dupe(u8, session_notes.items)
    else
        null;
    defer if (notes_str) |n| allocator.free(n);

    // Sync everything to git
    gs.syncAllWithNotes(store, notes_str) catch |err| {
        const msg = switch (err) {
            error.FileNotFound => "Failed to write to .tasks/ directory",
            else => "Failed to sync tasks",
        };
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Commit to git
    const commit_msg = if (summary) |s|
        try std.fmt.allocPrint(allocator, "beads: {s}", .{s})
    else
        try allocator.dupe(u8, "beads: session checkpoint");
    defer allocator.free(commit_msg);

    var git_warning: ?[]const u8 = null;
    gs.commit(commit_msg) catch |err| {
        // Log the error but continue - sync to disk succeeded
        std.log.warn("Failed to commit .tasks/: {}", .{err});
        git_warning = "Git commit failed - tasks saved to disk but not committed";
    };

    // Build response
    const counts = store.getTaskCounts();

    const response = Response{
        .landed = true,
        .summary = summary,
        .tasks_saved = store.tasks.count(),
        .completed = counts.completed,
        .pending = counts.pending,
        .blocked = counts.blocked,
        .warning = code_warning,
        .git_warning = git_warning,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
