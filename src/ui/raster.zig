//! The renderer on the CPU: the instances `shader.metal` draws, drawn to
//! the same pixels in memory (BGRA, premultiplied, sRGB-encoded values
//! blended as the GPU blends them). Windows present them where nanoui has
//! no GPU renderer, and the Tester renders with it there. A test proves it
//! matches the Metal renderer.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const shadow_cache = @import("raster_cache.zig");
pub const Cache = shadow_cache.Cache;

/// The glyph atlas, as the shader samples it: one byte per texel.
pub const Mask = struct {
    pixels: []const u8,
    size: u32,
};

/// The image atlas: BGRA premultiplied, `size` × `size` (empty: none).
pub const Pictures = struct {
    pixels: []const u8 = &.{},
    size: u32 = 0,
};

/// Draws `instances` over `clear` into `out` (sized `out.width` ×
/// `out.height` pixels, `scale` pixels a point).
pub fn draw(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color) void {
    drawImpl(out, instances, mask, pictures, scale, clear, null);
}

/// Like `draw`, reusing coverage of stable shadows in a bounded cache.
pub fn drawCached(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, cache: *Cache) void {
    cache.beginFrame();
    drawImpl(out, instances, mask, pictures, scale, clear, cache);
}

fn drawImpl(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, cache: ?*Cache) void {
    const px: [4]u8 = .{ unit(clear.b), unit(clear.g), unit(clear.r), 255 };
    const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out.bytes[0 .. out.width * out.height * 4]));
    @memset(words, @bitCast(px));
    for (instances) |*i| drawOne(out, i, mask, pictures, scale, cache);
}

fn unit(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// The pixels an instance covers: its quad (grown for a shadow's blur),
/// within its clip and the frame.
fn bounds(out: gpu.Pixels, i: *const gpu.Instance, scale: f32) ?[4]usize {
    const grow: f32 = if (i.kind == gpu.Kind.shadow) i.border_width * 3 else 0;
    const x0 = @max(i.rect[0] - grow, i.clip[0]);
    const y0 = @max(i.rect[1] - grow, i.clip[1]);
    const x1 = @min(i.rect[0] + i.rect[2] + grow, i.clip[2]);
    const y1 = @min(i.rect[1] + i.rect[3] + grow, i.clip[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: f32 = @floatFromInt(out.width);
    const h: f32 = @floatFromInt(out.height);
    // A pixel is drawn when its center is inside, as the GPU rasterizes.
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

fn drawOne(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, cache: ?*Cache) void {
    const b = bounds(out, i, scale) orelse return;
    if (i.kind == gpu.Kind.text) return glyph(out, i, mask, scale, b);
    if (i.kind == gpu.Kind.image) return picture(out, i, pictures, scale, b);
    if (i.kind == gpu.Kind.shadow) return shadow(out, i, scale, b, cache);
    quad(out, i, scale, b, true);
}

/// Blends a premultiplied color over the pixel at byte `at`.
inline fn blend(bytes: []u8, at: usize, r: f32, g: f32, bl: f32, a: f32) void {
    if (a <= 0) return;
    const inv = 1 - a;
    const d = bytes[at..][0..4];
    d[0] = @intFromFloat(@min(255, bl * 255 + @as(f32, @floatFromInt(d[0])) * inv + 0.5));
    d[1] = @intFromFloat(@min(255, g * 255 + @as(f32, @floatFromInt(d[1])) * inv + 0.5));
    d[2] = @intFromFloat(@min(255, r * 255 + @as(f32, @floatFromInt(d[2])) * inv + 0.5));
    d[3] = @intFromFloat(@min(255, a * 255 + @as(f32, @floatFromInt(d[3])) * inv + 0.5));
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// The signed distance to a rounded box centered at 0, and the sum of the
/// absolute values of its gradient (what `fwidth` measures per pixel).
fn roundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) [2]f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - r;
    const grad: f32 = if (len > 0) (mx + my) / len else 1;
    return .{ d, grad };
}

/// How much of the pixel at `wx`, `wy` the instance's clip lets through:
/// all of it, but in the clip's rounded corners (as the shader's
/// `clip_cover`).
inline fn clipCover(i: *const gpu.Instance, wx: f32, wy: f32, inv: f32) f32 {
    if (i.clip_round <= 0) return 1;
    const round = gpu.clipCorners(i.clip_round);
    const c = i.clip;
    const hw = (c[2] - c[0]) * 0.5;
    const hh = (c[3] - c[1]) * 0.5;
    const r = @min(round.radius, @min(hw, hh));
    // Between the corners, nothing is cut.
    if ((wx > c[0] + r and wx < c[2] - r) or (wy > c[1] + r and wy < c[3] - r)) return 1;
    const qx = wx - c[0] - hw;
    const qy = wy - c[1] - hh;
    const bit: u4 = if (qy < 0) (if (qx < 0) 1 else 2) else (if (qx < 0) 8 else 4);
    if (round.corners & bit == 0) return 1;
    const sd = roundedBox(qx, qy, hw, hh, r);
    const aa = @max(sd[1] * inv, 0.0001) * 0.5;
    return 1 - smoothstep(-aa, aa, sd[0]);
}

fn quad(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize, comptime fast: bool) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r = @min(i.radius, @min(hw, hh));
    const bw = i.border_width;
    const has_border = bw > 0 and i.border_color[3] > 0;
    const c = i.color;
    const bc = i.border_color;
    // Inside this, a pixel is wholly the fill: no edge, corner or border.
    const solid = @max(r, if (has_border) bw else 0) + 2 / scale;
    const inv = 1 / scale;
    // Opaque interiors overwrite their destination. Fill a conservative
    // span at once, leaving all edges, borders and rounded clips to the
    // scalar path. The extra pixel keeps fractional DPI edges outside it.
    const solid_fill = fast and c[3] == 1 and i.clip_round <= 0;
    const width: f32 = @floatFromInt(out.width);
    const left = @max(b[0], @as(usize, @intFromFloat(std.math.clamp(@ceil((cx - hw + solid) * scale + 1), 0, width))));
    const right = @min(b[2], @as(usize, @intFromFloat(std.math.clamp(@floor((cx + hw - solid) * scale - 1), 0, width))));
    var fill: [4]u8 = @splat(0);
    if (solid_fill) blend(&fill, 0, c[0], c[1], c[2], 1);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const py = wy - cy;
        const row = y * out.width * 4;
        const inner_y = @abs(py) < hh - solid;
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            if (solid_fill and inner_y and x == left and right > left) {
                const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out.bytes[row + left * 4 .. row + right * 4]));
                @memset(words, @as(u32, @bitCast(fill)));
                x = right - 1;
                continue;
            }
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const pxl = wx - cx;
            const cut = clipCover(i, wx, wy, inv);
            if (inner_y and @abs(pxl) < hw - solid) {
                const a = c[3] * cut;
                blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
                continue;
            }
            const sd = roundedBox(pxl, py, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const coverage = 1 - smoothstep(-aa, aa, sd[0]);
            if (coverage <= 0) continue;
            var col = c;
            if (has_border) {
                const t = smoothstep(-bw - aa, -bw + aa, sd[0]);
                for (0..4) |k| col[k] = c[k] + (bc[k] - c[k]) * t;
            }
            const a = col[3] * coverage * cut;
            blend(out.bytes, row + x * 4, col[0] * a, col[1] * a, col[2] * a, a);
        }
    }
}

