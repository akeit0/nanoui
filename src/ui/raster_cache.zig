//! A bounded, per-surface cache of uncolored shadow coverage. A shape
//! must recur before allocating pixels, so moving shadows use the scalar
//! path. Translation, DPI, blur and visible bounds are all part of its key.
const std = @import("std");
const gpu = @import("gpu.zig");

pub const Key = struct {
    values: [7]u32,
    bounds: [4]usize,

    pub fn init(i: *const gpu.Instance, scale: f32, bounds: [4]usize) Key {
        return .{
            .values = .{ @bitCast(i.rect[0]), @bitCast(i.rect[1]), @bitCast(i.rect[2]), @bitCast(i.rect[3]), @bitCast(i.radius), @bitCast(i.border_width), @bitCast(scale) },
            .bounds = bounds,
        };
    }

    fn hash(key: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.values));
        h.update(std.mem.asBytes(&key.bounds));
        return h.final();
    }
};

pub const Access = union(enum) { uncached, fill: []f32, hit: []const f32 };
const Entry = struct {
    key: ?Key = null,
    hash: u64 = 0,
    samples: []f32 = &.{},
    frame: u64 = 0,
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    entries: [64]Entry = @splat(.{}),
    frame: u64 = 0,
    bytes: usize = 0,
    /// Bounded per surface, regardless of window size or animation length.
    budget: usize = 16 << 20,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(cache: *Cache) void {
        for (&cache.entries) |*entry| cache.remove(entry);
    }

    pub fn beginFrame(cache: *Cache) void {
        cache.frame +%= 1;
    }

    fn remove(cache: *Cache, entry: *Entry) void {
        cache.bytes -= entry.samples.len * @sizeOf(f32);
        cache.gpa.free(entry.samples);
        entry.* = .{};
    }

    pub fn acquire(cache: *Cache, key: Key) Access {
        const count = (key.bounds[2] - key.bounds[0]) * (key.bounds[3] - key.bounds[1]);
        if (count == 0 or count > cache.budget / @sizeOf(f32)) return .uncached;
        const hash = key.hash();
        var oldest = &cache.entries[0];
        for (&cache.entries) |*entry| {
            if (entry.key) |saved| {
                if (entry.hash == hash and std.meta.eql(saved, key)) {
                    const recent = entry.frame == cache.frame or entry.frame +% 1 == cache.frame;
                    entry.frame = cache.frame;
                    if (entry.samples.len != 0) return .{ .hit = entry.samples };
                    if (!recent) return .uncached;
                    const needed = count * @sizeOf(f32);
                    // Never evict a shape already used in this frame to
                    // cache a new one. Crowded scenes fall back to drawing.
                    for (&cache.entries) |*other| {
                        if (cache.bytes + needed <= cache.budget) break;
                        if (other != entry and other.frame != cache.frame) cache.remove(other);
                    }
                    if (cache.bytes + needed > cache.budget) return .uncached;
                    entry.samples = cache.gpa.alloc(f32, count) catch return .uncached;
                    cache.bytes += needed;
                    return .{ .fill = entry.samples };
                }
            }
            if (entry.key == null or entry.frame < oldest.frame or
                (entry.frame == oldest.frame and entry.samples.len == 0)) oldest = entry;
        }
        cache.remove(oldest);
        oldest.* = .{ .key = key, .hash = hash, .frame = cache.frame };
        return .uncached;
    }
};

test "shadows are cached only after recurrence, bounded and freed" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    cache.budget = 4 * @sizeOf(f32);
    const i: gpu.Instance = .{ .rect = .{ 0, 0, 2, 2 }, .color = .{ 0, 0, 0, 1 } };
    const key: Key = .init(&i, 1, .{ 0, 0, 2, 2 });
    cache.beginFrame();
    try std.testing.expect(cache.acquire(key) == .uncached);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    cache.beginFrame();
    const fill = cache.acquire(key).fill;
    @memset(fill, 0.5);
    try std.testing.expectEqual(@as(usize, 16), cache.bytes);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 0.5 }, cache.acquire(key).hit);
    for (0..200) |frame| {
        cache.beginFrame();
        var moving = key;
        moving.values[0] = @intCast(frame + 1);
        _ = cache.acquire(moving);
        try std.testing.expect(cache.bytes <= cache.budget);
    }
    // A resized shadow exceeding the budget is drawn without caching.
    var huge = key;
    huge.bounds = .{ 0, 0, 100, 100 };
    try std.testing.expect(cache.acquire(huge) == .uncached);
}

test "cache allocation failure falls back without losing accounting" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var cache: Cache = .init(failing.allocator());
    defer cache.deinit();
    const i: gpu.Instance = .{ .rect = .{ 0, 0, 2, 2 }, .color = .{ 0, 0, 0, 1 } };
    const key: Key = .init(&i, 1, .{ 0, 0, 2, 2 });
    for (0..3) |_| {
        cache.beginFrame();
        try std.testing.expect(cache.acquire(key) == .uncached);
        try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    }
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = 1;
    cache.beginFrame();
    @memset(cache.acquire(key).fill, 0.5);
    try std.testing.expectEqual(@as(usize, 16), cache.bytes);
}

test "a full cache falls back for active entries and evicts older masks" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    cache.budget = 16;
    const i: gpu.Instance = .{ .rect = .{ 0, 0, 2, 2 }, .color = .{ 0, 0, 0, 1 } };
    const a: Key = .init(&i, 1, .{ 0, 0, 2, 2 });
    const b: Key = .init(&i, 2, .{ 0, 0, 2, 2 });
    cache.beginFrame();
    _ = cache.acquire(a);
    _ = cache.acquire(b);
    cache.beginFrame();
    @memset(cache.acquire(a).fill, 0.5);
    try std.testing.expect(cache.acquire(b) == .uncached);
    try std.testing.expect(cache.acquire(a) == .hit);
    cache.beginFrame();
    @memset(cache.acquire(b).fill, 0.75);
    try std.testing.expectEqual(@as(usize, 16), cache.bytes);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, 0.75, 0.75, 0.75 }, cache.acquire(b).hit);
}
