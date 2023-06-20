const std = @import("std");
const ast = @import("ast.zig");

const mem = std.mem;
const Cell = ast.Cell;
const AstNode = ast.AstNode;

const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/TargetMachine.h");
});

allocator: mem.Allocator,

ctx: c.LLVMContextRef,
module: c.LLVMModuleRef,
builder: c.LLVMBuilderRef,
functions: Functions,
tape: c.LLVMValueRef,
head: c.LLVMValueRef,

loop_lbl_count: usize = 0,

const Functions = struct {
    calloc: c.LLVMValueRef,
    getchar: c.LLVMValueRef,
    putchar: c.LLVMValueRef,
    main: c.LLVMValueRef,
};

const Self = @This();

pub fn init(allocator: mem.Allocator) Self {
    var self: Self = undefined;
    self.allocator = allocator;

    c.LLVMInitializeAllTargetInfos();
    c.LLVMInitializeAllTargets();
    c.LLVMInitializeAllTargetMCs();
    c.LLVMInitializeAllAsmParsers();
    c.LLVMInitializeAllAsmPrinters();

    self.ctx = c.LLVMContextCreate();
    self.module = c.LLVMModuleCreateWithNameInContext("bf-zig", self.ctx);
    self.builder = c.LLVMCreateBuilderInContext(self.ctx);

    self.loop_lbl_count = 0;

    return self;
}

pub fn deinit(self: Self) void {
    c.LLVMDisposeBuilder(self.builder);
    c.LLVMDisposeModule(self.module);
    c.LLVMContextDispose(self.ctx);
}

fn build_preamble(self: *Self) void {
    const i64_type = c.LLVMInt64TypeInContext(self.ctx);
    const i32_type = c.LLVMInt32TypeInContext(self.ctx);
    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);

    // calloc function
    var calloc_params: [2]c.LLVMTypeRef = .{ i64_type, i64_type };
    const calloc_fn_type = c.LLVMFunctionType(i8_ptr_type, @ptrCast([*]c.LLVMTypeRef, &calloc_params[0]), 2, 0);
    self.functions.calloc = c.LLVMAddFunction(self.module, "calloc", calloc_fn_type);
    c.LLVMSetLinkage(self.functions.calloc, c.LLVMExternalLinkage);

    // getchar function
    const getchar_fn_type = c.LLVMFunctionType(i32_type, null, 0, 0);
    self.functions.getchar = c.LLVMAddFunction(self.module, "getchar", getchar_fn_type);
    c.LLVMSetLinkage(self.functions.getchar, c.LLVMExternalLinkage);

    // putchar function
    var putchar_params: [1]c.LLVMTypeRef = .{i32_type};
    const putchar_fn_type = c.LLVMFunctionType(i32_type, @ptrCast([*]c.LLVMTypeRef, &putchar_params[0]), 1, 0);
    self.functions.putchar = c.LLVMAddFunction(self.module, "putchar", putchar_fn_type);
    c.LLVMSetLinkage(self.functions.getchar, c.LLVMExternalLinkage);

    // main entry function
    const main_fn_type = c.LLVMFunctionType(i32_type, null, 0, 0);
    self.functions.main = c.LLVMAddFunction(self.module, "main", main_fn_type);
    c.LLVMSetLinkage(self.functions.main, c.LLVMExternalLinkage);

    // setup the main function
    const basic_block = c.LLVMAppendBasicBlockInContext(self.ctx, self.functions.main, "entry");
    c.LLVMPositionBuilderAtEnd(self.builder, basic_block);

    // allocate variables for the tape and the head pointer
    self.tape = c.LLVMBuildAlloca(self.builder, i8_ptr_type, "tape");
    self.head = c.LLVMBuildAlloca(self.builder, i8_ptr_type, "head");

    // create call to the alloc function
    const i64_member_count = c.LLVMConstInt(i64_type, 30_000, 0);
    const i64_element_size = c.LLVMConstInt(i64_type, 1, 0);

    // create alloc call
    const data_ptr = self.build_call(self.functions.calloc, &.{ i64_member_count, i64_element_size }, "calloc_ret");

    // set the return to our pointers
    _ = c.LLVMBuildStore(self.builder, data_ptr, self.tape);
    _ = c.LLVMBuildStore(self.builder, data_ptr, self.head);
}

