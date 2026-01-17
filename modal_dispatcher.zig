// Modal dispatcher - unified handling for modal UI modes
const std = @import("std");
const ui = @import("ui");
const markdown = @import("markdown");
const llm_provider_module = @import("llm_provider");
const config_editor_state = @import("config_editor_state");
const config_editor_renderer = @import("config_editor_renderer");
const config_editor_input = @import("config_editor_input");
const agent_builder_state = @import("agent_builder_state");
const agent_builder_renderer = @import("agent_builder_renderer");
const agent_builder_input = @import("agent_builder_input");
const help_state = @import("help_state");
const help_renderer = @import("help_renderer");
const help_input = @import("help_input");
const profile_ui_state = @import("profile_ui_state");
const profile_ui_renderer = @import("profile_ui_renderer");
const profile_ui_input = @import("profile_ui_input");
const profile_manager = @import("profile_manager");

// Forward declare App type to avoid circular dependency
const App = @import("app.zig").App;

/// Result of modal handling
pub const ModalResult = enum {
    consumed, // Modal handled this iteration, skip normal app
    closed, // Modal was closed, continue normal app
    none, // No modal active
};

/// Handle all modal UI modes
/// Returns ModalResult indicating how to proceed
pub fn handleModals(app: *App) !ModalResult {
    // CONFIG EDITOR MODE (modal - takes priority over normal app)
    if (app.config_editor) |*editor| {
        return try handleConfigEditor(app, editor);
    }

    // AGENT BUILDER MODE (modal - similar to config editor)
    if (app.agent_builder) |*builder| {
        return try handleAgentBuilder(app, builder);
    }

    // HELP VIEWER MODE (modal - simple read-only display)
    if (app.help_viewer) |*viewer| {
        return try handleHelpViewer(app, viewer);
    }

    // PROFILE MANAGER MODE (modal - interactive profile management)
    if (app.profile_ui) |*profile_ui| {
        return try handleProfileUI(app, profile_ui);
    }

    return .none;
}

/// Handle config editor modal
fn handleConfigEditor(app: *App, editor: *config_editor_state.ConfigEditorState) !ModalResult {
    // Render editor (renderer will clear screen)
    var stdout_buffer: [8192]u8 = undefined;
    var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
    const writer = buffered_writer.writer();

    try config_editor_renderer.render(
        editor,
        writer,
        app.terminal_size.width,
        app.terminal_size.height,
    );
    try buffered_writer.flush();

    // Wait for input (blocking)
    var read_buffer: [128]u8 = undefined;
    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

    if (bytes_read > 0) {
        const input = read_buffer[0..@intCast(bytes_read)];
        const result = try config_editor_input.handleInput(editor, input);

        switch (result) {
            .save_and_close => {
                // Validate config before saving
                editor.temp_config.validate() catch |err| {
                    std.debug.print("\n⚠ Config validation warning: {s}\n", .{@errorName(err)});
                    std.debug.print("   Saving anyway, but please review your settings.\n\n", .{});
                };

                // Check if profile name changed
                const original_profile = try profile_manager.getActiveProfileName(app.allocator);
                defer app.allocator.free(original_profile);

                var profile_changed = !std.mem.eql(u8, editor.profile_name, original_profile);

                // If profile name changed, validate it
                if (profile_changed) {
                    if (!profile_manager.validateProfileName(editor.profile_name)) {
                        std.debug.print("\n⚠ Invalid profile name: '{s}'\n", .{editor.profile_name});
                        std.debug.print("   Profile names must be alphanumeric with dashes/underscores only.\n", .{});
                        std.debug.print("   Saving to original profile instead.\n\n", .{});
                        // Revert to original profile name
                        app.allocator.free(editor.profile_name);
                        editor.profile_name = try app.allocator.dupe(u8, original_profile);
                        profile_changed = false;
                    }
                }

                // Save based on whether name actually changed
                if (profile_changed) {
                    // Save to new profile name
                    try profile_manager.saveProfile(app.allocator, editor.profile_name, editor.temp_config);

                    // Set as active profile
                    try profile_manager.setActiveProfileName(app.allocator, editor.profile_name);

                    std.debug.print("\n✓ Saved as new profile: {s}\n", .{editor.profile_name});
                } else {
                    // Save to current profile
                    try profile_manager.saveProfile(app.allocator, editor.profile_name, editor.temp_config);

                    std.debug.print("\n✓ Saved profile: {s}\n", .{editor.profile_name});
                }

                // Apply changes to running config (transfer ownership)
                app.config.deinit(app.allocator);
                app.config = editor.temp_config;

                // Re-initialize markdown and UI colors with new config
                // CRITICAL: This must be done after config is replaced, since the old
                // config strings were just freed and markdown.COLOR_INLINE_CODE_BG
                // would be a dangling pointer otherwise
                markdown.initColors(app.config.color_inline_code_bg);
                ui.initUIColors(app.config.color_status);

                // Recreate LLM provider with new config
                app.llm_provider.deinit();
                app.llm_provider = try llm_provider_module.createProvider(
                    app.config.provider,
                    app.allocator,
                    app.config,
                );

                // Close editor (but DON'T deinit temp_config - we transferred it to app.config!)
                // Manually free only the editor's sections, fields, and profile_name
                app.allocator.free(editor.profile_name);

                for (editor.sections) |section| {
                    // Free section title (dynamically allocated)
                    app.allocator.free(section.title);

                    for (section.fields) |field| {
                        if (field.edit_buffer) |buffer| {
                            app.allocator.free(buffer);
                        }
                        // Free options array (allocated by listIdentifiers, etc.)
                        if (field.options) |options| {
                            app.allocator.free(options);
                        }
                    }
                    app.allocator.free(section.fields);
                }
                app.allocator.free(editor.sections);
                app.config_editor = null;
                return .closed;
            },
            .cancel => {
                // Discard changes and close editor
                editor.deinit();
                app.config_editor = null;
                return .closed;
            },
            .redraw, .@"continue" => {},
        }
    }

    return .consumed;
}

