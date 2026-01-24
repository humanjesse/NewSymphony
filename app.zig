// Application logic - App struct and coordination
// Extracted modules handle specific concerns:
// - app_streaming.zig: LLM streaming thread and chunk processing
// - app_agents.zig: Agent session lifecycle and result polling
// - modal_dispatcher.zig: Unified modal UI dispatch
// - app_tool_execution.zig: Tool permission prompts and execution

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const process = std.process;
const ui = @import("ui");
const markdown = @import("markdown");
const ollama = @import("ollama");
const llm_provider_module = @import("llm_provider");
const permission = @import("permission");
const tools_module = @import("tools");
const types = @import("types");
const state_module = @import("state");
const context_module = @import("context");
const config_module = @import("config");
const render = @import("render");
const message_renderer = @import("message_renderer");
const tool_executor_module = @import("tool_executor");
const zvdb = @import("zvdb");
const embeddings_module = @import("embeddings");
const embedder_interface = @import("embedder_interface");
const lmstudio = @import("lmstudio");
pub const agents_module = @import("agents"); // Re-export for agent_loader and agent_executor
const agent_executor = @import("agent_executor");
const config_editor_state = @import("config_editor_state");
const agent_loader = @import("agent_loader");
const agent_builder_state = @import("agent_builder_state");
const help_state = @import("help_state");
const profile_ui_state = @import("profile_ui_state");
const conversation_db_module = @import("conversation_db");
const task_store_module = @import("task_store");
const task_db_module = @import("task_db");
const git_sync_module = @import("git_sync");
const scroll_controller = @import("scroll_controller");

// Import extracted modules
const app_streaming = @import("app_streaming.zig");
const app_agents = @import("app_agents.zig");
const modal_dispatcher = @import("modal_dispatcher.zig");
const app_tool_execution = @import("app_tool_execution.zig");
const message_loader = @import("message_loader");

// Re-export types for convenience
pub const Message = types.Message;
pub const ClickableArea = types.ClickableArea;
pub const StreamChunk = types.StreamChunk;
pub const Config = config_module.Config;
pub const AppState = state_module.AppState;
pub const AppContext = context_module.AppContext;

// Re-export types from extracted modules for external access
pub const StreamThreadContext = app_streaming.StreamThreadContext;
pub const AgentThreadContext = app_agents.AgentThreadContext;
pub const AgentToolEvent = app_agents.AgentToolEvent;

// Define available tools for the model
fn createTools(allocator: mem.Allocator) ![]const ollama.Tool {
    return try tools_module.getOllamaTools(allocator);
}

// Incremental rendering support structures
pub const MessageRenderInfo = struct {
    message_index: usize,
    y_start: usize, // Absolute Y position where message starts
    y_end: usize, // Absolute Y position where message ends
    height: usize, // Total lines this message occupies
    content_hash: u64, // Hash of message content for change detection (includes expansion states)
};

/// Render cache - tracks terminal size and message Y positions for virtualization
pub const RenderCache = struct {
    last_terminal_width: u16 = 0,
    last_terminal_height: u16 = 0,
    message_y_positions: std.ArrayListUnmanaged(usize) = .{}, // Y position where each message starts
    total_content_height: usize = 0, // Total height of all messages
    previous_content_height: usize = 0, // Previous height for delta-based scrolling
    cache_valid: bool = false, // Whether position cache is valid
    last_message_count: usize = 0, // Message count when cache was built

    pub fn init() RenderCache {
        return .{};
    }

    pub fn deinit(self: *RenderCache, allocator: mem.Allocator) void {
        self.message_y_positions.deinit(allocator);
    }

    pub fn invalidate(self: *RenderCache) void {
        self.cache_valid = false;
    }
};

