#import "frontmost.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

@interface PandaBorderHostView : NSView
@end

@implementation PandaBorderHostView

- (BOOL)isOpaque {
    return NO;
}

@end

static NSMutableDictionary<NSNumber *, NSWindow *> *gPandaOverlayWindows;
static NSMutableDictionary<NSNumber *, CALayer *> *gPandaBorderLayers;
static NSMutableDictionary<NSNumber *, NSNumber *> *gPandaWindowToScreen;
static bool gPandaBordersVisible = true;

static NSMutableDictionary<NSNumber *, NSValue *> *gPandaHotkeyRefs;
static EventHandlerRef gPandaHotkeyHandler = NULL;
static CFMachPortRef gPandaHotkeyEventTap = NULL;
static CFRunLoopSourceRef gPandaHotkeyEventTapSource = NULL;
typedef struct PandaRegisteredHotkey {
    uint32_t id;
    uint16_t key_code;
    uint32_t modifiers;
    bool active;
} PandaRegisteredHotkey;
static PandaRegisteredHotkey gPandaRegisteredHotkeys[512];
static const int gPandaRegisteredHotkeyCapacity = 512;
static const int gPandaHotkeyQueueCapacity = 256;
static uint32_t gPandaHotkeyQueue[256];
static int gPandaHotkeyQueueRead = 0;
static int gPandaHotkeyQueueWrite = 0;

static UInt32 PandaToCarbonModifiers(uint32_t modifiers) {
    UInt32 result = 0;
    if ((modifiers & PANDA_MOD_COMMAND) != 0) result |= cmdKey;
    if ((modifiers & PANDA_MOD_CONTROL) != 0) result |= controlKey;
    if ((modifiers & PANDA_MOD_OPTION) != 0) result |= optionKey;
    if ((modifiers & PANDA_MOD_SHIFT) != 0) result |= shiftKey;
    return result;
}

static uint32_t PandaFromEventFlags(CGEventFlags flags) {
    uint32_t result = 0;
    if ((flags & kCGEventFlagMaskCommand) != 0) result |= PANDA_MOD_COMMAND;
    if ((flags & kCGEventFlagMaskControl) != 0) result |= PANDA_MOD_CONTROL;
    if ((flags & kCGEventFlagMaskAlternate) != 0) result |= PANDA_MOD_OPTION;
    if ((flags & kCGEventFlagMaskShift) != 0) result |= PANDA_MOD_SHIFT;
    return result;
}

static CGEventFlags PandaToEventFlags(uint32_t modifiers) {
    CGEventFlags flags = 0;
    if ((modifiers & PANDA_MOD_COMMAND) != 0) flags |= kCGEventFlagMaskCommand;
    if ((modifiers & PANDA_MOD_CONTROL) != 0) flags |= kCGEventFlagMaskControl;
    if ((modifiers & PANDA_MOD_OPTION) != 0) flags |= kCGEventFlagMaskAlternate;
    if ((modifiers & PANDA_MOD_SHIFT) != 0) flags |= kCGEventFlagMaskShift;
    return flags;
}

static void PandaPushHotkeyEvent(uint32_t hotkey_id) {
    const int next = (gPandaHotkeyQueueWrite + 1) % gPandaHotkeyQueueCapacity;
    if (next == gPandaHotkeyQueueRead) {
        gPandaHotkeyQueueRead = (gPandaHotkeyQueueRead + 1) % gPandaHotkeyQueueCapacity;
    }

    gPandaHotkeyQueue[gPandaHotkeyQueueWrite] = hotkey_id;
    gPandaHotkeyQueueWrite = next;
}

static void PandaStoreRegisteredHotkey(uint32_t hotkey_id, uint16_t key_code, uint32_t modifiers) {
    for (int i = 0; i < gPandaRegisteredHotkeyCapacity; i++) {
        if (gPandaRegisteredHotkeys[i].active && gPandaRegisteredHotkeys[i].id == hotkey_id) {
            gPandaRegisteredHotkeys[i].key_code = key_code;
            gPandaRegisteredHotkeys[i].modifiers = modifiers;
            return;
        }
    }

    for (int i = 0; i < gPandaRegisteredHotkeyCapacity; i++) {
        if (!gPandaRegisteredHotkeys[i].active) {
            gPandaRegisteredHotkeys[i] = (PandaRegisteredHotkey){
                .id = hotkey_id,
                .key_code = key_code,
                .modifiers = modifiers,
                .active = true,
            };
            return;
        }
    }
}

