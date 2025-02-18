const std = @import("std");
const Configuration = struct {
    os_name: []const u8 = "XROS",
    sv_major: u16 = 0,
    sv_minor: u16 = 0,
    sv_patch: u16 = 1,
    executables: []const []const u8,
    libraries: []const []const u8,
};
const config = Configuration{
    .executables = &.{"vrui","ctmn"},
    .libraries = &.{}
};
var id: ?[]u8 = null;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //libs
    const zgl = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });

    //various programs
    var modules:[config.executables.len]*std.Build.Module = undefined;
    var exes:[config.executables.len]*std.Build.Step.Compile = undefined;
    var main_path:[13]u8 = undefined;
    @memcpy(main_path[4..], "/main.zig");
    for (0..config.executables.len-1) |i| {
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

    const install_arch = b.step("install_arch","Install Archlinux into /build/");
    install_arch.makeFn = installArch;
    install_arch.dependOn(b.getInstallStep());

    const create_iso = b.step("create_iso","Create an install ISO for XROS");
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
    var buf:[4096]u8 = undefined;
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
        ,.{path}
    );

    var client = std.http.Client{.allocator = self.owner.allocator};
    defer client.deinit();
    var uri = try std.Uri.parse("http://localhost:2375/containers/create");
    var headers = std.http.Client.Request.Headers{};
    headers.content_type = .{ .override =  "application/json"};
    var request = try client.open(.POST, uri, .{.server_header_buffer = &buf, .headers = headers});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = data.len };
    try request.send();
    try request.writeAll(data);
    try request.finish();
    try request.wait();
    const body = try request.reader().readAllAlloc(self.owner.allocator, 8192);
    id = body[7..71];
    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/start", .{id orelse ""}));
    var request2 = try client.open(.POST, uri, .{.server_header_buffer = &buf, .headers = headers});
    defer request2.deinit();
    request2.transfer_encoding = .{ .content_length = 2 };
    try request2.send();
    try request2.writeAll("{}");
    try request2.finish();
    try request2.wait();
    errdefer {
        if(id != null){
            std.debug.print("Error occured! Killing container {s}.", .{id orelse "[NO CONTAINER]"});
            var uribuffer:[2048]u8 = undefined;
            uri = std.Uri.parse(std.fmt.bufPrint(&uribuffer, "http://localhost:2375/containers/{s}/kill", .{id orelse ""}) catch unreachable) catch unreachable;
            client = std.http.Client{.allocator = self.owner.allocator};
            request = client.open(.POST, uri, .{.server_header_buffer = &uribuffer}) catch unreachable;
            request.send() catch unreachable;
            request.finish() catch unreachable;
            request.wait() catch unreachable;
            client.deinit();
            request.deinit();
        }
    }

    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/wait", .{id orelse ""}));
    var request3 = try client.open(.POST, uri, .{.server_header_buffer = &buf});
    defer request3.deinit();
    try request3.send();
    try request3.wait();
    _ = try request3.reader().readAllAlloc(self.owner.allocator, 8192);
    _ = mkopts;
}

fn makeiso(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) !void {
    const builddir = try std.fs.cwd().openDir("build", .{});
    const usrbin = try builddir.openDir("usr/bin", .{});
    
    const binpath = try self.owner.allocator.alloc(u8, 4+self.owner.install_path.len);
    @memcpy(binpath[0..self.owner.install_path.len], self.owner.install_path);
    @memcpy(binpath[self.owner.install_path.len..], "/bin");
    
    const out = try std.fs.openDirAbsolute(binpath, .{ .iterate = true });

    for (config.executables) |i| {
        try out.copyFile(i, usrbin, i, .{});
    }
    _ = mkopts;
}