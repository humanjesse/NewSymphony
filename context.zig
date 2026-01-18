// Application context for tool execution
const std = @import("std");
const state_module = @import("state");
const config_module = @import("config");
const zvdb = @import("zvdb");
const embedder_interface = @import("embedder_interface");
const llm_provider_module = @import("llm_provider");
const types = @import("types");
const agents_module = @import("agents");
const ProgressUpdateType = agents_module.ProgressUpdateType;
const task_store_module = @import("task_store");
const task_db_module = @import("task_db");
const git_sync_module = @import("git_sync");
const conversation_db_module = @import("conversation_db");

/// State for an active agent conversation session (slash command mode)
pub const ActiveAgentSession = struct {
    /// Type-safe executor interface (use .ptr field to get underlying AgentExecutor when needed)
    executor: agents_module.AgentExecutorInterface,
    agent_name: []const u8,
    system_prompt: []const u8,
    capabilities: agents_module.AgentCapabilities,
};

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const config_module.Config,
    state: *state_module.AppState,
    llm_provider: *llm_provider_module.LLMProvider,

    // Vector DB components (kept for future semantic search)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio

    // Agent system (optional - only present if agents enabled)
    agent_registry: ?*agents_module.AgentRegistry = null,

    // Task memory system (Beads-inspired)
    task_store: ?*task_store_module.TaskStore = null,
    task_db: ?*task_db_module.TaskDB = null,
    git_sync: ?*git_sync_module.GitSync = null,

    // Conversation persistence for agent message tracking
    conversation_db: ?*conversation_db_module.ConversationDB = null,
    session_id: ?i64 = null,

    // Recent conversation messages for context-aware tools
    // Populated before tool execution, null otherwise
    // Tools can use this to understand what the user is asking about
    recent_messages: ?[]const types.Message = null,

    // Agent progress callback for real-time streaming
    // Set by app.zig before executing agent-powered tools
    // Allows sub-agents (like file curator) to stream progress to UI
    agent_progress_callback: ?agents_module.ProgressCallback = null,
    agent_progress_user_data: ?*anyopaque = null,

    // Active agent session for slash command conversations
    // When a user starts an agent with /agentname, session is stored here
    active_agent: ?*ActiveAgentSession = null,

    // Pointer to executor's planning_complete flag (set by planning_done tool)
    // When set to true, forces conversation_mode agent to complete
    planning_complete_ptr: ?*bool = null,

    // Pointer to executor's tinkering_complete flag (set by tinkering_done tool)
    // When set to true, signals that implementation is ready for Judge review
    tinkering_complete_ptr: ?*bool = null,

    // Current agent name (set by executor when running an agent)
    // Used by add_task_comment to attribute comments
    current_agent_name: ?[]const u8 = null,
};