fn build_instructions(self: *Self, nodes: []const AstNode) void {
    for (nodes) |node| {
        switch (node) {
            .increment => |inc| self.build_increment(inc.amount, inc.offset),
            .increment_ptr => |inc_ptr| self.build_increment_ptr(inc_ptr.amount),
            .write => |_| self.build_write(),
            .read => |_| self.build_read(),
            .loop => |loop| self.build_loop(loop.children),
        }
    }
}

fn build_increment(self: *Self, amount: Cell, offset: isize) void {
    _ = offset;

    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);
    const i8_amount = c.LLVMConstInt(i8_type, @bitCast(c_ulonglong, @intCast(c_longlong, amount)), 0);

    const head_load = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.head, "load_head");
    const head_val = c.LLVMBuildLoad2(self.builder, i8_type, head_load, "load_head_value");
    const result = c.LLVMBuildAdd(self.builder, head_val, i8_amount, "add_head_value");
    _ = c.LLVMBuildStore(self.builder, result, head_load);
}

fn build_increment_ptr(self: *Self, amount: Cell) void {
    const i32_type = c.LLVMInt32TypeInContext(self.ctx);
    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);
    const i32_amount = c.LLVMConstInt(i32_type, @bitCast(c_ulonglong, @intCast(c_longlong, amount)), 0);

    const head_load = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.head, "load_head");
    var indices: [1]c.LLVMValueRef = .{i32_amount};
    const result = c.LLVMBuildInBoundsGEP2(self.builder, i8_type, head_load, @ptrCast([*]c.LLVMValueRef, &indices[0]), indices.len, "add_head");
    _ = c.LLVMBuildStore(self.builder, result, self.head);
}

fn build_write(self: *Self) void {
    const i32_type = c.LLVMInt32TypeInContext(self.ctx);
    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);

    const putchar_c_ptr = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.head, "load_head");
    const putchar_c = c.LLVMBuildLoad2(self.builder, i8_type, putchar_c_ptr, "load_head_value");
    const putchar_sext = c.LLVMBuildSExt(self.builder, putchar_c, i32_type, "sext_head_value");
    _ = self.build_call(self.functions.putchar, &.{putchar_sext}, "putchar_ret");
}

fn build_read(self: *Self) void {
    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);

    const getchar_ret = self.build_call(self.functions.getchar, &.{}, "getchar_ret");
    const truncated = c.LLVMBuildTrunc(self.builder, getchar_ret, i8_type, "trunc_getchar_ret");

    const head_load = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.head, "load_head");
    _ = c.LLVMBuildStore(self.builder, truncated, head_load);
}

fn build_loop(self: *Self, nodes: []const AstNode) void {
    const loop_cond_lbl = std.fmt.allocPrintZ(self.allocator, "loop_cond_{}", .{self.loop_lbl_count}) catch @panic("OOM");
    defer self.allocator.free(loop_cond_lbl);
    const loop_body_lbl = std.fmt.allocPrintZ(self.allocator, "loop_body_{}", .{self.loop_lbl_count}) catch @panic("OOM");
    defer self.allocator.free(loop_body_lbl);
    const loop_exit_lbl = std.fmt.allocPrintZ(self.allocator, "loop_exit_{}", .{self.loop_lbl_count}) catch @panic("OOM");
    defer self.allocator.free(loop_exit_lbl);

    self.loop_lbl_count += 1;

    const loop_cond = c.LLVMAppendBasicBlockInContext(self.ctx, self.functions.main, loop_cond_lbl);
    const loop_body = c.LLVMAppendBasicBlockInContext(self.ctx, self.functions.main, loop_body_lbl);
    const loop_exit = c.LLVMAppendBasicBlockInContext(self.ctx, self.functions.main, loop_exit_lbl);

    _ = c.LLVMBuildBr(self.builder, loop_cond);
    _ = c.LLVMPositionBuilderAtEnd(self.builder, loop_cond);

    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);
    const i8_zero = c.LLVMConstInt(i8_type, 0, 0);

    const head_load = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.head, "load_head");
    const head_val = c.LLVMBuildLoad2(self.builder, i8_type, head_load, "load_head_value");
    const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, head_val, i8_zero, "loop_cond_cmp");

    // branch if cell == 0
    _ = c.LLVMBuildCondBr(self.builder, cmp, loop_exit, loop_body);
    c.LLVMPositionBuilderAtEnd(self.builder, loop_body);

    // TODO: use a stack instead
    // recursively build inside the body
    self.build_instructions(nodes);

    _ = c.LLVMBuildBr(self.builder, loop_cond);
    c.LLVMPositionBuilderAtEnd(self.builder, loop_exit);
}

