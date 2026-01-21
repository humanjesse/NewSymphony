// Message loader module - handles virtualized message loading/unloading
// Ensures memory stays bounded regardless of conversation length

const std = @import("std");
const mem = std.mem;
const markdown = @import("markdown");
const types = @import("types");
const conversation_db_module = @import("conversation_db");

// Forward declare App type to avoid circular dependency
const app_module = @import("app");
const App = app_module.App;
const Message = types.Message;

/// Free all allocations owned by a message
pub fn freeMessage(allocator: mem.Allocator, message: *Message) void {
    allocator.free(message.content);

    for (message.processed_content.items) |*item| {
        item.deinit(allocator);
    }
    message.processed_content.deinit(allocator);

    // Clean up thinking content if present
    if (message.thinking_content) |thinking| {
        allocator.free(thinking);
    }
    if (message.processed_thinking_content) |*thinking_processed| {
        for (thinking_processed.items) |*item| {
            item.deinit(allocator);
        }
        thinking_processed.deinit(allocator);
    }

    // Clean up tool calling fields
    if (message.tool_calls) |calls| {
        for (calls) |call| {
            if (call.id) |id| allocator.free(id);
            if (call.type) |call_type| allocator.free(call_type);
            allocator.free(call.function.name);
            allocator.free(call.function.arguments);
        }
        allocator.free(calls);
    }
    if (message.tool_call_id) |id| {
        allocator.free(id);
    }

    // Clean up permission request if present
    if (message.permission_request) |perm_req| {
        if (perm_req.tool_call.id) |id| allocator.free(id);
        if (perm_req.tool_call.type) |call_type| allocator.free(call_type);
        allocator.free(perm_req.tool_call.function.name);
        allocator.free(perm_req.tool_call.function.arguments);
        allocator.free(perm_req.eval_result.reason);
    }

    // Clean up tool execution metadata
    if (message.tool_name) |name| {
        allocator.free(name);
    }

    // Clean up agent analysis metadata
    if (message.agent_analysis_name) |name| {
        allocator.free(name);
    }

    // Clean up agent source
    if (message.agent_source) |source| {
        allocator.free(source);
    }
}

/// Unload messages outside a specified range, storing height estimates
/// keep_start and keep_end are inclusive
pub fn unloadOutsideRange(app: *App, keep_start: usize, keep_end: usize) !void {
    const virt = &app.virtualization;
    const allocator = app.allocator;

    // Calculate how many messages to unload from the start
    var unload_from_start: usize = 0;
    if (keep_start > virt.loaded_start) {
        unload_from_start = keep_start - virt.loaded_start;
    }

    // Calculate how many messages to unload from the end
    var unload_from_end: usize = 0;
    if (keep_end + 1 < virt.loaded_end) {
        unload_from_end = virt.loaded_end - (keep_end + 1);
    }

    // Don't unload streaming message (check before unloading from start)
    if (virt.streaming_message_idx) |streaming_idx| {
        // If streaming message would be unloaded, reduce unload count
        if (streaming_idx >= virt.loaded_start and streaming_idx < virt.loaded_start + unload_from_start) {
            unload_from_start = streaming_idx - virt.loaded_start;
        }
    }

    // Store height estimates and free messages from start
    for (0..unload_from_start) |_| {
        if (app.messages.items.len == 0) break;

        const msg = &app.messages.items[0];
        const abs_idx = virt.loaded_start;

        // Store height estimate if cached
        if (msg.cached_height) |height| {
            try virt.storeHeightEstimate(allocator, abs_idx, height);
        }

        // Free the message
        freeMessage(allocator, msg);

        // Remove from array (shift everything left)
        _ = app.messages.orderedRemove(0);
        virt.loaded_start += 1;
    }

    // Store height estimates and free messages from end
    for (0..unload_from_end) |_| {
        if (app.messages.items.len == 0) break;

        const last_idx = app.messages.items.len - 1;
        const msg = &app.messages.items[last_idx];
        const abs_idx = virt.loaded_end - 1;

        // Don't unload streaming message
        if (virt.streaming_message_idx) |streaming_idx| {
            if (abs_idx == streaming_idx) break;
        }

        // Store height estimate if cached
        if (msg.cached_height) |height| {
            try virt.storeHeightEstimate(allocator, abs_idx, height);
        }

        // Free the message
        freeMessage(allocator, msg);

        // Remove from array
        _ = app.messages.pop();
        virt.loaded_end -= 1;
    }

    // Invalidate render cache since messages changed
    app.render_cache.invalidate();
}

