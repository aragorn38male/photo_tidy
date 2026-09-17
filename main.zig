const std = @import("std");
const List = @import("list.zig");
const Extractor = @import("extractor.zig");

const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
};

// Recherche brute universelle de motif de date "YYYY:MM:DD HH:MM:SS" dans n'importe quel fichier
fn scanBruteForceDate(buffer: []const u8) ?[19]u8 {
    if (buffer.len < 19) return null;
    var i: usize = 0;
    while (i <= buffer.len - 19) : (i += 1) {
        if (buffer[i + 4] == ':' and buffer[i + 7] == ':' and buffer[i + 10] == ' ' and
            buffer[i + 13] == ':' and buffer[i + 16] == ':') 
        {
            var candidate: [19]u8 = undefined;
            @memcpy(&candidate, buffer[i .. i + 19]);
            if (candidate[0] >= '1' and candidate[0] <= '2') {
                return candidate;
            }
        }
    }
    return null;
}

fn worker(ctx: *WorkerCtx) !void {
    defer ctx.allocator.free(ctx.path);

    const file_path = ctx.path;
    
    var file = std.Io.Dir.cwd().openFile(ctx.io, file_path, .{ .mode = .read_only }) catch return;
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch return;
    if (stat.size > 50 * 1024 * 1024) return;

    const buffer = ctx.allocator.alloc(u8, @intCast(stat.size)) catch return;
    defer ctx.allocator.free(buffer);

    _ = file.readPositionalAll(ctx.io, buffer, 0) catch return;

    // 1. Date système (mtime) de base
    const total_secs = stat.mtime.toSeconds();
    const dt_sys = Extractor.unixToDateTime(total_secs);
    
    var best_date_buf: [19]u8 = undefined;
    _ = std.fmt.bufPrint(&best_date_buf, "{d:0>4}:{d:0>2}:{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        dt_sys.year, dt_sys.month, dt_sys.day,
        dt_sys.hour, dt_sys.minute, dt_sys.second,
    }) catch return;

    var source_used: []const u8 = "Systeme (mtime)";
    var metadata_found: ?[19]u8 = null;

    // 2. Si c'est un JPEG, on tente l'EXIF structuré
    if (buffer.len >= 2 and buffer[0] == 0xFF and buffer[1] == 0xD8) {
        var pos: usize = 2;
        while (pos < buffer.len - 1) {
            if (buffer[pos] != 0xFF) {
                pos += 1;
                continue;
            }

            const marker = buffer[pos + 1];
            if (marker == 0xDA or marker == 0xD9) break;

            if (pos + 4 > buffer.len) break;
            const length = (@as(u16, buffer[pos + 2]) << 8) | @as(u16, buffer[pos + 3]);
            if (length < 2) break;

            if (marker == 0xE1) {
                const start = pos + 4;
                const end = @min(start + length - 2, buffer.len);
                const seg = buffer[start..end];

                if (seg.len > 6 and std.mem.startsWith(u8, seg, "Exif\x00\x00")) {
                    const tiff = seg[6..];
                    if (Extractor.parseExifTiff(tiff)) |date| {
                        metadata_found = date;
                        break;
                    }
                }
            }
            pos += length + 2;
        }
    }

    // 3. Si l'EXIF structuré n'a rien donné, on tente la recherche brute dans le fichier (marche pour certains PNG/WebP/etc.)
    if (metadata_found == null) {
        metadata_found = scanBruteForceDate(buffer);
    }

    // 4. Comparaison stricte : on garde la date la plus ancienne (la plus petite lexicographiquement)
    if (metadata_found) |meta| {
        if (std.mem.lessThan(u8, &meta, &best_date_buf)) {
            best_date_buf = meta;
            source_used = "Metadonnees (plus ancien que systeme)";
        } else {
            // Optionnel : si vous voulez que les métadonnées priment même si elles sont plus récentes
            best_date_buf = meta;
            source_used = "Metadonnees (prioritaire)";
        }
    }

    const year_str = best_date_buf[0..4];
    const month_str = best_date_buf[5..7];
    const day_str = best_date_buf[8..10];

    var date_folder_buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&date_folder_buf, "{s}_{s}_{s}", .{ year_str, month_str, day_str }) catch return;

    const parent_dir = std.fs.path.dirname(file_path) orelse return;
    const target_dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ parent_dir, &date_folder_buf });
    defer ctx.allocator.free(target_dir_path);

    std.Io.Dir.cwd().createDir(ctx.io, target_dir_path, @enumFromInt(0)) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    const file_name = std.fs.path.basename(file_path);
    const target_file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ target_dir_path, file_name });
    defer ctx.allocator.free(target_file_path);

    std.Io.Dir.cwd().rename(file_path, std.Io.Dir.cwd(), target_file_path, ctx.io) catch |err| {
        std.debug.print("Erreur de déplacement pour {s}: {}\n", .{file_path, err});
        return;
    };

    std.debug.print("[Source: {s}] Déplacé : {s} -> {s}/\n", .{source_used, file_name, &date_folder_buf});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("Usage: {s} <folder>\n", .{std.fs.path.basename(args[0])});
        return;
    }

    const dir_path = args[1];
    var iter = try List.list(allocator, io, dir_path);

    var threads = std.ArrayListUnmanaged(std.Thread){ .items = &[_]std.Thread{}, .capacity = 0 };
    defer threads.deinit(allocator);

    var ctx_list = std.ArrayListUnmanaged(*WorkerCtx){ .items = &[_]*WorkerCtx{}, .capacity = 0 };
    defer ctx_list.deinit(allocator);

    while (try iter.next(allocator)) |full_path| {
        const ctx = try allocator.create(WorkerCtx);
        ctx.* = .{ .allocator = allocator, .io = io, .path = full_path };

        const t = try std.Thread.spawn(.{}, worker, .{ctx});
        try threads.append(allocator, t);
        try ctx_list.append(allocator, ctx);
    }

    for (threads.items) |t| t.join();
    for (ctx_list.items) |ctx| allocator.destroy(ctx);
}
