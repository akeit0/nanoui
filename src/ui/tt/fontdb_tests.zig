//! Regression coverage for style-preserving fallback, following mygo's
//! text formats and GPUI's font-match/fallback attributes.
const std = @import("std");
const font = @import("font.zig");
const Db = @import("fontdb.zig").Db;
const testing = std.testing;

fn fixturePath() ![]const u8 {
    for ([_][]const u8{
        "C:\\Windows\\Fonts\\arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    }) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20)) catch continue;
        defer testing.allocator.free(bytes);
        const parsed = font.Font.init(bytes, 0) catch continue;
        if (parsed.glyphIndex(0x03a9) != 0) return path;
    }
    return error.SkipZigTest;
}

// Reuse real glyph coverage with controlled family/style metadata, so
// matching tests do not depend on the OS's installed font ordering.
fn addFace(db: *Db, path: []const u8, name: []const u8, weight: u16, italic: bool) !u32 {
    var style: font.Style = .{ .weight = weight, .italic = italic, .family_len = @intCast(name.len) };
    @memcpy(style.family[0..name.len], name);
    const id: u32 = @intCast(db.faces.items.len);
    const owned = try testing.allocator.dupe(u8, path);
    errdefer testing.allocator.free(owned);
    try db.faces.append(testing.allocator, .{ .path = owned, .index = 0, .style = style });
    return id;
}

test "fallback preserves weight and italic regardless of load order and cache order" {
    const path = try fixturePath();
    var db: Db = .init(testing.allocator, testing.io);
    defer db.deinit();
    db.scanned = true;
    const bold = try addFace(&db, path, "Fixture Sans", 700, false);
    const regular = try addFace(&db, path, "Fixture Sans", 400, false);
    const italic = try addFace(&db, path, "Fixture Sans", 400, true);
    _ = db.load(bold).?;
    // Reproduces the bug: Bold was discovered and loaded first, but a
    // normal run needs Regular. Later styles must not reuse that cache key.
    try testing.expectEqual(regular, db.fallback(0x03a9, 400, false).?);
    try testing.expectEqual(bold, db.fallback(0x03a9, 700, false).?);
    try testing.expectEqual(regular, db.fallback(0x03a9, 400, false).?);
    try testing.expectEqual(italic, db.fallback(0x03a9, 400, true).?);
}

test "Japanese shaping retains regular, bold and italic attributes from the original run" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var text = @import("../text_tt.zig").TextSystem.init(testing.allocator);
    defer text.deinit();
    text.db.scanned = true;
    text.db.addFile("C:\\Windows\\Fonts\\arial.ttf");
    text.db.addFile("C:\\Windows\\Fonts\\BIZ-UDGothicB.ttc");
    text.db.addFile("C:\\Windows\\Fonts\\BIZ-UDGothicR.ttc");
    _ = text.db.family("Arial", 400, false) orelse return error.SkipZigTest;
    const regular = text.db.family("BIZ UDGothic", 400, false) orelse return error.SkipZigTest;
    const bold = text.db.family("BIZ UDGothic", 700, false) orelse return error.SkipZigTest;
    if (text.db.faces.items[regular].style.weight != 400 or text.db.faces.items[bold].style.weight != 700) return error.SkipZigTest;
    text.family = "Arial";
    const TextStyle = @import("../types.zig").TextStyle;
    for ([_]TextStyle{ .{}, .{ .weight = .bold }, .{}, .{ .italic = true } }) |style| {
        const layout = text.layout("日本語", style);
        try testing.expectEqual(@as(usize, 3), layout.glyphs.len);
        for (layout.glyphs) |glyph| {
            try testing.expect(glyph.glyph != 0);
            const face_id = text.run_faces.items[glyph.font];
            try testing.expectEqual(if (style.weight == .bold) bold else regular, face_id);
            const run = text.run_fonts.items[glyph.font];
            try testing.expectEqual(@as(f32, 0), run.embolden);
            try testing.expectEqual(@as(f32, if (style.italic) 0.2 else 0), run.skew);
        }
    }
}
