const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tab would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title of this tab. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        /// The tooltip of this tab. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        /// What the session in this tab is doing, and the blink of the dot
        /// that says so while it waits.
        session_state: SessionState = .none,
        session_blink_timer: ?c_uint = null,
        session_blink_on: bool = true,

        // Template bindings
        split_tree: *SplitTree,

        pub var offset: c_int = 0;
    };

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: struct {
        command: ?configpkg.Command = null,
        shell_integration: ?configpkg.Config.ShellIntegration = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,

        pub const none: @This() = .{};
    }) *Self {
        const tab = gobject.ext.newInstance(Tab, .{});

        const priv: *Private = tab.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        tab.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };

        return tab;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Init our actions
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("session-state", actionSessionState, s_param_type),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    pub fn promptTabTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getSplitTree();
        return tree.getNeedsConfirmQuit();
    }

    /// Get the tab view holding this tab, if any.
    fn getTabView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the tab page holding this tab, if any.
    fn getTabPage(self: *Self) ?*adw.TabPage {
        const tab_view = self.getTabView() orelse return null;
        return tab_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        if (priv.session_blink_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove session blink timer", .{});
            }
            priv.session_blink_timer = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const tab_view = self.getTabView() orelse return;
        const page = tab_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to tab.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to tab.close-tab: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => tab_view.closePage(page),
            .other => tab_view.closeOtherPages(page),
            .right => tab_view.closePagesAfter(page),
        }
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabTitle();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getTabPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// What the session in one of this tab's surfaces is doing, as a hook says
    /// through the palette.
    const SessionState = enum {
        none,
        working,
        waiting,
        idle,

        /// The color the rest of this setup draws the state in: orange while
        /// the model works, blue while it waits for an answer, green for a
        /// session with nothing left to do. The same 3 as the kitty tab bar's
        /// and the Mac's, which take them from claude/session_state.py.
        fn color(self: SessionState) ?u24 {
            return switch (self) {
                .none => null,
                .working => 0xff9500,
                .waiting => 0x5f87ff,
                .idle => 0x00d75f,
            };
        }
    };

    /// A waiting dot is hollow for every second half second, which is the blink
    /// the kitty tab bar gives it.
    const session_blink_interval_ms = 500;

    fn actionSessionState(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.session-state called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const name = std.mem.sliceTo(str orelse return, 0);
        self.setSessionState(std.meta.stringToEnum(SessionState, name) orelse .none);
    }

    /// Say what the session in this tab is doing.
    ///
    /// libadwaita has a word for 2 of the 3 states -- a page that is loading
    /// spins, a page that needs attention is marked -- and this uses both. But
    /// the mark is a line the width of the tab in the accent color, which says
    /// "something happened here" and not which of 3 things, and it is gone the
    /// moment the tab is selected. The Mac draws a colored dot instead, and the
    /// kitty tab bar beside it draws the same dot in the same 3 colors, so a
    /// glance across 2 terminals means 1 thing. That is worth more here than
    /// speaking only in libadwaita's own vocabulary, so the dot is drawn too,
    /// in the indicator a tab page already has room for.
    fn setSessionState(self: *Self, state: SessionState) void {
        const priv = self.private();
        priv.session_state = state;

        if (priv.session_blink_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove session blink timer", .{});
            }
            priv.session_blink_timer = null;
        }
        priv.session_blink_on = true;

        const page = self.getTabPage() orelse return;

        // A page whose session is working spins, as a loading page does.
        page.setLoading(@intFromBool(state == .working));

        // A page that is waiting asks for attention, as a bell does, and only
        // while it is not the page being looked at.
        switch (state) {
            .waiting => if (page.getSelected() == 0) {
                page.setNeedsAttention(@intFromBool(true));
            },
            .working => {},
            .none, .idle => page.setNeedsAttention(@intFromBool(false)),
        }

        if (state == .waiting) {
            priv.session_blink_timer = glib.timeoutAdd(
                session_blink_interval_ms,
                sessionBlinkTimer,
                self,
            );
        }

        self.drawSessionDot();
    }

    /// Half of the blink of a waiting dot.
    fn sessionBlinkTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        const priv = self.private();
        priv.session_blink_on = !priv.session_blink_on;
        self.drawSessionDot();
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    /// Put the dot for the current state in this tab's indicator, or take it
    /// away when there is no session to speak for.
    fn drawSessionDot(self: *Self) void {
        const priv = self.private();
        const page = self.getTabPage() orelse return;

        const rgb = priv.session_state.color() orelse {
            page.setIndicatorIcon(null);
            page.setIndicatorTooltip("");
            return;
        };

        const texture = sessionDot(rgb, priv.session_blink_on);
        defer texture.unref();
        page.setIndicatorIcon(texture.as(gio.Icon));
        page.setIndicatorTooltip(@tagName(priv.session_state));
    }

    /// The dot itself: a disc, or a ring while a waiting dot is blinked off.
    ///
    /// It is drawn rather than named because a tab page takes an icon, and an
    /// icon from the theme is drawn in the theme's color -- which is the 1
    /// thing this dot must not be, the color being the whole of what it says.
    fn sessionDot(rgb: u24, filled: bool) *gdk.MemoryTexture {
        const size = 32;
        const stride = size * 4;

        // The disc, and the ring left when a blink hollows it out. Inset from
        // the edge so that neither is clipped by whatever box the tab bar gives
        // an indicator.
        const center: f32 = @as(f32, size) / 2;
        const outer: f32 = center - 4;
        const inner: f32 = outer - 5;

        const r: f32 = @floatFromInt(@as(u8, @truncate(rgb >> 16)));
        const g: f32 = @floatFromInt(@as(u8, @truncate(rgb >> 8)));
        const b: f32 = @floatFromInt(@as(u8, @truncate(rgb)));

        var pixels: [size * stride]u8 = undefined;
        for (0..size) |y| {
            for (0..size) |x| {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - center;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - center;
                const d = @sqrt(dx * dx + dy * dy);

                // How much of this pixel the shape covers, taken across the 1
                // pixel an edge falls in, which is the whole of the smoothing
                // a dot this size needs.
                var a = std.math.clamp(outer + 0.5 - d, 0, 1);
                if (!filled) a *= std.math.clamp(d - (inner - 0.5), 0, 1);

                // Premultiplied, which is what the format below reads.
                const i = y * stride + x * 4;
                pixels[i + 0] = @intFromFloat(@round(r * a));
                pixels[i + 1] = @intFromFloat(@round(g * a));
                pixels[i + 2] = @intFromFloat(@round(b * a));
                pixels[i + 3] = @intFromFloat(@round(255 * a));
            }
        }

        const bytes = glib.Bytes.new(&pixels, pixels.len);
        defer bytes.unref();
        return gdk.MemoryTexture.new(
            size,
            size,
            .r8g8b8a8_premultiplied,
            bytes,
            stride,
        );
    }

    /// Select the next tab page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectNextPage();
    }

    /// Select the previous tab page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectPreviousPage();
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually tab overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
