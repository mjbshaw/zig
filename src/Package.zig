const Package = @This();

const builtin = @import("builtin");
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ascii = std.ascii;
const assert = std.debug.assert;
const log = std.log.scoped(.package);
const main = @import("main.zig");
const ThreadPool = std.Thread.Pool;
const WaitGroup = std.Thread.WaitGroup;

const Compilation = @import("Compilation.zig");
const Module = @import("Module.zig");
const Cache = std.Build.Cache;
const build_options = @import("build_options");
const Manifest = @import("Manifest.zig");

pub const Table = std.StringHashMapUnmanaged(*Package);

root_src_directory: Compilation.Directory,
/// Relative to `root_src_directory`. May contain path separators.
root_src_path: []const u8,
/// The dependency table of this module. Shared dependencies such as 'std', 'builtin', and 'root'
/// are not specified in every dependency table, but instead only in the table of `main_pkg`.
/// `Module.importFile` is responsible for detecting these names and using the correct package.
table: Table = .{},
/// Whether to free `root_src_directory` on `destroy`.
root_src_directory_owned: bool = false,

/// Allocate a Package. No references to the slices passed are kept.
pub fn create(
    gpa: Allocator,
    /// Null indicates the current working directory
    root_src_dir_path: ?[]const u8,
    /// Relative to root_src_dir_path
    root_src_path: []const u8,
) !*Package {
    const ptr = try gpa.create(Package);
    errdefer gpa.destroy(ptr);

    const owned_dir_path = if (root_src_dir_path) |p| try gpa.dupe(u8, p) else null;
    errdefer if (owned_dir_path) |p| gpa.free(p);

    const owned_src_path = try gpa.dupe(u8, root_src_path);
    errdefer gpa.free(owned_src_path);

    ptr.* = .{
        .root_src_directory = .{
            .path = owned_dir_path,
            .handle = if (owned_dir_path) |p| try fs.cwd().openDir(p, .{}) else fs.cwd(),
        },
        .root_src_path = owned_src_path,
        .root_src_directory_owned = true,
    };

    return ptr;
}

pub fn createWithDir(
    gpa: Allocator,
    directory: Compilation.Directory,
    /// Relative to `directory`. If null, means `directory` is the root src dir
    /// and is owned externally.
    root_src_dir_path: ?[]const u8,
    /// Relative to root_src_dir_path
    root_src_path: []const u8,
) !*Package {
    const ptr = try gpa.create(Package);
    errdefer gpa.destroy(ptr);

    const owned_src_path = try gpa.dupe(u8, root_src_path);
    errdefer gpa.free(owned_src_path);

    if (root_src_dir_path) |p| {
        const owned_dir_path = try directory.join(gpa, &[1][]const u8{p});
        errdefer gpa.free(owned_dir_path);

        ptr.* = .{
            .root_src_directory = .{
                .path = owned_dir_path,
                .handle = try directory.handle.openDir(p, .{}),
            },
            .root_src_directory_owned = true,
            .root_src_path = owned_src_path,
        };
    } else {
        ptr.* = .{
            .root_src_directory = directory,
            .root_src_directory_owned = false,
            .root_src_path = owned_src_path,
        };
    }
    return ptr;
}

/// Free all memory associated with this package. It does not destroy any packages
/// inside its table; the caller is responsible for calling destroy() on them.
pub fn destroy(pkg: *Package, gpa: Allocator) void {
    gpa.free(pkg.root_src_path);

    if (pkg.root_src_directory_owned) {
        // If root_src_directory.path is null then the handle is the cwd()
        // which shouldn't be closed.
        if (pkg.root_src_directory.path) |p| {
            gpa.free(p);
            pkg.root_src_directory.handle.close();
        }
    }

    pkg.deinitTable(gpa);
    gpa.destroy(pkg);
}

/// Only frees memory associated with the table.
pub fn deinitTable(pkg: *Package, gpa: Allocator) void {
    pkg.table.deinit(gpa);
}

pub fn add(pkg: *Package, gpa: Allocator, name: []const u8, package: *Package) !void {
    try pkg.table.ensureUnusedCapacity(gpa, 1);
    const name_dupe = try gpa.dupe(u8, name);
    pkg.table.putAssumeCapacityNoClobber(name_dupe, package);
}

