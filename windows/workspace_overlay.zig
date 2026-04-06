// workspace_overlay.zig — D3D11 workspace tile overlay for Windows.
//
// Renders a grid of tile thumbnails on top of the main back_tex when the
// workspace overview is visible (workspace.scale < 1.0). Follows the same
// visual model as the macOS WorkspaceOverlayView: a camera-zoom effect
// where scale=1.0 shows the active tile fullscreen and scale=0.0 shows
// a 3×3 grid of all tile slots.

const std = @import("std");
const c = @import("win32.zig").c;
const d3d11 = @import("renderer/d3d11_renderer.zig");
const workspace_mod = @import("workspace.zig");
const WorkspaceState = workspace_mod.WorkspaceState;
const applog = @import("app.zig").applog;

/// Draw the workspace overlay on top of the current back_tex.
/// Call this from WM_PAINT when workspace.isOverviewVisible() is true.
pub fn draw(renderer: *d3d11.Renderer, workspace: *const WorkspaceState, window_w: u32, window_h: u32) void {
    if (window_w == 0 or window_h == 0) return;

    const scale = workspace.scale;
    const t = 1.0 - scale; // 0 = fullscreen, 1 = full grid

    // Dim background overlay
    const bg_alpha = @min(t * 1.5, 0.88);
    renderer.drawOverlaySolid(.{ -1, 1, 1, -1 }, .{ 0, 0, 0, bg_alpha }) catch return;

    // Grid parameters
    const max_tiles = workspace.max_tiles;
    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(max_tiles)))));
    const rows: u32 = (max_tiles + cols - 1) / cols;

    const wf: f32 = @floatFromInt(window_w);
    const hf: f32 = @floatFromInt(window_h);

    // Tile dimensions at full grid view (with padding)
    const pad_px: f32 = 12.0;
    const grid_tile_w: f32 = (wf - pad_px * @as(f32, @floatFromInt(cols + 1))) / @as(f32, @floatFromInt(cols));
    const grid_tile_h: f32 = (hf - pad_px * @as(f32, @floatFromInt(rows + 1))) / @as(f32, @floatFromInt(rows));

    // Current tile size: lerp between window size (scale=1) and grid tile size (scale=0)
    const tile_w: f32 = wf + (grid_tile_w - wf) * t;
    const tile_h: f32 = hf + (grid_tile_h - hf) * t;

    // Active tile grid position
    const active_col: u32 = workspace.active_tile % @as(u8, @intCast(cols));
    const active_row: u32 = workspace.active_tile / @as(u8, @intCast(cols));

    // Grid origin at scale=0: centered in window
    const grid_origin_x: f32 = pad_px;
    const grid_origin_y: f32 = pad_px;

    // Active tile center at scale=0
    const active_cx_grid: f32 = grid_origin_x + @as(f32, @floatFromInt(active_col)) * (grid_tile_w + pad_px) + grid_tile_w * 0.5;
    const active_cy_grid: f32 = grid_origin_y + @as(f32, @floatFromInt(active_row)) * (grid_tile_h + pad_px) + grid_tile_h * 0.5;

    // Active tile center at scale=1: window center
    const active_cx_full: f32 = wf * 0.5;
    const active_cy_full: f32 = hf * 0.5;

    // Current active tile center: lerp
    const active_cx: f32 = active_cx_full + (active_cx_grid - active_cx_full) * t;
    const active_cy: f32 = active_cy_full + (active_cy_grid - active_cy_full) * t;

    // Offset so that the active tile is at its interpolated center
    const offset_x: f32 = active_cx - @as(f32, @floatFromInt(active_col)) * (tile_w + pad_px * t) - tile_w * 0.5 - pad_px * t;
    const offset_y: f32 = active_cy - @as(f32, @floatFromInt(active_row)) * (tile_h + pad_px * t) - tile_h * 0.5 - pad_px * t;

    // Draw each tile slot
    var idx: u32 = 0;
    while (idx < max_tiles) : (idx += 1) {
        const col = idx % cols;
        const row = idx / cols;

        // Pixel position of this tile
        const px_x: f32 = offset_x + @as(f32, @floatFromInt(col)) * (tile_w + pad_px * t) + pad_px * t;
        const px_y: f32 = offset_y + @as(f32, @floatFromInt(row)) * (tile_h + pad_px * t) + pad_px * t;

        // Convert pixel rect to NDC
        const ndc = pixelToNDC(px_x, px_y, tile_w, tile_h, wf, hf);

        // Skip tiles completely outside the viewport
        if (ndc[2] < -1.0 or ndc[0] > 1.0 or ndc[3] > 1.0 or ndc[1] < -1.0) continue;

        // Tile background (dark)
        const is_active = (idx == workspace.active_tile);
        const bg_color: [4]f32 = if (is_active) .{ 0.15, 0.15, 0.2, 1.0 } else .{ 0.08, 0.08, 0.1, 1.0 };
        renderer.drawOverlaySolid(ndc, bg_color) catch continue;

        // Draw snapshot if tile is occupied
        if (idx < workspace.tiles.items.len) {
            const tile = &workspace.tiles.items[idx];
            if (tile.snapshot) |snap| {
                renderer.drawOverlayQuad(snap.srv, ndc, 1.0) catch {};
            }
        }

        // Active tile border highlight
        if (is_active) {
            drawBorder(renderer, ndc, .{ 0.4, 0.6, 1.0, 0.9 }, 2.0, wf, hf) catch {};
        }
    }
}

/// Convert pixel rect to NDC coordinates.
/// Returns { ndc_left, ndc_top, ndc_right, ndc_bottom }.
fn pixelToNDC(px_x: f32, px_y: f32, px_w: f32, px_h: f32, win_w: f32, win_h: f32) [4]f32 {
    return .{
        px_x / win_w * 2.0 - 1.0, // left
        1.0 - px_y / win_h * 2.0, // top (NDC Y is flipped)
        (px_x + px_w) / win_w * 2.0 - 1.0, // right
        1.0 - (px_y + px_h) / win_h * 2.0, // bottom
    };
}

/// Draw a thin border around an NDC rect.
fn drawBorder(renderer: *d3d11.Renderer, ndc: [4]f32, color: [4]f32, thickness_px: f32, win_w: f32, win_h: f32) !void {
    const dx = thickness_px / win_w * 2.0;
    const dy = thickness_px / win_h * 2.0;

    // Top edge
    try renderer.drawOverlaySolid(.{ ndc[0], ndc[1], ndc[2], ndc[1] - dy }, color);
    // Bottom edge
    try renderer.drawOverlaySolid(.{ ndc[0], ndc[3] + dy, ndc[2], ndc[3] }, color);
    // Left edge
    try renderer.drawOverlaySolid(.{ ndc[0], ndc[1], ndc[0] + dx, ndc[3] }, color);
    // Right edge
    try renderer.drawOverlaySolid(.{ ndc[2] - dx, ndc[1], ndc[2], ndc[3] }, color);
}
