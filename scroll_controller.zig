// Unified scroll state management for all scrollable views
// Extracts common scroll logic from app.zig, help_state.zig, and message_renderer.zig
//
// CLASS INVARIANT (enforced after every public mutating method):
//   1. offset <= maxScroll()
//   2. (content_height == 0) implies (offset == 0)
//   3. (user_scrolled_away == false) implies isAtBottom()

const std = @import("std");

pub const ScrollState = struct {
    const Self = @This();

    offset: usize = 0,
    content_height: usize = 0,
    viewport_height: usize = 0,
    user_scrolled_away: bool = false,

    // Private helpers

    /// Enforce class invariant (debug builds only).
    fn checkInvariant(self: *const Self) void {
        std.debug.assert(self.offset <= self.maxScroll());
        std.debug.assert(self.content_height != 0 or self.offset == 0);
        std.debug.assert(self.user_scrolled_away or self.isAtBottom());
    }

    /// Clamp offset to valid bounds.
    fn clamp(self: *Self) void {
        const max = self.maxScroll();
        if (self.offset > max) {
            self.offset = max;
        }
    }

    /// Apply auto-scroll policy: if auto-scroll is enabled, snap to bottom.
    /// This is the single place where the auto-scroll invariant is enforced.
    fn applyAutoScrollPolicy(self: *Self) void {
        if (!self.user_scrolled_away) {
            self.offset = self.maxScroll();
        }
    }

    // Core methods

    /// Calculate the maximum scroll offset based on content and viewport height.
    /// This is a pure query with no preconditions.
    pub fn maxScroll(self: *const Self) usize {
        if (self.content_height > self.viewport_height) {
            return self.content_height - self.viewport_height;
        }
        return 0;
    }

    /// Check if currently scrolled to (or near) the bottom.
    /// Returns true if within 3 lines of bottom to provide hysteresis.
    /// This is a pure query with no preconditions.
    pub fn isAtBottom(self: *const Self) bool {
        const max = self.maxScroll();
        const near_bottom_threshold = 3;
        return self.offset >= max or (max > 0 and max - self.offset <= near_bottom_threshold);
    }

    // Scroll operations

    /// Scroll up by the specified number of lines.
    /// require: (none)
    /// ensure: offset <= old(offset), user_scrolled_away == true
    pub fn scrollUp(self: *Self, lines: usize) void {
        if (self.offset >= lines) {
            self.offset -= lines;
        } else {
            self.offset = 0;
        }
        self.user_scrolled_away = true;
        self.checkInvariant();
    }

    /// Scroll down by the specified number of lines.
    /// If this brings us near the bottom, re-enable auto-scroll.
    /// require: (none)
    /// ensure: offset >= old(offset), isAtBottom() implies user_scrolled_away == false
    pub fn scrollDown(self: *Self, lines: usize) void {
        const max = self.maxScroll();
        self.offset = @min(self.offset + lines, max);

        // Re-enable auto-scroll if near the bottom
        if (self.isAtBottom()) {
            self.user_scrolled_away = false;
        }
        self.checkInvariant();
    }

    /// Scroll to the very top.
    /// require: (none)
    /// ensure: offset == 0, user_scrolled_away == true
    pub fn scrollToTop(self: *Self) void {
        self.offset = 0;
        self.user_scrolled_away = true;
        self.checkInvariant();
    }

    /// Scroll to the very bottom and re-enable auto-scroll.
    /// require: (none)
    /// ensure: offset == maxScroll(), user_scrolled_away == false, isAtBottom() == true
    pub fn scrollToBottom(self: *Self) void {
        self.offset = self.maxScroll();
        self.user_scrolled_away = false;
        self.checkInvariant();
    }

    // Content/viewport updates

    /// Update the content height.
    /// require: (none)
    /// ensure: content_height == new_height,
    ///         (not user_scrolled_away) implies isAtBottom(),
    ///         offset <= maxScroll()
    pub fn updateContentHeight(self: *Self, new_height: usize) void {
        self.content_height = new_height;
        self.clamp();
        self.applyAutoScrollPolicy();
        self.checkInvariant();
    }

    /// Update the viewport height.
    /// require: (none)
    /// ensure: viewport_height == new_height, offset <= maxScroll()
    pub fn updateViewportHeight(self: *Self, new_height: usize) void {
        self.viewport_height = new_height;
        self.clamp();
        self.applyAutoScrollPolicy();
        self.checkInvariant();
    }

    /// Enable auto-scroll (e.g., after sending a message).
    /// require: (none)
    /// ensure: user_scrolled_away == false, isAtBottom() == true
    pub fn enableAutoScroll(self: *Self) void {
        self.user_scrolled_away = false;
        self.applyAutoScrollPolicy();
        self.checkInvariant();
    }

    /// Reset all scroll state (e.g., on terminal resize).
    /// require: (none)
    /// ensure: offset == 0, content_height == 0, viewport_height == 0,
    ///         user_scrolled_away == false
    pub fn resetAll(self: *Self) void {
        self.offset = 0;
        self.content_height = 0;
        self.viewport_height = 0;
        self.user_scrolled_away = false;
        self.checkInvariant();
    }

    // Visibility helpers

    /// Convert an absolute Y position to a screen Y position
    /// Returns null if the position is not visible in the current viewport
    pub fn toScreenY(self: *const Self, absolute_y: usize) ?usize {
        if (absolute_y < self.offset) return null;
        const screen_y = absolute_y - self.offset;
        if (screen_y >= self.viewport_height) return null;
        return screen_y;
    }

    /// Check if an absolute Y position is visible in the current viewport
    pub fn isVisible(self: *const Self, absolute_y: usize) bool {
        return self.toScreenY(absolute_y) != null;
    }

    /// Get the range of visible absolute Y positions
    pub fn visibleRange(self: *const Self) struct { start: usize, end: usize } {
        return .{
            .start = self.offset,
            .end = self.offset + self.viewport_height,
        };
    }
};

