#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"
MARKER="LIBGHOSTTY_SPM_FOREGROUND_PID"

python3 - "$SOURCE_DIR" "$MARKER" <<'PYEOF'
import sys
from pathlib import Path

source_dir = Path(sys.argv[1])
marker = sys.argv[2]


def patch_file(rel_path, replacements):
    path = source_dir / rel_path
    text = path.read_text()
    for old, new in replacements:
        if new in text:
            continue
        if old not in text:
            print(f"[-] pattern not found in {rel_path}:")
            print(f"    {old[:120]}...")
            sys.exit(1)
        count = text.count(old)
        if count > 1:
            print(f"[-] pattern matched {count} times in {rel_path} (expected 1):")
            print(f"    {old[:120]}...")
            sys.exit(1)
        text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"[+] patched {rel_path}")


patch_file("include/ghostty.h", [
    (
        "bool ghostty_surface_process_exited(ghostty_surface_t);\n",
        "bool ghostty_surface_process_exited(ghostty_surface_t);\n"
        f"uint64_t ghostty_surface_foreground_pid(ghostty_surface_t); // {marker}\n",
    ),
])

patch_file("src/pty.zig", [
    (
        '        .macos => @cImport({\n'
        '            @cInclude("sys/ioctl.h"); // ioctl and constants\n'
        '            @cInclude("util.h"); // openpty()\n'
        '        }),',
        '        .macos => @cImport({\n'
        '            @cInclude("sys/ioctl.h"); // ioctl and constants\n'
        '            @cInclude("unistd.h"); // tcgetpgrp()\n'
        '            @cInclude("util.h"); // openpty()\n'
        '        }),',
    ),
    (
        '        .freebsd => @cImport({\n'
        '            @cInclude("termios.h"); // ioctl and constants\n'
        '            @cInclude("libutil.h"); // openpty()\n'
        '        }),',
        '        .freebsd => @cImport({\n'
        '            @cInclude("termios.h"); // ioctl and constants\n'
        '            @cInclude("unistd.h"); // tcgetpgrp()\n'
        '            @cInclude("libutil.h"); // openpty()\n'
        '        }),',
    ),
    (
        '        else => @cImport({\n'
        '            @cInclude("sys/ioctl.h"); // ioctl and constants\n'
        '            @cInclude("pty.h");\n'
        '        }),',
        '        else => @cImport({\n'
        '            @cInclude("sys/ioctl.h"); // ioctl and constants\n'
        '            @cInclude("unistd.h"); // tcgetpgrp()\n'
        '            @cInclude("pty.h");\n'
        '        }),',
    ),
    (
        '    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {\n'
        '        _ = self;\n'
        '        _ = size;\n'
        '    }\n',
        '    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {\n'
        '        _ = self;\n'
        '        _ = size;\n'
        '    }\n'
        '\n'
        f'    pub fn foregroundProcessID(self: *Pty) ?u64 {{ // {marker}\n'
        '        _ = self;\n'
        '        return null;\n'
        '    }\n',
    ),
    (
        '    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };\n',
        f'    pub fn foregroundProcessID(self: *Pty) ?u64 {{ // {marker}\n'
        '        const process_id = c.tcgetpgrp(self.master);\n'
        '        if (process_id <= 0) return null;\n'
        '        return @intCast(process_id);\n'
        '    }\n'
        '\n'
        '    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };\n',
    ),
    (
        '    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {\n'
        '        const result = windows.exp.kernel32.ResizePseudoConsole(\n'
        '            self.pseudo_console,\n'
        '            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },\n'
        '        );\n'
        '\n'
        '        if (result != windows.S_OK) return error.ResizeFailed;\n'
        '        self.size = size;\n'
        '    }\n',
        '    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {\n'
        '        const result = windows.exp.kernel32.ResizePseudoConsole(\n'
        '            self.pseudo_console,\n'
        '            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },\n'
        '        );\n'
        '\n'
        '        if (result != windows.S_OK) return error.ResizeFailed;\n'
        '        self.size = size;\n'
        '    }\n'
        '\n'
        f'    pub fn foregroundProcessID(self: *Pty) ?u64 {{ // {marker}\n'
        '        _ = self;\n'
        '        return null;\n'
        '    }\n',
    ),
])