static void PandaRemoveRegisteredHotkey(uint32_t hotkey_id) {
    for (int i = 0; i < gPandaRegisteredHotkeyCapacity; i++) {
        if (gPandaRegisteredHotkeys[i].active && gPandaRegisteredHotkeys[i].id == hotkey_id) {
            gPandaRegisteredHotkeys[i].active = false;
            return;
        }
    }
}

static CGEventRef PandaHotkeyEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gPandaHotkeyEventTap != NULL) {
            CGEventTapEnable(gPandaHotkeyEventTap, true);
        }
        return event;
    }

    if (type != kCGEventKeyDown) return event;

    const uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    const uint32_t modifiers = PandaFromEventFlags(CGEventGetFlags(event));

    for (int i = 0; i < gPandaRegisteredHotkeyCapacity; i++) {
        if (!gPandaRegisteredHotkeys[i].active) continue;
        if (gPandaRegisteredHotkeys[i].key_code == key_code && gPandaRegisteredHotkeys[i].modifiers == modifiers) {
            PandaPushHotkeyEvent(gPandaRegisteredHotkeys[i].id);
            return NULL;
        }
    }

    return event;
}

static void PandaEnsureHotkeyEventTap(void) {
    if (gPandaHotkeyEventTap != NULL) return;

    gPandaHotkeyEventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventKeyDown),
        PandaHotkeyEventTapCallback,
        NULL
    );
    if (gPandaHotkeyEventTap == NULL) return;

    gPandaHotkeyEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gPandaHotkeyEventTap, 0);
    if (gPandaHotkeyEventTapSource == NULL) {
        CFRelease(gPandaHotkeyEventTap);
        gPandaHotkeyEventTap = NULL;
        return;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), gPandaHotkeyEventTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gPandaHotkeyEventTap, true);
}

static int PandaDrainHotkeyEvents(uint32_t *out_hotkey_ids, int capacity) {
    if (out_hotkey_ids == NULL || capacity <= 0) {
        return 0;
    }

    int count = 0;
    while (gPandaHotkeyQueueRead != gPandaHotkeyQueueWrite && count < capacity) {
        out_hotkey_ids[count] = gPandaHotkeyQueue[gPandaHotkeyQueueRead];
        gPandaHotkeyQueueRead = (gPandaHotkeyQueueRead + 1) % gPandaHotkeyQueueCapacity;
        count++;
    }
    return count;
}

bool pandaPromptForAccessibility(void) {
    NSDictionary *options = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static OSStatus PandaHotkeyEventHandler(EventHandlerCallRef next_handler, EventRef event, void *user_data) {
    (void)next_handler;
    (void)user_data;
    EventHotKeyID hotkey = {0};
    const OSStatus status = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        NULL,
        sizeof(hotkey),
        NULL,
        &hotkey
    );
    if (status == noErr) {
        PandaPushHotkeyEvent(hotkey.id);
    }
    return noErr;
}

static CGFloat PandaIntersectionArea(CGRect lhs, CGRect rhs) {
    CGRect intersection = CGRectIntersection(lhs, rhs);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) {
        return 0.0;
    }
    return intersection.size.width * intersection.size.height;
}

static NSNumber *PandaDisplayIdForScreen(NSScreen *screen) {
    NSNumber *screen_number = screen.deviceDescription[@"NSScreenNumber"];
    if (screen_number == nil) {
        return nil;
    }
    return @((uint32_t)screen_number.unsignedIntValue);
}

static NSDictionary<NSNumber *, NSDictionary *> *PandaCopyScreenInfo(void) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *result = [NSMutableDictionary dictionary];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *display_id = PandaDisplayIdForScreen(screen);
        if (display_id == nil) {
            continue;
        }

        CGRect cg_bounds = CGDisplayBounds((CGDirectDisplayID)display_id.unsignedIntValue);
        result[display_id] = @{
            @"screen": screen,
            @"cg_bounds": [NSValue valueWithRect:NSRectFromCGRect(cg_bounds)],
        };
    }
    return result;
}

