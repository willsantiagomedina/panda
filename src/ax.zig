const std = @import("std");

extern "ApplicationServices" fn _AXUIElementGetWindow(element: c.AXUIElementRef, identifier: *c.uint) c.AXError;

pub const c = @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("frontmost.h");
    @cInclude("libproc.h");
});

pub const NativeWindowRef = c.AXUIElementRef;

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const WindowSummary = struct {
    index: usize,
    element: NativeWindowRef,
    title: []u8,
    frame: Rect,

    pub fn deinit(self: *WindowSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        c.CFRelease(self.element);
    }
};

pub const RunningApp = struct {
    pid: i32,
    name: []u8,
    bundle_path: []u8,
    executable_path: []u8,

    pub fn deinit(self: *RunningApp, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bundle_path);
        allocator.free(self.executable_path);
    }
};

pub const ActiveApp = struct {
    pid: i32,
    name: []u8,
    bundle_path: []u8,

    pub fn deinit(self: *ActiveApp, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bundle_path);
    }
};

pub const WindowOnSpace = struct {
    window_id: u32,
    pid: i32,
    bounds: Rect,
};

pub const Direction = enum {
    left,
    right,
    up,
    down,
};

pub const Error = error{
    AccessibilityDenied,
    AppNotFound,
    AppUnresponsive,
    AmbiguousTarget,
    AttributeUnsupported,
    ConversionFailed,
    InvalidArguments,
    InvalidPid,
    OutOfMemory,
    UnsupportedTarget,
    UnexpectedAxError,
};

pub fn isProcessTrusted() bool {
    return c.AXIsProcessTrusted() != 0;
}

pub fn ensureTrusted() Error!void {
    if (!isProcessTrusted()) {
        return Error.AccessibilityDenied;
    }
}

pub fn promptForAccessibility() bool {
    return c.pandaPromptForAccessibility();
}

pub fn createApplication(pid: i32) Error!c.AXUIElementRef {
    const app = c.AXUIElementCreateApplication(pid);
    if (app == null) {
        return Error.UnexpectedAxError;
    }
    return app;
}

pub fn focusedApplicationPid() Error!i32 {
    const pid = try frontmostApplicationPid();
    if (pid <= 0) return Error.InvalidPid;
    return pid;
}

pub fn focusedApplication(allocator: std.mem.Allocator) Error!ActiveApp {
    var app = try frontmostRunningApp(allocator);
    defer app.deinit(allocator);

    return .{
        .pid = app.pid,
        .name = try allocator.dupe(u8, app.name),
        .bundle_path = try allocator.dupe(u8, app.bundle_path),
    };
}

pub fn describeRunningApp(allocator: std.mem.Allocator, pid: i32) Error!RunningApp {
    return runningAppForPid(allocator, pid);
}

pub fn listWindows(allocator: std.mem.Allocator, pid: i32) Error![]WindowSummary {
    const app = try createApplication(pid);
    defer c.CFRelease(app);

    const windows_attribute = try makeCfString("AXWindows");
    defer c.CFRelease(windows_attribute);

    var value: c.CFTypeRef = null;
    try axCall(c.AXUIElementCopyAttributeValue(app, windows_attribute, &value));
    defer c.CFRelease(value);

    const windows = cfArrayFromType(value) orelse return Error.ConversionFailed;
    const count: usize = @intCast(c.CFArrayGetCount(windows));
    var result = try allocator.alloc(WindowSummary, count);

    errdefer {
        for (result[0..count]) |*summary| {
            summary.deinit(allocator);
        }
        allocator.free(result);
    }

    for (0..count) |index| {
        const raw_value = c.CFArrayGetValueAtIndex(windows, @intCast(index));
        const window: c.AXUIElementRef = @ptrCast(@constCast(raw_value));
        _ = c.CFRetain(window);

        const title = try copyWindowTitle(allocator, window);
        errdefer allocator.free(title);

        const frame = try copyWindowFrame(window);

        result[index] = .{
            .index = index,
            .element = window,
            .title = title,
            .frame = frame,
        };
    }

    return result;
}

