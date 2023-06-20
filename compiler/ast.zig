const std = @import("std");
const mem = std.mem;

/// Primitive type used in Brainfuck for all values
pub const Cell = i8;

/// Span that stores where in the source code particular tokens where found
pub const Span = struct {
    start: usize,
    end: usize,

    const Self = @This();

    pub fn init(start: usize, end: usize) Self {
        return .{ .start = start, .end = end };
    }

    pub fn initSingle(start: usize) Self {
        return .{ .start = start, .end = start + 1 };
    }
};

pub const AstNode = union(enum) {
    const Self = @This();

    increment: struct {
        amount: Cell,
        offset: isize,
        span: ?Span,
    },
    increment_ptr: struct {
        amount: Cell,
        span: ?Span,
    },
    write: struct { span: ?Span },
    read: struct {
        span: ?Span,
    },
    loop: struct {
        children: []Self,
        span: ?Span,
    },

    pub fn deinitSlice(allocator: mem.Allocator, nodes: []Self) void {
        for (nodes) |node| {
            switch (node) {
                AstNode.loop => |loop| {
                    Self.deinitSlice(allocator, loop.children);
                },
                else => {},
            }
        }
        allocator.free(nodes);
    }
};

pub const ParseOptions = struct {
    source: []const u8,
    diagnostics: ?*Diagnostics = null,

    pub const Diagnostics = struct {
        location: Span,
    };
};

pub const ParseError = error{ ExpectedLoopClose, UnexpectedLoopOpen } || mem.Allocator.Error;

pub fn parse(allocator: mem.Allocator, args: ParseOptions) ![]AstNode {
    var dummy_diags: ParseOptions.Diagnostics = undefined;
    var diags = args.diagnostics orelse &dummy_diags;

    const AstNodeList = std.ArrayList(AstNode);
    var nodes = AstNodeList.init(allocator);

    const LoopTuple = std.meta.Tuple(&.{ AstNodeList, usize });
    var loops = std.ArrayList(LoopTuple).init(allocator);
    defer loops.deinit();

    for (args.source, 0..) |c, idx| {
        switch (c) {
            '+' => {
                try nodes.append(.{ .increment = .{ .amount = 1, .offset = 0, .span = Span.initSingle(idx) } });
            },
            '-' => {
                try nodes.append(.{ .increment = .{ .amount = -1, .offset = 0, .span = Span.initSingle(idx) } });
            },
            '>' => {
                try nodes.append(.{ .increment_ptr = .{ .amount = 1, .span = Span.initSingle(idx) } });
            },
            '<' => {
                try nodes.append(.{ .increment_ptr = .{ .amount = -1, .span = Span.initSingle(idx) } });
            },
            '.' => {
                try nodes.append(.{ .write = .{ .span = Span.initSingle(idx) } });
            },
            ',' => {
                try nodes.append(.{ .read = .{ .span = Span.initSingle(idx) } });
            },
            '[' => {
                try loops.append(.{ nodes, idx });
                nodes = AstNodeList.init(allocator);
            },
            ']' => {
                if (loops.popOrNull()) |loop| {
                    var parent_nodes = loop[0];
                    const start = loop[1];
                    try parent_nodes.append(.{ .loop = .{ .children = try nodes.toOwnedSlice(), .span = Span.init(start, idx) } });
                    nodes = parent_nodes;
                } else {
                    diags.location = Span.initSingle(idx);
                    return error.UnexpectedLoopOpen;
                }
            },
            else => {},
        }
    }

    // check if there are any loops left
    if (loops.popOrNull()) |loop| {
        const start = loop[1];
        diags.location = Span.initSingle(start);
        return error.ExpectedLoopClose;
    }

    return try nodes.toOwnedSlice();
}

pub fn ast_nodes_reprint_source(nodes: []AstNode, writer: anytype) !void {
    for (nodes) |node| {
        switch (node) {
            AstNode.increment => |inc| try writer.writeByte(if (inc.amount > 0) '+' else '-'),
            AstNode.increment_ptr => |inc| try writer.writeByte(if (inc.amount > 0) '>' else '<'),
            AstNode.write => |_| try writer.writeByte('.'),
            AstNode.read => |_| try writer.writeByte(','),
            AstNode.loop => |loop| {
                try writer.writeByte('[');
                try ast_nodes_reprint_source(loop.children, writer);
                try writer.writeByte(']');
            },
        }
    }
}
