const std = @import("std");
const testing = std.testing;

//@TODO: you can take *slice and alter slice.ptr
// make sign bits check more efficient
// add wrapper readLEB128 and write LEB128 that infer from type?
// or use assertions?

pub fn readULEB128(comptime T: type, reader: var) !T {
    const U = if (T.bit_count < 8) u8 else T;
    const ShiftT = std.math.Log2Int(U);

    const max_group = (U.bit_count + 6) / 7;

    var value = @as(U, 0);
    var group = @as(ShiftT, 0);

    while (group < max_group) : (group += 1) {
        const byte = try reader.readByte();
        var temp = @as(U, byte & 0x7f);

        if (@shlWithOverflow(U, temp, group * 7, &temp)) return error.Overflow;

        value |= temp;
        if (byte & 0x80 == 0) break;
    } else {
        return error.Overflow;
    }

    //only applies in the case that we extended to u8
    if (value > std.math.maxInt(T)) return error.Overflow;

    return @truncate(T, value);
}

pub fn writeULEB128(writer: var, uint_value: var) !void {
    const T = @TypeOf(uint_value);
    const U = if (T.bit_count < 8) u8 else T;
    var value = @intCast(U, uint_value);

    while (true) {
        const byte = @truncate(u8, value & 0x7f);
        value >>= 7;
        if (value == 0) {
            try writer.writeByte(byte);
            break;
        } else {
            try writer.writeByte(byte | 0x80);
        }
    }
}

pub fn readULEB128Mem(comptime T: type, ptr: *[*]const u8) !T {
    const max_group = (T.bit_count + 6) / 7;
    var buf = std.io.fixedBufferStream(ptr.*[0 .. max_group + 1]);
    const value = try readULEB128(T, buf.reader());
    ptr.* += @intCast(usize, try buf.getPos());
    return value;
}

pub fn writeULEB128Mem(ptr: []u8, uint_value: var) !usize {
    const T = @TypeOf(uint_value);
    const max_group = (T.bit_count + 6) / 7;
    var buf = std.io.fixedBufferStream(ptr);
    try writeULEB128(buf.writer(), uint_value);
    return try buf.getPos();
}

pub fn readILEB128(comptime T: type, reader: var) !T {
    const S = if (T.bit_count < 8) i8 else T;
    const U = std.meta.Int(false, S.bit_count);
    const ShiftU = std.math.Log2Int(U);

    const max_group = (U.bit_count + 6) / 7;

    var value = @as(U, 0);
    var group = @as(ShiftU, 0);

    while (group < max_group) : (group += 1) {
        const byte = try reader.readByte();
        var temp = @as(U, byte & 0x7f);

        if (@shlWithOverflow(U, temp, group * 7, &temp)) {
            //Overflow is ok so long as the sign bit is set and this is the last byte
            if (byte & 0x80 != 0) return error.Overflow;
            if (@bitCast(S, temp) >= 0) return error.Overflow;

            //and all the overflowed bits are 1
            const check_bits_shift = @intCast(u3, U.bit_count - @as(u16, group * 7));
            const check_bits_remaining = 7 - check_bits_shift;
            const check_bits = byte >> check_bits_shift;
            const num_consecutive_ones = @ctz(u8, ~check_bits);
            if (num_consecutive_ones < check_bits_remaining) return error.Overflow;
        }

        value |= temp;
        if (byte & 0x80 == 0) {
            if (byte & 0x40 != 0 and group + 1 < max_group) {
                value |= @bitCast(U, @as(S, -1)) << ((group + 1) * 7);
            }
            break;
        }
    } else {
        return error.Overflow;
    }

    //Only applies if we extended to i8
    if (@bitCast(S, value) > std.math.maxInt(T) or @bitCast(S, value) < std.math.minInt(T)) return error.Overflow;

    return @truncate(T, @bitCast(S, value));
}