/// The atlas sampled as Metal's linear filter with clamped edges does.
fn sample(mask: Mask, u: f32, v: f32) f32 {
    const s: f32 = @floatFromInt(mask.size);
    const fx = u * s - 0.5;
    const fy = v * s - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const max: i64 = @as(i64, mask.size) - 1;
    const x0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, max));
    const y0: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, max));
    const x1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, max));
    const y1: usize = @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, max));
    const n: usize = mask.size;
    const a = @as(f32, @floatFromInt(mask.pixels[y0 * n + x0]));
    const bb = @as(f32, @floatFromInt(mask.pixels[y0 * n + x1]));
    const c = @as(f32, @floatFromInt(mask.pixels[y1 * n + x0]));
    const d = @as(f32, @floatFromInt(mask.pixels[y1 * n + x1]));
    const top = a + (bb - a) * tx;
    const bottom = c + (d - c) * tx;
    return (top + (bottom - top) * ty) / 255;
}

fn glyph(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, scale: f32, b: [4]usize) void {
    if (mask.size == 0) return;
    const inv = 1 / scale;
    const c = i.color;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const ty = (wy - i.rect[1]) / i.rect[3];
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const tx = (wx - i.rect[0]) / i.rect[2];
            const u = i.uv[0] + (i.uv[2] - i.uv[0]) * tx;
            const a = sample(mask, u, v) * c[3] * clipCover(i, wx, wy, inv);
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

/// A BGRA texel of the image atlas, bilinear as Metal's sampler.
fn samplePicture(p: Pictures, u: f32, v: f32) [4]f32 {
    const s: f32 = @floatFromInt(p.size);
    const fx = u * s - 0.5;
    const fy = v * s - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const max: i64 = @as(i64, p.size) - 1;
    const xs = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)), 0, max)), @intCast(std.math.clamp(@as(i64, @intFromFloat(x0f)) + 1, 0, max)) };
    const ys = [2]usize{ @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)), 0, max)), @intCast(std.math.clamp(@as(i64, @intFromFloat(y0f)) + 1, 0, max)) };
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| {
        const t = p.pixels[(ys[k / 2] * p.size + xs[k % 2]) * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * weights[k];
    }
    return out;
}