fn build_postamble(self: *Self) void {
    const i32_type = c.LLVMInt32TypeInContext(self.ctx);
    const i8_type = c.LLVMInt8TypeInContext(self.ctx);
    const i8_ptr_type = c.LLVMPointerType(i8_type, 0);
    const i32_zero = c.LLVMConstInt(i32_type, 0, 0);

    // free memory
    const tape_ptr = c.LLVMBuildLoad2(self.builder, i8_ptr_type, self.tape, "tape_load");
    _ = c.LLVMBuildFree(self.builder, tape_ptr);

    // return zero
    _ = c.LLVMBuildRet(self.builder, i32_zero);
}

fn build_call(self: *Self, func: c.LLVMValueRef, arguments: []const c.LLVMValueRef, name: [:0]const u8) c.LLVMValueRef {
    const fn_type = c.LLVMGlobalGetValueType(func);

    // make the name empty when the return value is void
    const call_name = blk: {
        const ty = c.LLVMGetReturnType(fn_type);
        const kind = c.LLVMGetTypeKind(ty);
        if (kind == c.LLVMVoidTypeKind)
            break :blk ""
        else
            break :blk name;
    };
    // null if args is empty
    var args = if (arguments.len == 0)
        null
    else
        @ptrCast([*]c.LLVMValueRef, &@constCast(arguments)[0]);

    // actually build the function call
    return c.LLVMBuildCall2(self.builder, fn_type, func, args, @intCast(c_uint, arguments.len), call_name);
}

fn write_to_file(self: *Self, filename: [:0]const u8) void {
    const triple = c.LLVMGetDefaultTargetTriple();
    const cpu = c.LLVMGetHostCPUName();
    const features = c.LLVMGetHostCPUFeatures();

    var target: c.LLVMTargetRef = undefined;
    var err: [*c]u8 = null;
    if (c.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
        std.debug.print("LLVMGetTargetFromTriple failed: {s}\n", .{err});
        c.LLVMDisposeMessage(err);
    }

    // c.LLVMDumpModule(self.module);

    const target_machine = c.LLVMCreateTargetMachine(target, triple, cpu, features, c.LLVMCodeGenLevelDefault, c.LLVMCodeModelDefault, c.LLVMRelocDefault);
    if (c.LLVMTargetMachineEmitToFile(target_machine, self.module, filename, c.LLVMObjectFile, &err) != 0) {
        std.debug.print("LLVMTargetMachineEmitToFile failed: {s}\n", .{err});
        c.LLVMDisposeMessage(err);
    }
}

pub fn compile(self: *Self, nodes: []const AstNode) void {
    self.build_preamble();
    self.build_instructions(nodes);
    self.build_postamble();

    // Check that the module is valid
    const err: [*c]u8 = undefined;
    if (c.LLVMVerifyModule(self.module, c.LLVMAbortProcessAction, null) != 0) {
        c.LLVMDisposeMessage(err);
    }

    // somehow emit an object?
    self.write_to_file("bf.o");
}