/// Compute a readable name for the package. The returned name should be freed from gpa. This
/// function is very slow, as it traverses the whole package hierarchy to find a path to this
/// package. It should only be used for error output.
pub fn getName(target: *const Package, gpa: Allocator, mod: Module) ![]const u8 {
    // we'll do a breadth-first search from the root module to try and find a short name for this
    // module, using a DoublyLinkedList of module/parent pairs. note that the "parent" there is
    // just the first-found shortest path - a module may be children of arbitrarily many other
    // modules. This path may vary between executions due to hashmap iteration order, but that
    // doesn't matter too much.
    var node_arena = std.heap.ArenaAllocator.init(gpa);
    defer node_arena.deinit();
    const Parented = struct {
        parent: ?*const @This(),
        mod: *const Package,
    };
    const Queue = std.DoublyLinkedList(Parented);
    var to_check: Queue = .{};

    {
        const new = try node_arena.allocator().create(Queue.Node);
        new.* = .{ .data = .{ .parent = null, .mod = mod.root_pkg } };
        to_check.prepend(new);
    }

    if (mod.main_pkg != mod.root_pkg) {
        const new = try node_arena.allocator().create(Queue.Node);
        // TODO: once #12201 is resolved, we may want a way of indicating a different name for this
        new.* = .{ .data = .{ .parent = null, .mod = mod.main_pkg } };
        to_check.prepend(new);
    }

    // set of modules we've already checked to prevent loops
    var checked = std.AutoHashMap(*const Package, void).init(gpa);
    defer checked.deinit();

    const linked = while (to_check.pop()) |node| {
        const check = &node.data;

        if (checked.contains(check.mod)) continue;
        try checked.put(check.mod, {});

        if (check.mod == target) break check;

        var it = check.mod.table.iterator();
        while (it.next()) |kv| {
            var new = try node_arena.allocator().create(Queue.Node);
            new.* = .{ .data = .{
                .parent = check,
                .mod = kv.value_ptr.*,
            } };
            to_check.prepend(new);
        }
    } else {
        // this can happen for e.g. @cImport packages
        return gpa.dupe(u8, "<unnamed>");
    };

    // we found a path to the module! unfortunately, we can only traverse *up* it, so we have to put
    // all the names into a buffer so we can then print them in order.
    var names = std.ArrayList([]const u8).init(gpa);
    defer names.deinit();

    var cur: *const Parented = linked;
    while (cur.parent) |parent| : (cur = parent) {
        // find cur's name in parent
        var it = parent.mod.table.iterator();
        const name = while (it.next()) |kv| {
            if (kv.value_ptr.* == cur.mod) {
                break kv.key_ptr.*;
            }
        } else unreachable;
        try names.append(name);
    }

    // finally, print the names into a buffer!
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    try buf.writer().writeAll("root");
    var i: usize = names.items.len;
    while (i > 0) {
        i -= 1;
        try buf.writer().print(".{s}", .{names.items[i]});
    }

    return buf.toOwnedSlice();
}

pub const build_zig_basename = "build.zig";