// Tests
test "ScrollState basic operations" {
    var state = ScrollState{};

    // Initial state
    try std.testing.expectEqual(@as(usize, 0), state.offset);
    try std.testing.expectEqual(@as(usize, 0), state.maxScroll());
    try std.testing.expect(state.isAtBottom());

    // Set up viewport and content
    state.viewport_height = 10;
    state.content_height = 50;

    try std.testing.expectEqual(@as(usize, 40), state.maxScroll());
    try std.testing.expect(!state.isAtBottom());

    // Scroll to bottom
    state.scrollToBottom();
    try std.testing.expectEqual(@as(usize, 40), state.offset);
    try std.testing.expect(state.isAtBottom());
    try std.testing.expect(!state.user_scrolled_away);

    // Scroll up
    state.scrollUp(5);
    try std.testing.expectEqual(@as(usize, 35), state.offset);
    try std.testing.expect(state.user_scrolled_away);
    try std.testing.expect(!state.isAtBottom());

    // Scroll down near bottom (within 3 lines)
    state.scrollDown(3);
    try std.testing.expectEqual(@as(usize, 38), state.offset);
    try std.testing.expect(state.isAtBottom()); // Within 3 lines
    try std.testing.expect(!state.user_scrolled_away); // Re-enabled
}

test "ScrollState auto-scroll with content growth" {
    var state = ScrollState{};
    state.viewport_height = 10;

    // Initial content - auto-scroll snaps to bottom
    state.updateContentHeight(20);
    try std.testing.expectEqual(@as(usize, 10), state.offset);
    try std.testing.expect(state.isAtBottom());

    // Content grows - auto-scroll keeps us at bottom
    state.updateContentHeight(25);
    try std.testing.expectEqual(@as(usize, 15), state.offset);
    try std.testing.expect(state.isAtBottom());

    // User scrolls up - breaks auto-scroll
    state.scrollUp(5);
    try std.testing.expectEqual(@as(usize, 10), state.offset);
    try std.testing.expect(state.user_scrolled_away);

    // Content grows - should NOT auto-scroll (user scrolled away)
    state.updateContentHeight(30);
    try std.testing.expectEqual(@as(usize, 10), state.offset); // Stayed put
    try std.testing.expect(!state.isAtBottom());
}

test "ScrollState invariant holds through all operations" {
    var state = ScrollState{};

    // Invariant: empty state
    try std.testing.expect(state.offset <= state.maxScroll());
    try std.testing.expect(state.isAtBottom());

    // Set up viewport first, then content
    state.updateViewportHeight(10);
    state.updateContentHeight(50);

    // Invariant after content setup: auto-scroll on, so must be at bottom
    try std.testing.expect(!state.user_scrolled_away);
    try std.testing.expect(state.isAtBottom());

    // Scroll up - user_scrolled_away becomes true
    state.scrollUp(10);
    try std.testing.expect(state.user_scrolled_away);
    try std.testing.expect(state.offset <= state.maxScroll());

    // Content shrinks while user is scrolled away
    state.updateContentHeight(30);
    try std.testing.expect(state.offset <= state.maxScroll());

    // Scroll to bottom re-enables auto-scroll
    state.scrollToBottom();
    try std.testing.expect(!state.user_scrolled_away);
    try std.testing.expect(state.isAtBottom());

    // Enable auto-scroll
    state.scrollUp(5);
    state.enableAutoScroll();
    try std.testing.expect(!state.user_scrolled_away);
    try std.testing.expect(state.isAtBottom());
}

test "ScrollState toScreenY" {
    var state = ScrollState{};
    state.viewport_height = 10;
    state.content_height = 50;
    state.offset = 20;

    // Visible positions
    try std.testing.expectEqual(@as(?usize, 0), state.toScreenY(20));
    try std.testing.expectEqual(@as(?usize, 5), state.toScreenY(25));
    try std.testing.expectEqual(@as(?usize, 9), state.toScreenY(29));

    // Above viewport
    try std.testing.expectEqual(@as(?usize, null), state.toScreenY(19));

    // Below viewport
    try std.testing.expectEqual(@as(?usize, null), state.toScreenY(30));
}
