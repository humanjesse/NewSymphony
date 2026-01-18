// Git Utilities - Helper functions for git operations
// Used for commit tracking in the task lifecycle
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Get the current HEAD commit hash (full 40-char SHA)
/// Returns owned string that caller must free
pub fn getCurrentHead(allocator: Allocator, repo_path: ?[]const u8) ![]const u8 {
    var argv_buf: [5][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "git";
    argc += 1;

    if (repo_path) |path| {
        argv_buf[argc] = "-C";
        argc += 1;
        argv_buf[argc] = path;
        argc += 1;
    }

    argv_buf[argc] = "rev-parse";
    argc += 1;
    argv_buf[argc] = "HEAD";
    argc += 1;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_buf[0..argc],
    }) catch return error.GitCommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.GitCommandFailed;
        },
        else => return error.GitCommandFailed,
    }

    // Trim whitespace and validate length (40 hex chars for full SHA)
    const trimmed = mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len < 7) return error.InvalidCommitHash; // At least short hash

    return allocator.dupe(u8, trimmed);
}

/// Check if working directory has uncommitted changes
pub fn hasUncommittedChanges(allocator: Allocator, repo_path: ?[]const u8) !bool {
    var argv_buf: [5][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "git";
    argc += 1;

    if (repo_path) |path| {
        argv_buf[argc] = "-C";
        argc += 1;
        argv_buf[argc] = path;
        argc += 1;
    }

    argv_buf[argc] = "status";
    argc += 1;
    argv_buf[argc] = "--porcelain";
    argc += 1;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_buf[0..argc],
    }) catch return error.GitCommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.GitCommandFailed;
        },
        else => return error.GitCommandFailed,
    }

    // Any output means there are uncommitted changes
    return result.stdout.len > 0;
}

/// Validate that a commit hash exists in the repository
pub fn commitExists(allocator: Allocator, commit_hash: []const u8, repo_path: ?[]const u8) bool {
    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "git";
    argc += 1;

    if (repo_path) |path| {
        argv_buf[argc] = "-C";
        argc += 1;
        argv_buf[argc] = path;
        argc += 1;
    }

    argv_buf[argc] = "cat-file";
    argc += 1;
    argv_buf[argc] = "-t";
    argc += 1;
    argv_buf[argc] = commit_hash;
    argc += 1;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_buf[0..argc],
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