/// Fetches a package and all of its dependencies recursively. Writes the
/// corresponding datastructures for the build runner into `dependencies_source`.
pub fn fetchAndAddDependencies(
    pkg: *Package,
    deps_pkg: *Package,
    arena: Allocator,
    thread_pool: *ThreadPool,
    http_client: *std.http.Client,
    directory: Compilation.Directory,
    global_cache_directory: Compilation.Directory,
    local_cache_directory: Compilation.Directory,
    dependencies_source: *std.ArrayList(u8),
    error_bundle: *std.zig.ErrorBundle.Wip,
    all_modules: *AllModules,
    root_prog_node: *std.Progress.Node,
    /// null for the root package
    this_hash: ?[]const u8,
) !void {
    const max_bytes = 10 * 1024 * 1024;
    const gpa = thread_pool.allocator;
    const build_zig_zon_bytes = directory.handle.readFileAllocOptions(
        arena,
        Manifest.basename,
        max_bytes,
        null,
        1,
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            // Handle the same as no dependencies.
            if (this_hash) |hash| {
                try dependencies_source.writer().print(
                    \\    pub const {} = struct {{
                    \\        pub const build_root = "{}";
                    \\        pub const build_zig = @import("{}");
                    \\        pub const deps: []const struct {{ []const u8, []const u8 }} = &.{{}};
                    \\    }};
                    \\
                , .{
                    std.zig.fmtId(hash),
                    std.zig.fmtEscapes(pkg.root_src_directory.path.?),
                    std.zig.fmtEscapes(hash),
                });
            } else {
                try dependencies_source.writer().writeAll(
                    \\pub const packages = struct {};
                    \\pub const root_deps: []const struct { []const u8, []const u8 } = &.{};
                    \\
                );
            }
            return;
        },
        else => |e| return e,
    };

    var ast = try std.zig.Ast.parse(gpa, build_zig_zon_bytes, .zon);
    defer ast.deinit(gpa);

    if (ast.errors.len > 0) {
        const file_path = try directory.join(arena, &.{Manifest.basename});
        try main.putAstErrorsIntoBundle(gpa, ast, file_path, error_bundle);
        return error.PackageFetchFailed;
    }

    var manifest = try Manifest.parse(gpa, ast);
    defer manifest.deinit(gpa);

    if (manifest.errors.len > 0) {
        const file_path = try directory.join(arena, &.{Manifest.basename});
        for (manifest.errors) |msg| {
            try Report.addErrorMessage(ast, file_path, error_bundle, 0, msg);
        }
        return error.PackageFetchFailed;
    }

    const report: Report = .{
        .ast = &ast,
        .directory = directory,
        .error_bundle = error_bundle,
    };

    for (manifest.dependencies.values()) |dep| {
        // If the hash is invalid, let errors happen later
        // We only want to add these for progress reporting
        const hash = dep.hash orelse continue;
        if (hash.len != hex_multihash_len) continue;
        const gop = try all_modules.getOrPut(gpa, hash[0..hex_multihash_len].*);
        if (!gop.found_existing) gop.value_ptr.* = null;
    }

    root_prog_node.setEstimatedTotalItems(all_modules.count());

    if (this_hash == null) {
        try dependencies_source.writer().writeAll("pub const packages = struct {\n");
    }

    for (manifest.dependencies.keys(), manifest.dependencies.values()) |name, *dep| {
        const sub_mod, const found_existing = try getCachedPackage(
            arena,
            global_cache_directory,
            dep.*,
            all_modules,
            root_prog_node,
        ) orelse .{
            try fetchAndUnpack(
                thread_pool,
                http_client,
                directory,
                global_cache_directory,
                dep,
                report,
                all_modules,
                root_prog_node,
                name,
            ),
            false,
        };

        assert(dep.hash != null);

        switch (sub_mod) {
            .zig_pkg => |sub_pkg| {
                if (!found_existing) {
                    try sub_pkg.fetchAndAddDependencies(
                        deps_pkg,
                        arena,
                        thread_pool,
                        http_client,
                        sub_pkg.root_src_directory,
                        global_cache_directory,
                        local_cache_directory,
                        dependencies_source,
                        error_bundle,
                        all_modules,
                        root_prog_node,
                        dep.hash.?,
                    );
                }

                try pkg.add(gpa, name, sub_pkg);
                if (deps_pkg.table.get(dep.hash.?)) |other_sub| {
                    // This should be the same package (and hence module) since it's the same hash
                    // TODO: dedup multiple versions of the same package
                    assert(other_sub == sub_pkg);
                } else {
                    try deps_pkg.add(gpa, dep.hash.?, sub_pkg);
                }
            },
            .non_zig_pkg => |sub_pkg| {
                if (!found_existing) {
                    try dependencies_source.writer().print(
                        \\    pub const {} = struct {{
                        \\        pub const build_root = "{}";
                        \\        pub const deps: []const struct {{ []const u8, []const u8 }} = &.{{}};
                        \\    }};
                        \\
                    , .{
                        std.zig.fmtId(dep.hash.?),
                        std.zig.fmtEscapes(sub_pkg.root_src_directory.path.?),
                    });
                }
            },
        }
    }

    if (this_hash) |hash| {
        try dependencies_source.writer().print(
            \\    pub const {} = struct {{
            \\        pub const build_root = "{}";
            \\        pub const build_zig = @import("{}");
            \\        pub const deps: []const struct {{ []const u8, []const u8 }} = &.{{
            \\
        , .{
            std.zig.fmtId(hash),
            std.zig.fmtEscapes(pkg.root_src_directory.path.?),
            std.zig.fmtEscapes(hash),
        });
        for (manifest.dependencies.keys(), manifest.dependencies.values()) |name, dep| {
            try dependencies_source.writer().print(
                "            .{{ \"{}\", \"{}\" }},\n",
                .{ std.zig.fmtEscapes(name), std.zig.fmtEscapes(dep.hash.?) },
            );
        }
        try dependencies_source.writer().writeAll(
            \\        };
            \\    };
            \\
        );
    } else {
        try dependencies_source.writer().writeAll(
            \\};
            \\
            \\pub const root_deps: []const struct { []const u8, []const u8 } = &.{
            \\
        );
        for (manifest.dependencies.keys(), manifest.dependencies.values()) |name, dep| {
            try dependencies_source.writer().print(
                "    .{{ \"{}\", \"{}\" }},\n",
                .{ std.zig.fmtEscapes(name), std.zig.fmtEscapes(dep.hash.?) },
            );
        }
        try dependencies_source.writer().writeAll("};\n");
    }
}

pub fn createFilePkg(
    gpa: Allocator,
    cache_directory: Compilation.Directory,
    basename: []const u8,
    contents: []const u8,
) !*Package {
    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_sub_path = "tmp" ++ fs.path.sep_str ++ Manifest.hex64(rand_int);
    {
        var tmp_dir = try cache_directory.handle.makeOpenPath(tmp_dir_sub_path, .{});
        defer tmp_dir.close();
        try tmp_dir.writeFile(basename, contents);
    }

    var hh: Cache.HashHelper = .{};
    hh.addBytes(build_options.version);
    hh.addBytes(contents);
    const hex_digest = hh.final();

    const o_dir_sub_path = "o" ++ fs.path.sep_str ++ hex_digest;
    try renameTmpIntoCache(cache_directory.handle, tmp_dir_sub_path, o_dir_sub_path);

    return createWithDir(gpa, cache_directory, o_dir_sub_path, basename);
}

const Report = struct {
    ast: *const std.zig.Ast,
    directory: Compilation.Directory,
    error_bundle: *std.zig.ErrorBundle.Wip,

    fn fail(
        report: Report,
        tok: std.zig.Ast.TokenIndex,
        comptime fmt_string: []const u8,
        fmt_args: anytype,
    ) error{ PackageFetchFailed, OutOfMemory } {
        const gpa = report.error_bundle.gpa;

        const file_path = try report.directory.join(gpa, &.{Manifest.basename});
        defer gpa.free(file_path);

        const msg = try std.fmt.allocPrint(gpa, fmt_string, fmt_args);
        defer gpa.free(msg);

        try addErrorMessage(report.ast.*, file_path, report.error_bundle, 0, .{
            .tok = tok,
            .off = 0,
            .msg = msg,
        });

        return error.PackageFetchFailed;
    }

    fn addErrorMessage(
        ast: std.zig.Ast,
        file_path: []const u8,
        eb: *std.zig.ErrorBundle.Wip,
        notes_len: u32,
        msg: Manifest.ErrorMessage,
    ) error{OutOfMemory}!void {
        const token_starts = ast.tokens.items(.start);
        const start_loc = ast.tokenLocation(0, msg.tok);

        try eb.addRootErrorMessage(.{
            .msg = try eb.addString(msg.msg),
            .src_loc = try eb.addSourceLocation(.{
                .src_path = try eb.addString(file_path),
                .span_start = token_starts[msg.tok],
                .span_end = @as(u32, @intCast(token_starts[msg.tok] + ast.tokenSlice(msg.tok).len)),
                .span_main = token_starts[msg.tok] + msg.off,
                .line = @as(u32, @intCast(start_loc.line)),
                .column = @as(u32, @intCast(start_loc.column)),
                .source_line = try eb.addString(ast.source[start_loc.line_start..start_loc.line_end]),
            }),
            .notes_len = notes_len,
        });
    }
};

const FetchLocation = union(enum) {
    /// The absolute path to a file or directory.
    /// This may be a file that requires unpacking (such as a .tar.gz),
    /// or the path to the root directory of a package.
    file: []const u8,
    http_request: std.Uri,

    pub fn init(gpa: Allocator, directory: Compilation.Directory, dep: Manifest.Dependency, report: Report) !FetchLocation {
        switch (dep.location) {
            .url => |url| {
                const uri = std.Uri.parse(url) catch |err| switch (err) {
                    error.UnexpectedCharacter => return report.fail(dep.location_tok, "failed to parse dependency location as URI", .{}),
                    else => return err,
                };
                if (ascii.eqlIgnoreCase(uri.scheme, "file")) {
                    return report.fail(dep.location_tok, "'file' scheme is not allowed for URLs. Use '.path' instead", .{});
                }
                return .{ .http_request = uri };
            },
            .path => |path| {
                const unescaped = try std.Uri.unescapeString(gpa, path);
                defer gpa.free(unescaped);
                const unnormalized_path = try unnormalizePath(gpa, unescaped);
                defer gpa.free(unnormalized_path);

                if (fs.path.isAbsolute(unnormalized_path)) {
                    return report.fail(dep.location_tok, "Absolute paths are not allowed. Use a relative path instead", .{});
                }

                const new_path = try fs.path.resolve(gpa, &.{ directory.path.?, unnormalized_path });

                return .{ .file = new_path };
            },
        }
    }

    pub fn deinit(f: *FetchLocation, gpa: Allocator) void {
        switch (f.*) {
            .file => |path| gpa.free(path),
            .http_request => {},
        }
        f.* = undefined;
    }

    pub fn fetch(
        f: FetchLocation,
        gpa: Allocator,
        root_dir: Compilation.Directory,
        http_client: *std.http.Client,
        dep: Manifest.Dependency,
        report: Report,
    ) !ReadableResource {
        switch (f) {
            .file => |file| {
                const is_dir = isDirectory(root_dir, file) catch |err| switch (err) {
                    error.FileNotFound => return report.fail(dep.location_tok, "File not found: {s}", .{file}),
                    else => return err,
                };

                const owned_path = try gpa.dupe(u8, file);
                errdefer gpa.free(owned_path);

                return .{
                    .path = owned_path,
                    .resource = if (is_dir)
                        .{ .directory = try fs.openIterableDirAbsolute(file, .{}) }
                    else
                        .{ .file = try fs.openFileAbsolute(file, .{}) },
                };
            },
            .http_request => |uri| {
                var h = std.http.Headers{ .allocator = gpa };
                defer h.deinit();

                var req = try http_client.request(.GET, uri, h, .{});
                errdefer req.deinit();

                try req.start(.{});
                try req.wait();

                if (req.response.status != .ok) {
                    return report.fail(dep.location_tok, "Expected response status '200 OK' got '{} {s}'", .{
                        @intFromEnum(req.response.status),
                        req.response.status.phrase() orelse "",
                    });
                }

                return .{
                    .path = try gpa.dupe(u8, uri.path),
                    .resource = .{ .http_request = req },
                };
            },
        }
    }
};

const ReadableResource = struct {
    path: []const u8,
    resource: union(enum) {
        file: fs.File,
        directory: fs.IterableDir,
        http_request: std.http.Client.Request,
    },

    /// Unpack the package into the global cache directory.
    /// If `ps` does not require unpacking (for example, if it is a directory), then no caching is performed.
    /// In either case, the hash is computed and returned along with the path to the package.
    pub fn unpack(
        rr: *ReadableResource,
        allocator: Allocator,
        thread_pool: *ThreadPool,
        global_cache_directory: Compilation.Directory,
        dep: Manifest.Dependency,
        report: Report,
        pkg_prog_node: *std.Progress.Node,
    ) !PackageLocation {
        switch (rr.resource) {
            .directory => {
                return .{
                    .hash = computePathHash(rr.path),
                    .dir_path = try allocator.dupe(u8, rr.path),
                };
            },
            inline .file, .http_request => |*r| {
                const s = fs.path.sep_str;
                const rand_int = std.crypto.random.int(u64);
                const tmp_dir_sub_path = "tmp" ++ s ++ Manifest.hex64(rand_int);

                const actual_hash = h: {
                    var tmp_directory: Compilation.Directory = d: {
                        const path = try global_cache_directory.join(allocator, &.{tmp_dir_sub_path});
                        errdefer allocator.free(path);

                        const iterable_dir = try global_cache_directory.handle.makeOpenPathIterable(tmp_dir_sub_path, .{});
                        errdefer iterable_dir.close();

                        break :d .{
                            .path = path,
                            .handle = iterable_dir.dir,
                        };
                    };
                    defer tmp_directory.closeAndFree(allocator);

                    const opt_content_length = try rr.getSize();

                    var prog_reader: ProgressReader(@TypeOf(r.reader())) = .{
                        .child_reader = r.reader(),
                        .prog_node = pkg_prog_node,
                        .unit = if (opt_content_length) |content_length| unit: {
                            const kib = content_length / 1024;
                            const mib = kib / 1024;
                            if (mib > 0) {
                                pkg_prog_node.setEstimatedTotalItems(@intCast(mib));
                                pkg_prog_node.setUnit("MiB");
                                break :unit .mib;
                            } else {
                                pkg_prog_node.setEstimatedTotalItems(@intCast(@max(1, kib)));
                                pkg_prog_node.setUnit("KiB");
                                break :unit .kib;
                            }
                        } else .any,
                    };
                    pkg_prog_node.context.refresh();

                    switch (try rr.getFileType(dep, report)) {
                        .@"tar.gz" => try unpackTarball(allocator, prog_reader, tmp_directory.handle, std.compress.gzip),
                        // I have not checked what buffer sizes the xz decompression implementation uses
                        // by default, so the same logic applies for buffering the reader as for gzip.
                        .@"tar.xz" => try unpackTarball(allocator, prog_reader, tmp_directory.handle, std.compress.xz),
                    }

                    // Unpack completed - stop showing amount as progress
                    pkg_prog_node.setEstimatedTotalItems(0);
                    pkg_prog_node.setCompletedItems(0);
                    pkg_prog_node.context.refresh();

                    // TODO: delete files not included in the package prior to computing the package hash.
                    // for example, if the ini file has directives to include/not include certain files,
                    // apply those rules directly to the filesystem right here. This ensures that files
                    // not protected by the hash are not present on the file system.

                    break :h try computePackageHash(thread_pool, .{ .dir = tmp_directory.handle });
                };

                const pkg_dir_sub_path = "p" ++ s ++ Manifest.hexDigest(actual_hash);
                const unpacked_path = try global_cache_directory.join(allocator, &.{pkg_dir_sub_path});
                errdefer allocator.free(unpacked_path);

                const relative_unpacked_path = try fs.path.relative(allocator, global_cache_directory.path.?, unpacked_path);
                defer allocator.free(relative_unpacked_path);
                try renameTmpIntoCache(global_cache_directory.handle, tmp_dir_sub_path, relative_unpacked_path);

                return .{
                    .hash = actual_hash,
                    .dir_path = unpacked_path,
                };
            },
        }
    }

    const FileType = enum {
        @"tar.gz",
        @"tar.xz",
    };

    pub fn getSize(rr: ReadableResource) !?u64 {
        switch (rr.resource) {
            // TODO: Handle case of chunked content-length
            .http_request => |req| return req.response.content_length,
            .file => |f| return (try f.metadata()).size(),
            .directory => unreachable,
        }
    }

    pub fn getFileType(rr: ReadableResource, dep: Manifest.Dependency, report: Report) !FileType {
        switch (rr.resource) {
            .file => {
                return fileTypeFromPath(rr.path) orelse
                    return report.fail(dep.location_tok, "Unknown file type", .{});
            },
            .directory => return error.IsDir,
            .http_request => |req| {
                const content_type = req.response.headers.getFirstValue("Content-Type") orelse
                    return report.fail(dep.location_tok, "Missing 'Content-Type' header", .{});

                // If the response has a different content type than the URI indicates, override
                // the previously assumed file type.
                return if (ascii.eqlIgnoreCase(content_type, "application/gzip") or
                    ascii.eqlIgnoreCase(content_type, "application/x-gzip") or
                    ascii.eqlIgnoreCase(content_type, "application/tar+gzip"))
                    .@"tar.gz"
                else if (ascii.eqlIgnoreCase(content_type, "application/x-xz"))
                    .@"tar.xz"
                else if (ascii.eqlIgnoreCase(content_type, "application/octet-stream")) ty: {
                    // support gitlab tarball urls such as https://gitlab.com/<namespace>/<project>/-/archive/<sha>/<project>-<sha>.tar.gz
                    // whose content-disposition header is: 'attachment; filename="<project>-<sha>.tar.gz"'
                    const content_disposition = req.response.headers.getFirstValue("Content-Disposition") orelse
                        return report.fail(dep.location_tok, "Missing 'Content-Disposition' header for Content-Type=application/octet-stream", .{});
                    break :ty getAttachmentType(content_disposition) orelse
                        return report.fail(dep.location_tok, "Unsupported 'Content-Disposition' header value: '{s}' for Content-Type=application/octet-stream", .{content_disposition});
                } else return report.fail(dep.location_tok, "Unrecognized value for 'Content-Type' header: {s}", .{content_type});
            },
        }
    }

    fn fileTypeFromPath(file_path: []const u8) ?FileType {
        return if (ascii.endsWithIgnoreCase(file_path, ".tar.gz"))
            .@"tar.gz"
        else if (ascii.endsWithIgnoreCase(file_path, ".tar.xz"))
            .@"tar.xz"
        else
            null;
    }

    fn getAttachmentType(content_disposition: []const u8) ?FileType {
        const disposition_type_end = ascii.indexOfIgnoreCase(content_disposition, "attachment;") orelse return null;

        var value_start = ascii.indexOfIgnoreCasePos(content_disposition, disposition_type_end + 1, "filename") orelse return null;
        value_start += "filename".len;
        if (content_disposition[value_start] == '*') {
            value_start += 1;
        }
        if (content_disposition[value_start] != '=') return null;
        value_start += 1;

        var value_end = mem.indexOfPos(u8, content_disposition, value_start, ";") orelse content_disposition.len;
        if (content_disposition[value_end - 1] == '\"') {
            value_end -= 1;
        }
        return fileTypeFromPath(content_disposition[value_start..value_end]);
    }

    pub fn deinit(rr: *ReadableResource, gpa: Allocator) void {
        gpa.free(rr.path);
        switch (rr.resource) {
            .file => |file| file.close(),
            .directory => |*dir| dir.close(),
            .http_request => |*req| req.deinit(),
        }
        rr.* = undefined;
    }
};

pub const PackageLocation = struct {
    /// For packages that require unpacking, this is the hash of the package contents.
    /// For directories, this is the hash of the absolute file path.
    hash: [Manifest.Hash.digest_length]u8,
    dir_path: []const u8,

    pub fn deinit(pl: *PackageLocation, allocator: Allocator) void {
        allocator.free(pl.dir_path);
        pl.* = undefined;
    }
};

const hex_multihash_len = 2 * Manifest.multihash_len;
const MultiHashHexDigest = [hex_multihash_len]u8;

const DependencyModule = union(enum) {
    zig_pkg: *Package,
    non_zig_pkg: *Package,
};
/// This is to avoid creating multiple modules for the same build.zig file.
/// If the value is `null`, the package is a known dependency, but has not yet
/// been fetched.
pub const AllModules = std.AutoHashMapUnmanaged(MultiHashHexDigest, ?DependencyModule);

fn ProgressReader(comptime ReaderType: type) type {
    return struct {
        child_reader: ReaderType,
        bytes_read: u64 = 0,
        prog_node: *std.Progress.Node,
        unit: enum {
            kib,
            mib,
            any,
        },

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*@This(), Error, read);

        pub fn read(self: *@This(), buf: []u8) Error!usize {
            const amt = try self.child_reader.read(buf);
            self.bytes_read += amt;
            const kib = self.bytes_read / 1024;
            const mib = kib / 1024;
            switch (self.unit) {
                .kib => self.prog_node.setCompletedItems(@intCast(kib)),
                .mib => self.prog_node.setCompletedItems(@intCast(mib)),
                .any => {
                    if (mib > 0) {
                        self.prog_node.setUnit("MiB");
                        self.prog_node.setCompletedItems(@intCast(mib));
                    } else {
                        self.prog_node.setUnit("KiB");
                        self.prog_node.setCompletedItems(@intCast(kib));
                    }
                },
            }
            self.prog_node.context.maybeRefresh();
            return amt;
        }

        pub fn reader(self: *@This()) Reader {
            return .{ .context = self };
        }
    };
}

