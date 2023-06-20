const std = @import("std");
const mem = std.mem;

const max_program_size: usize = 16 * 1024;
const memory_size: usize = 32 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // open the program file
    const program = readFile(allocator) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Failed to open program file: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(program);

    run(allocator, program) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error running program: {}\n", .{err});
        std.process.exit(1);
    };
}

// this is fucked i think, this is why i wrote the compiler instead
fn run(allocator: mem.Allocator, program: []const u8) !void {
    // allocate tape
    var tape = try allocator.alloc(i8, memory_size);
    defer allocator.free(tape);
    @memset(tape, 0);

    // allocate loop stack, this is how many loops deep we can evaluate
    var loops = try allocator.alloc(usize, 256);
    defer allocator.free(loops);
    @memset(loops, 0);

    var ip: usize = 0; // instruction pointer
    var lp: usize = 0; // loop pointer
    var cp: usize = 0; // cell pointer

    while (ip < program.len) {
        switch (program[ip]) {
            '+' => tape[cp] +%= 1,
            '-' => tape[cp] -%= 1,
            '>' => cp += 1,
            '<' => cp -= 1,
            '.' => {
                const stdout = std.io.getStdOut().writer();
                try stdout.writeByte(@bitCast(u8, tape[cp]));
            },
            ',' => {
                const stdin = std.io.getStdIn().reader();
                tape[cp] = @bitCast(i8, try stdin.readByte());
            },
            '[' => {
                // if we aren't in the loop then enter it
                if (loops[lp] != ip) {
                    lp += 1;
                    loops[lp] = ip;
                }
                ip += 1;

                if (tape[cp] != 0) {
                    continue;
                } else {
                    // look for exiting bracket
                    var depth: usize = 1;
                    while (depth != 0) {
                        ip += 1;
                        switch (program[ip]) {
                            '[' => depth += 1,
                            ']' => depth -= 1,
                            else => {},
                        }
                    }
                    lp -= 1;
                }
            },
            ']' => {
                // return to start of loop, we exit the loop in the '[' case
                ip = loops[lp];
                continue;
            },
            else => {},
        }
        ip += 1;
    }
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
    return std.fs.cwd().readFileAlloc(allocator, filename, max_program_size);
}
