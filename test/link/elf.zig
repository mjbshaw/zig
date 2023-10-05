//! Here we test our ELF linker for correctness and functionality.
//! Currently, we support linking x86_64 Linux, but in the future we
//! will progressively relax those to exercise more combinations.

pub fn build(b: *Build) void {
    const elf_step = b.step("test-elf", "Run ELF tests");
    b.default_step = elf_step;

    const musl_target = CrossTarget{
        .cpu_arch = .x86_64, // TODO relax this once ELF linker is able to handle other archs
        .os_tag = .linux,
        .abi = .musl,
    };

    // Exercise linker with self-hosted backend (no LLVM)
    // elf_step.dependOn(testLinkingZig(b, .{ .use_llvm = false }));

    // Exercise linker with LLVM backend
    elf_step.dependOn(testCommonSymbols(b, .{ .target = musl_target }));
    elf_step.dependOn(testCommonSymbolsInArchive(b, .{ .target = musl_target }));
    elf_step.dependOn(testEmptyObject(b, .{ .target = musl_target }));
    elf_step.dependOn(testGcSections(b, .{ .target = musl_target }));
    elf_step.dependOn(testLinkingC(b, .{ .target = musl_target }));
    elf_step.dependOn(testLinkingCpp(b, .{ .target = musl_target }));
    elf_step.dependOn(testLinkingZig(b, .{ .target = musl_target }));
    elf_step.dependOn(testTlsStatic(b, .{ .target = musl_target }));
}

fn testCommonSymbols(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "common-symbols", opts);

    const exe = addExecutable(b, opts);
    addCSourceBytes(exe,
        \\int foo;
        \\int bar;
        \\int baz = 42;
    , &.{"-fcommon"});
    addCSourceBytes(exe,
        \\#include<stdio.h>
        \\int foo;
        \\int bar = 5;
        \\int baz;
        \\int main() {
        \\  printf("%d %d %d\n", foo, bar, baz);
        \\}
    , &.{"-fcommon"});
    exe.is_linking_libc = true;

    const run = addRunArtifact(exe);
    run.expectStdOutEqual("0 5 42\n");
    test_step.dependOn(&run.step);

    return test_step;
}

fn testCommonSymbolsInArchive(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "common-symbols-in-archive", opts);

    const a_o = addObject(b, opts);
    addCSourceBytes(a_o,
        \\#include <stdio.h>
        \\int foo;
        \\int bar;
        \\extern int baz;
        \\__attribute__((weak)) int two();
        \\int main() {
        \\  printf("%d %d %d %d\n", foo, bar, baz, two ? two() : -1);
        \\}
    , &.{"-fcommon"});
    a_o.is_linking_libc = true;

    const b_o = addObject(b, opts);
    addCSourceBytes(b_o, "int foo = 5;", &.{"-fcommon"});

    {
        const c_o = addObject(b, opts);
        addCSourceBytes(c_o,
            \\int bar;
            \\int two() { return 2; }
        , &.{"-fcommon"});

        const d_o = addObject(b, opts);
        addCSourceBytes(d_o, "int baz;", &.{"-fcommon"});

        const lib = addStaticLibrary(b, opts);
        lib.addObject(b_o);
        lib.addObject(c_o);
        lib.addObject(d_o);

        const exe = addExecutable(b, opts);
        exe.addObject(a_o);
        exe.linkLibrary(lib);
        exe.is_linking_libc = true;

        const run = addRunArtifact(exe);
        run.expectStdOutEqual("5 0 0 -1\n");
        test_step.dependOn(&run.step);
    }

    {
        const e_o = addObject(b, opts);
        addCSourceBytes(e_o,
            \\int bar = 0;
            \\int baz = 7;
            \\int two() { return 2; }
        , &.{"-fcommon"});

        const lib = addStaticLibrary(b, opts);
        lib.addObject(b_o);
        lib.addObject(e_o);

        const exe = addExecutable(b, opts);
        exe.addObject(a_o);
        exe.linkLibrary(lib);
        exe.is_linking_libc = true;

        const run = addRunArtifact(exe);
        run.expectStdOutEqual("5 0 7 2\n");
        test_step.dependOn(&run.step);
    }

    return test_step;
}

fn testEmptyObject(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "empty-object", opts);

    const exe = addExecutable(b, opts);
    addCSourceBytes(exe, "int main() { return 0; }", &.{});
    addCSourceBytes(exe, "", &.{});
    exe.is_linking_libc = true;

    const run = addRunArtifact(exe);
    run.expectExitCode(0);
    test_step.dependOn(&run.step);

    return test_step;
}