/// Get a cached package if it exists.
/// Returns `null` if the package has not been cached
/// If the package exists in the cache, returns a pointer to the package and a
/// boolean indicating whether this package has already been seen in the build
/// (i.e. whether or not its transitive dependencies have been fetched).
fn getCachedPackage(
    gpa: Allocator,
    global_cache_directory: Compilation.Directory,
    dep: Manifest.Dependency,
    all_modules: *AllModules,
    root_prog_node: *std.Progress.Node,
) !?struct { DependencyModule, bool } {
    const s = fs.path.sep_str;
    // Check if the expected_hash is already present in the global package
    // cache, and thereby avoid both fetching and unpacking.
    if (dep.hash) |h| {
        const hex_digest = h[0..hex_multihash_len];
        const pkg_dir_sub_path = "p" ++ s ++ hex_digest;

        var pkg_dir = global_cache_directory.handle.openDir(pkg_dir_sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        errdefer pkg_dir.close();

        // The compiler has a rule that a file must not be included in multiple modules,
        // so we must detect if a module has been created for this package and reuse it.
        const gop = try all_modules.getOrPut(gpa, hex_digest.*);
        if (gop.found_existing) {
            if (gop.value_ptr.*) |mod| {
                return .{ mod, true };
            }
        }

        root_prog_node.completeOne();

        const is_zig_mod = if (pkg_dir.access(build_zig_basename, .{})) |_| true else |_| false;

        const build_root = try global_cache_directory.join(gpa, &.{pkg_dir_sub_path});
        errdefer gpa.free(build_root);

        const ptr = try gpa.create(Package);
        errdefer gpa.destroy(ptr);

        const owned_src_path = if (is_zig_mod) try gpa.dupe(u8, build_zig_basename) else "";
        errdefer gpa.free(owned_src_path);

        ptr.* = .{
            .root_src_directory = .{
                .path = build_root,
                .handle = pkg_dir,
            },
            .root_src_directory_owned = true,
            .root_src_path = owned_src_path,
        };

        gop.value_ptr.* = if (is_zig_mod)
            .{ .zig_pkg = ptr }
        else
            .{ .non_zig_pkg = ptr };

        return .{ gop.value_ptr.*.?, false };
    }

    return null;
}

fn fetchAndUnpack(
    thread_pool: *ThreadPool,
    http_client: *std.http.Client,
    directory: Compilation.Directory,
    global_cache_directory: Compilation.Directory,
    dep: *Manifest.Dependency,
    report: Report,
    all_modules: *AllModules,
    root_prog_node: *std.Progress.Node,
    /// This does not have to be any form of canonical or fully-qualified name: it
    /// is only intended to be human-readable for progress reporting.
    name_for_prog: []const u8,
) !DependencyModule {
    const gpa = http_client.allocator;

    var pkg_prog_node = root_prog_node.start(name_for_prog, 0);
    defer pkg_prog_node.end();
    pkg_prog_node.activate();
    pkg_prog_node.context.refresh();

    var fetch_location = try FetchLocation.init(gpa, directory, dep.*, report);
    defer fetch_location.deinit(gpa);

    var readable_resource = try fetch_location.fetch(gpa, directory, http_client, dep.*, report);
    defer readable_resource.deinit(gpa);

    var package_location = try readable_resource.unpack(gpa, thread_pool, global_cache_directory, dep.*, report, &pkg_prog_node);
    defer package_location.deinit(gpa);

    const actual_hex = Manifest.hexDigest(package_location.hash);
    if (readable_resource.resource != .directory) {
        if (dep.hash) |h| {
            if (!mem.eql(u8, h, &actual_hex)) {
                return report.fail(dep.hash_tok, "hash mismatch: expected: {s}, found: {s}", .{
                    h, actual_hex,
                });
            }
        } else {
            const file_path = try report.directory.join(gpa, &.{Manifest.basename});
            defer gpa.free(file_path);

            const eb = report.error_bundle;
            const notes_len = 1;
            try Report.addErrorMessage(report.ast.*, file_path, eb, notes_len, .{
                .tok = dep.location_tok,
                .off = 0,
                .msg = "dependency is missing hash field",
            });
            const notes_start = try eb.reserveNotes(notes_len);
            eb.extra.items[notes_start] = @intFromEnum(try eb.addErrorMessage(.{
                .msg = try eb.printString("expected .hash = \"{s}\",", .{&actual_hex}),
            }));
            return error.PackageFetchFailed;
        }
    } else {
        if (dep.hash != null) {
            return report.fail(dep.hash_tok, "hash not allowed for directory package", .{});
        }
        // Since directory dependencies don't provide a hash in build.zig.zon,
        // set the hash here to be the hash of the absolute path to the dependency.
        dep.hash = try gpa.dupe(u8, &actual_hex);
    }

    const build_zig_path = try std.fs.path.join(gpa, &.{ package_location.dir_path, build_zig_basename });
    defer gpa.free(build_zig_path);
    assert(fs.path.isAbsolute(build_zig_path));

    global_cache_directory.handle.access(build_zig_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const module = try create(gpa, package_location.dir_path, "");
            try all_modules.put(gpa, actual_hex, .{ .non_zig_pkg = module });
            return .{ .non_zig_pkg = module };
        },
        else => return err,
    };

    const module = try create(gpa, package_location.dir_path, build_zig_basename);
    try all_modules.put(gpa, actual_hex, .{ .zig_pkg = module });
    return .{ .zig_pkg = module };
}