static NSDictionary *PandaScreenInfoForBounds(CGRect bounds, NSDictionary<NSNumber *, NSDictionary *> *screen_info) {
    NSDictionary *best_info = nil;
    CGFloat best_area = 0.0;

    for (NSDictionary *entry in screen_info.objectEnumerator) {
        CGRect cg_bounds = [entry[@"cg_bounds"] rectValue];
        const CGFloat area = PandaIntersectionArea(bounds, cg_bounds);
        if (area > best_area + 0.5) {
            best_area = area;
            best_info = entry;
        }
    }

    if (best_info != nil) {
        return best_info;
    }

    for (NSDictionary *entry in screen_info.objectEnumerator) {
        CGRect cg_bounds = [entry[@"cg_bounds"] rectValue];
        if (CGRectContainsPoint(cg_bounds, CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)))) {
            return entry;
        }
    }

    return screen_info.allValues.firstObject;
}

static NSRect PandaLocalFrameForBounds(CGRect bounds, CGRect screen_bounds, BOOL active) {
    const CGFloat padding = active ? 2.0 : 1.0;
    return NSMakeRect(
        bounds.origin.x - screen_bounds.origin.x - padding,
        CGRectGetMaxY(screen_bounds) - CGRectGetMaxY(bounds) - padding,
        bounds.size.width + padding * 2.0,
        bounds.size.height + padding * 2.0
    );
}

static NSArray<NSDictionary *> *PandaCopyWindowDescriptions(const PandaBorderFrame *frames, int count) {
    NSMutableArray *window_ids = [NSMutableArray arrayWithCapacity:MAX(count, 0)];
    for (int index = 0; index < count; index++) {
        if (frames[index].window_id == 0) {
            continue;
        }
        [window_ids addObject:@(frames[index].window_id)];
    }

    if (window_ids.count == 0) {
        return @[];
    }

    CFArrayRef descriptions = CGWindowListCreateDescriptionFromArray((__bridge CFArrayRef)window_ids);
    if (descriptions == NULL) {
        return @[];
    }

    NSArray *result = CFBridgingRelease(descriptions);
    return [result isKindOfClass:[NSArray class]] ? result : @[];
}

static NSDictionary<NSNumber *, NSDictionary *> *PandaCopyLiveWindowMap(const PandaBorderFrame *frames, int count) {
    NSArray<NSDictionary *> *descriptions = PandaCopyWindowDescriptions(frames, count);
    NSMutableDictionary<NSNumber *, NSDictionary *> *result = [NSMutableDictionary dictionaryWithCapacity:descriptions.count];

    for (NSDictionary *description in descriptions) {
        NSNumber *window_id = description[(id)kCGWindowNumber];
        NSDictionary *bounds_dict = description[(id)kCGWindowBounds];
        NSNumber *layer = description[(id)kCGWindowLayer];
        NSNumber *owner_pid = description[(id)kCGWindowOwnerPID];
        NSNumber *onscreen = description[(id)kCGWindowIsOnscreen];
        if (window_id == nil || bounds_dict == nil || layer == nil || owner_pid == nil || onscreen == nil) {
            continue;
        }
        if (layer.intValue != 0 || owner_pid.intValue == getpid() || !onscreen.boolValue) {
            continue;
        }

        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds_dict, &bounds)) {
            continue;
        }
        if (bounds.size.width < 60.0 || bounds.size.height < 60.0) {
            continue;
        }

        result[window_id] = @{
            @"bounds": [NSValue valueWithRect:NSRectFromCGRect(bounds)],
        };
    }

    return result;
}

static CAShapeLayer *PandaStrokeLayer(NSColor *color, CGFloat alpha, CGFloat width, CGFloat dash) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.fillColor = NSColor.clearColor.CGColor;
    layer.strokeColor = [color colorWithAlphaComponent:alpha].CGColor;
    layer.lineWidth = width;
    layer.lineCap = kCALineCapButt;
    layer.lineJoin = kCALineJoinRound;
    layer.lineDashPattern = @[ @(dash), @(dash) ];
    return layer;
}

static CALayer *PandaCreateBorderLayer(void) {
    CALayer *container = [CALayer layer];
    container.anchorPoint = CGPointZero;
    container.actions = @{
        @"bounds": [NSNull null],
        @"position": [NSNull null],
        @"frame": [NSNull null],
        @"hidden": [NSNull null],
    };

    CAShapeLayer *black = PandaStrokeLayer(NSColor.blackColor, 0.86, 3.5, 9.0);
    black.name = @"black";
    black.actions = @{
        @"path": [NSNull null],
        @"lineWidth": [NSNull null],
        @"strokeColor": [NSNull null],
        @"lineDashPhase": [NSNull null],
    };

    CAShapeLayer *white = PandaStrokeLayer(NSColor.whiteColor, 0.82, 3.5, 9.0);
    white.name = @"white";
    white.lineDashPhase = 9.0;
    white.actions = black.actions;

    [container addSublayer:black];
    [container addSublayer:white];
    return container;
}