pub fn writeILEB128(writer: var, int_value: var) !void {
    const T = @TypeOf(int_value);
    const S = if (T.bit_count < 8) i8 else T;
    const U = std.meta.Int(false, S.bit_count);

    var value = @intCast(S, int_value);

    while (true) {
        const uvalue = @bitCast(U, value);
        const byte = @truncate(u8, uvalue);
        value >>= 6;
        if (value == -1 or value == 0) {
            try writer.writeByte(byte & 0x7F);
            break;
        } else {
            value >>= 1;
            try writer.writeByte(byte | 0x80);
        }
    }
}

pub fn readILEB128Mem(comptime T: type, ptr: *[*]const u8) !T {
    const max_group = (T.bit_count + 6) / 7;
    var buf = std.io.fixedBufferStream(ptr.*[0 .. max_group + 1]);
    const value = try readILEB128(T, buf.reader());
    ptr.* += @intCast(usize, try buf.getPos());
    return value;
}

pub fn writeILEB128Mem(ptr: []u8, int_value: var) !usize {
    const T = @TypeOf(int_value);
    var buf = std.io.fixedBufferStream(ptr);
    try writeILEB128(buf.writer(), int_value);
    return try buf.getPos();
}

//tests
fn test_read_stream_ileb128(comptime T: type, encoded: []const u8) !T {
    var reader = std.io.fixedBufferStream(encoded);
    return try readILEB128(T, reader.reader());
}

fn test_read_stream_uleb128(comptime T: type, encoded: []const u8) !T {
    var reader = std.io.fixedBufferStream(encoded);
    return try readULEB128(T, reader.reader());
}

fn test_read_ileb128(comptime T: type, encoded: []const u8) !T {
    var reader = std.io.fixedBufferStream(encoded);
    const v1 = try readILEB128(T, reader.reader());
    var in_ptr = encoded.ptr;
    const v2 = try readILEB128Mem(T, &in_ptr);
    testing.expectEqual(v1, v2);
    return v1;
}

fn test_read_uleb128(comptime T: type, encoded: []const u8) !T {
    var reader = std.io.fixedBufferStream(encoded);
    const v1 = try readULEB128(T, reader.reader());
    var in_ptr = encoded.ptr;
    const v2 = try readULEB128Mem(T, &in_ptr);
    testing.expectEqual(v1, v2);
    return v1;
}

fn test_read_ileb128_seq(comptime T: type, comptime N: usize, encoded: []const u8) !void {
    var reader = std.io.fixedBufferStream(encoded);
    var in_ptr = encoded.ptr;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const v1 = try readILEB128(T, reader.reader());
        const v2 = try readILEB128Mem(T, &in_ptr);
        testing.expectEqual(v1, v2);
    }
}

fn test_read_uleb128_seq(comptime T: type, comptime N: usize, encoded: []const u8) !void {
    var reader = std.io.fixedBufferStream(encoded);
    var in_ptr = encoded.ptr;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const v1 = try readULEB128(T, reader.reader());
        const v2 = try readULEB128Mem(T, &in_ptr);
        testing.expectEqual(v1, v2);
    }
}