pub fn moveResizeWindow(window: NativeWindowRef, frame: Rect) Error!void {
    var point = c.CGPoint{ .x = frame.x, .y = frame.y };
    var size = c.CGSize{ .width = frame.width, .height = frame.height };
    const position_attribute = try makeCfString("AXPosition");
    defer c.CFRelease(position_attribute);
    const size_attribute = try makeCfString("AXSize");
    defer c.CFRelease(size_attribute);

    const position_value = c.AXValueCreate(c.kAXValueCGPointType, &point) orelse return Error.ConversionFailed;
    defer c.CFRelease(position_value);

    const size_value = c.AXValueCreate(c.kAXValueCGSizeType, &size) orelse return Error.ConversionFailed;
    defer c.CFRelease(size_value);

    try axCall(c.AXUIElementSetAttributeValue(window, position_attribute, position_value));
    try axCall(c.AXUIElementSetAttributeValue(window, size_attribute, size_value));
}

pub fn createObserver(pid: i32, callback: c.AXObserverCallback) Error!c.AXObserverRef {
    var observer: c.AXObserverRef = null;
    try axCall(c.AXObserverCreate(pid, callback, &observer));
    return observer orelse Error.UnexpectedAxError;
}

pub fn focusedWindowId(pid: i32) Error!?u64 {
    const app = try createApplication(pid);
    defer c.CFRelease(app);

    const focused_attribute = try makeCfString("AXFocusedWindow");
    defer c.CFRelease(focused_attribute);

    var value: c.CFTypeRef = null;
    const result = c.AXUIElementCopyAttributeValue(app, focused_attribute, &value);
    switch (result) {
        c.kAXErrorSuccess => {},
        c.kAXErrorNoValue, c.kAXErrorAttributeUnsupported => return null,
        else => try axCall(result),
    }
    defer if (value != null) c.CFRelease(value);

    const window = @as(c.AXUIElementRef, @ptrCast(value orelse return null));
    return windowId(window);
}

pub fn focusWindow(window: NativeWindowRef) Error!void {
    const raise_action = try makeCfString("AXRaise");
    defer c.CFRelease(raise_action);
    _ = c.AXUIElementPerformAction(window, raise_action);

    const main_attribute = try makeCfString("AXMain");
    defer c.CFRelease(main_attribute);
    _ = c.AXUIElementSetAttributeValue(window, main_attribute, c.kCFBooleanTrue);

    const focused_attribute = try makeCfString("AXFocused");
    defer c.CFRelease(focused_attribute);
    _ = c.AXUIElementSetAttributeValue(window, focused_attribute, c.kCFBooleanTrue);
}

pub fn postKeyChord(key_code: u16, modifiers: u32) bool {
    return c.pandaPostKeyChord(key_code, modifiers);
}

pub fn addObserverNotification(
    observer: c.AXObserverRef,
    element: c.AXUIElementRef,
    notification_name: []const u8,
    refcon: ?*anyopaque,
) Error!void {
    const notification = try makeCfString(notification_name);
    defer c.CFRelease(notification);

    try axCall(c.AXObserverAddNotification(observer, element, notification, refcon));
}

pub fn windowId(window: NativeWindowRef) u64 {
    var identifier: c.uint = 0;
    if (_AXUIElementGetWindow(window, &identifier) == c.kAXErrorSuccess and identifier != 0) {
        return identifier;
    }

    return @intCast(c.CFHash(window));
}

pub fn mainDisplayBounds() Rect {
    const display_id = c.CGMainDisplayID();
    const bounds = c.CGDisplayBounds(display_id);
    return .{
        .x = bounds.origin.x,
        .y = bounds.origin.y,
        .width = bounds.size.width,
        .height = bounds.size.height,
    };
}