patch_file("src/termio/Exec.zig", [
    (
        "pub fn deinit(self: *Exec) void {\n",
        f"pub fn foregroundProcessID(self: *Exec) ?u64 {{ // {marker}\n"
        "    if (self.subprocess.pty) |*pty| {\n"
        "        return pty.foregroundProcessID();\n"
        "    }\n"
        "\n"
        "    return null;\n"
        "}\n"
        "\n"
        "pub fn deinit(self: *Exec) void {\n",
    ),
])

backend_path = source_dir / "src/termio/backend.zig"
backend_text = backend_path.read_text()
if marker not in backend_text:
    host_block = (
        '    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {\n'
        '        switch (self.*) {\n'
        '            .exec => |*exec| exec.initTerminal(t),\n'
        '            .host_managed => |*host_managed| host_managed.initTerminal(t),\n'
        '        }\n'
        '    }\n'
    )
    exec_block = (
        '    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {\n'
        '        switch (self.*) {\n'
        '            .exec => |*exec| exec.initTerminal(t),\n'
        '        }\n'
        '    }\n'
    )
    if host_block in backend_text:
        replacement = host_block + (
            '\n'
            f'    pub fn foregroundProcessID(self: *Backend) ?u64 {{ // {marker}\n'
            '        return switch (self.*) {\n'
            '            .exec => |*exec| exec.foregroundProcessID(),\n'
            '            .host_managed => null,\n'
            '        };\n'
            '    }\n'
        )
        backend_text = backend_text.replace(host_block, replacement, 1)
    elif exec_block in backend_text:
        replacement = exec_block + (
            '\n'
            f'    pub fn foregroundProcessID(self: *Backend) ?u64 {{ // {marker}\n'
            '        return switch (self.*) {\n'
            '            .exec => |*exec| exec.foregroundProcessID(),\n'
            '        };\n'
            '    }\n'
        )
        backend_text = backend_text.replace(exec_block, replacement, 1)
    else:
        print("[-] backend initTerminal block not found")
        sys.exit(1)
    backend_path.write_text(backend_text)
    print("[+] patched src/termio/backend.zig")
else:
    print("[+] src/termio/backend.zig already patched")

patch_file("src/termio/Termio.zig", [
    (
        'const ThreadEnterState = struct {\n',
        f'pub fn foregroundProcessID(self: *Termio) ?u64 {{ // {marker}\n'
        '    return self.backend.foregroundProcessID();\n'
        '}\n'
        '\n'
        'const ThreadEnterState = struct {\n',
    ),
])

patch_file("src/Surface.zig", [
    (
        'pub const InputEffect = enum {\n',
        f'pub fn foregroundProcessID(self: *Surface) ?u64 {{ // {marker}\n'
        '    return self.io.foregroundProcessID();\n'
        '}\n'
        '\n'
        'pub const InputEffect = enum {\n',
    ),
])

patch_file("src/apprt/embedded.zig", [
    (
        '    export fn ghostty_surface_process_exited(surface: *Surface) bool {\n'
        '        return surface.core_surface.child_exited;\n'
        '    }\n',
        '    export fn ghostty_surface_process_exited(surface: *Surface) bool {\n'
        '        return surface.core_surface.child_exited;\n'
        '    }\n'
        '\n'
        f'    export fn ghostty_surface_foreground_pid(surface: *Surface) u64 {{ // {marker}\n'
        '        return surface.core_surface.foregroundProcessID() orelse 0;\n'
        '    }\n',
    ),
])
PYEOF