fn unpackTarball(
    gpa: Allocator,
    reader: anytype,
    out_dir: fs.Dir,
    comptime compression: type,
) !void {
    var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, reader);

    var decompress = try compression.decompress(gpa, br.reader());
    defer decompress.deinit();

    try std.tar.pipeToFileSystem(out_dir, decompress.reader(), .{
        .strip_components = 1,
        // TODO: we would like to set this to executable_bit_only, but two
        // things need to happen before that:
        // 1. the tar implementation needs to support it
        // 2. the hashing algorithm here needs to support detecting the is_executable
        //    bit on Windows from the ACLs (see the isExecutable function).
        .mode_mode = .ignore,
    });
}

const HashedFile = struct {
    fs_path: []const u8,
    normalized_path: []const u8,
    hash: [Manifest.Hash.digest_length]u8,
    failure: Error!void,

    const Error = fs.File.OpenError || fs.File.ReadError || fs.File.StatError;

    fn lessThan(context: void, lhs: *const HashedFile, rhs: *const HashedFile) bool {
        _ = context;
        return mem.lessThan(u8, lhs.normalized_path, rhs.normalized_path);
    }
};

fn computePackageHash(
    thread_pool: *ThreadPool,
    pkg_dir: fs.IterableDir,
) ![Manifest.Hash.digest_length]u8 {
    const gpa = thread_pool.allocator;

    // We'll use an arena allocator for the path name strings since they all
    // need to be in memory for sorting.
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // Collect all files, recursively, then sort.
    var all_files = std.ArrayList(*HashedFile).init(gpa);
    defer all_files.deinit();

    var walker = try pkg_dir.walk(gpa);
    defer walker.deinit();

    {
        // The final hash will be a hash of each file hashed independently. This
        // allows hashing in parallel.
        var wait_group: WaitGroup = .{};
        defer wait_group.wait();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .directory => continue,
                .file => {},
                else => return error.IllegalFileTypeInPackage,
            }
            const hashed_file = try arena.create(HashedFile);
            const fs_path = try arena.dupe(u8, entry.path);
            hashed_file.* = .{
                .fs_path = fs_path,
                .normalized_path = try normalizePath(arena, fs_path),
                .hash = undefined, // to be populated by the worker
                .failure = undefined, // to be populated by the worker
            };
            wait_group.start();
            try thread_pool.spawn(workerHashFile, .{ pkg_dir.dir, hashed_file, &wait_group });

            try all_files.append(hashed_file);
        }
    }

    mem.sort(*HashedFile, all_files.items, {}, HashedFile.lessThan);

    var hasher = Manifest.Hash.init(.{});
    var any_failures = false;
    for (all_files.items) |hashed_file| {
        hashed_file.failure catch |err| {
            any_failures = true;
            std.log.err("unable to hash '{s}': {s}", .{ hashed_file.fs_path, @errorName(err) });
        };
        hasher.update(&hashed_file.hash);
    }
    if (any_failures) return error.PackageHashUnavailable;
    return hasher.finalResult();
}

