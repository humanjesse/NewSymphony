// Agent System - Core abstractions for isolated LLM sub-tasks
const std = @import("std");
const ollama = @import("ollama");
const llm_provider_module = @import("llm_provider");
const config_module = @import("config");
const tools_module = @import("tools");
const zvdb = @import("zvdb");
const embedder_interface = @import("embedder_interface");
const conversation_db_module = @import("conversation_db");
const task_store_module = @import("task_store");
const task_db_module = @import("task_db");
const git_sync_module = @import("git_sync");
const state_module = @import("state");

/// Structured data for tool completion progress updates
/// Replaces stringly-typed "name|success|time_ms" format
pub const ToolProgressData = struct {
    name: []const u8,
    success: bool,
    execution_time_ms: i64,
    // Display fields for subagent tool call transparency
    arguments: ?[]const u8 = null, // Tool call arguments JSON
    result: ?[]const u8 = null, // Tool result (success data or error msg)
    data_size_bytes: usize = 0, // For display stats
};

/// Progress update callback function type (shared with GraphRAG)
/// - message: Text message for most update types
/// - tool_data: Structured data for .tool_complete updates (null for other types)
pub const ProgressCallback = *const fn (user_data: ?*anyopaque, update_type: ProgressUpdateType, message: []const u8, tool_data: ?*const ToolProgressData) void;

/// Types of progress updates during agent execution (shared with GraphRAG)
pub const ProgressUpdateType = enum {
    thinking,       // LLM is thinking
    content,        // LLM produced text content
    tool_call,      // Made a tool call (for stream detection)
    tool_start,     // Tool execution starting
    tool_complete,  // Tool execution finished with result
    iteration,      // Starting new iteration
    complete,       // Task finished
    // GraphRAG-specific types (backward compatible)
    embedding,      // Creating embeddings (GraphRAG only)
    storage,        // Storing in vector DB (GraphRAG only)
};

/// Task-specific metadata for progress display (GraphRAG stats, etc.)
pub const TaskMetadata = struct {
    file_path: ?[]const u8 = null,
    nodes_created: usize = 0,
    edges_created: usize = 0,
    embeddings_created: usize = 0,
};

/// Shared context for streaming progress to UI (agents + GraphRAG + future tasks)
/// This unified type replaces both AgentProgressContext and IndexingProgressContext
pub const ProgressDisplayContext = struct {
    app: *@import("app").App,
    current_message_idx: ?usize = null,

    // Separate buffers for thinking vs content (better UX than single buffer)
    thinking_buffer: std.ArrayListUnmanaged(u8) = .{},
    content_buffer: std.ArrayListUnmanaged(u8) = .{},

    // Finalization tracking
    finalized: bool = false,

    // Display metadata
    task_name: []const u8 = "Task",  // e.g., "File Curator", "GraphRAG Indexing"
    task_name_owned: bool = false,   // Whether task_name was allocated and needs freeing
    task_icon: []const u8 = "🤔",    // Custom icon per task type
    start_time: i64 = 0,             // For execution time tracking

    // Optional task-specific metadata (for GraphRAG stats, etc.)
    metadata: ?TaskMetadata = null,

    // Track current tool message for updating after completion
    current_tool_message_idx: ?usize = null,

    // Flag to indicate this is running in a background thread
    // When true, UI operations (message appends, redraws) should be skipped
    is_background_thread: bool = false,

    pub fn deinit(self: *ProgressDisplayContext, allocator: std.mem.Allocator) void {
        self.thinking_buffer.deinit(allocator);
        self.content_buffer.deinit(allocator);
        if (self.task_name_owned) {
            allocator.free(self.task_name);
        }
    }
};

/// Agent capability and resource limits
pub const AgentCapabilities = struct {
    /// Which tools this agent is allowed to use (by name)
    allowed_tools: []const []const u8,

    /// Maximum iterations before agent must terminate
    max_iterations: usize,

    /// Override model (use different/smaller model than main app)
    model_override: ?[]const u8 = null,

    /// Temperature for LLM sampling (0.0 = deterministic, 1.0 = creative)
    temperature: f32 = 0.7,

    /// Context window size override
    num_ctx: ?usize = null,

    /// Max tokens to predict (-1 = unlimited, positive = limit)
    num_predict: isize = -1,

    /// Enable extended thinking for this agent
    enable_thinking: bool = false,

    /// Response format (e.g., "json" for structured output)
    format: ?[]const u8 = null,

    /// Conversation mode - agent waits for user input instead of completing
    /// When true, agent returns .needs_input when it responds without tool calls
    conversation_mode: bool = false,
};

