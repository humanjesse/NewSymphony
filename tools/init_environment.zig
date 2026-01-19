// Init Environment Tool - Environment remediation actions
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
                .name = try allocator.dupe(u8, "init_environment"),
                .description = try allocator.dupe(u8, "Fix environment issues: initialize git repo, stash uncommitted changes, or create tasks directory."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "action": {
                    \\      "type": "string",
                    \\      "enum": ["git_init", "git_stash", "create_tasks_dir"],
                    \\      "description": "Action to perform: git_init (initialize git repo), git_stash (stash uncommitted changes), create_tasks_dir (create .tasks/ directory)"
                    \\    },
                    \\    "stash_message": {
                    \\      "type": "string",
                    \\      "description": "Optional message for git_stash action"
                    \\    }
                    \\  },
                    \\  "required": ["action"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "init_environment",
            .description = "Initialize or fix environment issues",
            .risk_level = .medium,
            .required_scopes = &.{.write_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, args_json: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        action: []const u8,
        stash_message: ?[]const u8 = null,
    };

    const parsed = json.parseFromSlice(Args, allocator, args_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Invalid JSON arguments: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    const is_git_init = std.mem.eql(u8, args.action, "git_init");
    const is_git_stash = std.mem.eql(u8, args.action, "git_stash");
    const is_create_tasks = std.mem.eql(u8, args.action, "create_tasks_dir");

    if (!is_git_init and !is_git_stash and !is_create_tasks) {
        const msg = try std.fmt.allocPrint(allocator, "Invalid action: {s}. Must be 'git_init', 'git_stash', or 'create_tasks_dir'", .{args.action});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    if (is_git_init) {
        return executeGitInit(allocator, start_time);
    } else if (is_git_stash) {
        return executeGitStash(allocator, args.stash_message, start_time);
    } else if (is_create_tasks) {
        return executeCreateTasksDir(allocator, context, start_time);
    }

    return ToolResult.err(allocator, .internal_error, "Unknown action", start_time);
}

fn executeGitInit(allocator: std.mem.Allocator, start_time: i64) !ToolResult {
    // Check if already a git repo
    const check_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--is-inside-work-tree" },
    }) catch null;

    if (check_result) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    return ToolResult.err(allocator, .validation_failed, "Already inside a git repository", start_time);
                }
            },
            else => {},
        }
    }

    // Initialize git repo
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init" },
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to initialize git: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    switch (init_result.term) {
        .Exited => |code| {
            if (code != 0) {
                const msg = if (init_result.stderr.len > 0)
                    try std.fmt.allocPrint(allocator, "git init failed: {s}", .{init_result.stderr})
                else
                    try allocator.dupe(u8, "git init failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            return ToolResult.err(allocator, .io_error, "git init terminated abnormally", start_time);
        },
    }

    // Create initial .gitignore if it doesn't exist
    const gitignore_exists = std.fs.cwd().statFile(".gitignore") catch null;
    if (gitignore_exists == null) {
        const gitignore_content =
            \\# Dependencies
            \\node_modules/
            \\vendor/
            \\
            \\# Build outputs
            \\zig-cache/
            \\zig-out/
            \\target/
            \\dist/
            \\build/
            \\
            \\# IDE
            \\.idea/
            \\.vscode/
            \\*.swp
            \\*.swo
            \\
            \\# Environment
            \\.env
            \\.env.local
            \\
        ;
        std.fs.cwd().writeFile(.{
            .sub_path = ".gitignore",
            .data = gitignore_content,
        }) catch {};
    }

    const Response = struct {
        success: bool,
        action: []const u8,
        message: []const u8,
        stash_message: ?[]const u8 = null,
    };

    const response = Response{
        .success = true,
        .action = "git_init",
        .message = "Git repository initialized successfully",
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}

fn executeGitStash(allocator: std.mem.Allocator, message: ?[]const u8, start_time: i64) !ToolResult {
    // Build stash command
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "stash");
    try argv.append(allocator, "push");
    try argv.append(allocator, "-m");

    const stash_msg = message orelse "Auto-stash before session";
    try argv.append(allocator, stash_msg);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute git stash: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const msg = if (result.stderr.len > 0)
                    try std.fmt.allocPrint(allocator, "git stash failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git stash failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            return ToolResult.err(allocator, .io_error, "git stash terminated abnormally", start_time);
        },
    }

    const Response = struct {
        success: bool,
        action: []const u8,
        message: []const u8,
        stash_message: []const u8,
    };

    const response = Response{
        .success = true,
        .action = "git_stash",
        .message = "Changes stashed successfully",
        .stash_message = stash_msg,
    };

    const final_result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(final_result);

    return ToolResult.ok(allocator, final_result, start_time, null);
}

fn executeCreateTasksDir(allocator: std.mem.Allocator, context: *AppContext, start_time: i64) !ToolResult {
    const Response = struct {
        success: bool,
        action: []const u8,
        message: []const u8,
    };

    // Try to use git_sync if available (it handles all the details)
    if (context.git_sync) |gs| {
        gs.ensureTasksDir() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to create .tasks/ directory: {}", .{err});
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        };

        const response = Response{
            .success = true,
            .action = "create_tasks_dir",
            .message = ".tasks/ directory created successfully",
        };

        const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
        defer allocator.free(result);

        return ToolResult.ok(allocator, result, start_time, null);
    }

    // Fallback: try to create .tasks/ in current directory
    std.fs.cwd().makeDir(".tasks") catch |err| {
        if (err == error.PathAlreadyExists) {
            const response = Response{
                .success = true,
                .action = "create_tasks_dir",
                .message = ".tasks/ directory already exists",
            };

            const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
            defer allocator.free(result);

            return ToolResult.ok(allocator, result, start_time, null);
        }

        const msg = try std.fmt.allocPrint(allocator, "Failed to create .tasks/ directory: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    const response = Response{
        .success = true,
        .action = "create_tasks_dir",
        .message = ".tasks/ directory created successfully",
    };

    const result = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(response, .{})});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