/// Compute the hash of a file path.
fn computePathHash(path: []const u8) [Manifest.Hash.digest_length]u8 {
    var hasher = Manifest.Hash.init(.{});
    hasher.update(path);
    return hasher.finalResult();
}

fn isDirectory(root_dir: Compilation.Directory, path: []const u8) !bool {
    var dir = root_dir.handle.openDir(path, .{}) catch |err| switch (err) {
        error.NotDir => return false,
        else => return err,
    };
    defer dir.close();
    return true;
}

/// Make a file system path identical independently of operating system path inconsistencies.
/// This converts backslashes into forward slashes.
fn normalizePath(arena: Allocator, fs_path: []const u8) ![]const u8 {
    const canonical_sep = '/';

    if (fs.path.sep == canonical_sep)
        return fs_path;

    const normalized = try arena.dupe(u8, fs_path);
    for (normalized) |*byte| {
        switch (byte.*) {
            fs.path.sep => byte.* = canonical_sep,
            else => continue,
        }
    }
    return normalized;
}

/// Make a OS-specific file system path
/// This performs the inverse operation of normalizePath,
/// converting forward slashes into backslashes on Windows
fn unnormalizePath(arena: Allocator, fs_path: []const u8) ![]const u8 {
    const canonical_sep = '/';

    const unnormalized = try arena.dupe(u8, fs_path);
    if (fs.path.sep == canonical_sep)
        return unnormalized;

    for (unnormalized) |*byte| {
        switch (byte.*) {
            canonical_sep => byte.* = fs.path.sep,
            else => continue,
        }
    }
    return unnormalized;
}

