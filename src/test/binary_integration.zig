const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.binary_integration);

const ribbon = @import("ribbon_language");
const common = ribbon.common;
const core = ribbon.core;
const bin = ribbon.binary;
const AllocWriter = ribbon.common.AllocWriter;

// test {
//     std.debug.print("binary_integration", .{});
// }

test "linker map locations and fixups" {
    const gpa = std.testing.allocator;

    var linker_map = bin.LinkerMap.init(gpa);
    defer linker_map.deinit();

    // The new API uses Location structs which contain Region and Offset structs.
    // These can be constructed from any common.Id type.
    const region1_id = bin.RegionId.fromInt(1);
    const offset1_id = bin.RegionId.fromInt(10);
    const loc1 = bin.Location.from(region1_id, offset1_id);

    const region2_id = bin.RegionId.fromInt(2);
    const offset2_id = bin.RegionId.fromInt(20);
    const loc2 = bin.Location.from(region2_id, offset2_id);

    const other_ref = AllocWriter.RelativeAddress.fromInt(1234);

    try linker_map.bindFixup(.absolute, loc1, .from, other_ref, null);
    try linker_map.bindLocationName(loc1, "my.cool.symbol");

    // Note: FixupKind changed from .relative to .relative_words
    try linker_map.bindFixup(.relative_words, loc2, .to, other_ref, 32);

    const unbound = linker_map.getUnbound();
    try testing.expectEqual(@as(usize, 2), unbound.len);

    const l_loc1 = linker_map.unbound.get(loc1).?;
    try testing.expectEqualStrings("my.cool.symbol", l_loc1.name.?);
    try testing.expectEqual(@as(usize, 1), l_loc1.fixups.count());

    var it1 = l_loc1.fixups.iterator();
    const fixup1 = it1.next().?.key_ptr;
    try testing.expect(fixup1.kind == .absolute);
    try testing.expect(fixup1.basis == .from);
    try testing.expect(fixup1.other == other_ref);

    const l_loc2 = linker_map.unbound.get(loc2).?;
    try testing.expect(l_loc2.name == null);
    try testing.expectEqual(@as(usize, 1), l_loc2.fixups.count());

    var it2 = l_loc2.fixups.iterator();
    const fixup2 = it2.next().?.key_ptr;
    try testing.expect(fixup2.kind == .relative_words);
    try testing.expect(fixup2.basis == .to);

    linker_map.clear();
    try testing.expectEqual(@as(usize, 0), linker_map.getUnbound().len);
}

test "location map regions and locations" {
    const gpa = std.testing.allocator;
    const initial_region_id = bin.RegionId.fromInt(1);
    var map = bin.LocationMap.init(gpa, initial_region_id);
    defer map.deinit();

    const region_id1 = bin.RegionId.fromInt(1);
    const parent_region = map.enterRegion(region_id1);

    // Parent region should have the initial ID.
    try testing.expectEqual(initial_region_id, parent_region.id);

    // Current region should be the one we just entered.
    try testing.expectEqual(region_id1, map.currentRegion().id);

    const offset_id1 = common.Id.of(u16, 16).fromInt(10);
    const loc1 = map.localLocationId(offset_id1);

    // The location's region should be the current region.
    try testing.expectEqual(region_id1, loc1.region.id);

    // Registering a location should add it to the map with a null address initially.
    try map.registerLocation(loc1);
    try testing.expect(map.addresses.get(loc1) != null); // Check that the key exists
    try testing.expect(map.addresses.get(loc1).? == null); // Check that the value is null

    const rel_addr = AllocWriter.RelativeAddress.fromInt(42);
    try map.bindLocation(loc1, rel_addr);
    try testing.expect(map.addresses.get(loc1).?.? == rel_addr);

    // After leaving, the current region should be restored to the parent.
    map.leaveRegion(parent_region);
    try testing.expectEqual(initial_region_id, map.currentRegion().id);
}