/// Execution context provided to agents (controlled subset of AppContext)
pub const AgentContext = struct {
    allocator: std.mem.Allocator,
    llm_provider: *llm_provider_module.LLMProvider,
    config: *const config_module.Config,
    capabilities: AgentCapabilities,
    system_prompt: []const u8, // Agent's defining prompt (from AgentDefinition)

    // Optional resources - only provided if agent needs them
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio

    // Optional conversation history for context-aware agents
    // Contains recent messages from main conversation to help agents
    // understand what the user is asking about
    recent_messages: ?[]const @import("types").Message = null,

    // Optional mutable messages list for compression agent
    // Allows compression tools to modify the conversation history
    messages_list: ?*anyopaque = null, // *std.ArrayListUnmanaged(Message) - using anyopaque to avoid circular import

    // Conversation persistence for agent message tracking
    conversation_db: ?*conversation_db_module.ConversationDB = null,
    session_id: ?i64 = null,
    current_task_id: ?[]const u8 = null, // Task ID from task_store if working on a specific task

    // Task memory system (for agents that manage tasks)
    task_store: ?*task_store_module.TaskStore = null,
    task_db: ?*task_db_module.TaskDB = null,
    git_sync: ?*git_sync_module.GitSync = null,

    // Application state (for agents that use todos/file tracking)
    state: *state_module.AppState,

    // Agent registry (for agents that spawn other agents)
    agent_registry: ?*AgentRegistry = null,
};

/// Statistics about agent execution
pub const AgentStats = struct {
    iterations_used: usize,
    tool_calls_made: usize,
    tokens_used: usize = 0,
    execution_time_ms: i64,
};

/// Status of agent execution
pub const AgentStatus = enum {
    complete, // Agent finished successfully
    failed, // Agent failed with error
    needs_input, // Agent responded but needs user input (conversation mode)
};

/// Result returned by agent execution
pub const AgentResult = struct {
    success: bool,

    /// Execution status (complete or failed)
    status: AgentStatus = .complete,

    /// Main result data (JSON string or plain text)
    data: ?[]const u8,

    /// Structured metadata (optional, parsed JSON)
    metadata: ?std.json.Value = null,

    /// Error message if success = false
    error_message: ?[]const u8 = null,

    /// Agent's extended thinking/reasoning (if enabled)
    thinking: ?[]const u8 = null,

    /// Execution statistics
    stats: AgentStats,

    /// Helper to create success result
    pub fn ok(allocator: std.mem.Allocator, data: []const u8, stats: AgentStats, thinking_opt: ?[]const u8) !AgentResult {
        return .{
            .success = true,
            .status = .complete,
            .data = try allocator.dupe(u8, data),
            .error_message = null,
            .thinking = if (thinking_opt) |t| try allocator.dupe(u8, t) else null,
            .stats = stats,
        };
    }

    /// Helper to create error result
    pub fn err(allocator: std.mem.Allocator, error_msg: []const u8, stats: AgentStats) !AgentResult {
        return .{
            .success = false,
            .status = .failed,
            .data = null,
            .error_message = try allocator.dupe(u8, error_msg),
            .stats = stats,
        };
    }

    /// Free all owned memory
    pub fn deinit(self: *AgentResult, allocator: std.mem.Allocator) void {
        if (self.data) |data| {
            allocator.free(data);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.thinking) |thinking| {
            allocator.free(thinking);
        }
        if (self.metadata) |_| {
            // metadata is a std.json.Value, we'll handle this in agent_executor
            // when we actually parse JSON
        }
    }
};

/// Agent definition - describes what the agent does and how to run it
pub const AgentDefinition = struct {
    /// Unique name for this agent
    name: []const u8,

    /// Human-readable description
    description: []const u8,

    /// System prompt that guides the agent's behavior
    system_prompt: []const u8,

    /// Capabilities and resource limits
    capabilities: AgentCapabilities,

    /// Main execution function
    /// - allocator: Memory allocator
    /// - context: Execution context with resources
    /// - task: Task description/input for the agent
    /// - progress_callback: Optional callback for progress updates
    /// - callback_user_data: User data passed to progress callback
    execute: *const fn (
        allocator: std.mem.Allocator,
        context: AgentContext,
        task: []const u8,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) anyerror!AgentResult,
};

/// Interface for AgentExecutor to avoid circular imports and anyopaque casts
/// Implemented by agent_executor.AgentExecutor
pub const AgentExecutorInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        getMessageHistoryLen: *const fn (ptr: *anyopaque) usize,
    };

    pub fn deinit(self: AgentExecutorInterface) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getMessageHistoryLen(self: AgentExecutorInterface) usize {
        return self.vtable.getMessageHistoryLen(self.ptr);
    }
};

/// Agent registry for looking up agents by name
pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.StringHashMapUnmanaged(AgentDefinition),

    pub fn init(allocator: std.mem.Allocator) AgentRegistry {
        return .{
            .allocator = allocator,
            .agents = .{},
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        self.agents.deinit(self.allocator);
    }

    /// Clear all registered agents (keeps allocated capacity)
    pub fn clear(self: *AgentRegistry) void {
        self.agents.clearRetainingCapacity();
    }

    /// Register an agent
    pub fn register(self: *AgentRegistry, definition: AgentDefinition) !void {
        try self.agents.put(self.allocator, definition.name, definition);
    }

    /// Get an agent by name
    pub fn get(self: *const AgentRegistry, name: []const u8) ?AgentDefinition {
        return self.agents.get(name);
    }

    /// Check if agent exists
    pub fn has(self: *const AgentRegistry, name: []const u8) bool {
        return self.agents.contains(name);
    }
};
