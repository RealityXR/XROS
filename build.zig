const std = @import("std");
const Configuration = struct {
    os_name: []const u8 = "XROS",
    sv_major: u16 = 0,
    sv_minor: u16 = 0,
    sv_patch: u16 = 1,
    executables: []const []const u8 = &.{ "vrui", "ctmn" },
    libraries: []const []const u8 = &.{},
};
var config: Configuration = undefined;

var id: ?[]u8 = null;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    config = cfg: {
        const configdir = std.fs.cwd().openDir("config", .{}) catch |err| {
            std.debug.print("No config dir found. Using defaults.\n", .{});
            break :cfg err;
        };
        const configjsonfile = configdir.openFile("config.json", .{}) catch |err| {
            std.debug.print("No config.json file found. Using defaults.\n", .{});
            break :cfg err;
        };
        const configjson = try configjsonfile.readToEndAlloc(b.allocator, 1024 * 1024);
        const parsedconfig = try std.json.parseFromSlice(Configuration, b.allocator, configjson, .{});
        defer parsedconfig.deinit();
        break :cfg parsedconfig.value;
    } catch Configuration{ .executables = &.{ "vrui", "ctmn" }, .libraries = &.{} };

    //libs
    const zgl = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });

    //various programs
    var modules = try b.allocator.alloc(*std.Build.Module, config.executables.len);
    var exes = try b.allocator.alloc(*std.Build.Step.Compile, config.executables.len);
    var main_path: [13]u8 = undefined;
    @memcpy(main_path[4..], "/main.zig");
    if (config.executables.len > 0) {
        for (0..config.executables.len - 1) |i| {
            @memcpy(main_path[0..4], config.executables[i]);
            modules[i] = b.createModule(.{
                .root_source_file = b.path(&main_path),
                .target = target,
                .optimize = optimize,
            });
            exes[i] = b.addExecutable(.{
                .name = config.executables[i],
                .root_module = modules[i],
            });
            modules[i].addImport("zgl", zgl.module("zgl"));
            b.installArtifact(exes[i]);
        }
    }

    const install_arch = b.step("install_arch", "Install Archlinux into /build/");
    install_arch.makeFn = installArch;
    install_arch.dependOn(b.getInstallStep());

    const create_iso = b.step("create_iso", "Create an install ISO for XROS");
    b.default_step = create_iso;
    create_iso.dependOn(b.getInstallStep());
    create_iso.dependOn(install_arch);
    create_iso.makeFn = makeiso;
}

//fn loadConfig(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) !void {}

fn installArch(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) !void {
    try std.fs.cwd().deleteTree("build");
    try std.fs.cwd().makeDir("build");
    const builddir = try std.fs.cwd().openDir("build", .{});
    try builddir.makeDir("arch");
    std.debug.print("Pacstrapping arch directory. This will take a while.\n", .{});
    var buf: [4096]u8 = undefined;
    var path = try std.fs.cwd().realpathAlloc(self.owner.allocator, ".");
    std.mem.replaceScalar(u8, path[0..], '\\', '/');
    const data = try std.fmt.bufPrint(&buf,
        \\{{
        \\"Image": "archlinux",
        \\"Cmd": ["/bin/bash","-c","pacman -Sy arch-install-scripts --noconfirm && pacstrap -K /build base base-devel"],
        \\"HostConfig": {{
        \\"Binds": ["{s}/build/arch:/build"],
        \\"Privileged": true
        \\}}
        \\}}
    , .{path});

    var client = std.http.Client{ .allocator = self.owner.allocator };
    defer client.deinit();
    var uri = try std.Uri.parse("http://localhost:2375/containers/create");
    var headers = std.http.Client.Request.Headers{};
    headers.content_type = .{ .override = "application/json" };
    var request = try client.open(.POST, uri, .{ .server_header_buffer = &buf, .headers = headers });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = data.len };
    try request.send();
    try request.writeAll(data);
    try request.finish();
    try request.wait();
    const body = try request.reader().readAllAlloc(self.owner.allocator, 8192);
    std.debug.print("Body: {s}", .{body});
    id = body[7..71];
    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/start", .{id orelse ""}));
    var request2 = try client.open(.POST, uri, .{ .server_header_buffer = &buf, .headers = headers });
    defer request2.deinit();
    request2.transfer_encoding = .{ .content_length = 2 };
    try request2.send();
    try request2.writeAll("{}");
    try request2.finish();
    try request2.wait();
    errdefer stopContainer(0) catch unreachable;

    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/wait", .{id orelse ""}));
    var request3 = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
    defer request3.deinit();
    try request3.send();
    try request3.wait();
    _ = try request3.reader().readAllAlloc(self.owner.allocator, 8192);
    _ = mkopts;
}

fn makeiso(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) !void {
    const builddir = std.fs.cwd().openDir("build", .{}) catch |err| {
        std.debug.print("Error opening build.", .{});
        return err;
    };
    const usrbin = builddir.openDir("arch/usr/bin", .{}) catch |err| {
        std.debug.print("Error opening usr/bin", .{});
        return err;
    };

    var binpath = try std.fs.openDirAbsolute(self.owner.install_path, .{});
    binpath = try binpath.openDir("bin", .{});

    for (config.executables) |i| {
        binpath.copyFile(i, usrbin, i, .{}) catch |err| {
            std.debug.print("Error while copying file {s}.", .{i});
            return err;
        };
    }
    _ = mkopts;
}

fn stopContainer(_: i32) !void {
    if (id != null) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        std.debug.print("Error occured! Killing container {s}.", .{id orelse "[NO CONTAINER]"});
        var uribuffer: [2048]u8 = undefined;
        const uri = try std.Uri.parse(try std.fmt.bufPrint(&uribuffer, "http://localhost:2375/containers/{s}/kill", .{id orelse ""}));
        var client = std.http.Client{ .allocator = allocator };
        var request = try client.open(.POST, uri, .{ .server_header_buffer = &uribuffer });
        try request.send();
        try request.finish();
        try request.wait();
        client.deinit();
        request.deinit();
        _ = gpa.deinit();
    }
}