/// Virtualization state for memory-bounded message management
/// Tracks which messages are loaded in memory vs stored only in DB
pub const VirtualizationState = struct {
    total_message_count: usize = 0, // Total messages in conversation (from DB)
    loaded_start: usize = 0, // First message index currently loaded
    loaded_end: usize = 0, // Last message index currently loaded (exclusive)
    buffer_size: usize = 25, // Extra messages to keep around visible range
    target_loaded: usize = 100, // Target number of messages to keep loaded
    streaming_message_idx: ?usize = null, // Protected message during streaming
    estimated_heights: std.AutoHashMapUnmanaged(usize, usize) = .{}, // Heights of unloaded messages
    average_message_height: usize = 15, // Default for never-loaded messages
    height_sum: usize = 0, // Running sum for O(1) average calculation
    last_load_time: i64 = 0, // For debouncing rapid scroll

    const Self = @This();

    pub fn init() VirtualizationState {
        return .{};
    }

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        self.estimated_heights.deinit(allocator);
    }

    /// Check if an absolute message index is currently loaded
    pub fn isLoaded(self: *const Self, absolute_idx: usize) bool {
        return absolute_idx >= self.loaded_start and absolute_idx < self.loaded_end;
    }

    /// Convert absolute index to local array index (or null if not loaded)
    pub fn localIndex(self: *const Self, absolute_idx: usize) ?usize {
        if (!self.isLoaded(absolute_idx)) return null;
        return absolute_idx - self.loaded_start;
    }

    /// Convert local array index to absolute index
    pub fn absoluteIndex(self: *const Self, local_idx: usize) usize {
        return local_idx + self.loaded_start;
    }

    /// Get estimated height for an unloaded message (or average if unknown)
    pub fn getEstimatedHeight(self: *const Self, absolute_idx: usize) usize {
        return self.estimated_heights.get(absolute_idx) orelse self.average_message_height;
    }

    /// Store height estimate before unloading a message (O(1) incremental average)
    pub fn storeHeightEstimate(self: *Self, allocator: mem.Allocator, absolute_idx: usize, height: usize) !void {
        // Check if we're updating an existing entry
        if (self.estimated_heights.get(absolute_idx)) |old_height| {
            // Update: adjust sum by delta
            self.height_sum = self.height_sum - old_height + height;
        } else {
            // New entry: add to sum
            self.height_sum += height;
        }

        try self.estimated_heights.put(allocator, absolute_idx, height);

        // Update average using running sum (O(1) instead of O(n))
        const count = self.estimated_heights.count();
        if (count > 0) {
            self.average_message_height = self.height_sum / count;
        }
    }

    /// Clear all height estimates (on terminal resize)
    pub fn clearHeightEstimates(self: *Self) void {
        self.estimated_heights.clearRetainingCapacity();
        self.height_sum = 0;
        self.average_message_height = 15; // Reset to default
    }
};

