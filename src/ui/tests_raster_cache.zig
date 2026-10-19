//! Cached coverage must preserve scalar pixels through geometry, color,
//! DPI and clip changes, including fallback when the cache is full.
const std = @import("std");
const raster = @import("raster.zig");
const gpu = @import("gpu.zig");

test "cached shadows preserve pixels across movement, resize, DPI and color changes" {
    const gpa = std.testing.allocator;
    var cache: raster.Cache = .init(gpa);
    defer cache.deinit();
    const bytes = try gpa.alloc(u8, 83 * 73 * 4);
    defer gpa.free(bytes);
    const reference = try gpa.alloc(u8, bytes.len);
    defer gpa.free(reference);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 83, .height = 73 };
    const expected: gpu.Pixels = .{ .bytes = reference, .width = 83, .height = 73 };
    const mask: raster.Mask = .{ .size = 0, .pixels = &.{} };
    for ([_]f32{ 1, 1.25, 1.5, 2, 0.75 }) |scale| {
        for (0..12) |variant| {
            const n: f32 = @floatFromInt(variant);
            var instances = [_]gpu.Instance{
                .{
                    .kind = gpu.Kind.shadow,
                    .rect = .{ n * 0.375 - 4, 4.25 - n, 35.5 + n, 20.25 + n },
                    .radius = n,
                    .border_width = 0.25 + n * 0.75,
                    .color = .{ 0.2, 0.4, 0.8, 0.35 },
                    .clip = .{ 1.25, 2.75, 60.5, 50.25 },
                },
                .{ .rect = .{ 9.25, 8.5, 20, 18 }, .color = .{ 0.8, 0.1, 0.3, 0.6 }, .radius = 4 },
            };
            for (0..4) |frame| {
                // Color and rounded clipping change while geometry stays
                // cached. These are applied at compositing time.
                instances[0].color[3] = @as(f32, @floatFromInt(frame + 1)) / 5;
                instances[0].clip_round = if (frame % 2 == 0) 0 else gpu.clipRound(10, 1 | 4);
                raster.draw(expected, &instances, mask, .{}, scale, .hex(0xb6c1da));
                raster.drawCached(out, &instances, mask, .{}, scale, .hex(0xb6c1da), &cache);
                try std.testing.expectEqualSlices(u8, expected.bytes, out.bytes);
            }
        }
    }
    try std.testing.expect(cache.bytes > 0);
}

test "a disabled cache still draws every shadow" {
    var cache: raster.Cache = .init(std.testing.allocator);
    defer cache.deinit();
    cache.budget = 0;
    var bytes: [32 * 32 * 4]u8 align(4) = undefined;
    var reference: @TypeOf(bytes) align(4) = undefined;
    const instances = [_]gpu.Instance{.{ .kind = gpu.Kind.shadow, .rect = .{ 8, 8, 16, 16 }, .color = .{ 0, 0, 0, 0.8 }, .radius = 4, .border_width = 3 }};
    const out: gpu.Pixels = .{ .bytes = &bytes, .width = 32, .height = 32 };
    const expected: gpu.Pixels = .{ .bytes = &reference, .width = 32, .height = 32 };
    const mask: raster.Mask = .{ .size = 0, .pixels = &.{} };
    raster.draw(expected, &instances, mask, .{}, 1, .white);
    for (0..4) |_| {
        raster.drawCached(out, &instances, mask, .{}, 1, .white, &cache);
        try std.testing.expectEqualSlices(u8, expected.bytes, out.bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
}
