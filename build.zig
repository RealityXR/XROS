const std = @import("std");
var target: std.Build.ResolvedTarget = undefined;

pub fn build(b: *std.Build) void {
    target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //libs
    const zgl = b.dependency("zgl", .{
        .target = target,
        .optimize = optimize,
    });

    //various programs
    const vrui_mod = b.createModule(.{
        .root_source_file = b.path("vrui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vrui = b.addExecutable(.{
        .name = "vrui",
        .root_module = vrui_mod,
    });

    const ctmn_mod = b.createModule(.{
        .root_source_file = b.path("ctmn/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctmn = b.addExecutable(.{
        .name = "ctmn",
        .root_module = ctmn_mod,
    });

    //imports
    vrui_mod.addImport("zgl", zgl.module("zgl"));

    //installs
    b.installArtifact(vrui);
    b.installArtifact(ctmn);

    const install_arch = b.step("install_arch","Install Archlinux into /build/");
    install_arch.makeFn = installArch;

    const create_iso = b.step("create_iso","Create an install ISO for XROS");
    b.default_step = create_iso;
    create_iso.dependOn(b.getInstallStep());
    create_iso.dependOn(install_arch);
    create_iso.makeFn = makeiso;
}

fn installArch(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) anyerror!void {
    try std.fs.cwd().deleteTree("build");
    try std.fs.cwd().makeDir("build");

    var buf:[4096]u8 = undefined;
    var path = try std.fs.cwd().realpathAlloc(self.owner.allocator, ".");
    std.mem.replaceScalar(u8, path[0..], '\\', '/');
    const data = try std.fmt.bufPrint(&buf,
        \\{{
        \\"Image": "archlinux",
        \\"Cmd": ["/bin/bash","-c","pacman -Sy arch-install-scripts --noconfirm && pacstrap -K /build base base-devel"],
        \\"HostConfig": {{
        \\"Binds": ["{s}/build:/build"],
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
    const id = body[7..71];
    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/start", .{id}));
    var request2 = try client.open(.POST, uri, .{.server_header_buffer = &buf, .headers = headers});
    defer request2.deinit();
    request2.transfer_encoding = .{ .content_length = 2 };
    try request2.send();
    try request2.writeAll("{}");
    try request2.finish();
    try request2.wait();

    uri = try std.Uri.parse(try std.fmt.bufPrint(&buf, "http://localhost:2375/containers/{s}/wait", .{id}));
    var request3 = try client.open(.POST, uri, .{.server_header_buffer = &buf});
    defer request3.deinit();
    try request3.send();
    try request3.wait();
    _ = try request3.reader().readAllAlloc(self.owner.allocator, 8192);
    _ = mkopts;
}

fn makeiso(self: *std.Build.Step, mkopts: std.Build.Step.MakeOptions) anyerror!void {
    const builddir = try std.fs.cwd().openDir("build", .{});
    const usrbin = try builddir.openDir("usr/bin", .{});
    
    const binpath = try self.owner.allocator.alloc(u8, 4+self.owner.install_path.len);
    @memcpy(binpath[0..self.owner.install_path.len], self.owner.install_path);
    @memcpy(binpath[self.owner.install_path.len..], "/bin");
    
    const out = try std.fs.openDirAbsolute(binpath, .{ .iterate = true });
    
    const exe_names = [_]*const[4:0]u8 {"vrui", "ctmn"};

    for (exe_names) |i| {
        try out.copyFile(i, usrbin, i, .{});
    }
    _ = mkopts;
}