// workspace.zig — Workspace tile manager for multi-core nvim instances.
//
// Provides the WorkspaceState type that manages multiple zonvie_core instances
// as independent tiles. Each tile has its own core, snapshot texture, and
// connection metadata.
//
// Phase 1: Type definitions and basic lifecycle. The existing App.corep field
// is preserved for backward compatibility; workspace.activeCorep() returns
// the same pointer. Future phases will migrate all corep references.

const std = @import("std");
const c = @import("win32.zig").c;
const core = @import("zonvie_core");

pub const zonvie_core = core.zonvie_core;

/// How this tile connects to nvim.
pub const ConnectionType = enum(u8) {
    local = 0,
    ssh = 1,
    devcontainer = 2,
};

/// Per-tile callback context. Passed as the `ctx` parameter to
/// zonvie_core_create so that callbacks can identify which tile they
/// belong to.
pub const TileContext = struct {
    app: *anyopaque, // *App (avoid circular import)
    tile_index: u8,
};

/// One workspace slot.
pub const Tile = struct {
    corep: ?*zonvie_core = null,
    ctx: ?*TileContext = null,
    connection: ConnectionType = .local,
    is_suspended: bool = false,

    // Title from nvim (set_title callback)
    title_buf: [256]u8 = .{0} ** 256,
    title_len: usize = 0,

    // Snapshot texture for tile thumbnail display
    // (ID3D11Texture2D, opaque to avoid d3d11 dependency here)
    snapshot_texture: ?*anyopaque = null,

    pub fn isOccupied(self: *const Tile) bool {
        return self.corep != null;
    }
};