/// Load messages from database into the specified range
/// Returns number of messages loaded
pub fn loadRange(app: *App, start_idx: usize, end_idx: usize) !usize {
    const virt = &app.virtualization;
    const allocator = app.allocator;

    // Get conversation database
    const conv_id = app.current_conversation_id orelse return 0;
    const db = if (app.conversation_db) |*d| d else return 0;

    // Load messages from database
    const rows = try db.loadMessages(conv_id, @intCast(start_idx), @intCast(end_idx));
    defer {
        for (rows) |*row| {
            var r = row.*;
            r.deinit(allocator);
        }
        allocator.free(rows);
    }

    var loaded_count: usize = 0;

    for (rows) |*row| {
        // Convert row to Message
        const message = try app.messageFromRow(row);

        // Determine where to insert based on index
        const abs_idx: usize = @intCast(row.message_index);

        if (abs_idx < virt.loaded_start) {
            // Insert at beginning
            try app.messages.insert(allocator, 0, message);
            virt.loaded_start = abs_idx;
        } else if (abs_idx >= virt.loaded_end) {
            // Append at end
            try app.messages.append(allocator, message);
            virt.loaded_end = abs_idx + 1;
        } else {
            // Insert in middle (shouldn't happen in normal use)
            const local_idx = abs_idx - virt.loaded_start;
            if (local_idx <= app.messages.items.len) {
                try app.messages.insert(allocator, local_idx, message);
            }
        }

        loaded_count += 1;
    }

    // Invalidate render cache since messages changed
    app.render_cache.invalidate();

    return loaded_count;
}

/// Ensure messages around a target index are loaded
/// Respects streaming protection and debouncing
pub fn ensureMessagesLoaded(app: *App, target_idx: usize) !void {
    const virt = &app.virtualization;

    // Debounce rapid scroll (50ms)
    const now = std.time.milliTimestamp();
    if (now - virt.last_load_time < 50) return;
    virt.last_load_time = now;

    // Calculate desired range around target
    const half_target = virt.target_loaded / 2;
    const desired_start = if (target_idx > half_target) target_idx - half_target else 0;
    const desired_end = @min(target_idx + half_target, virt.total_message_count);

    // Add buffer
    const buffer_start = if (desired_start > virt.buffer_size) desired_start - virt.buffer_size else 0;
    const buffer_end = @min(desired_end + virt.buffer_size, virt.total_message_count);

    // Protect streaming message
    var keep_start = buffer_start;
    var keep_end = buffer_end;
    if (virt.streaming_message_idx) |streaming_idx| {
        keep_start = @min(keep_start, streaming_idx);
        keep_end = @max(keep_end, streaming_idx + 1);
    }

    // Unload messages outside the desired range
    try unloadOutsideRange(app, keep_start, keep_end);

    // Load messages that are needed but not yet loaded
    if (keep_start < virt.loaded_start) {
        // Need to load from start
        const load_end = @min(virt.loaded_start, keep_end);
        if (load_end > keep_start) {
            _ = try loadRange(app, keep_start, load_end - 1);
        }
    }

    if (keep_end > virt.loaded_end) {
        // Need to load from end
        const load_start = @max(virt.loaded_end, keep_start);
        if (keep_end > load_start) {
            _ = try loadRange(app, load_start, keep_end - 1);
        }
    }
}

/// Calculate total height of all messages (loaded and unloaded)
/// Uses cached heights for loaded messages, estimates for unloaded
pub fn calculateTotalHeight(app: *App) !usize {
    const virt = &app.virtualization;
    var total: usize = 1; // Start at 1

    // Height for messages before loaded range (use estimates)
    for (0..virt.loaded_start) |abs_idx| {
        total += virt.getEstimatedHeight(abs_idx);
    }

    // Height for loaded messages (use cached or calculate)
    const message_renderer = @import("message_renderer");
    for (app.messages.items, 0..) |*message, local_idx| {
        const abs_idx = virt.absoluteIndex(local_idx);

        // Skip tool JSON if hidden by config
        if (message.role == .tool and !app.config.show_tool_json) continue;

        // Skip empty system messages
        if (message.role == .system and message.content.len == 0) continue;

        total += try message_renderer.getMessageHeight(app, message, abs_idx);
    }

    // Height for messages after loaded range (use estimates)
    for (virt.loaded_end..virt.total_message_count) |abs_idx| {
        total += virt.getEstimatedHeight(abs_idx);
    }

    return total;
}

/// Initialize virtualization state with current message count
pub fn initVirtualization(app: *App) !void {
    const virt = &app.virtualization;

    // Get total message count from database
    if (app.conversation_db) |*db| {
        if (app.current_conversation_id) |conv_id| {
            virt.total_message_count = try db.getMessageCount(conv_id);
        }
    }

    // Initially all messages in memory are "loaded"
    virt.loaded_start = 0;
    virt.loaded_end = app.messages.items.len;
}

/// Update virtualization state after adding a new message
pub fn onMessageAdded(app: *App) void {
    app.virtualization.total_message_count += 1;
    app.virtualization.loaded_end += 1;
    app.render_cache.invalidate();
}

/// Set streaming protection for a message
pub fn setStreamingProtection(app: *App, absolute_idx: ?usize) void {
    app.virtualization.streaming_message_idx = absolute_idx;
}

/// Clear streaming protection
pub fn clearStreamingProtection(app: *App) void {
    app.virtualization.streaming_message_idx = null;
}
