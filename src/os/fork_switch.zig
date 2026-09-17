//! Switches that this build adds to the Ghostty it came from.
//!
//! Each desktop keeps a switch of this kind in its own place, and this reads
//! that place rather than the configuration file: a Ghostty from the website
//! would warn about a setting it has never heard of, and one configuration
//! file has to serve both. Every switch is off until asked for, so unasked
//! this build behaves as the one it came from.
//!
//!   macOS: defaults write com.mitchellh.ghostty <key> -bool true
//!   Linux: <env>=1 in the environment

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");

/// Highlight links under a program that has turned mouse reporting on.
pub const link_hover_mouse_capture: Switch = .{
    .key = "LinkHoverMouseCapture",
    .env = "GHOSTTY_LINK_HOVER_MOUSE_CAPTURE",
};

/// Match a link across a hard line break where a program wrapped it by
/// itself, as Claude Code does with a long URL in inline code.
pub const link_join_hard_wraps: Switch = .{
    .key = "LinkJoinHardWraps",
    .env = "GHOSTTY_LINK_JOIN_HARD_WRAPS",
};

pub const Switch = struct {
    /// The key under com.mitchellh.ghostty in the macOS defaults.
    key: [:0]const u8,

    /// The environment variable on every other desktop.
    env: []const u8,

    pub fn enabled(self: Switch) bool {
        if (comptime builtin.os.tag.isDarwin()) {
            const macos = @import("macos");
            const key = macos.foundation.String.createWithBytes(
                self.key,
                .utf8,
                false,
            ) catch return false;
            defer key.release();

            // Named rather than asked for as the current application, so that
            // the domain is the one the command above writes whatever is
            // reading it: the application, or the `ghostty` beside it in the
            // bundle.
            const domain = macos.foundation.String.createWithBytes(
                "com.mitchellh.ghostty",
                .utf8,
                false,
            ) catch return false;
            defer domain.release();

            var valid: u8 = 0;
            const value = macos.c.CFPreferencesGetAppBooleanValue(
                @ptrCast(key),
                @ptrCast(domain),
                &valid,
            );
            return valid != 0 and value != 0;
        }

        const value = global.environ().getPosix(self.env) orelse return false;
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "0")) return false;
        if (std.ascii.eqlIgnoreCase(value, "false")) return false;
        return true;
    }
};
