const std = @import("std");

pub fn Image_Reader(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);

    const buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    _ = try file.readPositionalAll(io, buffer, 0);

    std.debug.print("\n--- {s} ---\n{s}\n", .{ path, buffer });
}