pub fn mainDisplayVisibleFrame() Rect {
    const screen = c.NSScreen_mainScreen();
    if (screen == null) return mainDisplayBounds();

    const visible = c.NSScreen_visibleFrame(screen);
    const full = c.NSScreen_frame(screen);

    return .{
        .x = visible.origin.x,
        .y = full.size.height - visible.origin.y - visible.size.height,
        .width = visible.size.width,
        .height = visible.size.height,
    };
}

pub fn cfStringEquals(value: c.CFStringRef, literal: []const u8) bool {
    const other = makeCfString(literal) catch return false;
    defer c.CFRelease(other);
    return c.CFStringCompare(value, other, 0) == c.kCFCompareEqualTo;
}

pub fn resolvePidForTarget(allocator: std.mem.Allocator, target: []const u8) Error!i32 {
    if (std.ascii.eqlIgnoreCase(target, "active")) {
        return focusedApplicationPid();
    }

    if (std.fmt.parseInt(i32, target, 10)) |pid| {
        return pid;
    } else |err| switch (err) {
        error.InvalidCharacter => {},
        else => return Error.InvalidArguments,
    }

    const apps = try listRunningApps(allocator);
    defer {
        for (apps) |*app| app.deinit(allocator);
        allocator.free(apps);
    }

    var matched_pid: ?i32 = null;
    for (apps) |app| {
        if (!matchesTargetName(app.name, app.executable_path, target)) continue;
        if (matched_pid != null) return Error.AmbiguousTarget;
        matched_pid = app.pid;
    }

    return matched_pid orelse Error.AppNotFound;
}

pub fn listRunningGuiApps(allocator: std.mem.Allocator) Error![]RunningApp {
    var buffer: [c.PANDA_MAX_RUNNING_APPS]c.PandaFrontmostApp = undefined;
    const count = c.pandaListRunningGuiApps(&buffer, c.PANDA_MAX_RUNNING_APPS);

    if (count <= 0) {
        return allocator.alloc(RunningApp, 0);
    }

    var apps = std.ArrayList(RunningApp){};
    defer apps.deinit(allocator);

    for (buffer[0..@intCast(count)]) |app| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&app.name)));
        const bundle_path = std.mem.span(@as([*:0]const u8, @ptrCast(&app.bundle_path)));
        const executable_path = std.mem.span(@as([*:0]const u8, @ptrCast(&app.executable_path)));

        try apps.append(allocator, .{
            .pid = app.pid,
            .name = try allocator.dupe(u8, name),
            .bundle_path = try allocator.dupe(u8, bundle_path),
            .executable_path = try allocator.dupe(u8, executable_path),
        });
    }

    const result = try apps.toOwnedSlice(allocator);
    std.mem.sort(RunningApp, result, {}, lessRunningApp);
    return result;
}

pub fn listWindowsOnCurrentSpace(allocator: std.mem.Allocator) Error![]WindowOnSpace {
    var buffer: [c.PANDA_MAX_WINDOW_IDS]c.PandaWindowInfo = undefined;
    const count = c.pandaListWindowsOnCurrentSpace(&buffer, c.PANDA_MAX_WINDOW_IDS);

    if (count <= 0) {
        return allocator.alloc(WindowOnSpace, 0);
    }

    var windows = std.ArrayList(WindowOnSpace){};
    defer windows.deinit(allocator);

    for (buffer[0..@intCast(count)]) |win| {
        try windows.append(allocator, .{
            .window_id = win.window_id,
            .pid = win.pid,
            .bounds = .{
                .x = win.bounds.origin.x,
                .y = win.bounds.origin.y,
                .width = win.bounds.size.width,
                .height = win.bounds.size.height,
            },
        });
    }

    return windows.toOwnedSlice(allocator);
}