/// Check if the current working directory has a .git folder
/// Returns true if .git exists in cwd, false otherwise
fn cwdHasGit(allocator: mem.Allocator) !bool {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd_path = try fs.cwd().realpath(".", &path_buf);

    const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{cwd_path});
    defer allocator.free(git_path);

    if (fs.cwd().statFile(git_path)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

/// Initialize a git repository in the current working directory
fn initGitRepo() !void {
    var child = std.process.Child.init(&.{ "git", "init" }, std.heap.page_allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    messages: std.ArrayListUnmanaged(Message),
    llm_provider: llm_provider_module.LLMProvider,
    input_buffer: std.ArrayListUnmanaged(u8),
    clickable_areas: std.ArrayListUnmanaged(ClickableArea),
    scroll: scroll_controller.ScrollState = .{},
    cursor_y: usize = 1,
    terminal_size: ui.TerminalSize,
    valid_cursor_positions: std.ArrayListUnmanaged(usize),
    // Resize handling state
    resize_in_progress: bool = false,
    saved_expansion_states: std.ArrayListUnmanaged(bool),
    last_resize_time: i64 = 0,
    // Streaming state
    streaming_active: bool = false,
    streaming_message_idx: ?usize = null, // Specific message to update (for agents with tool calls)
    streaming_message_id: ?u64 = null, // Stable ID for streaming target (survives virtualization)
    next_message_id: u64 = 1, // Counter for assigning unique message IDs
    last_markdown_process_time: i64 = 0, // Throttle markdown reprocessing (ms timestamp)
    // Agent responding state (for status indicator)
    agent_responding: bool = false,
    stream_mutex: std.Thread.Mutex = .{},
    stream_chunks: std.ArrayListUnmanaged(StreamChunk) = .{},
    stream_thread: ?std.Thread = null,
    stream_thread_ctx: ?*StreamThreadContext = null,
    // Agent thread state (for non-blocking agent execution)
    agent_thread: ?std.Thread = null,
    agent_thread_ctx: ?*AgentThreadContext = null,
    agent_result: ?agents_module.AgentResult = null,
    agent_result_ready: bool = false,
    agent_result_mutex: std.Thread.Mutex = .{},
    agent_tool_events: std.ArrayListUnmanaged(AgentToolEvent) = .{},
    // Agent command events (queued from kickback functions for main loop dispatch)
    agent_command_events: std.ArrayListUnmanaged(app_agents.AgentCommandEvent) = .{},
    // Pending user messages (queued while agent/streaming is active)
    pending_user_messages: std.ArrayListUnmanaged([]const u8) = .{},
    // Available tools for the model
    tools: []const ollama.Tool,
    // Tool execution state
    pending_tool_calls: ?[]ollama.ToolCall = null,
    tool_call_depth: usize = 0,
    max_tool_depth: usize = 15, // Max tools per iteration (increased for agentic tasks)
    // Permission system
    permission_manager: permission.PermissionManager,
    permission_pending: bool = false,
    permission_response: ?permission.PermissionMode = null, // Set by UI, consumed by tool_executor
    // Tool execution state machine
    tool_executor: tool_executor_module.ToolExecutor,
    // Phase 1: Task management state
    state: AppState,
    app_context: AppContext,
    max_iterations: usize = 10, // Master loop iteration limit
    // Vector DB components (kept for future semantic search)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio
    // Config editor state (modal mode)
    config_editor: ?config_editor_state.ConfigEditorState = null,
    // Agent system
    agent_registry: agents_module.AgentRegistry,
    agent_loader: agent_loader.AgentLoader,
    agent_builder: ?agent_builder_state.AgentBuilderState = null,
    // Help viewer state (modal mode)
    help_viewer: ?help_state.HelpState = null,
    // Profile manager state (modal mode)
    profile_ui: ?profile_ui_state.ProfileUIState = null,
    // Conversation persistence
    conversation_db: ?conversation_db_module.ConversationDB = null,
    current_conversation_id: ?i64 = null,
    // Task memory system (Beads-inspired)
    task_store: ?*task_store_module.TaskStore = null,
    task_db: ?*task_db_module.TaskDB = null,
    git_sync: ?*git_sync_module.GitSync = null,
    git_root: ?[]const u8 = null, // Project root (where .git is)

    // Incremental rendering state
    render_cache: RenderCache = RenderCache.init(),

    // Virtualization state for memory-bounded message management
    virtualization: VirtualizationState = VirtualizationState.init(),

    pub fn init(allocator: mem.Allocator, config: Config) !App {
        const tools = try createTools(allocator);
        errdefer app_agents.freeOllamaTools(allocator, tools);

        // Initialize permission manager
        var perm_manager = try permission.PermissionManager.init(allocator, ".", null); // No audit log by default
        errdefer perm_manager.deinit();
        const tool_metadata = try tools_module.getPermissionMetadata(allocator);
        defer allocator.free(tool_metadata);
        try perm_manager.registerTools(tool_metadata);

        // Load saved policies from disk
        config_module.loadPolicies(allocator, &perm_manager) catch |err| {
            // Log error but don't fail - just continue with default policies
            std.debug.print("Warning: Failed to load policies: {}\n", .{err});
        };

        // Vector database components reserved for future semantic search
        // Currently disabled - can be re-enabled for semantic code search
        const vector_store_opt: ?*zvdb.HNSW(f32) = null;
        const embedder_opt: ?*embedder_interface.Embedder = null;

        // Create LLM provider based on config
        const provider = try llm_provider_module.createProvider(config.provider, allocator, config);

        // Initialize agent system
        var agent_registry = agents_module.AgentRegistry.init(allocator);
        errdefer agent_registry.deinit();

        var loader = agent_loader.AgentLoader.init(allocator, &agent_registry);
        errdefer loader.deinit();

        // Load all agents (native + markdown)
        try loader.loadAllAgents();

        var app = App{
            .allocator = allocator,
            .config = config,
            .messages = .{},
            .llm_provider = provider,
            .input_buffer = .{},
            .clickable_areas = .{},
            .terminal_size = try ui.Tui.getTerminalSize(),
            .valid_cursor_positions = .{},
            .saved_expansion_states = .{},
            .tools = tools,
            .permission_manager = perm_manager,
            .tool_executor = tool_executor_module.ToolExecutor.init(allocator),
            // Phase 1: Initialize state (session-ephemeral)
            .state = AppState.init(allocator),
            .app_context = undefined, // Will be fixed by caller after struct is in final location
            .vector_store = vector_store_opt,
            .embedder = embedder_opt,
            .agent_registry = agent_registry,
            .agent_loader = loader,
            .agent_builder = null,
        };

        // Initialize conversation database
        const home_dir = std.posix.getenv("HOME") orelse ".";
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/localharness", .{home_dir});
        defer allocator.free(config_dir);

        // Ensure config directory exists
        std.fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const db_path = try std.fmt.allocPrint(allocator, "{s}/conversations.db", .{config_dir});
        defer allocator.free(db_path);

        // Initialize database - fail fast if this fails
        const conv_db = try conversation_db_module.ConversationDB.init(allocator, db_path);
        app.conversation_db = conv_db;

        // Create conversation immediately on startup
        const profile_name = "default"; // TODO: Get from profile manager
        const conv_id = try app.conversation_db.?.createConversation(profile_name);
        app.current_conversation_id = conv_id;
        std.debug.print("Created new conversation: {}\n", .{conv_id});

        // Add system prompt (Position 0 - stable)
        // Session Coordinator: handles startup checks, task visibility, and graceful shutdown
        const system_prompt =
            \\You are a helpful coding assistant and session coordinator.
            \\
            \\## Startup Protocol
            \\At the start of each session, check the environment:
            \\1. Call `check_environment` to assess workspace state
            \\2. If no git repo: Inform user that task persistence is limited (no .tasks/ sync)
            \\3. If uncommitted changes: Warn user about dirty working directory
            \\4. If previous session exists: Briefly summarize what was in progress
            \\
            \\## During Session
            \\- For simple questions: Answer directly using your knowledge and available tools
            \\- For complex multi-step tasks: Suggest using `/planner` to create a structured plan
            \\- When asked about progress: Call `get_session_status` to report task status
            \\- Use file tools (read_lines, grep_search, write_file, etc.) for code tasks
            \\
            \\## Shutdown Protocol
            \\When user indicates they're done ("I'm done", "that's all", "wrap up", "goodbye", etc.):
            \\1. Call `get_session_status` to gather accomplishments
            \\2. Present a brief summary of what was accomplished
            \\3. Ask if they want to save session state
            \\4. If yes, call `end_session` to save state for next time
            \\
            \\## Available Agents
            \\- `/planner` - Creates detailed implementation plans for complex tasks
            \\- `/tinkerer` - Executes tasks with code changes and tool use
            \\- `/judge` - Reviews and validates completed work
            \\- `/questioner` - Gathers requirements through targeted questions
            \\
            \\Remember: Always be helpful, provide clear explanations, and guide the user through their development workflow.
        ;
        const system_processed = try markdown.processMarkdown(allocator, system_prompt);
        try app.messages.append(allocator, .{
            .role = .system,
            .content = try allocator.dupe(u8, system_prompt),
            .processed_content = system_processed,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });
        message_loader.onMessageAdded(&app);

        // Persist system message immediately
        try app.persistMessage(app.messages.items.len - 1);

        // Initialize virtualization state after system message is ready
        try message_loader.initVirtualization(&app);

        // Initialize task memory system (Beads-style per-project)
        // Always use current working directory as project root
        // This ensures .tasks/ is created where the app was started
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const cwd_path = try fs.cwd().realpath(".", &path_buf);
        const project_root = try allocator.dupe(u8, cwd_path);
        app.git_root = project_root;

        // Initialize git repo if one doesn't exist in current directory
        if (!try cwdHasGit(allocator)) {
            std.log.info("No git repo in current directory, initializing one...", .{});
            initGitRepo() catch |err| {
                std.log.warn("Failed to initialize git repo: {}", .{err});
            };
        }

        // Initialize GitSync for this project
        const git_sync_ptr = try allocator.create(git_sync_module.GitSync);
        git_sync_ptr.* = try git_sync_module.GitSync.init(allocator, project_root);
        app.git_sync = git_sync_ptr;

        // Ensure .tasks directory exists
        try git_sync_ptr.ensureTasksDir();

        // Create per-project SQLite database (single source of truth)
        const task_db_path = try std.fmt.allocPrint(allocator, "{s}/.tasks/tasks.db", .{project_root});
        defer allocator.free(task_db_path);

        const task_db_ptr = try allocator.create(task_db_module.TaskDB);
        task_db_ptr.* = try task_db_module.TaskDB.init(allocator, task_db_path);
        app.task_db = task_db_ptr;

        // Create task store with TaskDB reference (facade pattern)
        const task_store_ptr = try allocator.create(task_store_module.TaskStore);
        task_store_ptr.* = task_store_module.TaskStore.init(allocator, task_db_ptr);
        app.task_store = task_store_ptr;

        // Check if SQLite has existing tasks
        const task_count = task_db_ptr.getTaskCount() catch 0;

        // Fall back to JSONL import only if SQLite is empty (fresh clone scenario)
        if (task_count == 0) {
            if (git_sync_ptr.importTasks(task_db_ptr)) |count| {
                if (count > 0) {
                    std.log.info("Imported {d} tasks from JSONL to SQLite", .{count});
                }
            } else |_| {}
        } else {
            std.log.info("Loaded {d} tasks from SQLite", .{task_count});
        }

        // Try to restore session state from SQLite
        if (try task_db_ptr.loadSessionState()) |state| {
            defer {
                var s = state;
                s.deinit(allocator);
            }

            // Restore session to TaskStore
            const current_task = if (state.current_task_id) |cid|
                if (try task_db_ptr.taskExists(cid)) cid else null
            else
                null;
            try task_store_ptr.restoreSession(state.session_id, current_task, state.started_at);
        } else {
            // Start a new session
            try task_store_ptr.startSession();
        }

        return app;
    }

    // Fix context pointers after App is in its final location
    // MUST be called immediately after init() in main.zig
    pub fn fixContextPointers(self: *App) void {
        self.app_context = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = &self.state,
            .llm_provider = &self.llm_provider,
            .vector_store = self.vector_store,
            .embedder = self.embedder,
            .agent_registry = &self.agent_registry,
            .task_store = self.task_store,
            .task_db = self.task_db,
            .git_sync = self.git_sync,
            .conversation_db = if (self.conversation_db) |*db| db else null,
            .session_id = self.current_conversation_id,
        };
    }

    // Persist a message to the database immediately
    // Fails fast if database persistence fails
    pub fn persistMessage(self: *App, message_index: usize) !void {
        // Conversation ID must exist (created in init)
        const conv_id = self.current_conversation_id orelse return error.NoConversation;

        // Database must be initialized
        if (self.conversation_db) |*db| {
            // Save message - fail fast if this fails
            const message = &self.messages.items[message_index];
            _ = try db.saveMessage(conv_id, @intCast(message_index), message);
        } else {
            return error.DatabaseNotInitialized;
        }
    }

    /// Find a message by its stable ID, returns local index if found
    pub fn findMessageById(self: *App, message_id: u64) ?usize {
        for (self.messages.items, 0..) |*msg, idx| {
            if (msg.message_id == message_id) {
                return idx;
            }
        }
        return null;
    }

    /// Assign a unique ID to a message and return it
    pub fn assignMessageId(self: *App, message: *Message) u64 {
        const id = self.next_message_id;
        self.next_message_id += 1;
        message.message_id = id;
        return id;
    }

    /// Invalidate height cache for a specific message (call when message content changes)
    pub fn invalidateMessageCache(self: *App, message_index: usize) void {
        if (message_index < self.messages.items.len) {
            self.messages.items[message_index].cached_height = null;
        }
        self.render_cache.invalidate();
    }

    /// Invalidate all message caches (call on terminal resize)
    pub fn invalidateAllMessageCaches(self: *App) void {
        for (self.messages.items) |*message| {
            message.cached_height = null;
        }
        self.render_cache.invalidate();
        self.virtualization.clearHeightEstimates();
    }

    /// Convert a MessageRow from the database into a full Message
    /// Regenerates processed_content from raw content using markdown parser
    /// Note: tool_calls and permission_request are NOT persisted (ephemeral)
    pub fn messageFromRow(self: *App, row: *const conversation_db_module.MessageRow) !Message {
        const allocator = self.allocator;

        // Parse role enum from string
        const role: @TypeOf(@as(Message, undefined).role) = if (std.mem.eql(u8, row.role, "user"))
            .user
        else if (std.mem.eql(u8, row.role, "assistant"))
            .assistant
        else if (std.mem.eql(u8, row.role, "system"))
            .system
        else if (std.mem.eql(u8, row.role, "tool"))
            .tool
        else
            .display_only_data;

        // Duplicate content (take ownership)
        const content = try allocator.dupe(u8, row.content);
        errdefer allocator.free(content);

        // Generate processed_content from markdown
        var processed_content = try markdown.processMarkdown(allocator, content);
        errdefer {
            for (processed_content.items) |*item| item.deinit(allocator);
            processed_content.deinit(allocator);
        }

        // Process thinking content if present
        var thinking_content: ?[]const u8 = null;
        var processed_thinking_content: ?std.ArrayListUnmanaged(markdown.RenderableItem) = null;
        if (row.thinking_content) |tc| {
            thinking_content = try allocator.dupe(u8, tc);
            processed_thinking_content = try markdown.processMarkdown(allocator, thinking_content.?);
        }

        // Duplicate optional string fields
        const tool_call_id = if (row.tool_call_id) |id| try allocator.dupe(u8, id) else null;
        const tool_name = if (row.tool_name) |name| try allocator.dupe(u8, name) else null;
        const agent_analysis_name = if (row.agent_analysis_name) |name| try allocator.dupe(u8, name) else null;
        const agent_source = if (row.agent_source) |source| try allocator.dupe(u8, source) else null;

        return Message{
            .role = role,
            .content = content,
            .agent_source = agent_source,
            .processed_content = processed_content,
            .thinking_content = thinking_content,
            .processed_thinking_content = processed_thinking_content,
            .thinking_expanded = row.thinking_expanded,
            .timestamp = row.timestamp,
            .tool_calls = null, // Not persisted (complex nested structure)
            .tool_call_id = tool_call_id,
            .permission_request = null, // Not persisted (session-only ephemeral)
            .tool_call_expanded = row.tool_call_expanded,
            .tool_name = tool_name,
            .tool_success = row.tool_success,
            .tool_execution_time = row.tool_execution_time,
            .agent_analysis_name = agent_analysis_name,
            .agent_analysis_expanded = row.agent_analysis_expanded,
            .agent_analysis_completed = row.agent_analysis_completed,
            // Height cache starts empty (will be populated on first render)
            .cached_height = null,
            .cache_width = 0,
            .cache_hash = 0,
        };
    }

    // Check if viewport is currently at the bottom
    fn isViewportAtBottom(self: *App) bool {
        if (self.valid_cursor_positions.items.len == 0) return true;

        const last_position = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        return self.cursor_y == last_position;
    }

    /// Process all queued user messages (Option C):
    /// 1. Process agent slash commands first (in order) - they may change state
    /// 2. Combine remaining regular messages with \n\n
    /// 3. Send combined message (routes to agent or main chat automatically)
    /// Returns true if any messages were processed
    pub fn processQueuedMessages(self: *App) !bool {
        if (self.pending_user_messages.items.len == 0) return false;

        // First pass: process agent slash commands (they take priority and may change state)
        var i: usize = 0;
        while (i < self.pending_user_messages.items.len) {
            const msg = self.pending_user_messages.items[i];
            if (mem.startsWith(u8, msg, "/")) {
                const command = msg[1..]; // Skip "/"
                if (self.app_context.agent_registry) |registry| {
                    const space_idx = mem.indexOf(u8, command, " ");
                    const agent_name = if (space_idx) |idx| command[0..idx] else command;
                    if (registry.has(agent_name)) {
                        // Remove from queue and process
                        const pending = self.pending_user_messages.orderedRemove(i);
                        defer self.allocator.free(pending);
                        const task = if (space_idx) |idx| blk: {
                            const t = command[idx + 1 ..];
                            break :blk if (t.len == 0) null else t;
                        } else null;
                        try self.handleAgentCommand(agent_name, task, pending);
                        // Don't increment i - array shifted
                        continue;
                    }
                }
            }
            i += 1;
        }

        // Second pass: combine remaining regular messages
        if (self.pending_user_messages.items.len == 0) return true;

        var combined = std.ArrayListUnmanaged(u8){};
        defer combined.deinit(self.allocator);

        for (self.pending_user_messages.items, 0..) |msg, idx| {
            if (idx > 0) try combined.appendSlice(self.allocator, "\n\n");
            try combined.appendSlice(self.allocator, msg);
        }

        // Clear the queue (free all messages)
        for (self.pending_user_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.pending_user_messages.clearRetainingCapacity();

        // Send combined message (sendMessage routes to agent if active)
        if (combined.items.len > 0) {
            try self.sendMessage(combined.items, null);
        }

        return true;
    }

    // Update cursor to track bottom position after redraw
    pub fn updateCursorToBottom(self: *App) void {
        if (self.valid_cursor_positions.items.len > 0) {
            self.cursor_y = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        }
    }

    // Send a message and get streaming response from Ollama (non-blocking)
    pub fn sendMessage(self: *App, user_text: []const u8, format: ?[]const u8) !void {
        // If agent is active, route to agent instead
        if (self.app_context.active_agent != null) {
            // For continuation messages, display_text is same as user_text (no slash prefix)
            app_agents.sendToAgent(self, user_text, null) catch |err| {
                if (err == error.AgentThreadAlreadyRunning) {
                    // Queue message for processing after current agent completes
                    try self.pending_user_messages.append(
                        self.allocator,
                        try self.allocator.dupe(u8, user_text),
                    );
                    return;
                }
                return err;
            };
            return;
        }

        // Reset tool call depth for new user messages
        self.tool_call_depth = 0;

        // Phase 1: Reset iteration count for new user messages (master loop)
        self.state.iteration_count = 0;

        // 1. Add user message
        const user_content = try self.allocator.dupe(u8, user_text);
        const user_processed = try markdown.processMarkdown(self.allocator, user_content);

        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = user_content,
            .processed_content = user_processed,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });
        message_loader.onMessageAdded(self);

        // Persist user message immediately
        try self.persistMessage(self.messages.items.len - 1);

        // Show user message right away (receipt printer mode)
        _ = try message_renderer.redrawScreen(self);
        self.updateCursorToBottom();

        // Enable auto-scroll for response
        self.scroll.enableAutoScroll();

        // 2. Start streaming
        try app_streaming.startStreaming(self, format);
    }

    /// Handle agent slash command (e.g., /agentname or /agentname task)
    /// full_input is the complete user input for display (e.g., "/planner hello")
    pub fn handleAgentCommand(self: *App, agent_name: []const u8, task: ?[]const u8, full_input: []const u8) !void {
        return app_agents.handleAgentCommand(self, agent_name, task, full_input);
    }

    /// End the current agent conversation session
    pub fn endAgentSession(self: *App) !void {
        return app_agents.endAgentSession(self);
    }

    pub fn deinit(self: *App) void {
        // Wait for streaming thread to finish if active
        if (self.stream_thread) |thread| {
            thread.join();
        }

        // Clean up thread context if it exists
        if (self.stream_thread_ctx) |ctx| {
            self.allocator.free(ctx.messages);
            self.allocator.destroy(ctx);
        }

        // Wait for agent thread to finish if active
        if (self.agent_thread) |thread| {
            thread.join();
        }

        // Clean up agent thread context if it exists
        if (self.agent_thread_ctx) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }

        // Clean up agent result if pending
        if (self.agent_result) |*result| {
            result.deinit(self.allocator);
        }

        // Clean up active agent session if any (conversation-mode agents)
        // This frees the executor and its message history
        if (self.app_context.active_agent) |session| {
            // Get the executor through the type-safe interface
            const executor: *agent_executor.AgentExecutor = @ptrCast(@alignCast(session.executor.ptr));
            session.executor.deinit(); // Frees message history
            self.allocator.destroy(executor);
            self.allocator.free(session.agent_name);
            self.allocator.destroy(session);
            self.app_context.active_agent = null;
        }

        // Clean up any pending agent tool events
        for (self.agent_tool_events.items) |event| {
            self.allocator.free(event.tool_name);
            if (event.arguments) |a| self.allocator.free(a);
            if (event.result) |r| self.allocator.free(r);
        }
        self.agent_tool_events.deinit(self.allocator);

        // Clean up pending agent command events
        for (self.agent_command_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.agent_command_events.deinit(self.allocator);

        // Clean up pending user messages if any
        for (self.pending_user_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.pending_user_messages.deinit(self.allocator);

        // Clean up stream chunks
        for (self.stream_chunks.items) |chunk| {
            if (chunk.thinking) |t| self.allocator.free(t);
            if (chunk.content) |c| self.allocator.free(c);
        }
        self.stream_chunks.deinit(self.allocator);

        for (self.messages.items) |*message| {
            self.allocator.free(message.content);
            for (message.processed_content.items) |*item| {
                item.deinit(self.allocator);
            }
            message.processed_content.deinit(self.allocator);

            // Clean up thinking content if present
            if (message.thinking_content) |thinking| {
                self.allocator.free(thinking);
            }
            if (message.processed_thinking_content) |*thinking_processed| {
                for (thinking_processed.items) |*item| {
                    item.deinit(self.allocator);
                }
                thinking_processed.deinit(self.allocator);
            }

            // Clean up tool calling fields
            if (message.tool_calls) |calls| {
                for (calls) |call| {
                    if (call.id) |id| self.allocator.free(id);
                    if (call.type) |call_type| self.allocator.free(call_type);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                self.allocator.free(calls);
            }
            if (message.tool_call_id) |id| {
                self.allocator.free(id);
            }

            // Clean up permission request if present
            if (message.permission_request) |perm_req| {
                if (perm_req.tool_call.id) |id| self.allocator.free(id);
                if (perm_req.tool_call.type) |call_type| self.allocator.free(call_type);
                self.allocator.free(perm_req.tool_call.function.name);
                self.allocator.free(perm_req.tool_call.function.arguments);
                self.allocator.free(perm_req.eval_result.reason);
            }

            // Clean up tool execution metadata
            if (message.tool_name) |name| {
                self.allocator.free(name);
            }

            // Clean up agent analysis metadata
            if (message.agent_analysis_name) |name| {
                self.allocator.free(name);
            }

            // Clean up agent source (for subagent message filtering)
            if (message.agent_source) |source| {
                self.allocator.free(source);
            }
        }
        self.messages.deinit(self.allocator);
        self.llm_provider.deinit();
        self.input_buffer.deinit(self.allocator);
        self.clickable_areas.deinit(self.allocator);
        self.valid_cursor_positions.deinit(self.allocator);
        self.saved_expansion_states.deinit(self.allocator);

        // Clean up tools
        app_agents.freeOllamaTools(self.allocator, self.tools);

        // Clean up pending tool calls if any
        if (self.pending_tool_calls) |calls| {
            for (calls) |call| {
                if (call.id) |id| self.allocator.free(id);
                if (call.type) |call_type| self.allocator.free(call_type);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            self.allocator.free(calls);
        }

        // Clean up permission manager
        self.permission_manager.deinit();

        // Clean up tool executor
        self.tool_executor.deinit();

        // Phase 1: Clean up state
        self.state.deinit();

        // Clean up Graph RAG components (session-only, not persisted)
        if (self.vector_store) |vs| {
            vs.deinit();
            self.allocator.destroy(vs);
        }

        if (self.embedder) |emb| {
            // Clean up the underlying client first
            switch (emb.*) {
                .ollama => |client| {
                    client.deinit();
                    self.allocator.destroy(client);
                },
                .lmstudio => |client| {
                    client.deinit();
                    self.allocator.destroy(client);
                },
            }
            // Then destroy the embedder wrapper
            self.allocator.destroy(emb);
        }

        // Clean up config editor if active
        if (self.config_editor) |*editor| {
            editor.deinit();
        }

        // Clean up agent builder if active
        if (self.agent_builder) |*builder| {
            builder.deinit();
        }

        // Clean up help viewer if active
        if (self.help_viewer) |*viewer| {
            viewer.deinit();
        }

        // Clean up profile UI if active
        if (self.profile_ui) |*profile_ui| {
            profile_ui.deinit();
        }

        // Clean up task memory system
        if (self.task_store) |store| {
            store.deinit();
            self.allocator.destroy(store);
        }
        if (self.task_db) |db| {
            var task_db = db;
            task_db.deinit();
            self.allocator.destroy(db);
        }

        // Clean up git sync
        if (self.git_sync) |sync| {
            sync.deinit();
            self.allocator.destroy(sync);
        }

        // Clean up git root path
        if (self.git_root) |root| {
            self.allocator.free(root);
        }

        // Clean up conversation database
        if (self.conversation_db) |*db| {
            db.deinit();
        }

        // Clean up agent system
        self.agent_loader.deinit();
        self.agent_registry.deinit();

        // Clean up incremental rendering state
        self.render_cache.deinit(self.allocator);

        // Clean up virtualization state
        self.virtualization.deinit(self.allocator);

        // Clean up config (App owns it)
        self.config.deinit(self.allocator);
    }

    /// Main event loop - thin dispatcher that coordinates extracted modules
    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        _ = app_tui; // Will be used later for editor integration

        // Buffers for accumulating stream data
        // Track which streaming session the accumulators belong to
        var thinking_accumulator = std.ArrayListUnmanaged(u8){};
        defer thinking_accumulator.deinit(self.allocator);
        var content_accumulator = std.ArrayListUnmanaged(u8){};
        defer content_accumulator.deinit(self.allocator);
        var accumulator_session_id: ?u64 = null; // Tracks which streaming_message_id the accumulators belong to

        while (true) {
            // 1. Modal modes take priority
            switch (try modal_dispatcher.handleModals(self)) {
                .consumed => continue,
                .closed, .none => {},
            }

            // 2. Tool execution state machine
            switch (try app_tool_execution.tickToolExecution(self)) {
                .iteration_complete => {
                    // Streaming already started by tickToolExecution
                },
                .iteration_limit => {
                    // Already displayed message
                },
                .needs_redraw => {
                    // Redraw already done by tickToolExecution
                },
                .no_action => {},
            }

            // 3. Process stream chunks
            if (self.streaming_active) {
                // Detect session change - clear accumulators if streaming to a different message
                // This fixes a race condition where the done chunk from the previous session
                // might not be processed before the new session starts
                if (self.streaming_message_id) |current_id| {
                    if (accumulator_session_id) |prev_id| {
                        if (current_id != prev_id) {
                            // New streaming session - clear stale accumulator content
                            thinking_accumulator.clearRetainingCapacity();
                            content_accumulator.clearRetainingCapacity();
                        }
                    }
                    accumulator_session_id = current_id;
                }

                const result = try app_streaming.processStreamChunks(
                    self,
                    &thinking_accumulator,
                    &content_accumulator,
                );
                if (result.streaming_complete and result.has_pending_tool_calls) {
                    // pending_tool_calls was set by processStreamChunks, start execution
                    if (self.pending_tool_calls) |tool_calls| {
                        self.tool_executor.startExecution(tool_calls);
                        self.pending_tool_calls = null;
                    }
                }
                // Process queued messages after main streaming completes (no tool calls)
                if (result.streaming_complete and !result.has_pending_tool_calls) {
                    _ = try self.processQueuedMessages();
                }
                // Clear session tracking when streaming ends
                if (result.streaming_complete) {
                    accumulator_session_id = null;
                }
                if (result.needs_redraw) {
                    _ = try message_renderer.redrawScreen(self);
                }
            }

            // 4. Poll agent results
            try app_agents.processAgentToolEvents(self);
            if (try app_agents.pollAgentResult(self)) {
                self.agent_responding = false;

                // Process queued user messages
                _ = try self.processQueuedMessages();
            }

            // 4b. Process queued agent command events (kickback dispatch)
            _ = try app_agents.processAgentCommandEvents(self);

            // 5. Render (when not streaming)
            if (!self.streaming_active) {
                if (ui.resize_pending) {
                    ui.resize_pending = false;
                }
                _ = try message_renderer.redrawScreen(self);
            }

            // 6. Input handling
            if (self.streaming_active or self.tool_executor.hasPendingWork() or self.agent_thread != null) {
                // Read input non-blocking
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    var should_redraw = false;
                    if (try ui.handleInput(self, input, &should_redraw)) {
                        return;
                    }
                    if (should_redraw) {
                        _ = try message_renderer.redrawScreen(self);
                    }
                }
                // Small sleep to avoid busy-waiting
                std.Thread.sleep(10 * std.time.ns_per_ms);
            } else {
                // Normal blocking mode when not streaming
                var should_redraw = false;
                while (!should_redraw) {
                    // Check for resize signal before blocking on input
                    if (ui.resize_pending) {
                        should_redraw = true;
                        break;
                    }

                    // Check for resize completion timeout
                    if (self.resize_in_progress) {
                        const now = std.time.milliTimestamp();
                        if (now - self.last_resize_time > 200) {
                            should_redraw = true;
                            break;
                        }
                    }

                    var read_buffer: [128]u8 = undefined;
                    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                    if (bytes_read <= 0) {
                        // Check again after read timeout/interrupt
                        if (ui.resize_pending) {
                            should_redraw = true;
                            break;
                        }
                        if (self.resize_in_progress) {
                            const now = std.time.milliTimestamp();
                            if (now - self.last_resize_time > 200) {
                                should_redraw = true;
                                break;
                            }
                        }
                        continue;
                    }
                    const input = read_buffer[0..@intCast(bytes_read)];
                    if (try ui.handleInput(self, input, &should_redraw)) {
                        return;
                    }
                }
            }

            // Adjust viewport to keep cursor in view
            const input_field_height = message_renderer.calculateInputFieldHeight(self) catch 2;
            const view_height = if (self.terminal_size.height > input_field_height + 1)
                self.terminal_size.height - input_field_height - 1
            else
                1;
            if (self.cursor_y < self.scroll.offset + 1) {
                self.scroll.offset = if (self.cursor_y > 0) self.cursor_y - 1 else 0;
            }
            if (self.cursor_y > self.scroll.offset + view_height) {
                self.scroll.offset = self.cursor_y - view_height;
            }
        }
    }
};