fn picture(out: gpu.Pixels, i: *const gpu.Instance, p: Pictures, scale: f32, b: [4]usize) void {
    if (p.size == 0) return;
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = @min(i.radius, @min(hw, hh));
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const ty = (wy - i.rect[1]) / i.rect[3];
        const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const tx = (wx - i.rect[0]) / i.rect[2];
            const sd = roundedBox(wx - i.rect[0] - hw, wy - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const k = (1 - smoothstep(-aa, aa, sd[0])) * i.color[3] * clipCover(i, wx, wy, inv);
            if (k <= 0) continue;
            const t = samplePicture(p, i.uv[0] + (i.uv[2] - i.uv[0]) * tx, v);
            blend(out.bytes, row + x * 4, t[2] * k, t[1] * k, t[0] * k, t[3] * k);
        }
    }
}

// Shadows as the shader draws them: a box's coverage blurred by a
// Gaussian, exact along x with erf, sampled four times along y.
fn gaussian(x: f32, sigma: f32) f32 {
    return @exp(-(x * x) / (2 * sigma * sigma)) / (@sqrt(2 * std.math.pi) * sigma);
}

fn erf(x: f32) f32 {
    const s: f32 = if (x < 0) -1 else 1;
    const a = @abs(x);
    var y = 1 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    y *= y;
    return s - s / (y * y);
}

fn blurAlongX(x: f32, y: f32, sigma: f32, corner: f32, hw: f32, hh: f32) f32 {
    const delta = @min(hh - corner - @abs(y), 0);
    const curved = hw - corner + @sqrt(@max(0, corner * corner - delta * delta));
    const k = @sqrt(@as(f32, 0.5)) / sigma;
    const lo = 0.5 + 0.5 * erf((x - curved) * k);
    const hi = 0.5 + 0.5 * erf((x + curved) * k);
    return hi - lo;
}

