const std = @import("std");
const mem = std.mem;

const ast = @import("ast.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const source = try readFile(allocator);
    defer allocator.free(source);

    var nodes = try ast.parse(allocator, .{ .source = source });
    defer ast.AstNode.deinitSlice(allocator, nodes);

    // const stderr = std.io.getStdErr().writer();
    // try ast.ast_nodes_reprint_source(nodes, stderr);

    // consider using cranelift instead?
    var llvm = @import("llvm.zig").init(allocator);
    defer llvm.deinit();
    llvm.compile(nodes);
}

fn readFile(allocator: mem.Allocator) ![]const u8 {
    // get a list of program args
    var args = std.process.args();
    defer args.deinit();
    _ = args.skip();

    // get the second param (filename), default to program.b if none
    const filename = args.next() orelse blk: {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("No argument found, opening default file \"program.b\"\n", .{});
        break :blk "program.b";
    };

    // read the brainfuck program into memory
    return std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
}
