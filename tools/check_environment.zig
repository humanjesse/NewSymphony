// Check Environment Tool - Startup environment assessment
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
                .name = try allocator.dupe(u8, "check_environment"),
                .description = try allocator.dupe(u8, "Check workspace environment status: git repo, uncommitted changes, tasks directory, and previous session state. Use at startup to assess workspace."),
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
            .name = "check_environment",
            .description = "Check workspace environment status",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, args_json: []const u8, context: *AppContext) !ToolResult {
    _ = args_json;
    const start_time = std.time.milliTimestamp();

    // Response structs for JSON serialization
    const PreviousSession = struct {
        exists: bool,
        task_count: ?usize = null,
        pending: ?usize = null,
        in_progress: ?usize = null,
        completed: ?usize = null,
        blocked: ?usize = null,
    };

    const Response = struct {
        git_repo: bool,
        git_root: ?[]const u8,
        uncommitted_changes: bool,
        uncommitted_files: []const []const u8,
        tasks_dir_exists: bool,
        previous_session: PreviousSession,
        session_notes: ?[]const u8 = null,
    };

    // Check if we're in a git repository
    var is_git_repo = false;
    var git_root: ?[]const u8 = null;

    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--show-toplevel" },
    }) catch null;

    if (git_check) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0 and result.stdout.len > 0) {
                    is_git_repo = true;
                    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r");
                    git_root = try allocator.dupe(u8, trimmed);
                }
            },
            else => {},
        }
    }
    defer if (git_root) |root| allocator.free(root);

    // Check for uncommitted changes
    var has_uncommitted = false;
    var uncommitted_files = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (uncommitted_files.items) |f| allocator.free(f);
        uncommitted_files.deinit(allocator);
    }

    if (is_git_repo) {
        const status_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "status", "--porcelain" },
        }) catch null;

        if (status_result) |result| {
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            switch (result.term) {
                .Exited => |code| {
                    if (code == 0 and result.stdout.len > 0) {
                        has_uncommitted = true;

                        // Parse uncommitted files (limit to 10 for brevity)
                        var lines = std.mem.splitSequence(u8, result.stdout, "\n");
                        var count: usize = 0;
                        while (lines.next()) |line| {
                            if (line.len > 3 and count < 10) {
                                const filename = std.mem.trim(u8, line[3..], " ");
                                if (!std.mem.startsWith(u8, filename, ".tasks/")) {
                                    try uncommitted_files.append(allocator, try allocator.dupe(u8, filename));
                                    count += 1;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Check if .tasks/ directory exists
    var tasks_dir_exists = false;
    if (git_root) |root| {
        const tasks_path = try std.fmt.allocPrint(allocator, "{s}/.tasks", .{root});
        defer allocator.free(tasks_path);

        if (std.fs.cwd().statFile(tasks_path)) |stat| {
            tasks_dir_exists = stat.kind == .directory;
        } else |_| {}
    }

    // Check for previous session state
    var previous_session = PreviousSession{ .exists = false };
    const store = context.task_store;
    if (store) |s| {
        if (s.getTaskCounts()) |counts| {
            const total = counts.pending + counts.in_progress + counts.completed + counts.blocked;

            if (total > 0) {
                previous_session = .{
                    .exists = true,
                    .task_count = total,
                    .pending = counts.pending,
                    .in_progress = counts.in_progress,
                    .completed = counts.completed,
                    .blocked = counts.blocked,
                };
            }
        } else |_| {}
    }

    // Get session notes if available
    var session_notes: ?[]const u8 = null;
    if (context.git_sync) |gs| {
        if (try gs.parseSessionState()) |parsed_state| {
            var mutable_state = parsed_state;
            defer mutable_state.deinit(allocator);
            if (mutable_state.notes) |notes| {
                session_notes = try allocator.dupe(u8, notes);
            }
        }
    }
    defer if (session_notes) |n| allocator.free(n);

    // Build response and serialize
    const response = Response{
        .git_repo = is_git_repo,
        .git_root = git_root,
        .uncommitted_changes = has_uncommitted,
        .uncommitted_files = uncommitted_files.items,
        .tasks_dir_exists = tasks_dir_exists,
        .previous_session = previous_session,
        .session_notes = session_notes,
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