fn testGcSections(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "gc-sections", opts);

    const obj = addObject(b, opts);
    addCppSourceBytes(obj,
        \\#include <stdio.h>
        \\int two() { return 2; }
        \\int live_var1 = 1;
        \\int live_var2 = two();
        \\int dead_var1 = 3;
        \\int dead_var2 = 4;
        \\void live_fn1() {}
        \\void live_fn2() { live_fn1(); }
        \\void dead_fn1() {}
        \\void dead_fn2() { dead_fn1(); }
        \\int main() {
        \\  printf("%d %d\n", live_var1, live_var2);
        \\  live_fn2();
        \\}
    , &.{});
    obj.link_function_sections = true;
    obj.link_data_sections = true;
    obj.is_linking_libc = true;
    obj.is_linking_libcpp = true;

    {
        const exe = addExecutable(b, opts);
        exe.addObject(obj);
        exe.link_gc_sections = false;
        exe.is_linking_libc = true;
        exe.is_linking_libcpp = true;

        const run = addRunArtifact(exe);
        run.expectStdOutEqual("1 2\n");
        test_step.dependOn(&run.step);

        const check = exe.checkObject();
        check.checkInSymtab();
        check.checkContains("live_var1");
        check.checkInSymtab();
        check.checkContains("live_var2");
        check.checkInSymtab();
        check.checkContains("dead_var1");
        check.checkInSymtab();
        check.checkContains("dead_var2");
        check.checkInSymtab();
        check.checkContains("live_fn1");
        check.checkInSymtab();
        check.checkContains("live_fn2");
        check.checkInSymtab();
        check.checkContains("dead_fn1");
        check.checkInSymtab();
        check.checkContains("dead_fn2");
        test_step.dependOn(&check.step);
    }

    {
        const exe = addExecutable(b, opts);
        exe.addObject(obj);
        exe.link_gc_sections = true;
        exe.is_linking_libc = true;
        exe.is_linking_libcpp = true;

        const run = addRunArtifact(exe);
        run.expectStdOutEqual("1 2\n");
        test_step.dependOn(&run.step);

        const check = exe.checkObject();
        check.checkInSymtab();
        check.checkContains("live_var1");
        check.checkInSymtab();
        check.checkContains("live_var2");
        check.checkInSymtab();
        check.checkNotPresent("dead_var1");
        check.checkInSymtab();
        check.checkNotPresent("dead_var2");
        check.checkInSymtab();
        check.checkContains("live_fn1");
        check.checkInSymtab();
        check.checkContains("live_fn2");
        check.checkInSymtab();
        check.checkNotPresent("dead_fn1");
        check.checkInSymtab();
        check.checkNotPresent("dead_fn2");
        test_step.dependOn(&check.step);
    }

    return test_step;
}

fn testLinkingC(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "linking-c", opts);

    const exe = addExecutable(b, opts);
    addCSourceBytes(exe,
        \\#include <stdio.h>
        \\int main() {
        \\  printf("Hello World!\n");
        \\  return 0;
        \\}
    , &.{});
    exe.is_linking_libc = true;

    const run = addRunArtifact(exe);
    run.expectStdOutEqual("Hello World!\n");
    test_step.dependOn(&run.step);

    const check = exe.checkObject();
    check.checkStart();
    check.checkExact("header");
    check.checkExact("type EXEC");
    check.checkStart();
    check.checkExact("section headers");
    check.checkNotPresent("name .dynamic");
    test_step.dependOn(&check.step);

    return test_step;
}

fn testLinkingCpp(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "linking-cpp", opts);

    const exe = addExecutable(b, opts);
    addCppSourceBytes(exe,
        \\#include <iostream>
        \\int main() {
        \\  std::cout << "Hello World!" << std::endl;
        \\  return 0;
        \\}
    , &.{});
    exe.is_linking_libc = true;
    exe.is_linking_libcpp = true;

    const run = addRunArtifact(exe);
    run.expectStdOutEqual("Hello World!\n");
    test_step.dependOn(&run.step);

    const check = exe.checkObject();
    check.checkStart();
    check.checkExact("header");
    check.checkExact("type EXEC");
    check.checkStart();
    check.checkExact("section headers");
    check.checkNotPresent("name .dynamic");
    test_step.dependOn(&check.step);

    return test_step;
}