fn workerHashFile(dir: fs.Dir, hashed_file: *HashedFile, wg: *WaitGroup) void {
    defer wg.finish();
    hashed_file.failure = hashFileFallible(dir, hashed_file);
}

fn hashFileFallible(dir: fs.Dir, hashed_file: *HashedFile) HashedFile.Error!void {
    var buf: [8000]u8 = undefined;
    var file = try dir.openFile(hashed_file.fs_path, .{});
    defer file.close();
    var hasher = Manifest.Hash.init(.{});
    hasher.update(hashed_file.normalized_path);
    hasher.update(&.{ 0, @intFromBool(try isExecutable(file)) });
    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }
    hasher.final(&hashed_file.hash);
}

fn isExecutable(file: fs.File) !bool {
    if (builtin.os.tag == .windows) {
        // TODO check the ACL on Windows.
        // Until this is implemented, this could be a false negative on
        // Windows, which is why we do not yet set executable_bit_only above
        // when unpacking the tarball.
        return false;
    } else {
        const stat = try file.stat();
        return (stat.mode & std.os.S.IXUSR) != 0;
    }
}

fn renameTmpIntoCache(
    cache_dir: fs.Dir,
    tmp_dir_sub_path: []const u8,
    dest_dir_sub_path: []const u8,
) !void {
    assert(dest_dir_sub_path[1] == fs.path.sep);
    var handled_missing_dir = false;
    while (true) {
        cache_dir.rename(tmp_dir_sub_path, dest_dir_sub_path) catch |err| switch (err) {
            error.FileNotFound => {
                if (handled_missing_dir) return err;
                cache_dir.makeDir(dest_dir_sub_path[0..1]) catch |mkd_err| switch (mkd_err) {
                    error.PathAlreadyExists => handled_missing_dir = true,
                    else => |e| return e,
                };
                continue;
            },
            error.PathAlreadyExists, error.AccessDenied => {
                // Package has been already downloaded and may already be in use on the system.
                cache_dir.deleteTree(tmp_dir_sub_path) catch |del_err| {
                    std.log.warn("unable to delete temp directory: {s}", .{@errorName(del_err)});
                };
            },
            else => |e| return e,
        };
        break;
    }
}