static void PandaUpdateBorderLayer(CALayer *container, NSRect frame, BOOL active) {
    const CGFloat width = active ? 4.0 : 3.0;
    const CGFloat dash = active ? 10.0 : 8.0;
    const CGFloat radius = active ? 14.0 : 12.0;
    const CGFloat inset = width * 0.5 + 0.5;
    const CGRect local_bounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
    const CGRect stroke_rect = CGRectInset(local_bounds, inset, inset);
    CGPathRef path = CGPathCreateWithRoundedRect(stroke_rect, radius, radius, NULL);

    container.frame = frame;

    CAShapeLayer *black = (CAShapeLayer *)[container.sublayers firstObject];
    CAShapeLayer *white = (CAShapeLayer *)[container.sublayers lastObject];
    for (CAShapeLayer *layer in @[ black, white ]) {
        layer.frame = local_bounds;
        layer.path = path;
        layer.lineWidth = width;
        layer.lineDashPattern = @[ @(dash), @(dash) ];
    }

    black.strokeColor = [[NSColor colorWithWhite:0.0 alpha:(active ? 0.94 : 0.78)] CGColor];
    black.lineDashPhase = 0.0;

    white.strokeColor = [[NSColor colorWithWhite:1.0 alpha:(active ? 0.9 : 0.72)] CGColor];
    white.lineDashPhase = dash;

    CGPathRelease(path);
}

static NSWindow *PandaCreateOverlayWindow(NSScreen *screen) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO
                                                      screen:screen];
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.releasedWhenClosed = NO;
    window.level = NSFloatingWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorIgnoresCycle;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    window.excludedFromWindowsMenu = YES;

    PandaBorderHostView *view = [[PandaBorderHostView alloc] initWithFrame:NSMakeRect(0.0, 0.0, screen.frame.size.width, screen.frame.size.height)];
    view.wantsLayer = YES;
    view.layer = [CALayer layer];
    view.layer.masksToBounds = NO;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = view;
    return window;
}

static void PandaEnsureStores(void) {
    pandaEnsureAppKitReady();
    if (gPandaOverlayWindows == nil) {
        gPandaOverlayWindows = [[NSMutableDictionary alloc] init];
    }
    if (gPandaBorderLayers == nil) {
        gPandaBorderLayers = [[NSMutableDictionary alloc] init];
    }
    if (gPandaWindowToScreen == nil) {
        gPandaWindowToScreen = [[NSMutableDictionary alloc] init];
    }
}

static NSWindow *PandaOverlayWindowForScreen(NSNumber *screen_key, NSScreen *screen) {
    NSWindow *window = gPandaOverlayWindows[screen_key];
    if (window == nil) {
        window = PandaCreateOverlayWindow(screen);
        gPandaOverlayWindows[screen_key] = window;
    } else if (!NSEqualRects(window.frame, screen.frame)) {
        [window setFrame:screen.frame display:NO];
    }
    return window;
}

static void PandaRemoveBorderLayer(NSNumber *window_key) {
    CALayer *layer = gPandaBorderLayers[window_key];
    if (layer != nil) {
        [layer removeFromSuperlayer];
        [gPandaBorderLayers removeObjectForKey:window_key];
    }
    [gPandaWindowToScreen removeObjectForKey:window_key];
}

bool pandaCopyFrontmostApp(PandaFrontmostApp *out_app) {
    if (out_app == NULL) {
        return false;
    }

    memset(out_app, 0, sizeof(*out_app));

    @autoreleasepool {
        NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (app == nil) {
            return false;
        }

        out_app->pid = app.processIdentifier;

        NSString *name = app.localizedName;
        if (name != nil) {
            strncpy(out_app->name, name.UTF8String ?: "", sizeof(out_app->name) - 1);
        }

        NSURL *bundle_url = app.bundleURL;
        if (bundle_url != nil) {
            strncpy(out_app->bundle_path, bundle_url.path.UTF8String ?: "", sizeof(out_app->bundle_path) - 1);
        }

        NSURL *executable_url = app.executableURL;
        if (executable_url != nil) {
            strncpy(out_app->executable_path, executable_url.path.UTF8String ?: "", sizeof(out_app->executable_path) - 1);
        }
    }

    return out_app->pid > 0;
}