/// Handle agent builder modal
fn handleAgentBuilder(app: *App, builder: *agent_builder_state.AgentBuilderState) !ModalResult {
    // Render builder
    var stdout_buffer: [8192]u8 = undefined;
    var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
    const writer = buffered_writer.writer();

    try agent_builder_renderer.render(
        builder,
        writer,
        app.terminal_size.width,
        app.terminal_size.height,
    );
    try buffered_writer.flush();

    // Wait for input (blocking)
    var read_buffer: [128]u8 = undefined;
    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

    if (bytes_read > 0) {
        const input = read_buffer[0..@intCast(bytes_read)];
        const result = try agent_builder_input.handleInput(builder, input);

        switch (result) {
            .save_and_close => {
                // Save agent
                agent_builder_input.saveAgent(builder) catch |err| {
                    std.debug.print("Failed to save agent: {}\n", .{err});
                };

                // Close builder
                builder.deinit();
                app.agent_builder = null;

                // Reload agents to include the new one
                try app.agent_loader.loadAllAgents();
                return .closed;
            },
            .cancel => {
                // Close without saving
                builder.deinit();
                app.agent_builder = null;
                return .closed;
            },
            .redraw, .@"continue" => {
                // Just re-render next iteration
            },
        }
    }

    return .consumed;
}

/// Handle help viewer modal
fn handleHelpViewer(app: *App, viewer: *help_state.HelpState) !ModalResult {
    // Render help
    var stdout_buffer: [8192]u8 = undefined;
    var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
    const writer = buffered_writer.writer();

    try help_renderer.render(
        viewer,
        writer,
        app.terminal_size.width,
        app.terminal_size.height,
    );
    try buffered_writer.flush();

    // Wait for input (blocking)
    var read_buffer: [128]u8 = undefined;
    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

    if (bytes_read > 0) {
        const input = read_buffer[0..@intCast(bytes_read)];
        // Calculate visible lines for scrolling
        const visible_lines = app.terminal_size.height -| 6; // Account for borders and footer
        const result = try help_input.handleInput(viewer, input, visible_lines);

        switch (result) {
            .close => {
                // Close help viewer
                viewer.deinit();
                app.help_viewer = null;
                return .closed;
            },
            .redraw, .@"continue" => {
                // Just re-render next iteration
            },
        }
    }

    return .consumed;
}

/// Handle profile UI modal
fn handleProfileUI(app: *App, profile_ui: *profile_ui_state.ProfileUIState) !ModalResult {
    // Render profile UI
    var stdout_buffer: [8192]u8 = undefined;
    var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
    const writer = buffered_writer.writer();

    try profile_ui_renderer.render(
        profile_ui,
        writer,
        app.terminal_size.width,
        app.terminal_size.height,
    );
    try buffered_writer.flush();

    // Wait for input (blocking)
    var read_buffer: [128]u8 = undefined;
    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

    if (bytes_read > 0) {
        const input = read_buffer[0..@intCast(bytes_read)];
        const result = try profile_ui_input.handleInput(profile_ui, app, input);

        switch (result) {
            .close, .profile_switched => {
                // Close profile UI
                profile_ui.deinit();
                app.profile_ui = null;
                return .closed;
            },
            .redraw, .@"continue" => {
                // Just re-render next iteration
            },
        }
    }

    return .consumed;
}
