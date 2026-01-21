// End Session Tool - Graceful shutdown with auto-summary
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

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "end_session"),
                .description = try allocator.dupe(u8, "End the current session gracefully: auto-generate summary from completed tasks, save session state, and commit to git. Use when user indicates they're done."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Optional override for auto-generated summary"
                    \\    },
                    \\    "notes_for_next_session": {
                    \\      "type": "string",
                    \\      "description": "Notes and context for the next session"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "end_session",
            .description = "End session gracefully with auto-summary",
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
    var user_summary: ?[]const u8 = null;
    var notes_for_next: ?[]const u8 = null;

    if (args_json.len > 2) {
        const parsed = json.parseFromSlice(json.Value, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("summary")) |v| {
                if (v == .string) user_summary = v.string;
            }
            if (p.value.object.get("notes_for_next_session")) |v| {
                if (v == .string) notes_for_next = v.string;
            }
        }
    }

    // Get task counts for summary
    const counts = try store.getTaskCounts();

    // Auto-generate summary from completed tasks if not provided
    var auto_summary = std.ArrayListUnmanaged(u8){};
    defer auto_summary.deinit(allocator);

    if (user_summary == null) {
        // Collect recently completed tasks from SQLite
        const completed_tasks = try store.db.getTasksByStatus(.completed);
        defer {
            for (completed_tasks) |*t| {
                var task = t.*;
                task.deinit(allocator);
            }
            allocator.free(completed_tasks);
        }

        // Sort by completion time (most recent first)
        std.mem.sort(task_store.Task, completed_tasks, {}, struct {
            fn cmp(_: void, a: task_store.Task, b: task_store.Task) bool {
                return (a.completed_at orelse 0) > (b.completed_at orelse 0);
            }
        }.cmp);

        // Build summary from completed task titles
        if (completed_tasks.len > 0) {
            try auto_summary.appendSlice(allocator, "Completed: ");
            const max_items = @min(5, completed_tasks.len);
            for (completed_tasks[0..max_items], 0..) |task, i| {
                if (i > 0) try auto_summary.appendSlice(allocator, ", ");
                try auto_summary.appendSlice(allocator, task.title);
            }
            if (completed_tasks.len > 5) {
                try auto_summary.writer(allocator).print(" (+{d} more)", .{completed_tasks.len - 5});
            }
        } else {
            try auto_summary.appendSlice(allocator, "Session ended (no tasks completed)");
        }
    }

    const final_summary = user_summary orelse auto_summary.items;

    // Build combined notes for SESSION_STATE.md
    var session_notes = std.ArrayListUnmanaged(u8){};
    defer session_notes.deinit(allocator);

    try session_notes.appendSlice(allocator, "Session summary: ");
    try session_notes.appendSlice(allocator, final_summary);
    try session_notes.appendSlice(allocator, "\n");

    if (notes_for_next) |notes| {
        try session_notes.appendSlice(allocator, "Next session: ");
        try session_notes.appendSlice(allocator, notes);
        try session_notes.appendSlice(allocator, "\n");
    }

    // Add task summary to notes
    try session_notes.writer(allocator).print(
        "Tasks: {d} completed, {d} pending, {d} blocked\n",
        .{ counts.completed, counts.pending, counts.blocked },
    );

    // Check for uncommitted code changes (warn user)
    var code_warning: ?[]const u8 = null;
    if (gs.hasUncommittedCodeChanges()) |has_changes| {
        if (has_changes) {
            code_warning = "Warning: You have uncommitted code changes. Consider committing your code separately.";
        }
    } else |_| {}

    // Sync everything to git
    gs.syncAllWithNotes(store, try allocator.dupe(u8, session_notes.items)) catch |err| {
        const msg = switch (err) {
            error.FileNotFound => "Failed to write to .tasks/ directory",
            else => "Failed to sync tasks",
        };
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Commit to git
    const commit_msg = try std.fmt.allocPrint(allocator, "beads: {s}", .{final_summary});
    defer allocator.free(commit_msg);

    var git_warning: ?[]const u8 = null;
    gs.commit(commit_msg) catch |err| {
        std.log.warn("Failed to commit .tasks/: {}", .{err});
        git_warning = "Git commit failed - tasks saved to disk but not committed";
    };

    // Build handoff notes
    var handoff = std.ArrayListUnmanaged(u8){};
    defer handoff.deinit(allocator);

    if (counts.in_progress > 0) {
        try handoff.writer(allocator).print("{d} task(s) still in progress. ", .{counts.in_progress});
    }
    if (counts.blocked > 0) {
        try handoff.writer(allocator).print("{d} task(s) blocked. ", .{counts.blocked});
    }
    if (counts.pending > 0) {
        try handoff.writer(allocator).print("{d} task(s) pending. ", .{counts.pending});
    }

    // Response struct for JSON serialization
    const Response = struct {
        ended: bool,
        summary: []const u8,
        tasks_saved: usize,
        completed: usize,
        pending: usize,
        blocked: usize,
        notes_for_next_session: ?[]const u8 = null,
        handoff_notes: ?[]const u8 = null,
        warning: ?[]const u8 = null,
        git_warning: ?[]const u8 = null,
    };

    const response = Response{
        .ended = true,
        .summary = final_summary,
        .tasks_saved = try store.count(),
        .completed = counts.completed,
        .pending = counts.pending,
        .blocked = counts.blocked,
        .notes_for_next_session = notes_for_next,
        .handoff_notes = if (handoff.items.len > 0) handoff.items else null,
        .warning = code_warning,
        .git_warning = git_warning,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