int pandaListRunningGuiApps(PandaFrontmostApp *out_apps, int capacity) {
    if (out_apps == NULL || capacity <= 0) {
        return 0;
    }

    @autoreleasepool {
        NSArray<NSRunningApplication *> *apps = NSWorkspace.sharedWorkspace.runningApplications;
        int count = 0;

        for (NSRunningApplication *app in apps) {
            if (count >= capacity) break;
            if (app.processIdentifier == getpid()) continue;
            if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
            if (app.isTerminated) continue;

            PandaFrontmostApp *out = &out_apps[count];
            memset(out, 0, sizeof(*out));
            out->pid = app.processIdentifier;

            NSString *name = app.localizedName;
            if (name != nil) {
                strncpy(out->name, name.UTF8String ?: "", sizeof(out->name) - 1);
            }

            NSURL *bundle_url = app.bundleURL;
            if (bundle_url != nil) {
                strncpy(out->bundle_path, bundle_url.path.UTF8String ?: "", sizeof(out->bundle_path) - 1);
            }

            NSURL *executable_url = app.executableURL;
            if (executable_url != nil) {
                strncpy(out->executable_path, executable_url.path.UTF8String ?: "", sizeof(out->executable_path) - 1);
            }

            count++;
        }

        return count;
    }
}

int pandaListWindowsOnCurrentSpace(PandaWindowInfo *out_windows, int capacity) {
    if (out_windows == NULL || capacity <= 0) {
        return 0;
    }

    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID
    );
    if (windowList == NULL) {
        return 0;
    }

    int count = 0;
    CFIndex windowCount = CFArrayGetCount(windowList);
    for (CFIndex index = 0; index < windowCount && count < capacity; index++) {
        CFDictionaryRef window = CFArrayGetValueAtIndex(windowList, index);

        CFNumberRef layerRef = CFDictionaryGetValue(window, kCGWindowLayer);
        int layer = 0;
        if (layerRef != NULL) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) continue;

        CFNumberRef pidRef = CFDictionaryGetValue(window, kCGWindowOwnerPID);
        pid_t pid = 0;
        if (pidRef != NULL) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (pid <= 0) continue;

        CFNumberRef windowIdRef = CFDictionaryGetValue(window, kCGWindowNumber);
        uint32_t windowId = 0;
        if (windowIdRef != NULL) {
            CFNumberGetValue(windowIdRef, kCFNumberIntType, &windowId);
        }

        CFDictionaryRef boundsRef = CFDictionaryGetValue(window, kCGWindowBounds);
        CGRect bounds = CGRectZero;
        if (boundsRef != NULL) {
            CGRectMakeWithDictionaryRepresentation(boundsRef, &bounds);
        }
        if (bounds.size.width < 50 || bounds.size.height < 50) continue;

        CFBooleanRef onScreenRef = CFDictionaryGetValue(window, kCGWindowIsOnscreen);
        bool isOnScreen = (onScreenRef != NULL && CFBooleanGetValue(onScreenRef));

        out_windows[count].window_id = windowId;
        out_windows[count].pid = pid;
        out_windows[count].bounds = bounds;
        out_windows[count].is_on_screen = isOnScreen;
        count++;
    }

    CFRelease(windowList);
    return count;
}

void *NSScreen_mainScreen(void) {
    @autoreleasepool {
        return (__bridge void *)NSScreen.mainScreen;
    }
}

CGRect NSScreen_visibleFrame(void *screen) {
    @autoreleasepool {
        NSScreen *ns_screen = (__bridge NSScreen *)screen;
        if (ns_screen == nil) {
            return CGRectZero;
        }
        return ns_screen.visibleFrame;
    }
}

CGRect NSScreen_frame(void *screen) {
    @autoreleasepool {
        NSScreen *ns_screen = (__bridge NSScreen *)screen;
        if (ns_screen == nil) {
            return CGRectZero;
        }
        return ns_screen.frame;
    }
}