pub fn listRunningApps(allocator: std.mem.Allocator) Error![]RunningApp {
    var pid_buffer = try allocator.alloc(c_int, 4096);
    defer allocator.free(pid_buffer);

    const bytes = c.proc_listallpids(pid_buffer.ptr, @intCast(pid_buffer.len * @sizeOf(c_int)));
    if (bytes <= 0) {
        return Error.UnexpectedAxError;
    }

    const count: usize = @intCast(@divTrunc(bytes, @as(c_int, @intCast(@sizeOf(c_int)))));
    var apps = std.ArrayList(RunningApp){};
    defer apps.deinit(allocator);

    var name_buffer: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    var path_buffer: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;

    for (pid_buffer[0..count]) |raw_pid| {
        if (raw_pid <= 0) continue;

        @memset(&name_buffer, 0);
        const name_len = c.proc_name(raw_pid, &name_buffer, name_buffer.len);
        if (name_len <= 0) continue;

        @memset(&path_buffer, 0);
        const path_len = c.proc_pidpath(raw_pid, &path_buffer, @intCast(path_buffer.len));
        if (path_len <= 0) continue;

        const process_name = std.mem.span(@as([*:0]u8, @ptrCast(&name_buffer)));
        const process_path = std.mem.span(@as([*:0]u8, @ptrCast(&path_buffer)));
        const bundle_path = topLevelBundlePath(process_path) orelse continue;
        if (!isPrimaryAppExecutable(bundle_path, process_path)) continue;
        const bundle_name = std.fs.path.stem(std.fs.path.basename(bundle_path));

        try apps.append(allocator, .{
            .pid = raw_pid,
            .name = if (bundle_name.len != 0)
                try allocator.dupe(u8, bundle_name)
            else
                try allocator.dupe(u8, process_name),
            .bundle_path = try allocator.dupe(u8, bundle_path),
            .executable_path = try allocator.dupe(u8, process_path),
        });
    }

    const result = try apps.toOwnedSlice(allocator);
    std.mem.sort(RunningApp, result, {}, lessRunningApp);
    return result;
}

fn runningAppForPid(allocator: std.mem.Allocator, pid: i32) Error!RunningApp {
    const apps = try listRunningApps(allocator);
    defer {
        for (apps) |*app| app.deinit(allocator);
        allocator.free(apps);
    }

    for (apps) |app| {
        if (app.pid != pid) continue;
        return .{
            .pid = app.pid,
            .name = try allocator.dupe(u8, app.name),
            .bundle_path = try allocator.dupe(u8, app.bundle_path),
            .executable_path = try allocator.dupe(u8, app.executable_path),
        };
    }

    return Error.AppNotFound;
}

fn lessRunningApp(_: void, lhs: RunningApp, rhs: RunningApp) bool {
    const order = std.ascii.orderIgnoreCase(lhs.name, rhs.name);
    if (order == .lt) return true;
    if (order == .gt) return false;
    return lhs.pid < rhs.pid;
}

fn appBundleBasename(path: []const u8) []const u8 {
    const bundle_path = topLevelBundlePath(path) orelse return "";
    return std.fs.path.stem(std.fs.path.basename(bundle_path));
}

fn isPrimaryAppExecutable(bundle_path: []const u8, executable_path: []const u8) bool {
    const contents_macos = "/Contents/MacOS/";
    if (!std.mem.startsWith(u8, executable_path, bundle_path)) return false;
    const suffix = executable_path[bundle_path.len..];
    if (!std.mem.startsWith(u8, suffix, contents_macos)) return false;

    const binary_name = suffix[contents_macos.len..];
    if (binary_name.len == 0) return false;
    return std.mem.indexOfScalar(u8, binary_name, '/') == null;
}

fn topLevelBundlePath(path: []const u8) ?[]const u8 {
    const app_marker = std.mem.indexOf(u8, path, ".app/") orelse return null;
    const bundle_path = path[0 .. app_marker + 4];
    const remainder = path[app_marker + 5 ..];
    if (std.mem.indexOf(u8, remainder, ".app/") != null) return null;
    return bundle_path;
}

fn matchesTargetName(process_name: []const u8, process_path: []const u8, target: []const u8) bool {
    if (nameEquals(process_name, target)) {
        return true;
    }

    const bundle_name = appBundleBasename(process_path);
    if (bundle_name.len != 0 and nameEquals(bundle_name, target)) {
        return true;
    }

    return false;
}