test "finalize buffer with resolvable fixups" {
    const gpa = std.testing.allocator;
    const region_id = bin.RegionId.fromInt(1);
    var map = bin.LocationMap.init(gpa, region_id);
    defer map.deinit();

    var linker_map = bin.LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try bin.Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // Word 0: Will contain the absolute address of Word 2.
    const from_abs_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0));
    const from_abs_loc = encoder.localLocationId(bin.RegionId.fromInt(1));
    try encoder.registerLocation(from_abs_loc);
    try encoder.bindLocation(from_abs_loc, from_abs_rel);

    // Word 1: Will contain a relative jump to Word 3. The low 16 bits will be patched.
    const from_rel_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xFFFFFFFFFFFF0000));
    const from_rel_loc = encoder.localLocationId(bin.RegionId.fromInt(2));
    try encoder.registerLocation(from_rel_loc);
    try encoder.bindLocation(from_rel_loc, from_rel_rel);

    // Word 2: The target for the absolute fixup.
    const to_abs_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xAAAAAAAAAAAAAAA));
    const to_abs_loc = encoder.localLocationId(bin.RegionId.fromInt(3));
    try encoder.registerLocation(to_abs_loc);
    try encoder.bindLocation(to_abs_loc, to_abs_rel);

    // Word 3: The target for the relative fixup.
    const to_rel_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xBBBBBBBBBBBBBBBB));
    const to_rel_loc = encoder.localLocationId(bin.RegionId.fromInt(4));
    try encoder.registerLocation(to_rel_loc);
    try encoder.bindLocation(to_rel_loc, to_rel_rel);

    // Bind fixups
    try encoder.bindFixup(.absolute, .{ .location = from_abs_loc }, .{ .location = to_abs_loc }, null);
    try encoder.bindFixup(.relative_words, .{ .location = from_rel_loc }, .{ .location = to_rel_loc }, 0);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    // Finalize the buffer by applying fixups
    try map.finalizeBuffer(&linker_map, buf);

    // Check results
    const words: [*]const u64 = @ptrCast(buf.ptr);

    // Absolute fixup: words[0] should now hold the address of words[2]
    const expected_abs_addr = @intFromPtr(&words[2]);
    try testing.expectEqual(expected_abs_addr, words[0]);

    // Relative fixup: words[1] should contain a relative offset.
    // The jump is from words[1] to words[3], which is 2 words forward (16 bytes).
    // The relative offset is calculated in words.
    const expected_relative_val: i16 = 2;
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFF0000) | @as(u16, @bitCast(expected_relative_val)), words[1]);

    try testing.expectEqual(@as(u64, 0xAAAAAAAAAAAAAAA), words[2]);
    try testing.expectEqual(@as(u64, 0xBBBBBBBBBBBBBBBB), words[3]);
}

test "finalize buffer with unresolvable fixups" {
    const gpa = std.testing.allocator;
    const region_id = bin.RegionId.fromInt(1);
    var map = bin.LocationMap.init(gpa, region_id);
    defer map.deinit();

    var linker_map = bin.LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try bin.Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // A known location that needs a fixup from an unknown one.
    const from_known_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0)); // Placeholder for absolute address
    const from_known_loc = encoder.localLocationId(bin.RegionId.fromInt(1));
    try encoder.registerLocation(from_known_loc);
    try encoder.bindLocation(from_known_loc, from_known_rel);

    // An unknown location that will be resolved by the linker.
    // We create it in a different "region" to simulate an external reference.
    const to_unknown_loc = bin.Location.from(
        bin.RegionId.fromInt(99),
        bin.RegionId.fromInt(100),
    );
    try encoder.registerLocation(to_unknown_loc); // Register in the map, but never bind an address.

    // Bind a fixup from the known location to the unknown one.
    try encoder.bindFixup(.absolute, .{ .location = from_known_loc }, .{ .location = to_unknown_loc }, null);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    // Finalize. This should move the unresolved fixup to the linker_map.
    try map.finalizeBuffer(&linker_map, buf);

    try testing.expectEqual(@as(usize, 1), linker_map.unbound.count());

    // The unbound location should be the one we never provided an address for.
    const unbound_loc = linker_map.unbound.get(to_unknown_loc).?;
    try testing.expect(to_unknown_loc.eql(unbound_loc.identity));
    try testing.expectEqual(@as(usize, 1), unbound_loc.fixups.count());

    var it = unbound_loc.fixups.iterator();
    const fixup = it.next().?.key_ptr;

    try testing.expect(fixup.kind == .absolute);
    try testing.expect(fixup.basis == .to); // The 'to' part was unknown
    const expected_other_addr = AllocWriter.RelativeAddress.fromPtr(buf, &buf[from_known_rel.toInt()]);
    try testing.expect(fixup.other == expected_other_addr);
}

test "finalize buffer with absolute fixup and bit offset" {
    const gpa = std.testing.allocator;
    const region_id = bin.RegionId.fromInt(1);
    var map = bin.LocationMap.init(gpa, region_id);
    defer map.deinit();

    var linker_map = bin.LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try bin.Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // A pointer location with some pre-existing tag data in the low bits
    const from_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0b101)); // Initial value with tag
    const from_loc = encoder.localLocationId(bin.RegionId.fromInt(1));
    try encoder.registerLocation(from_loc);
    try encoder.bindLocation(from_loc, from_rel);

    // Pad to a different address
    try encoder.writeValue(@as(u64, 0));

    // The target data
    const to_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xCAFE));
    const to_loc = encoder.localLocationId(bin.RegionId.fromInt(2));
    try encoder.registerLocation(to_loc);
    try encoder.bindLocation(to_loc, to_rel);

    // Bind a fixup for a 48-bit pointer, at bit offset 16.
    try encoder.bindFixup(.absolute, .{ .location = from_loc }, .{ .location = to_loc }, 16);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    try map.finalizeBuffer(&linker_map, buf);

    const words: [*]const u64 = @ptrCast(buf.ptr);
    const to_ptr_addr = @intFromPtr(&words[2]);

    // The `finalizeBuffer` logic for absolute fixup with bit offset uses a 48-bit value.
    const addr_48bit = @as(u48, @truncate(to_ptr_addr));

    const expected_val = (@as(u64, addr_48bit) << 16) | 0b101;

    try testing.expectEqual(expected_val, words[0]);
}
