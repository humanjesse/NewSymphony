// Submit Work Tool - Atomic tool that replaces git_add + git_commit + tinkering_done
// Ensures the Tinkerer can't partially complete the workflow
// Phase 2: Commit tracking for robust Judge review
const std = @import("std");
const json = std.json;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const task_store_module = @import("task_store");
const git_utils = @import("git_utils");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "submit_work"),
                .description = try allocator.dupe(u8, "Submit your work for review. This atomic tool stages ONLY the specified files, commits them, and signals completion. Use this instead of separate git_add/git_commit/tinkering_done calls."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "files": {
                    \\      "type": "array",
                    \\      "items": {"type": "string"},
                    \\      "description": "Array of file paths to commit (only files you created/modified for this task)"
                    \\    },
                    \\    "commit_message": {
                    \\      "type": "string",
                    \\      "description": "Clear commit message describing the change"
                    \\    },
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Brief summary of what was implemented (for audit trail)"
                    \\    }
                    \\  },
                    \\  "required": ["files", "commit_message", "summary"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "submit_work",
            .description = "Submit work for review (atomic git add + commit + signal)",
            .risk_level = .medium,
            .required_scopes = &.{ .write_files, .todo_management },
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const parsed = json.parseFromSlice(json.Value, allocator, arguments, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Invalid JSON arguments: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    // Extract files array
    const files_value = parsed.value.object.get("files") orelse {
        return ToolResult.err(allocator, .validation_failed, "Missing required 'files' array", start_time);
    };
    if (files_value != .array) {
        return ToolResult.err(allocator, .validation_failed, "'files' must be an array", start_time);
    }
    const files_array = files_value.array;
    if (files_array.items.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "'files' array cannot be empty", start_time);
    }

    // Extract commit_message
    const commit_msg_value = parsed.value.object.get("commit_message") orelse {
        return ToolResult.err(allocator, .validation_failed, "Missing required 'commit_message'", start_time);
    };
    if (commit_msg_value != .string) {
        return ToolResult.err(allocator, .validation_failed, "'commit_message' must be a string", start_time);
    }
    const commit_message = commit_msg_value.string;
    if (commit_message.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "'commit_message' cannot be empty", start_time);
    }

    // Extract summary
    const summary_value = parsed.value.object.get("summary") orelse {
        return ToolResult.err(allocator, .validation_failed, "Missing required 'summary'", start_time);
    };
    if (summary_value != .string) {
        return ToolResult.err(allocator, .validation_failed, "'summary' must be a string", start_time);
    }
    const summary = summary_value.string;

    // Step 1: Reset staging area (git reset HEAD)
    {
        const reset_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "reset", "HEAD" },
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to reset staging area: {}", .{err});
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        };
        defer allocator.free(reset_result.stdout);
        defer allocator.free(reset_result.stderr);
        // Note: git reset returns 0 even if there's nothing to reset, so we don't check exit code
    }

    // Step 2: Stage only the specified files
    var staged_files = std.ArrayListUnmanaged([]const u8){};
    defer staged_files.deinit(allocator);

    for (files_array.items) |file_value| {
        if (file_value != .string) continue;
        const file_path = file_value.string;

        const add_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "add", file_path },
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to stage file '{s}': {}", .{ file_path, err });
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        };
        defer allocator.free(add_result.stdout);
        defer allocator.free(add_result.stderr);

        switch (add_result.term) {
            .Exited => |code| {
                if (code != 0) {
                    const msg = if (add_result.stderr.len > 0)
                        try std.fmt.allocPrint(allocator, "Failed to stage '{s}': {s}", .{ file_path, add_result.stderr })
                    else
                        try std.fmt.allocPrint(allocator, "Failed to stage '{s}': file may not exist or not be in a git repository", .{file_path});
                    defer allocator.free(msg);
                    return ToolResult.err(allocator, .io_error, msg, start_time);
                }
            },
            else => {
                const msg = try std.fmt.allocPrint(allocator, "git add terminated abnormally for '{s}'", .{file_path});
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            },
        }

        try staged_files.append(allocator, file_path);
    }

    // Step 3: Create the commit
    const commit_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "commit", "-m", commit_message },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to create commit: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);

    switch (commit_result.term) {
        .Exited => |code| {
            if (code != 0) {
                const msg = if (commit_result.stderr.len > 0)
                    try std.fmt.allocPrint(allocator, "git commit failed: {s}", .{commit_result.stderr})
                else
                    try allocator.dupe(u8, "git commit failed (nothing staged or other issue)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git commit terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Step 4: Get the new HEAD commit hash
    var commit_hash: ?[]const u8 = null;
    {
        const head = git_utils.getCurrentHead(allocator, null) catch |err| blk: {
            std.log.warn("Failed to get HEAD commit after submit_work: {}", .{err});
            break :blk null;
        };
        commit_hash = head;
    }
    defer if (commit_hash) |h| allocator.free(h);

    // Step 5: Update task with completed_at_commit and add SUMMARY comment
    if (context.task_store) |store| {
        if (store.getCurrentTaskId()) |task_id| {
            // Set completed_at_commit
            if (commit_hash) |hash| {
                store.setTaskCompletedCommit(task_id, hash) catch |err| {
                    std.log.warn("Failed to set completed_at_commit: {}", .{err});
                };
            }

            // Add SUMMARY comment to audit trail
            const agent_name = context.current_agent_name orelse "tinkerer";
            const summary_comment = try std.fmt.allocPrint(allocator, "SUMMARY: {s}", .{summary});
            defer allocator.free(summary_comment);

            store.addComment(task_id, agent_name, summary_comment) catch |err| {
                std.log.warn("Failed to add summary comment: {}", .{err});
            };
        }
    }

    // Step 6: Signal tinkering complete (triggers Judge)
    if (context.tinkering_complete_ptr) |ptr| {
        ptr.* = true;
    }

    // Response struct for JSON serialization
    const Response = struct {
        success: bool,
        message: []const u8,
        commit_hash: ?[]const u8 = null,
        files_committed: usize,
        summary: []const u8,
        commit_output: ?[]const u8 = null,
    };

    // Truncate commit output if needed
    const commit_output: ?[]const u8 = if (commit_result.stdout.len > 0)
        commit_result.stdout[0..@min(commit_result.stdout.len, 500)]
    else
        null;

    const response = Response{
        .success = true,
        .message = "Work submitted for review.",
        .commit_hash = commit_hash,
        .files_committed = staged_files.items.len,
        .summary = summary,
        .commit_output = commit_output,
    };

    const json_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(json_result);

    return ToolResult.ok(allocator, json_result, start_time, null);
}