fn copyWindowTitle(allocator: std.mem.Allocator, window: NativeWindowRef) Error![]u8 {
    const title_attribute = try makeCfString("AXTitle");
    defer c.CFRelease(title_attribute);

    var value: c.CFTypeRef = null;
    try axCall(c.AXUIElementCopyAttributeValue(window, title_attribute, &value));
    defer if (value != null) c.CFRelease(value);

    const string = cfStringFromType(value) orelse return allocator.dupe(u8, "<untitled>");
    return copyCfString(allocator, string);
}

fn copyWindowFrame(window: NativeWindowRef) Error!Rect {
    const position_attribute = try makeCfString("AXPosition");
    defer c.CFRelease(position_attribute);
    const size_attribute = try makeCfString("AXSize");
    defer c.CFRelease(size_attribute);

    return .{
        .x = try copyPointComponent(window, position_attribute, .x),
        .y = try copyPointComponent(window, position_attribute, .y),
        .width = try copySizeComponent(window, size_attribute, .width),
        .height = try copySizeComponent(window, size_attribute, .height),
    };
}

pub fn isWindowMinimized(window: NativeWindowRef) bool {
    const minimized_attribute = makeCfString("AXMinimized") catch return false;
    defer c.CFRelease(minimized_attribute);

    var value: c.CFTypeRef = null;
    axCall(c.AXUIElementCopyAttributeValue(window, minimized_attribute, &value)) catch return false;
    defer if (value != null) c.CFRelease(value);

    if (value == null) return false;
    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return false;
    return c.CFBooleanGetValue(@as(c.CFBooleanRef, @ptrCast(value.?))) != 0;
}

pub fn isWindowStandard(window: NativeWindowRef) bool {
    const subrole_attribute = makeCfString("AXSubrole") catch return true;
    defer c.CFRelease(subrole_attribute);

    var value: c.CFTypeRef = null;
    axCall(c.AXUIElementCopyAttributeValue(window, subrole_attribute, &value)) catch return true;
    defer if (value != null) c.CFRelease(value);

    const subrole = cfStringFromType(value) orelse return true;

    const standard_window = makeCfString("AXStandardWindow") catch return true;
    defer c.CFRelease(standard_window);

    return c.CFStringCompare(subrole, standard_window, 0) == c.kCFCompareEqualTo;
}

const PointComponent = enum { x, y };
const SizeComponent = enum { width, height };

fn copyPointComponent(window: NativeWindowRef, attribute: c.CFStringRef, component: PointComponent) Error!f64 {
    var value: c.CFTypeRef = null;
    try axCall(c.AXUIElementCopyAttributeValue(window, attribute, &value));
    defer if (value != null) c.CFRelease(value);

    const ax_value = cfAxValueFromType(value) orelse return Error.ConversionFailed;
    var point: c.CGPoint = undefined;
    if (c.AXValueGetValue(ax_value, c.kAXValueCGPointType, &point) == 0) {
        return Error.ConversionFailed;
    }

    return switch (component) {
        .x => point.x,
        .y => point.y,
    };
}

fn copySizeComponent(window: NativeWindowRef, attribute: c.CFStringRef, component: SizeComponent) Error!f64 {
    var value: c.CFTypeRef = null;
    try axCall(c.AXUIElementCopyAttributeValue(window, attribute, &value));
    defer if (value != null) c.CFRelease(value);

    const ax_value = cfAxValueFromType(value) orelse return Error.ConversionFailed;
    var size: c.CGSize = undefined;
    if (c.AXValueGetValue(ax_value, c.kAXValueCGSizeType, &size) == 0) {
        return Error.ConversionFailed;
    }

    return switch (component) {
        .width => size.width,
        .height => size.height,
    };
}