test "deserialize signed LEB128" {
    // Truncated
    testing.expectError(error.EndOfStream, test_read_stream_ileb128(i64, "\x80"));

    // Overflow
    testing.expectError(error.Overflow, test_read_ileb128(i8, "\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_ileb128(i16, "\x80\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_ileb128(i32, "\x80\x80\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_ileb128(i64, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_ileb128(i8, "\xff\x7e"));

    // Decode SLEB128
    testing.expect((try test_read_ileb128(i64, "\x00")) == 0);
    testing.expect((try test_read_ileb128(i64, "\x01")) == 1);
    testing.expect((try test_read_ileb128(i64, "\x3f")) == 63);
    testing.expect((try test_read_ileb128(i64, "\x40")) == -64);
    testing.expect((try test_read_ileb128(i64, "\x41")) == -63);
    testing.expect((try test_read_ileb128(i64, "\x7f")) == -1);
    testing.expect((try test_read_ileb128(i64, "\x80\x01")) == 128);
    testing.expect((try test_read_ileb128(i64, "\x81\x01")) == 129);
    testing.expect((try test_read_ileb128(i64, "\xff\x7e")) == -129);
    testing.expect((try test_read_ileb128(i64, "\x80\x7f")) == -128);
    testing.expect((try test_read_ileb128(i64, "\x81\x7f")) == -127);
    testing.expect((try test_read_ileb128(i64, "\xc0\x00")) == 64);
    testing.expect((try test_read_ileb128(i64, "\xc7\x9f\x7f")) == -12345);
    testing.expect((try test_read_ileb128(i8, "\xff\x7f")) == -1);
    testing.expect((try test_read_ileb128(i16, "\xff\xff\x7f")) == -1);
    testing.expect((try test_read_ileb128(i32, "\xff\xff\xff\xff\x7f")) == -1);
    testing.expect((try test_read_ileb128(i32, "\x80\x80\x80\x80\x08")) == -0x80000000);
    testing.expect((try test_read_ileb128(i64, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01")) == @bitCast(i64, @intCast(u64, 0x8000000000000000)));
    testing.expect((try test_read_ileb128(i64, "\x80\x80\x80\x80\x80\x80\x80\x80\x40")) == -0x4000000000000000);
    testing.expect((try test_read_ileb128(i64, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x7f")) == -0x8000000000000000);

    // Decode unnormalized SLEB128 with extra padding bytes.
    testing.expect((try test_read_ileb128(i64, "\x80\x00")) == 0);
    testing.expect((try test_read_ileb128(i64, "\x80\x80\x00")) == 0);
    testing.expect((try test_read_ileb128(i64, "\xff\x00")) == 0x7f);
    testing.expect((try test_read_ileb128(i64, "\xff\x80\x00")) == 0x7f);
    testing.expect((try test_read_ileb128(i64, "\x80\x81\x00")) == 0x80);
    testing.expect((try test_read_ileb128(i64, "\x80\x81\x80\x00")) == 0x80);

    // Decode sequence of SLEB128 values
    try test_read_ileb128_seq(i64, 4, "\x81\x01\x3f\x80\x7f\x80\x80\x80\x00");
}

test "deserialize unsigned LEB128" {
    // Truncated
    testing.expectError(error.EndOfStream, test_read_stream_uleb128(u64, "\x80"));

    // Overflow
    testing.expectError(error.Overflow, test_read_uleb128(u8, "\x80\x02"));
    testing.expectError(error.Overflow, test_read_uleb128(u8, "\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_uleb128(u16, "\x80\x80\x84"));
    testing.expectError(error.Overflow, test_read_uleb128(u16, "\x80\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_uleb128(u32, "\x80\x80\x80\x80\x90"));
    testing.expectError(error.Overflow, test_read_uleb128(u32, "\x80\x80\x80\x80\x40"));
    testing.expectError(error.Overflow, test_read_uleb128(u64, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x40"));

    // Decode ULEB128
    testing.expect((try test_read_uleb128(u64, "\x00")) == 0);
    testing.expect((try test_read_uleb128(u64, "\x01")) == 1);
    testing.expect((try test_read_uleb128(u64, "\x3f")) == 63);
    testing.expect((try test_read_uleb128(u64, "\x40")) == 64);
    testing.expect((try test_read_uleb128(u64, "\x7f")) == 0x7f);
    testing.expect((try test_read_uleb128(u64, "\x80\x01")) == 0x80);
    testing.expect((try test_read_uleb128(u64, "\x81\x01")) == 0x81);
    testing.expect((try test_read_uleb128(u64, "\x90\x01")) == 0x90);
    testing.expect((try test_read_uleb128(u64, "\xff\x01")) == 0xff);
    testing.expect((try test_read_uleb128(u64, "\x80\x02")) == 0x100);
    testing.expect((try test_read_uleb128(u64, "\x81\x02")) == 0x101);
    testing.expect((try test_read_uleb128(u64, "\x80\xc1\x80\x80\x10")) == 4294975616);
    testing.expect((try test_read_uleb128(u64, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01")) == 0x8000000000000000);

    // Decode ULEB128 with extra padding bytes
    testing.expect((try test_read_uleb128(u64, "\x80\x00")) == 0);
    testing.expect((try test_read_uleb128(u64, "\x80\x80\x00")) == 0);
    testing.expect((try test_read_uleb128(u64, "\xff\x00")) == 0x7f);
    testing.expect((try test_read_uleb128(u64, "\xff\x80\x00")) == 0x7f);
    testing.expect((try test_read_uleb128(u64, "\x80\x81\x00")) == 0x80);
    testing.expect((try test_read_uleb128(u64, "\x80\x81\x80\x00")) == 0x80);

    // Decode sequence of ULEB128 values
    try test_read_uleb128_seq(u64, 4, "\x81\x01\x3f\x80\x7f\x80\x80\x80\x00");
}

fn test_write_leb128(value: var) !void {
    const T = @TypeOf(value);

    if (T.bit_count == 0) std.debug.warn("{}\n", .{@typeName(T)});

    const writeStream = if (T.is_signed) writeILEB128 else writeULEB128;
    const writeMem = if (T.is_signed) writeILEB128Mem else writeULEB128Mem;
    const readStream = if (T.is_signed) readILEB128 else readULEB128;
    const readMem = if (T.is_signed) readILEB128Mem else readULEB128Mem;

    //decode to a larger bit size too, to ensure sign extension
    // is working as expected
    const larger_type_bits = ((T.bit_count + 8) / 8) * 8;
    const B = std.meta.Int(T.is_signed, larger_type_bits);
    const max_groups = if (T.bit_count == 0) 1 else (T.bit_count + 6) / 7;

    var buf: [max_groups]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    //stream write
    try writeStream(fbs.writer(), value);
    const w1_pos = fbs.pos;
    testing.expect(w1_pos > 0);

    //stream read
    fbs.pos = 0;
    const sr = try readStream(T, fbs.reader());
    testing.expect(fbs.pos == w1_pos);
    testing.expect(sr == value);

    //bigger type stream read
    fbs.pos = 0;
    const bsr = try readStream(B, fbs.reader());
    testing.expect(fbs.pos == w1_pos);
    testing.expect(bsr == value);

    //mem write
    const w2_pos = try writeMem(&buf, value);
    testing.expect(w2_pos == w1_pos);

    //mem read
    var buf_ref: []u8 = buf[0..];
    const mr = try readMem(T, &buf_ref.ptr);
    testing.expect(@ptrToInt(buf_ref.ptr) - @ptrToInt(&buf) == w2_pos);
    testing.expect(mr == value);

    //bigger type mem read
    buf_ref = buf[0..];
    const bmr = try readMem(T, &buf_ref.ptr);
    testing.expect(@ptrToInt(buf_ref.ptr) - @ptrToInt(&buf) == w2_pos);
    testing.expect(bmr == value);
}

test "serialize unsigned LEB128" {
    const max_bits = 18;

    comptime var t = 0;
    inline while (t <= max_bits) : (t += 1) {
        const T = std.meta.Int(false, t);
        const min = std.math.minInt(T);
        const max = std.math.maxInt(T);
        var i = @as(std.meta.Int(false, T.bit_count + 1), min);

        while (i <= max) : (i += 1) try test_write_leb128(@intCast(T, i));
    }
}

test "serialize signed LEB128" {
    //explicitly test i0 because starting `t` at 0
    // will break the while loop
    try test_write_leb128(@as(i0, 0));

    const max_bits = 18;

    comptime var t = 1;
    inline while (t <= max_bits) : (t += 1) {
        const T = std.meta.Int(true, t);
        const min = std.math.minInt(T);
        const max = std.math.maxInt(T);
        var i = @as(std.meta.Int(true, T.bit_count + 1), min);

        while (i <= max) : (i += 1) try test_write_leb128(@intCast(T, i));
    }
}