test "getAttachmentType" {
    try std.testing.expectEqual(@as(?ReadableResource.FileType, .@"tar.gz"), ReadableResource.getAttachmentType("attaChment; FILENAME=\"stuff.tar.gz\"; size=42"));
    try std.testing.expectEqual(@as(?ReadableResource.FileType, .@"tar.gz"), ReadableResource.getAttachmentType("attachment; filename*=\"stuff.tar.gz\""));
    try std.testing.expectEqual(@as(?ReadableResource.FileType, .@"tar.xz"), ReadableResource.getAttachmentType("ATTACHMENT; filename=\"stuff.tar.xz\""));
    try std.testing.expectEqual(@as(?ReadableResource.FileType, .@"tar.xz"), ReadableResource.getAttachmentType("attachment; FileName=\"stuff.tar.xz\""));
    try std.testing.expectEqual(@as(?ReadableResource.FileType, .@"tar.gz"), ReadableResource.getAttachmentType("attachment; FileName*=UTF-8\'\'xyz%2Fstuff.tar.gz"));

    try std.testing.expect(ReadableResource.getAttachmentType("attachment FileName=\"stuff.tar.gz\"") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("attachment; FileName=\"stuff.tar\"") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("attachment; FileName\"stuff.gz\"") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("attachment; size=42") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("inline; size=42") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("FileName=\"stuff.tar.gz\"; attachment;") == null);
    try std.testing.expect(ReadableResource.getAttachmentType("FileName=\"stuff.tar.gz\";") == null);
}
