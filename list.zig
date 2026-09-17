const std = @import("std");

pub const FileIterator = struct {
    walker: std.Io.Dir.Walker,
    dir: std.Io.Dir,
    io: std.Io,
    root_path: []const u8,

    pub fn next(self: *FileIterator, allocator: std.mem.Allocator) !?[]const u8 {
        while (try self.walker.next(self.io)) |entry| {
            if (entry.kind == .file) {
                // Construit le chemin complet proprement
                return try std.fmt.allocPrint(allocator, "{s}/{s}", .{
                    self.root_path,
                    entry.path,
                });
            }
        }

        self.walker.deinit();
        self.dir.close(self.io);

        return null;
    }
};

pub fn list(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !FileIterator {
    var dir: std.Io.Dir = undefined;

    if (std.fs.path.isAbsolute(root_path)) {
        dir = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    } else {
        dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    }

    const walker = try dir.walk(allocator);

    return FileIterator{
        .walker = walker,
        .dir = dir,
        .io = io,
        .root_path = root_path,
    };
}
