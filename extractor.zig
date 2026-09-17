const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <image.jpg>\n", .{args[0]});
        return;
    }

    const file_path = args[1];

    const buffer = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        file_path,
        allocator,
        .limited(50 * 1024 * 1024),
    ) catch {
        std.debug.print("Erreur: Impossible de lire le fichier {s}\n", .{file_path});
        return;
    };
    defer allocator.free(buffer);

    if (buffer.len < 2 or buffer[0] != 0xFF or buffer[1] != 0xD8) {
        std.debug.print("Erreur: Ce n'est pas un fichier JPEG valide.\n", .{});
        return;
    }

    var found_date: ?[19]u8 = null;

    // 1. Analyse structurelle des segments JPEG (APP1 / EXIF)
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
                if (parseExifTiff(tiff)) |date| {
                    found_date = date;
                    break;
                }
            }
        }
        pos += length + 2;
    }

    // 2. Recherche globale brute de motifs de date (EXIF / XMP)
    if (found_date == null) {
        found_date = scanBruteForceDate(buffer);
    }

    if (found_date) |date| {
        std.debug.print("Date trouvee : {s}\n", .{date});
        return;
    }

    // 3. Fallback : Date de modification du fichier via file.stat(io)
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch {
        std.debug.print("Aucune date trouvee (ni EXIF, ni systeme).\n", .{});
        return;
    };
    defer file.close(io);

    const stat = file.stat(io) catch {
        std.debug.print("Aucune date EXIF trouvee et stat inaccessibles.\n", .{});
        return;
    };

    const total_secs = stat.mtime.toSeconds();
    const dt = unixToDateTime(total_secs);

    std.debug.print("Aucun EXIF. Date systeme du fichier : {d:0>4}:{d:0>2}:{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{
        dt.year,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
        dt.second,
    });
}

pub fn parseExifTiff(tiff: []const u8) ?[19]u8 {
    if (tiff.len < 8) return null;
    const is_le = switch (tiff[0]) {
        'I' => true,
        'M' => false,
        else => return null,
    };
    if (tiff[1] != tiff[0]) return null;

    const readU16 = struct {
        fn f(s: []const u8, le: bool) u16 {
            return if (le) @as(u16, s[0]) | (@as(u16, s[1]) << 8) else (@as(u16, s[0]) << 8) | @as(u16, s[1]);
        }
    }.f;

    const readU32 = struct {
        fn f(s: []const u8, le: bool) u32 {
            return if (le) @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24)
            else (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
        }
    }.f;

    const ifd0_offset = readU32(tiff[4..8], is_le);
    if (ifd0_offset + 2 > tiff.len) return null;

    const num_fields = readU16(tiff[ifd0_offset..], is_le);
    var current_pos = ifd0_offset + 2;
    var exif_offset: ?u32 = null;

    for (0..num_fields) |_| {
        if (current_pos + 12 > tiff.len) break;
        const tag = readU16(tiff[current_pos..], is_le);
        
        if (tag == 0x0132) {
            const count = readU32(tiff[current_pos + 4 ..], is_le);
            const val_off = readU32(tiff[current_pos + 8 ..], is_le);
            if (count >= 19 and val_off + 19 <= tiff.len) {
                var buf: [19]u8 = undefined;
                @memcpy(&buf, tiff[val_off .. val_off + 19]);
                if (isValidDateString(buf)) return buf;
            }
        }
        if (tag == 0x8769) {
            exif_offset = readU32(tiff[current_pos + 8 ..], is_le);
        }
        current_pos += 12;
    }

    if (exif_offset) |sub_off| {
        if (sub_off + 2 <= tiff.len) {
            const sub_fields = readU16(tiff[sub_off..], is_le);
            var sub_pos = sub_off + 2;
            for (0..sub_fields) |_| {
                if (sub_pos + 12 > tiff.len) break;
                const tag = readU16(tiff[sub_pos..], is_le);
                if (tag == 0x9003 or tag == 0x9004) {
                    const count = readU32(tiff[sub_pos + 4 ..], is_le);
                    const val_off = readU32(tiff[sub_pos + 8 ..], is_le);
                    if (count >= 19 and val_off + 19 <= tiff.len) {
                        var buf: [19]u8 = undefined;
                        @memcpy(&buf, tiff[val_off .. val_off + 19]);
                        if (isValidDateString(buf)) return buf;
                    }
                }
                sub_pos += 12;
            }
        }
    }
    return null;
}

fn scanBruteForceDate(buffer: []const u8) ?[19]u8 {
    if (buffer.len < 19) return null;
    var i: usize = 0;
    while (i <= buffer.len - 19) : (i += 1) {
        if (buffer[i + 4] == ':' and buffer[i + 7] == ':' and buffer[i + 10] == ' ' and
            buffer[i + 13] == ':' and buffer[i + 16] == ':') 
        {
            var candidate: [19]u8 = undefined;
            @memcpy(&candidate, buffer[i .. i + 19]);
            if (isValidDateString(candidate)) return candidate;
        }
    }
    return null;
}

fn isValidDateString(s: [19]u8) bool {
    const indices = [_]usize{0,1,2,3, 5,6, 8,9, 11,12, 14,15, 17,18};
    for (indices) |idx| {
        if (s[idx] < '0' or s[idx] > '9') return false;
    }
    return (s[0] == '1' or s[0] == '2');
}

pub fn unixToDateTime(secs: i64) struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 } {
    const days = @divFloor(secs, 86400);
    const day_of_sec = @mod(secs, 86400);
    
    const hour = @as(u8, @intCast(@divFloor(day_of_sec, 3600)));
    const minute = @as(u8, @intCast(@divFloor(@mod(day_of_sec, 3600), 60)));
    const second = @as(u8, @intCast(@mod(day_of_sec, 60)));

    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = @as(u32, @intCast(z - era * 146097));
    const yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    const y = yoe + @as(u32, @intCast(era * 400));
    const doy = doe - (365*yoe + yoe/4 - yoe/100);
    const mp = (5*doy + 2)/153;
    const d = doy - (153*mp+2)/5 + 1;
    const m_val: i32 = @as(i32, @intCast(mp)) + if (mp < 10) @as(i32, 3) else -9;
    const m = @as(u8, @intCast(m_val));
    const yr = y + @as(u32, @intCast(if (m <= 2) @as(i32, 1) else 0));

    return .{
        .year = @as(u16, @intCast(yr)),
        .month = m,
        .day = @as(u8, @intCast(d)),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}