void pandaEnsureAppKitReady(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

pid_t pandaCurrentProcessId(void) {
    return getpid();
}

void pandaSyncBorders(const PandaBorderFrame *frames, int count) {
    @autoreleasepool {
        PandaEnsureStores();

        NSDictionary<NSNumber *, NSDictionary *> *screen_info = PandaCopyScreenInfo();
        NSDictionary<NSNumber *, NSDictionary *> *live_windows = PandaCopyLiveWindowMap(frames, count);
        NSMutableSet<NSNumber *> *seen_windows = [NSMutableSet set];
        NSMutableSet<NSNumber *> *seen_screens = [NSMutableSet set];

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        for (int index = 0; index < count; index++) {
            NSNumber *window_key = @(frames[index].window_id);
            if (frames[index].window_id == 0 || [seen_windows containsObject:window_key]) {
                continue;
            }
            [seen_windows addObject:window_key];

            NSDictionary *window_info = live_windows[window_key];
            if (window_info == nil) {
                PandaRemoveBorderLayer(window_key);
                continue;
            }

            CGRect bounds = [window_info[@"bounds"] rectValue];
            NSDictionary *target_screen = PandaScreenInfoForBounds(bounds, screen_info);
            if (target_screen == nil) {
                PandaRemoveBorderLayer(window_key);
                continue;
            }

            NSScreen *screen = target_screen[@"screen"];
            NSNumber *screen_key = PandaDisplayIdForScreen(screen);
            if (screen_key == nil) {
                PandaRemoveBorderLayer(window_key);
                continue;
            }

            CGRect screen_bounds = [target_screen[@"cg_bounds"] rectValue];
            NSRect local_frame = PandaLocalFrameForBounds(bounds, screen_bounds, frames[index].is_active ? YES : NO);
            if (local_frame.size.width < 20.0 || local_frame.size.height < 20.0) {
                PandaRemoveBorderLayer(window_key);
                continue;
            }

            NSWindow *overlay = PandaOverlayWindowForScreen(screen_key, screen);
            PandaBorderHostView *host_view = (PandaBorderHostView *)overlay.contentView;
            CALayer *host_layer = host_view.layer;
            if (host_layer == nil) {
                host_view.wantsLayer = YES;
                host_view.layer = [CALayer layer];
                host_layer = host_view.layer;
            }

            CALayer *border_layer = gPandaBorderLayers[window_key];
            if (border_layer == nil) {
                border_layer = PandaCreateBorderLayer();
                gPandaBorderLayers[window_key] = border_layer;
            }
            if (border_layer.superlayer != host_layer) {
                [border_layer removeFromSuperlayer];
                [host_layer addSublayer:border_layer];
            }

            PandaUpdateBorderLayer(border_layer, local_frame, frames[index].is_active ? YES : NO);
            gPandaWindowToScreen[window_key] = screen_key;
            [seen_screens addObject:screen_key];
        }

        for (NSNumber *window_key in [gPandaBorderLayers.allKeys copy]) {
            if (![seen_windows containsObject:window_key]) {
                PandaRemoveBorderLayer(window_key);
            }
        }

        for (NSNumber *screen_key in [gPandaOverlayWindows.allKeys copy]) {
            NSWindow *overlay = gPandaOverlayWindows[screen_key];
            BOOL has_visible_layers = NO;
            for (NSNumber *window_key in gPandaWindowToScreen) {
                if ([gPandaWindowToScreen[window_key] isEqualToNumber:screen_key] && gPandaBorderLayers[window_key] != nil) {
                    has_visible_layers = YES;
                    break;
                }
            }

            if (!has_visible_layers) {
                [overlay orderOut:nil];
                [overlay close];
                [gPandaOverlayWindows removeObjectForKey:screen_key];
                continue;
            }

            if (gPandaBordersVisible) {
                [overlay orderFront:nil];
            } else {
                [overlay orderOut:nil];
            }
        }

        [CATransaction commit];
    }
}

void pandaClearBorders(void) {
    @autoreleasepool {
        PandaEnsureStores();
        for (NSNumber *window_key in [gPandaBorderLayers.allKeys copy]) {
            PandaRemoveBorderLayer(window_key);
        }
        for (NSNumber *screen_key in [gPandaOverlayWindows.allKeys copy]) {
            NSWindow *window = gPandaOverlayWindows[screen_key];
            [window orderOut:nil];
            [window close];
        }
        [gPandaOverlayWindows removeAllObjects];
    }
}

void pandaSetBordersVisible(bool visible) {
    @autoreleasepool {
        PandaEnsureStores();
        gPandaBordersVisible = visible;
        for (NSWindow *window in gPandaOverlayWindows.objectEnumerator) {
            if (visible) {
                [window orderFront:nil];
            } else {
                [window orderOut:nil];
            }
        }
    }
}

typedef int (*PandaCGSMainConnectionIDFn)(void);
typedef CFArrayRef (*PandaCGSCopyManagedDisplaySpacesFn)(int connection);
typedef uint64_t (*PandaCGSGetActiveSpaceFn)(int connection);
typedef int (*PandaCGSManagedDisplaySetCurrentSpaceFn)(int connection, CFStringRef display, uint64_t space_id);

static void *PandaSkyLightSymbol(const char *name) {
    static void *handle = NULL;
    if (handle == NULL) {
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    }
    return handle == NULL ? NULL : dlsym(handle, name);
}

static NSArray<NSNumber *> *PandaCopyDesktopSpaceIds(NSString **out_display_uuid, NSUInteger *out_active_index) {
    PandaCGSMainConnectionIDFn main_connection = (PandaCGSMainConnectionIDFn)PandaSkyLightSymbol("CGSMainConnectionID");
    PandaCGSCopyManagedDisplaySpacesFn copy_spaces = (PandaCGSCopyManagedDisplaySpacesFn)PandaSkyLightSymbol("CGSCopyManagedDisplaySpaces");
    PandaCGSGetActiveSpaceFn active_space = (PandaCGSGetActiveSpaceFn)PandaSkyLightSymbol("CGSGetActiveSpace");
    if (main_connection == NULL || copy_spaces == NULL || active_space == NULL) return @[];

    int connection = main_connection();
    uint64_t active_id = active_space(connection);
    CFArrayRef raw_displays = copy_spaces(connection);
    if (raw_displays == NULL) return @[];

    NSArray *displays = CFBridgingRelease(raw_displays);
    for (NSDictionary *display in displays) {
        NSArray *spaces = display[@"Spaces"];
        if (![spaces isKindOfClass:NSArray.class]) continue;

        NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
        NSUInteger active_index = NSNotFound;
        for (NSDictionary *space in spaces) {
            NSNumber *space_id = space[@"ManagedSpaceID"];
            NSNumber *tile_layout = space[@"TileLayoutManager"];
            if (space_id == nil || tile_layout != nil) continue;

            if (space_id.unsignedLongLongValue == active_id) active_index = ids.count;
            [ids addObject:space_id];
        }

        if (active_index != NSNotFound && ids.count > 0) {
            if (out_display_uuid != NULL) {
                NSString *uuid = display[@"Display Identifier"] ?: @"Main";
                *out_display_uuid = uuid;
            }
            if (out_active_index != NULL) *out_active_index = active_index;
            return ids;
        }
    }

    return @[];
}

static bool PandaSetDesktopSpace(uint64_t space_id, NSString *display_uuid) {
    PandaCGSMainConnectionIDFn main_connection = (PandaCGSMainConnectionIDFn)PandaSkyLightSymbol("CGSMainConnectionID");
    PandaCGSManagedDisplaySetCurrentSpaceFn set_space = (PandaCGSManagedDisplaySetCurrentSpaceFn)PandaSkyLightSymbol("CGSManagedDisplaySetCurrentSpace");
    if (main_connection == NULL || set_space == NULL || display_uuid == nil) return false;
    return set_space(main_connection(), (__bridge CFStringRef)display_uuid, space_id) == 0;
}

bool pandaGetDesktopState(int *out_active_index, int *out_count) {
    @autoreleasepool {
        NSUInteger active_index = NSNotFound;
        NSArray<NSNumber *> *ids = PandaCopyDesktopSpaceIds(NULL, &active_index);
        if (ids.count == 0 || active_index == NSNotFound) return false;
        if (out_active_index != NULL) *out_active_index = (int)active_index + 1;
        if (out_count != NULL) *out_count = (int)ids.count;
        return true;
    }
}

bool pandaSwitchDesktopRelative(int direction) {
    @autoreleasepool {
        NSString *display_uuid = nil;
        NSUInteger active_index = NSNotFound;
        NSArray<NSNumber *> *ids = PandaCopyDesktopSpaceIds(&display_uuid, &active_index);
        if (ids.count <= 1 || active_index == NSNotFound) return false;

        NSInteger next = (NSInteger)active_index + (direction < 0 ? -1 : 1);
        if (next < 0) next = (NSInteger)ids.count - 1;
        if (next >= (NSInteger)ids.count) next = 0;
        return PandaSetDesktopSpace(ids[(NSUInteger)next].unsignedLongLongValue, display_uuid);
    }
}

bool pandaSwitchDesktopIndex(int desktop_index) {
    @autoreleasepool {
        if (desktop_index < 1) return false;
        NSString *display_uuid = nil;
        NSArray<NSNumber *> *ids = PandaCopyDesktopSpaceIds(&display_uuid, NULL);
        NSUInteger index = (NSUInteger)(desktop_index - 1);
        if (index >= ids.count) return false;
        return PandaSetDesktopSpace(ids[index].unsignedLongLongValue, display_uuid);
    }
}

bool pandaPostKeyChord(uint16_t key_code, uint32_t modifiers) {
    @autoreleasepool {
        pandaEnsureAppKitReady();

        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (source == NULL) {
            return false;
        }

        CGEventRef key_down = CGEventCreateKeyboardEvent(source, (CGKeyCode)key_code, true);
        CGEventRef key_up = CGEventCreateKeyboardEvent(source, (CGKeyCode)key_code, false);
        if (key_down == NULL || key_up == NULL) {
            if (key_down != NULL) CFRelease(key_down);
            if (key_up != NULL) CFRelease(key_up);
            CFRelease(source);
            return false;
        }

        const CGEventFlags flags = PandaToEventFlags(modifiers);
        CGEventSetFlags(key_down, flags);
        CGEventSetFlags(key_up, flags);

        CGEventPost(kCGHIDEventTap, key_down);
        CGEventPost(kCGHIDEventTap, key_up);

        CFRelease(key_down);
        CFRelease(key_up);
        CFRelease(source);
        return true;
    }
}

void pandaHotkeysInitialize(void) {
    @autoreleasepool {
        pandaEnsureAppKitReady();

        if (gPandaHotkeyRefs == nil) {
            gPandaHotkeyRefs = [[NSMutableDictionary alloc] init];
        }

        PandaEnsureHotkeyEventTap();

        if (gPandaHotkeyHandler == NULL) {
            EventTypeSpec spec = {
                .eventClass = kEventClassKeyboard,
                .eventKind = kEventHotKeyPressed,
            };
            InstallEventHandler(
                GetApplicationEventTarget(),
                PandaHotkeyEventHandler,
                1,
                &spec,
                NULL,
                &gPandaHotkeyHandler
            );
        }
    }
}

bool pandaRegisterHotkey(uint32_t hotkey_id, uint16_t key_code, uint32_t modifiers) {
    @autoreleasepool {
        pandaHotkeysInitialize();
        if (gPandaHotkeyRefs == nil) {
            return false;
        }

        NSNumber *key = @(hotkey_id);
        NSValue *existing = gPandaHotkeyRefs[key];
        if (existing != nil) {
            EventHotKeyRef existing_ref = (EventHotKeyRef)existing.pointerValue;
            if (existing_ref != NULL) {
                UnregisterEventHotKey(existing_ref);
            }
            [gPandaHotkeyRefs removeObjectForKey:key];
            PandaRemoveRegisteredHotkey(hotkey_id);
        }

        EventHotKeyRef hotkey_ref = NULL;
        EventHotKeyID event_hotkey_id = {
            .signature = 'pnda',
            .id = hotkey_id,
        };

        PandaStoreRegisteredHotkey(hotkey_id, key_code, modifiers);

        const OSStatus status = RegisterEventHotKey(
            (UInt32)key_code,
            PandaToCarbonModifiers(modifiers),
            event_hotkey_id,
            GetApplicationEventTarget(),
            0,
            &hotkey_ref
        );

        if (status != noErr || hotkey_ref == NULL) {
            return false;
        }

        gPandaHotkeyRefs[key] = [NSValue valueWithPointer:hotkey_ref];
        return true;
    }
}

void pandaClearHotkeys(void) {
    @autoreleasepool {
        if (gPandaHotkeyRefs != nil) {
            for (NSValue *value in gPandaHotkeyRefs.objectEnumerator) {
                EventHotKeyRef hotkey_ref = (EventHotKeyRef)value.pointerValue;
                if (hotkey_ref != NULL) {
                    UnregisterEventHotKey(hotkey_ref);
                }
            }
            [gPandaHotkeyRefs removeAllObjects];
        }

        for (int i = 0; i < gPandaRegisteredHotkeyCapacity; i++) {
            gPandaRegisteredHotkeys[i].active = false;
        }

        gPandaHotkeyQueueRead = 0;
        gPandaHotkeyQueueWrite = 0;
    }
}

int pandaDrainHotkeys(uint32_t *out_hotkey_ids, int capacity) {
    @autoreleasepool {
        return PandaDrainHotkeyEvents(out_hotkey_ids, capacity);
    }
}