/// Manages multiple tiles, each holding an independent nvim process.
pub const WorkspaceState = struct {
    alloc: std.mem.Allocator,
    tiles: std.ArrayListUnmanaged(Tile) = .{},
    active_tile: u8 = 0,
    scale: f32 = 1.0,
    scale_step: f32 = 0.2,
    max_tiles: u8 = 9,

    pub fn init(alloc: std.mem.Allocator) WorkspaceState {
        var ws = WorkspaceState{ .alloc = alloc };
        // Pre-create the first tile (populated during core creation)
        ws.tiles.append(alloc, .{}) catch {};
        return ws;
    }

    pub fn deinit(self: *WorkspaceState) void {
        // Note: core destruction is handled by the caller (App.deinit)
        // because it needs to happen in the correct order relative to
        // renderer/atlas cleanup.
        for (self.tiles.items) |*tile| {
            if (tile.ctx) |ctx_ptr| {
                const typed: *TileContext = @ptrCast(@alignCast(ctx_ptr));
                self.alloc.destroy(typed);
                tile.ctx = null;
            }
        }
        self.tiles.deinit(self.alloc);
    }

    /// Return the core pointer for the active tile (may be null if empty).
    pub fn activeCorep(self: *const WorkspaceState) ?*zonvie_core {
        if (self.active_tile >= self.tiles.items.len) return null;
        return self.tiles.items[self.active_tile].corep;
    }

    /// Return a mutable reference to the active tile.
    pub fn activeTile(self: *WorkspaceState) *Tile {
        return &self.tiles.items[self.active_tile];
    }

    /// Add a new empty tile. Returns the index, or error if at capacity.
    pub fn addTile(self: *WorkspaceState, connection: ConnectionType) !u8 {
        if (self.tiles.items.len >= self.max_tiles) return error.MaxTilesReached;
        try self.tiles.append(self.alloc, .{ .connection = connection });
        return @intCast(self.tiles.items.len - 1);
    }

    /// Attach a core to an existing tile.
    pub fn attachCore(self: *WorkspaceState, index: u8, corep: *zonvie_core) void {
        if (index >= self.tiles.items.len) return;
        self.tiles.items[index].corep = corep;
    }

    /// Remove a tile and clean up its TileContext. Core destruction is
    /// the caller's responsibility.
    pub fn removeTile(self: *WorkspaceState, index: u8) void {
        if (index >= self.tiles.items.len) return;
        if (self.tiles.items.len <= 1) return; // keep at least one

        var tile = &self.tiles.items[index];
        if (tile.ctx) |ctx_ptr| {
            const typed: *TileContext = @ptrCast(@alignCast(ctx_ptr));
            self.alloc.destroy(typed);
            tile.ctx = null;
        }
        _ = self.tiles.orderedRemove(index);

        if (self.active_tile >= self.tiles.items.len) {
            self.active_tile = @intCast(self.tiles.items.len - 1);
        }
    }

    /// Switch the active tile index. The caller is responsible for
    /// snapshot capture and core/view rewiring.
    pub fn switchToTile(self: *WorkspaceState, index: u8) void {
        if (index >= self.tiles.items.len) return;
        self.active_tile = index;
    }

    // Scale control for workspace overview
    pub fn scaleIn(self: *WorkspaceState) void {
        self.scale = @min(1.0, self.scale + self.scale_step);
    }

    pub fn scaleOut(self: *WorkspaceState) void {
        self.scale = @max(0.0, self.scale - self.scale_step);
    }

    pub fn isOverviewVisible(self: *const WorkspaceState) bool {
        return self.scale <= 0.7;
    }

    // MARK: - System menu (taskbar right-click)

    // Command IDs for system menu items (must not collide with SC_* constants).
    // SC_* values are in the 0xF000+ range; we use 0xE000+.
    pub const SC_WS_NEW_SESSION: c_uint = 0xE001;
    pub const SC_WS_SESSION_BASE: c_uint = 0xE100; // + tile index

    /// Populate the system menu with workspace items.
    /// Called on WM_CREATE and can be called again to refresh.
    pub fn updateSystemMenu(self: *const WorkspaceState, hwnd: c.HWND) void {
        const sys_menu = c.GetSystemMenu(hwnd, 0); // FALSE = get current menu
        if (sys_menu == null) return;

        // Remove previously added workspace items (by command ID range)
        var id: c_uint = SC_WS_NEW_SESSION;
        while (id < SC_WS_SESSION_BASE + self.max_tiles) : (id += 1) {
            _ = c.RemoveMenu(sys_menu, id, c.MF_BYCOMMAND);
        }
        // Also remove "New Session..." item
        _ = c.RemoveMenu(sys_menu, SC_WS_NEW_SESSION, c.MF_BYCOMMAND);

        // Separator
        _ = c.AppendMenuW(sys_menu, c.MF_SEPARATOR, 0, null);

        // "New Session..."
        _ = c.AppendMenuW(sys_menu, c.MF_STRING, SC_WS_NEW_SESSION, toWide("New Session..."));

        // Active sessions
        for (self.tiles.items, 0..) |tile, i| {
            if (!tile.isOccupied()) continue;
            var buf: [300]u16 = undefined;
            const prefix: []const u8 = if (i == self.active_tile) "\xE2\x97\x8F " else "  "; // ● or spaces
            const title = if (tile.title_len > 0) tile.title_buf[0..tile.title_len] else connectionLabel(tile.connection);
            var pos: usize = 0;
            for (prefix) |byte| {
                if (pos >= buf.len - 1) break;
                buf[pos] = byte;
                pos += 1;
            }
            for (title) |byte| {
                if (pos >= buf.len - 1) break;
                buf[pos] = byte;
                pos += 1;
            }
            buf[pos] = 0;
            _ = c.AppendMenuW(sys_menu, c.MF_STRING, SC_WS_SESSION_BASE + @as(c_uint, @intCast(i)), &buf);
        }
    }

    fn connectionLabel(conn: ConnectionType) []const u8 {
        return switch (conn) {
            .local => "Local",
            .ssh => "SSH",
            .devcontainer => "Devcontainer",
        };
    }

    fn toWide(comptime s: []const u8) [*:0]const u16 {
        const buf = comptime blk: {
            var b: [s.len:0]u16 = undefined;
            for (s, 0..) |byte, i| {
                b[i] = byte;
            }
            break :blk b;
        };
        return &buf;
    }
};
