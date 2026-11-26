const std = @import("std");

/// A lock-free, allocation-free Single-Producer Single-Consumer (SPSC) ring buffer.
/// Capacity must be a power of two for branchless index wrapping.
pub fn SpscRingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0 and std.math.isPowerOfTwo(capacity));
    }

    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init() Self {
            return .{};
        }

        /// Number of readable items currently in the buffer.
        pub fn readable(self: *const Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return h -% t;
        }

        /// Number of available slots for writing.
        pub fn writable(self: *const Self) usize {
            return capacity - self.readable();
        }

        /// Push a single item into the ring buffer.
        /// Returns true on success, false if the buffer is full.
        pub fn push(self: *Self, item: T) bool {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);

            if (h -% t >= capacity) {
                return false;
            }

            self.buffer[h & mask] = item;
            self.head.store(h +% 1, .release);
            return true;
        }

        /// Inspect the front item without consuming it (consumer-thread only).
        pub fn peek(self: *const Self) ?T {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            if (h == t) {
                return null;
            }
            return self.buffer[t & mask];
        }

        /// Pop a single item from the ring buffer.
        /// Returns null if the buffer is empty.
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);

            if (h == t) {
                return null;
            }

            const item = self.buffer[t & mask];
            self.tail.store(t +% 1, .release);
            return item;
        }

        /// Push multiple items into the buffer. Returns count of items written.
        pub fn pushSlice(self: *Self, items: []const T) usize {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);

            const space = capacity - (h -% t);
            const count = @min(items.len, space);
            if (count == 0) return 0;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                self.buffer[(h +% i) & mask] = items[i];
            }

            self.head.store(h +% count, .release);
            return count;
        }

        /// Pop multiple items from the buffer. Returns count of items read.
        pub fn popSlice(self: *Self, dest: []T) usize {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);

            const available = h -% t;
            const count = @min(dest.len, available);
            if (count == 0) return 0;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                dest[i] = self.buffer[(t +% i) & mask];
            }

            self.tail.store(t +% count, .release);
            return count;
        }
    };
}

test "SpscRingBuffer basic operations" {
    var rb = SpscRingBuffer(u32, 4).init();

    try std.testing.expectEqual(@as(usize, 0), rb.readable());
    try std.testing.expectEqual(@as(usize, 4), rb.writable());
    try std.testing.expect(rb.pop() == null);

    try std.testing.expect(rb.push(10));
    try std.testing.expect(rb.push(20));
    try std.testing.expectEqual(@as(usize, 2), rb.readable());

    try std.testing.expectEqual(@as(?u32, 10), rb.pop());
    try std.testing.expectEqual(@as(?u32, 20), rb.pop());
    try std.testing.expect(rb.pop() == null);

    // Fill to capacity
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expect(rb.push(4));
    try std.testing.expect(!rb.push(5)); // full

    try std.testing.expectEqual(@as(?u32, 1), rb.pop());
    try std.testing.expect(rb.push(5)); // now space available
}

test "SpscRingBuffer slice batching" {
    var rb = SpscRingBuffer(u8, 8).init();

    const input = [_]u8{ 1, 2, 3, 4, 5 };
    const pushed = rb.pushSlice(&input);
    try std.testing.expectEqual(@as(usize, 5), pushed);

    var output: [8]u8 = undefined;
    const popped = rb.popSlice(output[0..3]);
    try std.testing.expectEqual(@as(usize, 3), popped);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, output[0..3]);

    // Wrap-around push
    const input2 = [_]u8{ 6, 7, 8, 9, 10 };
    const pushed2 = rb.pushSlice(&input2);
    try std.testing.expectEqual(@as(usize, 5), pushed2);

    const popped2 = rb.popSlice(&output);
    try std.testing.expectEqual(@as(usize, 7), popped2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5, 6, 7, 8, 9, 10 }, output[0..7]);
}

test "SpscRingBuffer threaded producer-consumer" {
    const BufferType = SpscRingBuffer(usize, 1024);
    var rb = BufferType.init();

    const total_items: usize = 20_000;

    const Producer = struct {
        fn run(buf: *BufferType) void {
            var i: usize = 0;
            while (i < total_items) {
                if (buf.push(i)) {
                    i += 1;
                } else {
                    std.Thread.yield() catch |err| {
                        std.log.warn("producer yield: {s}", .{@errorName(err)});
                    };
                }
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Producer.run, .{&rb});

    var received: usize = 0;
    while (received < total_items) {
        if (rb.pop()) |val| {
            try std.testing.expectEqual(received, val);
            received += 1;
        } else {
            std.Thread.yield() catch |err| {
                std.log.warn("consumer yield: {s}", .{@errorName(err)});
            };
        }
    }

    thread.join();
}
