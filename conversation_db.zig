// Conversation database module - SQLite persistence for all conversation data
const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("types");
const ollama = @import("ollama");
const markdown = @import("markdown");

const Allocator = std.mem.Allocator;

/// Row data loaded from the messages table
/// Contains all fields needed to reconstruct a Message
pub const MessageRow = struct {
    id: i64,
    message_index: i64,
    role: []const u8,
    content: []const u8,
    thinking_content: ?[]const u8,
    timestamp: i64,
    tool_call_id: ?[]const u8,
    thinking_expanded: bool,
    tool_call_expanded: bool,
    tool_name: ?[]const u8,
    tool_success: ?bool,
    tool_execution_time: ?i64,
    agent_analysis_name: ?[]const u8,
    agent_analysis_expanded: bool,
    agent_analysis_completed: bool,
    agent_source: ?[]const u8,

    pub fn deinit(self: *MessageRow, allocator: Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.thinking_content) |tc| allocator.free(tc);
        if (self.tool_call_id) |tcid| allocator.free(tcid);
        if (self.tool_name) |tn| allocator.free(tn);
        if (self.agent_analysis_name) |aan| allocator.free(aan);
        if (self.agent_source) |as| allocator.free(as);
    }
};

pub const ConversationDB = struct {
    db: *sqlite.Db,
    allocator: Allocator,

    const Self = @This();

    /// Initialize database connection and create schema if needed
    pub fn init(allocator: Allocator, db_path: []const u8) !Self {
        // Open database with WAL mode for better concurrency
        const db = try sqlite.open(
            db_path,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        );
        errdefer sqlite.close(db);

        var self = Self{
            .db = db,
            .allocator = allocator,
        };

        // Enable WAL mode for non-blocking reads during writes
        try sqlite.exec(db, "PRAGMA journal_mode=WAL");

        // Enable foreign keys
        try sqlite.exec(db, "PRAGMA foreign_keys=ON");

        // Create schema if it doesn't exist
        try self.createSchema();

        return self;
    }

    pub fn deinit(self: *Self) void {
        sqlite.close(self.db);
    }

    /// Create database schema
    fn createSchema(self: *Self) !void {
        // Conversations table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS conversations (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    profile_name TEXT NOT NULL,
            \\    started_at INTEGER NOT NULL,
            \\    last_message_at INTEGER NOT NULL,
            \\    message_count INTEGER DEFAULT 0,
            \\    tool_call_count INTEGER DEFAULT 0,
            \\    iteration_count INTEGER DEFAULT 0
            \\)
        );

        // Messages table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    conversation_id INTEGER NOT NULL,
            \\    message_index INTEGER NOT NULL,
            \\    role TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    thinking_content TEXT,
            \\    timestamp INTEGER NOT NULL,
            \\    tool_call_id TEXT,
            \\    thinking_expanded INTEGER DEFAULT 1,
            \\    tool_call_expanded INTEGER DEFAULT 0,
            \\    tool_name TEXT,
            \\    tool_success INTEGER,
            \\    tool_execution_time INTEGER,
            \\    agent_analysis_name TEXT,
            \\    agent_analysis_expanded INTEGER DEFAULT 0,
            \\    agent_analysis_completed INTEGER DEFAULT 0,
            \\    agent_source TEXT,
            \\    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            \\)
        );


        // Agent executions table (legacy - kept for backward compatibility)
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS agent_executions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    message_id INTEGER NOT NULL,
            \\    agent_name TEXT NOT NULL,
            \\    thinking TEXT,
            \\    result_data TEXT,
            \\    execution_time_ms INTEGER,
            \\    tool_calls_made INTEGER DEFAULT 0,
            \\    iterations_used INTEGER DEFAULT 0,
            \\    timestamp INTEGER NOT NULL,
            \\    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
            \\)
        );

        // Agent invocations table - tracks each agent run with full context
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS agent_invocations (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    session_id INTEGER NOT NULL,
            \\    parent_message_id INTEGER,
            \\    agent_name TEXT NOT NULL,
            \\    task_id TEXT,
            \\    started_at INTEGER NOT NULL,
            \\    ended_at INTEGER,
            \\    status TEXT DEFAULT 'running',
            \\    result_summary TEXT,
            \\    tool_calls_made INTEGER DEFAULT 0,
            \\    iterations_used INTEGER DEFAULT 0,
            \\    FOREIGN KEY (session_id) REFERENCES conversations(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (parent_message_id) REFERENCES messages(id)
            \\)
        );

        // Agent messages table - full conversation history for each agent invocation
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS agent_messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    invocation_id INTEGER NOT NULL,
            \\    message_index INTEGER NOT NULL,
            \\    role TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    thinking_content TEXT,
            \\    timestamp INTEGER NOT NULL,
            \\    tool_call_id TEXT,
            \\    tool_name TEXT,
            \\    tool_success INTEGER,
            \\    FOREIGN KEY (invocation_id) REFERENCES agent_invocations(id) ON DELETE CASCADE
            \\)
        );

        // Session state table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS session_state (
            \\    conversation_id INTEGER PRIMARY KEY,
            \\    todos_json TEXT,
            \\    read_files_json TEXT,
            \\    indexed_files_json TEXT,
            \\    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            \\)
        );

        // Metadata table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS db_metadata (
            \\    key TEXT PRIMARY KEY,
            \\    value TEXT NOT NULL
            \\)
        );

        // Create indexes
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_messages_conversation
            \\ON messages(conversation_id, message_index)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_conversations_profile
            \\ON conversations(profile_name, last_message_at DESC)
        );

        // Index for agent messages
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_agent_messages_invocation
            \\ON agent_messages(invocation_id, message_index)
        );

        // Index for agent invocations by task
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_agent_invocations_task
            \\ON agent_invocations(task_id)
        );

        // Set schema version
        try self.setMetadata("schema_version", "1");
    }

    /// Create a new conversation
    pub fn createConversation(self: *Self, profile_name: []const u8) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO conversations (profile_name, started_at, last_message_at)
            \\VALUES (?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, profile_name);
        try sqlite.bindInt64(stmt, 2, now);
        try sqlite.bindInt64(stmt, 3, now);

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Save a message to the database
    pub fn saveMessage(self: *Self, conversation_id: i64, message_index: i64, message: *const types.Message) !i64 {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO messages (
            \\    conversation_id, message_index, role, content, thinking_content,
            \\    timestamp, tool_call_id, thinking_expanded, tool_call_expanded,
            \\    tool_name, tool_success, tool_execution_time,
            \\    agent_analysis_name, agent_analysis_expanded, agent_analysis_completed,
            \\    agent_source
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        const role_str = @tagName(message.role);

        try sqlite.bindInt64(stmt, 1, conversation_id);
        try sqlite.bindInt64(stmt, 2, message_index);
        try sqlite.bindText(stmt, 3, role_str);
        try sqlite.bindText(stmt, 4, message.content);

        if (message.thinking_content) |thinking| {
            try sqlite.bindText(stmt, 5, thinking);
        } else {
            try sqlite.bindNull(stmt, 5);
        }

        try sqlite.bindInt64(stmt, 6, message.timestamp);

        if (message.tool_call_id) |id| {
            try sqlite.bindText(stmt, 7, id);
        } else {
            try sqlite.bindNull(stmt, 7);
        }

        try sqlite.bindInt64(stmt, 8, if (message.thinking_expanded) 1 else 0);
        try sqlite.bindInt64(stmt, 9, if (message.tool_call_expanded) 1 else 0);

        if (message.tool_name) |name| {
            try sqlite.bindText(stmt, 10, name);
        } else {
            try sqlite.bindNull(stmt, 10);
        }

        if (message.tool_success) |success| {
            try sqlite.bindInt64(stmt, 11, if (success) 1 else 0);
        } else {
            try sqlite.bindNull(stmt, 11);
        }

        if (message.tool_execution_time) |time| {
            try sqlite.bindInt64(stmt, 12, time);
        } else {
            try sqlite.bindNull(stmt, 12);
        }

        if (message.agent_analysis_name) |name| {
            try sqlite.bindText(stmt, 13, name);
        } else {
            try sqlite.bindNull(stmt, 13);
        }

        try sqlite.bindInt64(stmt, 14, if (message.agent_analysis_expanded) 1 else 0);
        try sqlite.bindInt64(stmt, 15, if (message.agent_analysis_completed) 1 else 0);

        if (message.agent_source) |source| {
            try sqlite.bindText(stmt, 16, source);
        } else {
            try sqlite.bindNull(stmt, 16);
        }

        _ = try sqlite.step(stmt);

        const message_id = sqlite.lastInsertRowId(self.db);

        // Update conversation stats
        try self.updateConversationStats(conversation_id);

        return message_id;
    }



    /// Save an agent execution
    pub fn saveAgentExecution(self: *Self, message_id: i64, agent_name: []const u8,
                              thinking: ?[]const u8, result_data: ?[]const u8,
                              execution_time_ms: ?i64, tool_calls_made: i64,
                              iterations_used: i64) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO agent_executions (message_id, agent_name, thinking, result_data,
            \\                              execution_time_ms, tool_calls_made, iterations_used, timestamp)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, message_id);
        try sqlite.bindText(stmt, 2, agent_name);

        if (thinking) |t| {
            try sqlite.bindText(stmt, 3, t);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        if (result_data) |d| {
            try sqlite.bindText(stmt, 4, d);
        } else {
            try sqlite.bindNull(stmt, 4);
        }

        if (execution_time_ms) |time| {
            try sqlite.bindInt64(stmt, 5, time);
        } else {
            try sqlite.bindNull(stmt, 5);
        }

        try sqlite.bindInt64(stmt, 6, tool_calls_made);
        try sqlite.bindInt64(stmt, 7, iterations_used);
        try sqlite.bindInt64(stmt, 8, now);

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Update conversation statistics (incremental - O(1) instead of O(n) COUNT(*))
    fn updateConversationStats(self: *Self, conversation_id: i64) !void {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\UPDATE conversations
            \\SET last_message_at = ?,
            \\    message_count = message_count + 1
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, now);
        try sqlite.bindInt64(stmt, 2, conversation_id);

        _ = try sqlite.step(stmt);
    }

    /// Decrement message count (for message deletion)
    pub fn decrementMessageCount(self: *Self, conversation_id: i64) !void {
        const stmt = try sqlite.prepare(self.db,
            \\UPDATE conversations
            \\SET message_count = CASE WHEN message_count > 0 THEN message_count - 1 ELSE 0 END
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, conversation_id);

        _ = try sqlite.step(stmt);
    }

    /// Set a metadata key-value pair
    fn setMetadata(self: *Self, key: []const u8, value: []const u8) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO db_metadata (key, value) VALUES (?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);
        try sqlite.bindText(stmt, 2, value);

        _ = try sqlite.step(stmt);
    }

    /// Get a metadata value
    pub fn getMetadata(self: *Self, key: []const u8) !?[]const u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT value FROM db_metadata WHERE key = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            if (sqlite.columnText(stmt, 0)) |text| {
                return try self.allocator.dupe(u8, text);
            }
        }

        return null;
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "BEGIN TRANSACTION");
    }

    /// Commit a transaction
    pub fn commitTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "COMMIT");
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "ROLLBACK");
    }

    // ========== Agent Invocation Methods ==========

    /// Create a new agent invocation record
    pub fn createAgentInvocation(
        self: *Self,
        session_id: i64,
        agent_name: []const u8,
        task_id: ?[]const u8,
        parent_message_id: ?i64,
    ) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO agent_invocations (session_id, parent_message_id, agent_name, task_id, started_at, status)
            \\VALUES (?, ?, ?, ?, ?, 'running')
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, session_id);

        if (parent_message_id) |msg_id| {
            try sqlite.bindInt64(stmt, 2, msg_id);
        } else {
            try sqlite.bindNull(stmt, 2);
        }

        try sqlite.bindText(stmt, 3, agent_name);

        if (task_id) |tid| {
            try sqlite.bindText(stmt, 4, tid);
        } else {
            try sqlite.bindNull(stmt, 4);
        }

        try sqlite.bindInt64(stmt, 5, now);

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Save a message within an agent invocation
    pub fn saveAgentMessage(
        self: *Self,
        invocation_id: i64,
        message_index: i64,
        role: []const u8,
        content: []const u8,
        thinking_content: ?[]const u8,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
        tool_success: ?bool,
    ) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO agent_messages (invocation_id, message_index, role, content, thinking_content, timestamp, tool_call_id, tool_name, tool_success)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, invocation_id);
        try sqlite.bindInt64(stmt, 2, message_index);
        try sqlite.bindText(stmt, 3, role);
        try sqlite.bindText(stmt, 4, content);

        if (thinking_content) |thinking| {
            try sqlite.bindText(stmt, 5, thinking);
        } else {
            try sqlite.bindNull(stmt, 5);
        }

        try sqlite.bindInt64(stmt, 6, now);

        if (tool_call_id) |tcid| {
            try sqlite.bindText(stmt, 7, tcid);
        } else {
            try sqlite.bindNull(stmt, 7);
        }

        if (tool_name) |name| {
            try sqlite.bindText(stmt, 8, name);
        } else {
            try sqlite.bindNull(stmt, 8);
        }

        if (tool_success) |success| {
            try sqlite.bindInt64(stmt, 9, if (success) 1 else 0);
        } else {
            try sqlite.bindNull(stmt, 9);
        }

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Complete an agent invocation (update status and stats)
    pub fn completeAgentInvocation(
        self: *Self,
        invocation_id: i64,
        status: []const u8,
        result_summary: ?[]const u8,
        tool_calls_made: i64,
        iterations_used: i64,
    ) !void {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\UPDATE agent_invocations
            \\SET ended_at = ?, status = ?, result_summary = ?, tool_calls_made = ?, iterations_used = ?
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, now);
        try sqlite.bindText(stmt, 2, status);

        if (result_summary) |summary| {
            try sqlite.bindText(stmt, 3, summary);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        try sqlite.bindInt64(stmt, 4, tool_calls_made);
        try sqlite.bindInt64(stmt, 5, iterations_used);
        try sqlite.bindInt64(stmt, 6, invocation_id);

        _ = try sqlite.step(stmt);
    }

    // ========== Query Methods ==========

    /// Agent invocation query result
    pub const AgentInvocation = struct {
        id: i64,
        session_id: i64,
        agent_name: []const u8,
        task_id: ?[]const u8,
        started_at: i64,
        ended_at: ?i64,
        status: []const u8,
        result_summary: ?[]const u8,
        tool_calls_made: i64,
        iterations_used: i64,

        pub fn deinit(self: *AgentInvocation, allocator: Allocator) void {
            allocator.free(self.agent_name);
            if (self.task_id) |tid| allocator.free(tid);
            allocator.free(self.status);
            if (self.result_summary) |rs| allocator.free(rs);
        }
    };

    /// Agent message query result
    pub const AgentMessage = struct {
        id: i64,
        invocation_id: i64,
        message_index: i64,
        role: []const u8,
        content: []const u8,
        thinking_content: ?[]const u8,
        timestamp: i64,
        tool_call_id: ?[]const u8,
        tool_name: ?[]const u8,
        tool_success: ?bool,

        pub fn deinit(self: *AgentMessage, allocator: Allocator) void {
            allocator.free(self.role);
            allocator.free(self.content);
            if (self.thinking_content) |tc| allocator.free(tc);
            if (self.tool_call_id) |tcid| allocator.free(tcid);
            if (self.tool_name) |tn| allocator.free(tn);
        }
    };

    /// Get agent invocations with optional filters
    pub fn getAgentInvocations(
        self: *Self,
        session_id: ?i64,
        agent_name: ?[]const u8,
        limit: usize,
    ) ![]AgentInvocation {
        var query_buf: [512]u8 = undefined;
        var query_len: usize = 0;

        const base_query =
            \\SELECT id, session_id, agent_name, task_id, started_at, ended_at,
            \\       status, result_summary, tool_calls_made, iterations_used
            \\FROM agent_invocations WHERE 1=1
        ;
        @memcpy(query_buf[0..base_query.len], base_query);
        query_len = base_query.len;

        if (session_id != null) {
            const clause = " AND session_id = ?";
            @memcpy(query_buf[query_len..][0..clause.len], clause);
            query_len += clause.len;
        }

        if (agent_name != null) {
            const clause = " AND agent_name = ?";
            @memcpy(query_buf[query_len..][0..clause.len], clause);
            query_len += clause.len;
        }

        const order = " ORDER BY started_at DESC LIMIT ?";
        @memcpy(query_buf[query_len..][0..order.len], order);
        query_len += order.len;

        const stmt = try sqlite.prepare(self.db, query_buf[0..query_len]);
        defer sqlite.finalize(stmt);

        var bind_idx: usize = 1;
        if (session_id) |sid| {
            try sqlite.bindInt64(stmt, @intCast(bind_idx), sid);
            bind_idx += 1;
        }
        if (agent_name) |name| {
            try sqlite.bindText(stmt, @intCast(bind_idx), name);
            bind_idx += 1;
        }
        try sqlite.bindInt64(stmt, @intCast(bind_idx), @intCast(limit));

        var results = std.ArrayListUnmanaged(AgentInvocation){};
        errdefer {
            for (results.items) |*inv| inv.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const inv = AgentInvocation{
                .id = sqlite.columnInt64(stmt, 0),
                .session_id = sqlite.columnInt64(stmt, 1),
                .agent_name = if (sqlite.columnText(stmt, 2)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .task_id = if (sqlite.columnType(stmt, 3) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 3)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .started_at = sqlite.columnInt64(stmt, 4),
                .ended_at = if (sqlite.columnType(stmt, 5) != sqlite.SQLITE_NULL) sqlite.columnInt64(stmt, 5) else null,
                .status = if (sqlite.columnText(stmt, 6)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .result_summary = if (sqlite.columnType(stmt, 7) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 7)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .tool_calls_made = sqlite.columnInt64(stmt, 8),
                .iterations_used = sqlite.columnInt64(stmt, 9),
            };
            try results.append(self.allocator, inv);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Get all messages for an agent invocation
    pub fn getAgentMessages(self: *Self, invocation_id: i64) ![]AgentMessage {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, invocation_id, message_index, role, content, thinking_content,
            \\       timestamp, tool_call_id, tool_name, tool_success
            \\FROM agent_messages WHERE invocation_id = ?
            \\ORDER BY message_index ASC
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, invocation_id);

        var results = std.ArrayListUnmanaged(AgentMessage){};
        errdefer {
            for (results.items) |*msg| msg.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const msg = AgentMessage{
                .id = sqlite.columnInt64(stmt, 0),
                .invocation_id = sqlite.columnInt64(stmt, 1),
                .message_index = sqlite.columnInt64(stmt, 2),
                .role = if (sqlite.columnText(stmt, 3)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .content = if (sqlite.columnText(stmt, 4)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .thinking_content = if (sqlite.columnType(stmt, 5) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 5)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .timestamp = sqlite.columnInt64(stmt, 6),
                .tool_call_id = if (sqlite.columnType(stmt, 7) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 7)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .tool_name = if (sqlite.columnType(stmt, 8) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 8)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .tool_success = if (sqlite.columnType(stmt, 9) != sqlite.SQLITE_NULL)
                    sqlite.columnInt64(stmt, 9) != 0
                else
                    null,
            };
            try results.append(self.allocator, msg);
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Get all agent invocations for a specific task
    pub fn getInvocationsForTask(self: *Self, task_id: []const u8) ![]AgentInvocation {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, session_id, agent_name, task_id, started_at, ended_at,
            \\       status, result_summary, tool_calls_made, iterations_used
            \\FROM agent_invocations WHERE task_id = ?
            \\ORDER BY started_at DESC
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, task_id);

        var results = std.ArrayListUnmanaged(AgentInvocation){};
        errdefer {
            for (results.items) |*inv| inv.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const inv = AgentInvocation{
                .id = sqlite.columnInt64(stmt, 0),
                .session_id = sqlite.columnInt64(stmt, 1),
                .agent_name = if (sqlite.columnText(stmt, 2)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .task_id = if (sqlite.columnType(stmt, 3) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 3)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .started_at = sqlite.columnInt64(stmt, 4),
                .ended_at = if (sqlite.columnType(stmt, 5) != sqlite.SQLITE_NULL) sqlite.columnInt64(stmt, 5) else null,
                .status = if (sqlite.columnText(stmt, 6)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .result_summary = if (sqlite.columnType(stmt, 7) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 7)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .tool_calls_made = sqlite.columnInt64(stmt, 8),
                .iterations_used = sqlite.columnInt64(stmt, 9),
            };
            try results.append(self.allocator, inv);
        }

        return results.toOwnedSlice(self.allocator);
    }

    // ========== Message Loading Methods (Phase 2: Virtualization) ==========

    /// Get the total count of messages in a conversation
    pub fn getMessageCount(self: *Self, conversation_id: i64) !usize {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT COUNT(*) FROM messages WHERE conversation_id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, conversation_id);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            return @intCast(sqlite.columnInt64(stmt, 0));
        }

        return 0;
    }

    /// Load messages from database within a range [start_idx, end_idx] (inclusive)
    /// Returns an owned slice of MessageRow that must be freed by the caller
    pub fn loadMessages(self: *Self, conversation_id: i64, start_idx: i64, end_idx: i64) ![]MessageRow {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT id, message_index, role, content, thinking_content, timestamp,
            \\       tool_call_id, thinking_expanded, tool_call_expanded, tool_name,
            \\       tool_success, tool_execution_time, agent_analysis_name,
            \\       agent_analysis_expanded, agent_analysis_completed, agent_source
            \\FROM messages
            \\WHERE conversation_id = ? AND message_index >= ? AND message_index <= ?
            \\ORDER BY message_index ASC
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, conversation_id);
        try sqlite.bindInt64(stmt, 2, start_idx);
        try sqlite.bindInt64(stmt, 3, end_idx);

        var results = std.ArrayListUnmanaged(MessageRow){};
        errdefer {
            for (results.items) |*row| row.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        while (true) {
            const rc = try sqlite.step(stmt);
            if (rc != sqlite.SQLITE_ROW) break;

            const row = MessageRow{
                .id = sqlite.columnInt64(stmt, 0),
                .message_index = sqlite.columnInt64(stmt, 1),
                .role = if (sqlite.columnText(stmt, 2)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .content = if (sqlite.columnText(stmt, 3)) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
                .thinking_content = if (sqlite.columnType(stmt, 4) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 4)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .timestamp = sqlite.columnInt64(stmt, 5),
                .tool_call_id = if (sqlite.columnType(stmt, 6) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 6)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .thinking_expanded = sqlite.columnInt64(stmt, 7) != 0,
                .tool_call_expanded = sqlite.columnInt64(stmt, 8) != 0,
                .tool_name = if (sqlite.columnType(stmt, 9) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 9)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .tool_success = if (sqlite.columnType(stmt, 10) != sqlite.SQLITE_NULL)
                    sqlite.columnInt64(stmt, 10) != 0
                else
                    null,
                .tool_execution_time = if (sqlite.columnType(stmt, 11) != sqlite.SQLITE_NULL)
                    sqlite.columnInt64(stmt, 11)
                else
                    null,
                .agent_analysis_name = if (sqlite.columnType(stmt, 12) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 12)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
                .agent_analysis_expanded = sqlite.columnInt64(stmt, 13) != 0,
                .agent_analysis_completed = sqlite.columnInt64(stmt, 14) != 0,
                .agent_source = if (sqlite.columnType(stmt, 15) != sqlite.SQLITE_NULL)
                    if (sqlite.columnText(stmt, 15)) |t| try self.allocator.dupe(u8, t) else null
                else
                    null,
            };
            try results.append(self.allocator, row);
        }

        return results.toOwnedSlice(self.allocator);
    }
};