fn copyCfString(allocator: std.mem.Allocator, value: c.CFStringRef) Error![]u8 {
    const len = c.CFStringGetLength(value);
    const max_size: usize = @intCast(c.CFStringGetMaximumSizeForEncoding(len, c.kCFStringEncodingUTF8) + 1);
    const buffer = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buffer);

    if (c.CFStringGetCString(value, @ptrCast(buffer.ptr), @intCast(buffer.len), c.kCFStringEncodingUTF8) == 0) {
        return Error.ConversionFailed;
    }

    const actual_len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return allocator.realloc(buffer, actual_len);
}

fn makeCfString(bytes: []const u8) Error!c.CFStringRef {
    return c.CFStringCreateWithBytes(
        c.kCFAllocatorDefault,
        bytes.ptr,
        @intCast(bytes.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse Error.ConversionFailed;
}

fn frontmostApplicationPid() Error!i32 {
    var app: c.PandaFrontmostApp = undefined;
    if (!c.pandaCopyFrontmostApp(&app)) return Error.AppNotFound;
    if (app.pid <= 0) return Error.InvalidPid;
    return @intCast(app.pid);
}

fn frontmostRunningApp(allocator: std.mem.Allocator) Error!RunningApp {
    var app: c.PandaFrontmostApp = undefined;
    if (!c.pandaCopyFrontmostApp(&app)) return Error.AppNotFound;
    if (app.pid <= 0) return Error.InvalidPid;

    const name = try dupCStringField(allocator, &app.name);
    errdefer allocator.free(name);

    const bundle_path = try dupCStringField(allocator, &app.bundle_path);
    errdefer allocator.free(bundle_path);

    const executable_path = if (app.executable_path[0] != 0)
        try dupCStringField(allocator, &app.executable_path)
    else
        try allocator.dupe(u8, bundle_path);
    errdefer allocator.free(executable_path);

    return .{
        .pid = @intCast(app.pid),
        .name = name,
        .bundle_path = bundle_path,
        .executable_path = executable_path,
    };
}

fn dupCStringField(allocator: std.mem.Allocator, buffer: [*c]const u8) Error![]u8 {
    const slice = std.mem.span(buffer);
    if (slice.len == 0) return Error.ConversionFailed;
    return allocator.dupe(u8, slice);
}

fn axCall(code: c.AXError) Error!void {
    switch (code) {
        c.kAXErrorSuccess => return,
        c.kAXErrorAPIDisabled => return Error.AccessibilityDenied,
        c.kAXErrorCannotComplete => return Error.AppUnresponsive,
        c.kAXErrorAttributeUnsupported, c.kAXErrorNoValue => return Error.AttributeUnsupported,
        c.kAXErrorIllegalArgument, c.kAXErrorInvalidUIElement, c.kAXErrorInvalidUIElementObserver => return Error.InvalidPid,
        c.kAXErrorNotImplemented, c.kAXErrorActionUnsupported, c.kAXErrorNotificationUnsupported, c.kAXErrorParameterizedAttributeUnsupported => return Error.UnsupportedTarget,
        else => return Error.UnexpectedAxError,
    }
}

fn nameEquals(candidate: []const u8, target: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(candidate, target)) return true;
    if (std.mem.endsWith(u8, target, ".app")) {
        return std.ascii.eqlIgnoreCase(candidate, target[0 .. target.len - 4]);
    }
    return false;
}

fn cfArrayFromType(value: c.CFTypeRef) ?c.CFArrayRef {
    if (value == null) return null;
    if (c.CFGetTypeID(value) != c.CFArrayGetTypeID()) return null;
    return @as(c.CFArrayRef, @ptrCast(value.?));
}

fn cfStringFromType(value: c.CFTypeRef) ?c.CFStringRef {
    if (value == null) return null;
    if (c.CFGetTypeID(value) != c.CFStringGetTypeID()) return null;
    return @as(c.CFStringRef, @ptrCast(value.?));
}

fn cfAxValueFromType(value: c.CFTypeRef) ?c.AXValueRef {
    if (value == null) return null;
    if (c.CFGetTypeID(value) != c.AXValueGetTypeID()) return null;
    return @as(c.AXValueRef, @ptrCast(value.?));
}
