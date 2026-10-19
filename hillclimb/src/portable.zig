//! CPU renderer benchmarks for Windows and Linux. No window, input,
//! clipboard or GPU is used. History is separate from the Metal results.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const scenes = @import("scenes.zig");

const warmup = 10;
const Options = struct {
    frames: usize = 100,
    repeat: usize = 3,
    scale: f32 = 1.5,
    scenes: []const scenes.Scene = std.enums.values(scenes.Scene),
    label: []const u8 = "",
};
const Result = struct {
    scene: scenes.Scene,
    total_ms: f64,
    p95_ms: f64,
    frame_ms: f64,
    raster_ms: f64,
};
const Entry = struct {
    time: i64,
    os: []const u8,
    arch: []const u8,
    optimize: []const u8,
    scale: f32,
    frames: usize,
    label: []const u8,
    results: []const Result,
};

fn now(io: std.Io) f64 {
    return @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).toNanoseconds())) / 1e9;
}

fn percentile(xs: []f64, percent: usize) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[(xs.len - 1) * percent / 100];
}

fn measure(init: std.process.Init, opts: Options, scene: scenes.Scene) !Result {
    const gpa = init.gpa;
    var state: scenes.State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, scenes.State.view), .{ .width = 900, .height = 640, .scale = opts.scale });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    var samples: [3][]f64 = @splat(&.{});
    defer for (samples) |s| gpa.free(s);
    for (&samples) |*s| s.* = try gpa.alloc(f64, opts.frames);
    for (0..warmup + opts.frames) |i| {
        state.frame = i;
        state.time = @as(f32, @floatFromInt(i)) / 120;
        t.time = state.time;
        const start = now(init.io);
        t.frame();
        const built = now(init.io);
        // Includes allocating and freeing the offscreen framebuffer.
        const pixels = try t.render(gpa);
        pixels.deinit(gpa);
        const drawn = now(init.io);
        if (i >= warmup) {
            samples[0][i - warmup] = (drawn - start) * 1000;
            samples[1][i - warmup] = (built - start) * 1000;
            samples[2][i - warmup] = (drawn - built) * 1000;
        }
    }
    return .{
        .scene = scene,
        .total_ms = percentile(samples[0], 50),
        .p95_ms = percentile(samples[0], 95),
        .frame_ms = percentile(samples[1], 50),
        .raster_ms = percentile(samples[2], 50),
    };
}

fn parse(init: std.process.Init) !Options {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: hillclimb [--scene boxes,text,scroll,list,dashboard] [--frames N] [--repeat N] [--scale N] [--label NAME] [--only nanoui]\n", .{});
            std.process.exit(0);
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--frames")) {
            opts.frames = try std.fmt.parseInt(usize, value, 10);
            if (opts.frames == 0 or opts.frames > 1_000_000) return error.InvalidFrames;
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            opts.repeat = try std.fmt.parseInt(usize, value, 10);
            if (opts.repeat == 0) return error.InvalidRepeat;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            opts.scale = try std.fmt.parseFloat(f32, value);
            if (!std.math.isFinite(opts.scale) or opts.scale <= 0 or opts.scale > 4) return error.InvalidScale;
        } else if (std.mem.eql(u8, arg, "--label")) {
            opts.label = value;
        } else if (std.mem.eql(u8, arg, "--only")) {
            if (!std.mem.eql(u8, value, "nanoui")) return error.MygoRequiresMacOS;
        } else if (std.mem.eql(u8, arg, "--scene")) {
            var list: std.ArrayList(scenes.Scene) = .empty;
            var names = std.mem.splitScalar(u8, value, ',');
            while (names.next()) |name| try list.append(arena, std.meta.stringToEnum(scenes.Scene, name) orelse return error.UnknownScene);
            opts.scenes = list.items;
        } else return error.UnknownArgument;
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const opts = try parse(init);
    const arena = init.arena.allocator();
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    const optimize = @tagName(builtin.mode);
    std.debug.print("CPU hill-climb: {s}/{s}, {s}, 900x640 at {d}x, {d} frames, {d} repeats; offscreen\n", .{ os, arch, optimize, opts.scale, opts.frames, opts.repeat });
    std.debug.print("{s:<12} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "scene", "total ms", "p95 ms", "frame ms", "raster ms", "vs last" });
    const cwd = std.Io.Dir.cwd();
    const history_path = "history-cpu.jsonl";
    const old = cwd.readFileAlloc(init.io, history_path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var previous: ?Entry = null;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        const entry = std.json.parseFromSliceLeaky(Entry, arena, line, .{}) catch continue;
        if (std.mem.eql(u8, entry.os, os) and std.mem.eql(u8, entry.arch, arch) and
            std.mem.eql(u8, entry.optimize, optimize) and entry.scale == opts.scale and entry.frames == opts.frames)
            previous = entry;
    }
    var results: std.ArrayList(Result) = .empty;
    for (opts.scenes) |scene| {
        var best: ?Result = null;
        for (0..opts.repeat) |_| {
            const r = try measure(init, opts, scene);
            if (best == null or r.total_ms < best.?.total_ms) best = r;
        }
        const r = best.?;
        try results.append(arena, r);
        std.debug.print("{s:<12} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10.3}", .{ @tagName(scene), r.total_ms, r.p95_ms, r.frame_ms, r.raster_ms });
        if (previous) |p| for (p.results) |last| {
            if (last.scene == scene and last.total_ms > 0) {
                const delta = (r.total_ms / last.total_ms - 1) * 100;
                std.debug.print(" {s}{d:.1}%", .{ if (delta < 0) "-" else "+", @abs(delta) });
                break;
            }
        };
        std.debug.print("\n", .{});
    }
    if (previous) |p| std.debug.print("Compared with: {s}. Changes within 5% may be noise.\n", .{p.label});
    var output: std.Io.Writer.Allocating = .init(arena);
    try output.writer.writeAll(old);
    const entry: Entry = .{ .time = std.Io.Clock.real.now(init.io).toSeconds(), .os = os, .arch = arch, .optimize = optimize, .scale = opts.scale, .frames = opts.frames, .label = opts.label, .results = results.items };
    try std.json.Stringify.value(entry, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try cwd.writeFile(init.io, .{ .sub_path = history_path, .data = output.written() });
}