fn testLinkingZig(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "linking-zig-static", opts);

    const exe = addExecutable(b, opts);
    addZigSourceBytes(exe,
        \\pub fn main() void {
        \\    @import("std").debug.print("Hello World!\n", .{});
        \\}
    );

    const run = addRunArtifact(exe);
    run.expectStdErrEqual("Hello World!\n");
    test_step.dependOn(&run.step);

    const check = exe.checkObject();
    check.checkStart();
    check.checkExact("header");
    check.checkExact("type EXEC");
    check.checkStart();
    check.checkExact("section headers");
    check.checkNotPresent("name .dynamic");
    test_step.dependOn(&check.step);

    return test_step;
}

fn testTlsStatic(b: *Build, opts: Options) *Step {
    const test_step = addTestStep(b, "tls-static", opts);

    const exe = addExecutable(b, opts);
    addCSourceBytes(exe,
        \\#include <stdio.h>
        \\_Thread_local int a = 10;
        \\_Thread_local int b;
        \\_Thread_local char c = 'a';
        \\int main(int argc, char* argv[]) {
        \\  printf("%d %d %c\n", a, b, c);
        \\  a += 1;
        \\  b += 1;
        \\  c += 1;
        \\  printf("%d %d %c\n", a, b, c);
        \\  return 0;
        \\}
    , &.{});
    exe.is_linking_libc = true;

    const run = addRunArtifact(exe);
    run.expectStdOutEqual(
        \\10 0 a
        \\11 1 b
        \\
    );
    test_step.dependOn(&run.step);

    return test_step;
}

const Options = struct {
    target: CrossTarget = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    optimize: std.builtin.OptimizeMode = .Debug,
    use_llvm: bool = true,
};

fn addTestStep(b: *Build, comptime prefix: []const u8, opts: Options) *Step {
    const target = opts.target.zigTriple(b.allocator) catch @panic("OOM");
    const optimize = @tagName(opts.optimize);
    const use_llvm = if (opts.use_llvm) "llvm" else "no-llvm";
    const name = std.fmt.allocPrint(b.allocator, "test-elf-" ++ prefix ++ "-{s}-{s}-{s}", .{
        target,
        optimize,
        use_llvm,
    }) catch @panic("OOM");
    return b.step(name, "");
}

fn addExecutable(b: *Build, opts: Options) *Compile {
    return b.addExecutable(.{
        .name = "test",
        .target = opts.target,
        .optimize = opts.optimize,
        .use_llvm = opts.use_llvm,
        .use_lld = false,
    });
}

fn addObject(b: *Build, opts: Options) *Compile {
    return b.addObject(.{
        .name = "a.o",
        .target = opts.target,
        .optimize = opts.optimize,
        .use_llvm = opts.use_llvm,
        .use_lld = false,
    });
}

fn addStaticLibrary(b: *Build, opts: Options) *Compile {
    return b.addStaticLibrary(.{
        .name = "a.a",
        .target = opts.target,
        .optimize = opts.optimize,
        .use_llvm = opts.use_llvm,
        .use_lld = true,
    });
}

fn addRunArtifact(comp: *Compile) *Run {
    const b = comp.step.owner;
    const run = b.addRunArtifact(comp);
    run.skip_foreign_checks = true;
    return run;
}

fn addZigSourceBytes(comp: *Compile, comptime bytes: []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.zig", bytes);
    file.addStepDependencies(&comp.step);
    comp.root_src = file;
}

fn addCSourceBytes(comp: *Compile, comptime bytes: []const u8, flags: []const []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.c", bytes);
    comp.addCSourceFile(.{ .file = file, .flags = flags });
}

fn addCppSourceBytes(comp: *Compile, comptime bytes: []const u8, flags: []const []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.cpp", bytes);
    comp.addCSourceFile(.{ .file = file, .flags = flags });
}

fn addAsmSourceBytes(comp: *Compile, comptime bytes: []const u8) void {
    const b = comp.step.owner;
    const file = WriteFile.create(b).add("a.s", bytes ++ "\n");
    comp.addAssemblyFile(file);
}

const std = @import("std");

const Build = std.Build;
const Compile = Step.Compile;
const CrossTarget = std.zig.CrossTarget;
const LazyPath = Build.LazyPath;
const Run = Step.Run;
const Step = Build.Step;
const WriteFile = Step.WriteFile;