fn shadowAlpha(px: f32, py: f32, hw: f32, hh: f32, corner: f32, sigma: f32) f32 {
    const low = py - hh;
    const high = py + hh;
    const start = std.math.clamp(-3 * sigma, low, high);
    const end = std.math.clamp(3 * sigma, low, high);
    const step = (end - start) / 4;
    var y = start + step * 0.5;
    var alpha: f32 = 0;
    for (0..4) |_| {
        alpha += blurAlongX(px, py - y, sigma, corner, hw, hh) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

/// A Gaussian shadow's four integration samples depend on the row, not
/// the column. Keep their square roots and exponentials out of the pixel
/// loop, preserving the scalar formula's order of floating point work.
const ShadowRow = struct {
    curved: [4]f32,
    gaussian: [4]f32,
    step: f32,
    k: f32,

    fn init(py: f32, hw: f32, hh: f32, corner: f32, sigma: f32) ShadowRow {
        const start = std.math.clamp(-3 * sigma, py - hh, py + hh);
        const end = std.math.clamp(3 * sigma, py - hh, py + hh);
        var row: ShadowRow = .{ .curved = undefined, .gaussian = undefined, .step = (end - start) / 4, .k = @sqrt(@as(f32, 0.5)) / sigma };
        var y = start + row.step * 0.5;
        for (0..4) |j| {
            const delta = @min(hh - corner - @abs(py - y), 0);
            row.curved[j] = hw - corner + @sqrt(@max(0, corner * corner - delta * delta));
            row.gaussian[j] = @exp(-(y * y) / (2 * sigma * sigma)) / (@sqrt(2 * std.math.pi) * sigma);
            y += row.step;
        }
        return row;
    }

    fn alpha(row: ShadowRow, px: f32) f32 {
        var a: f32 = 0;
        for (0..4) |j| {
            const lo = 0.5 + 0.5 * erf((px - row.curved[j]) * row.k);
            const hi = 0.5 + 0.5 * erf((px + row.curved[j]) * row.k);
            a += (hi - lo) * row.gaussian[j] * row.step;
        }
        return a;
    }
};

fn shadow(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize, cache: ?*Cache) void {
    const access = if (cache) |c| c.acquire(.init(i, scale, b)) else shadow_cache.Access.uncached;
    if (access == .hit) return cachedShadow(out, i, scale, b, access.hit);
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r = @min(i.radius, @min(hw, hh));
    const sigma = @max(i.border_width, 0.25);
    const c = i.color;
    const inv = 1 / scale;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const py = wy - cy;
        const row = y * out.width * 4;
        const samples = ShadowRow.init(py, hw, hh, r, sigma);
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const pxl = wx - cx;
            const coverage = samples.alpha(pxl);
            if (access == .fill) access.fill[(y - b[1]) * (b[2] - b[0]) + x - b[0]] = coverage;
            const a = coverage * c[3] * clipCover(i, wx, wy, inv);
            blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

fn cachedShadow(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize, coverage: []const f32) void {
    const inv = 1 / scale;
    const c = i.color;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const a = coverage[(y - b[1]) * (b[2] - b[0]) + x - b[0]] * c[3] * clipCover(i, wx, wy, inv);
            blend(out.bytes, (y * out.width + x) * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

test "shadow rows match the scalar Gaussian at fractional DPI" {
    for ([_]f32{ 0.75, 1, 1.25, 1.5, 2, 3 }) |scale| {
        for ([_][4]f32{ .{ 20, 12, 0, 0.25 }, .{ 18.25, 9.5, 9.5, 3 }, .{ 140, 25, 12, 16 }, .{ 3, 2, 2, 20 } }) |shape| {
            for (0..80) |y| {
                const py = (@as(f32, @floatFromInt(y)) - 40.25) / scale;
                const row = ShadowRow.init(py, shape[0], shape[1], shape[2], shape[3]);
                for (0..100) |x| {
                    const px = (@as(f32, @floatFromInt(x)) - 50.75) / scale;
                    const expected = shadowAlpha(px, py, shape[0], shape[1], shape[2], shape[3]);
                    try std.testing.expectEqual(expected, row.alpha(px));
                }
            }
        }
    }
}

test "opaque spans match scalar pixels with borders, clipping and fractional DPI" {
    const gpa = std.testing.allocator;
    const size = 100 * 80 * 4;
    const expected = try gpa.alloc(u8, size);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, size);
    defer gpa.free(actual);
    for ([_]f32{ 0.75, 1, 1.25, 1.5, 2, 3 }) |scale| {
        for ([_]f32{ 0, 1.5, 8 }) |radius| {
            for ([_]f32{ 0, 2, 12 }) |border| {
                for ([_]f32{ 0.3, 1 }) |alpha| {
                    for ([_]f32{ 0, gpu.clipRound(9, 15) }) |clip_round| {
                        const i: gpu.Instance = .{
                            .rect = .{ -2.25, 3.5, 70.75, 50.25 },
                            .color = .{ 0.3, 0.6, 0.8, alpha },
                            .radius = radius,
                            .border_width = border,
                            .border_color = .{ 0.9, 0.4, 0.1, 0.5 },
                            .clip = .{ 5.25, 6.75, 90, 65 },
                            .clip_round = clip_round,
                        };
                        const a: gpu.Pixels = .{ .bytes = actual, .width = 100, .height = 80 };
                        const e: gpu.Pixels = .{ .bytes = expected, .width = 100, .height = 80 };
                        @memset(expected, 113);
                        @memset(actual, 113);
                        const b = bounds(a, &i, scale).?;
                        quad(e, &i, scale, b, false);
                        quad(a, &i, scale, b, true);
                        try std.testing.expectEqualSlices(u8, expected, actual);
                    }
                }
            }
        }
    }
}

test "rounded boxes, borders, glyphs and shadows" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    var texels: [4]u8 = .{ 255, 255, 255, 255 };
    draw(out, &.{
        .{ .rect = .{ 2, 2, 16, 16 }, .color = .{ 1, 0, 0, 1 }, .radius = 4 },
        .{ .rect = .{ 0, 0, 10, 10 }, .color = .{ 0, 0, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.text, .clip = .{ 0, 0, 5, 20 } },
    }, .{ .pixels = &texels, .size = 2 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    // The middle of the box is red (BGRA); its rounded corner is not.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 4, 34));
    // The glyph is blue where its clip lets it be.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(out, 2, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 15, 2));
}

test "a clip's rounded corners cut what it clips, only where asked" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    // A square filling its clip, whose left corners round by 8.
    draw(out, &.{
        .{ .rect = .{ 0, 0, 20, 20 }, .color = .{ 1, 0, 0, 1 }, .clip = .{ 0, 0, 20, 20 }, .clip_round = gpu.clipRound(8, 1 | 8) },
    }, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: gpu.Pixels, x: usize, y: usize) [4]u8 {
            return o.bytes[(y * o.width + x) * 4 ..][0..4].*;
        }
    }.f;
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    const unpacked = gpu.clipCorners(gpu.clipRound(8, 1 | 8));
    try std.testing.expectEqual(@as(f32, 8), unpacked.radius);
    try std.testing.expectEqual(@as(u4, 9), unpacked.corners);
}
