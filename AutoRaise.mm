/*
 * AutoRaise - Copyright (C) 2023 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// g++ -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -o AutoRaise AutoRaise.mm \
//   -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>

#define AUTORAISE_VERSION "3.7"
#define STACK_THRESHOLD 20

#define __MAC_11_06_0 110600
#define __MAC_12_00_0 120000

#ifdef EXPERIMENTAL_FOCUS_FIRST
#if SKYLIGHT_AVAILABLE
// Focus first is an experimental feature that can break easily across different OSX
// versions. It relies on the private Skylight api. As such, there are absolutely no
// guarantees that this feature will keep on working in future versions of AutoRaise.
#define FOCUS_FIRST
#else
#pragma message "Skylight api is unavailable, Focus First is disabled"
#endif
#endif

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_12_00_0
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
static CGPoint oldCorrectedPoint = {0, 0};
#endif

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.

#ifdef FOCUS_FIRST
#define kCPSUserGenerated 0x200
extern "C" CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern "C" CGError _SLPSSetFrontProcessWithOptions(
  ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);

/* -----------Could these be a replacement for GetProcessForPID?-----------
extern "C" int SLSMainConnectionID(void);
extern "C" CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern "C" CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
int element_connection;
SLSGetWindowOwner(SLSMainConnectionID(), window_id, &element_connection);
SLSGetConnectionPSN(element_connection, &window_psn);
-------------------------------------------------------------------------*/
#endif

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

#ifdef FOCUS_FIRST
static pid_t lastFocusedWindow_pid;
static AXUIElementRef _lastFocusedWindow = NULL;
static CGWindowID lastFocusedWindow_id = 0;
#endif

CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static const NSString * IntelliJ = @"IntelliJ IDEA";
static const NSString * Dock = @"com.apple.dock";
static const NSString * Finder = @"com.apple.finder";
static const NSString * AssistiveControl = @"AssistiveControl";
static const NSString * Photos = @"Photos";
static const NSString * BartenderBar = @"Bartender Bar";
static const NSString * Launchpad = @"Launchpad";
static const NSString * XQuartz = @"XQuartz";
static const NSString * NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool ignoreSpaceChanged = false;
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool altTaskSwitcher = false;
static bool warpMouse = false;
static bool verbose = false;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static float mouseDelta = 0;
static int ignoreTimes = 0;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;
static int pollMillis = 0;
static int disableKey = 0;
#ifdef FOCUS_FIRST
static int raiseDelayCount = 0;
#endif

//----------------------------------------yabai focus only methods------------------------------------------

#ifdef FOCUS_FIRST
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
void window_manager_make_key_window(ProcessSerialNumber * _window_psn, uint32_t window_id) {
    uint8_t bytes1[0xf8] = { [0x04] = 0xf8, [0x08] = 0x01, [0x3a] = 0x10 };
    uint8_t bytes2[0xf8] = { [0x04] = 0xf8, [0x08] = 0x02, [0x3a] = 0x10 };

    memcpy(bytes1 + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes1 + 0x20, 0xFF, 0x10);

    memcpy(bytes2 + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes2 + 0x20, 0xFF, 0x10);

    SLPSPostEventRecordTo(_window_psn, bytes1);
    SLPSPostEventRecordTo(_window_psn, bytes2);
}

void window_manager_focus_window_without_raise(
    ProcessSerialNumber * _window_psn, uint32_t window_id,
    ProcessSerialNumber * _focused_window_psn, uint32_t focused_window_id
) {
    if (verbose) { NSLog(@"Focus"); }
    if (_focused_window_psn) {
        Boolean same_process;
        SameProcess(_window_psn, _focused_window_psn, &same_process);
        if (same_process) {
            if (verbose) { NSLog(@"Same process"); }
            uint8_t bytes1[0xf8] = { [0x04] = 0xf8, [0x08] = 0x0d, [0x8a] = 0x02 };
            memcpy(bytes1 + 0x3c, &focused_window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_focused_window_psn, bytes1);

            // @hack
            // Artificially delay the activation by 1ms. This is necessary
            // because some applications appear to be confused if both of
            // the events appear instantaneously.
            usleep(10000);

            uint8_t bytes2[0xf8] = { [0x04] = 0xf8, [0x08] = 0x0d, [0x8a] = 0x01 };
            memcpy(bytes2 + 0x3c, &window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_window_psn, bytes2);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#if MAC_OS_X_VERSION_MIN_REQUIRED < __MAC_11_06_0 or OLD_ACTIVATION_METHOD
    // Temporary solution as NSRunningApplication does not work properly on OSX 11.1
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        activateWithOptions: NSApplicationActivateIgnoringOtherApps];
#endif
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (verbose) { NSLog(@"Raise"); }
    if (AXUIElementPerformAction(_window, kAXRaiseAction) == kAXErrorSuccess) {
        activate(window_pid);
    }
}

inline bool titleEquals(AXUIElementRef _element, NSArray * _titles) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (_elementTitle) {
        equal = [_titles containsObject: (__bridge NSString *) _elementTitle];
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

        int x = [window_bounds_dict[@"X"] intValue];
        int y = [window_bounds_dict[@"Y"] intValue];
        int width = [window_bounds_dict[@"Width"] intValue];
        int height = [window_bounds_dict[@"Height"] intValue];
        NSRect window_bounds = NSMakeRect(x, y, width, height);
        if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
            top_window = window;
            break;
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    if (verbose) { NSLog(@"Fallback"); }
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

inline bool launchpad_active() {
    bool active = false;
    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i=0;!active && i != count;i++) {
            CFStringRef _element_role = NULL;
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            if (_element_role) {
                active = CFEqual(_element_role, kAXGroupRole) && titleEquals(_element, @[Launchpad]);
                CFRelease(_element_role);
            }
        }
        CFRelease(_children);
    }

    if (verbose && active) { NSLog(@"Launchpad is active"); }
    return active;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"Application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole) ||
                    CFEqual(_element_role, kAXPopUpButtonRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    bool xquartz = titleEquals(_element, @[XQuartz]);
                    if (xquartz) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such AutoRaise features (delay/warp) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    }
                    check_attributes = !xquartz;
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        _window = get_raisable_window(_element, point, 0);
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        if (verbose) { NSLog(@"Copy element: no accessibility support"); }
        _window = fallback(point);
    } else if (error == kAXErrorIllegalArgument) {
        // fallback, happens in some System Preferences windows
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        if (verbose) { NSLog(@"Copy element: no value"); }
        _window = fallback(point);
    } else if (error == kAXErrorAttributeUnsupported) {
        // no fallback, happens when hovering into volume/wifi menubar window
        if (verbose) { NSLog(@"Copy element: attribute unsupported"); }
    } else if (error == kAXErrorFailure) {
        // no fallback, happens when hovering over the menubar itself
        if (verbose) { NSLog(@"Copy element: failure"); }
    } else if (verbose) {
        NSLog(@"Copy element: AXError %d", error);
    }

    if (verbose) {
        if (_window) {
            CFStringRef _windowTitle = NULL;
            AXUIElementCopyAttributeValue(_window, kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
            NSLog(@"Mouse window: %@", _windowTitle);
            if (_windowTitle) { CFRelease(_windowTitle); }
        } else { NSLog(@"No raisable window"); }
    }

    return _window;
}

CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    AXValueRef _size = NULL;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
        if (_pos) {
            CGSize cg_size;
            CGPoint cg_pos;
            if (AXValueGetValue(_size, kAXValueCGSizeType, &cg_size) &&
                AXValueGetValue(_pos, kAXValueCGPointType, &cg_pos)) {
                mousepoint.x = cg_pos.x + (cg_size.width * warpX);
                mousepoint.y = cg_pos.y + (cg_size.height * warpY);
            }
            CFRelease(_pos);
        }
        CFRelease(_size);
    }

    return mousepoint;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    bool contained = false;
    AXValueRef _size1 = NULL;
    AXValueRef _size2 = NULL;
    AXValueRef _pos1 = NULL;
    AXValueRef _pos2 = NULL;

    AXUIElementCopyAttributeValue(_window1, kAXSizeAttribute, (CFTypeRef *) &_size1);
    if (_size1) {
        AXUIElementCopyAttributeValue(_window1, kAXPositionAttribute, (CFTypeRef *) &_pos1);
        if (_pos1) {
            AXUIElementCopyAttributeValue(_window2, kAXSizeAttribute, (CFTypeRef *) &_size2);
            if (_size2) {
                AXUIElementCopyAttributeValue(_window2, kAXPositionAttribute, (CFTypeRef *) &_pos2);
                if (_pos2) {
                    CGSize cg_size1;
                    CGSize cg_size2;
                    CGPoint cg_pos1;
                    CGPoint cg_pos2;
                    if (AXValueGetValue(_size1, kAXValueCGSizeType, &cg_size1) &&
                        AXValueGetValue(_pos1, kAXValueCGPointType, &cg_pos1) &&
                        AXValueGetValue(_size2, kAXValueCGSizeType, &cg_size2) &&
                        AXValueGetValue(_pos2, kAXValueCGPointType, &cg_pos2)) {
                        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
                            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
                            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
                    }
                    CFRelease(_pos2);
                }
                CFRelease(_size2);
            }
            CFRelease(_pos1);
        }
        CFRelease(_size1);
    }

    return contained;
}

AXUIElementRef findDockApplication() {
    AXUIElementRef _dock = NULL;
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: Dock]) {
            _dock = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }

    if (verbose && !_dock) { NSLog(@"Dock application isn't running"); }
    return _dock;
}

CGPoint findDesktopOrigin() {
    CGPoint origin = {0, 0};
    NSScreen * main_screen = NSScreen.screens[0];
    float mainScreenTop = NSMaxY(main_screen.frame);
    for (NSScreen * screen in [NSScreen screens]) {
        float screenOriginY = mainScreenTop - NSMaxY(screen.frame);
        if (screenOriginY < origin.y) { origin.y = screenOriginY; }
        if (screen.frame.origin.x < origin.x) { origin.x = screen.frame.origin.x; }
    }

    if (verbose) { NSLog(@"Desktop origin (%f, %f)", origin.x, origin.y); }
    return origin;
}

inline bool desktop_window(AXUIElementRef _window) {
    bool desktop_window = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        desktop_window = AXValueGetValue(_pos, kAXValueCGPointType, &cg_pos) &&
            NSEqualPoints(NSPointFromCGPoint(cg_pos), NSPointFromCGPoint(desktopOrigin));
        CFRelease(_pos);
    }

    if (verbose && desktop_window) { NSLog(@"Desktop window"); }
    return desktop_window;
}

#ifdef FOCUS_FIRST
inline bool main_window(AXUIElementRef _window) {
    bool main_window = false;
    CFBooleanRef _result = NULL;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        main_window = CFEqual(_result, kCFBooleanTrue);
        CFRelease(_result);
    }

    main_window = main_window && !titleEquals(_window, @[NoTitle]);
    if (verbose && !main_window) { NSLog(@"Not a main window"); }
    return main_window;
}
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_12_00_0
inline NSScreen * findScreen(CGPoint point) {
    NSScreen * main_screen = NSScreen.screens[0];
    point.y = NSMaxY(main_screen.frame) - point.y;
    for (NSScreen * screen in [NSScreen screens]) {
        if (NSPointInRect(NSPointFromCGPoint(point), screen.frame)) {
            return screen;
        }
    }
    return NULL;
}
#endif
//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
bool appActivated();
void onTick();

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

static MDWorkspaceWatcher * workspaceWatcher = NULL;

@implementation MDWorkspaceWatcher
- (id)init {
    if ((self = [super init])) {
        NSNotificationCenter * center =
            [[NSWorkspace sharedWorkspace] notificationCenter];
        [center
            addObserver: self
            selector: @selector(spaceChanged:)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil];
        if (warpMouse) {
            [center
                addObserver: self
                selector: @selector(appActivated:)
                name: NSWorkspaceDidActivateApplicationNotification
                object: nil];
            if (verbose) { NSLog(@"Registered app activated selector"); }
        }
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}

- (void)spaceChanged:(NSNotification *)notification {
    if (verbose) { NSLog(@"Space changed"); }
    spaceChanged();
}

- (void)appActivated:(NSNotification *)notification {
    if (verbose) { NSLog(@"App activated, waiting %0.3fs", ACTIVATE_DELAY_MS/1000.0); }
    [self performSelector: @selector(onAppActivated) withObject: nil afterDelay: ACTIVATE_DELAY_MS/1000.0];
}

- (void)onAppActivated {
    if (appActivated() && cursorScale != oldScale) {
        if (verbose) { NSLog(@"Set cursor scale after %0.3fs", SCALE_DELAY_MS/1000.0); }
        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: cursorScale]
            afterDelay: SCALE_DELAY_MS/1000.0];

        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: oldScale]
            afterDelay: SCALE_DURATION_MS/1000.0];
    }
}

- (void)onSetCursorScale:(NSNumber *)scale {
    if (verbose) { NSLog(@"Set cursor scale: %@", scale); }
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}

- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector: @selector(onTick:)
        withObject: timerInterval
        afterDelay: timerInterval.floatValue];
    onTick();
}

#ifdef FOCUS_FIRST
- (void)windowFocused:(AXUIElementRef)_window {
    if (verbose) { NSLog(@"Window focused, waiting %0.3fs", raiseDelayCount*pollMillis/1000.0); }
    [self performSelector: @selector(onWindowFocused:)
        withObject: [NSNumber numberWithUnsignedLong: (uint64_t) _window]
        afterDelay: raiseDelayCount*pollMillis/1000.0];
}

- (void)onWindowFocused:(NSNumber *)_window {
    if (_window.unsignedLongValue == (uint64_t) _lastFocusedWindow) {
        raiseAndActivate(_lastFocusedWindow, lastFocusedWindow_pid);
    } else if (verbose) { NSLog(@"Ignoring window focused event"); }
}
#endif
@end // MDWorkspaceWatcher

//----------------------------------------------configuration-----------------------------------------------

const NSString *kDelay = @"delay";
const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
const NSString *kVerbose = @"verbose";
const NSString *kAltTaskSwitcher = @"altTaskSwitcher";
const NSString *kIgnoreSpaceChanged = @"ignoreSpaceChanged";
const NSString *kStayFocusedBundleIds = @"stayFocusedBundleIds";
const NSString *kIgnoreApps = @"ignoreApps";
const NSString *kMouseDelta = @"mouseDelta";
const NSString *kPollMillis = @"pollMillis";
const NSString *kDisableKey = @"disableKey";
#ifdef FOCUS_FIRST
const NSString *kFocusDelay = @"focusDelay";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher, kFocusDelay,
    kIgnoreSpaceChanged, kIgnoreApps, kStayFocusedBundleIds, kDisableKey, kMouseDelta, kPollMillis];
#else
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kIgnoreSpaceChanged, kIgnoreApps, kStayFocusedBundleIds, kDisableKey, kMouseDelta, kPollMillis];
#endif
NSMutableDictionary *parameters = [[NSMutableDictionary alloc] init];

@interface ConfigClass:NSObject
- (NSString *) getFilePath:(NSString *) filename;
- (void) readConfig:(int) argc;
- (void) readOriginalConfig;
- (void) readHiddenConfig;
- (void) validateParameters;
@end

@implementation ConfigClass
- (NSString *) getFilePath:(NSString *) filename {
    filename = [NSString stringWithFormat: @"%@/%@", NSHomeDirectory(), filename];
    if (not [[NSFileManager defaultManager] fileExistsAtPath: filename]) { filename = NULL; }
    return filename;
}

- (void) readConfig:(int) argc {
    if (argc > 1) {
        // read NSArgumentDomain
        NSUserDefaults *arguments = [NSUserDefaults standardUserDefaults];

        for (id key in parametersDictionary) {
            id arg = [arguments objectForKey: key];
            if (arg != NULL) { parameters[key] = arg; }
        }
    } else {
        [self readHiddenConfig];
    }
    return;
}

- (void) readOriginalConfig {
    // original config files:
    NSString *delayFilePath = [self getFilePath: @"AutoRaise.delay"];
    NSString *warpFilePath = [self getFilePath: @"AutoRaise.warp"];

    if (delayFilePath || warpFilePath) {
        NSFileHandle *hDelayFile = [NSFileHandle fileHandleForReadingAtPath: delayFilePath];
        if (hDelayFile) {
            parameters[kDelay] = @(abs([[[NSString alloc]
                initWithData: [hDelayFile readDataOfLength: 2]
                encoding: NSUTF8StringEncoding] intValue]));
            [hDelayFile closeFile];
        }

        NSFileHandle *hWarpFile = [NSFileHandle fileHandleForReadingAtPath: warpFilePath];
        if (hWarpFile) {
            NSString *line = [[NSString alloc]
                initWithData: [hWarpFile readDataOfLength:11]
                encoding: NSUTF8StringEncoding];
            NSArray *components = [line componentsSeparatedByString: @" "];
            if (components.count >= 1) { parameters[kWarpX] = @([[components objectAtIndex:0] floatValue]); }
            if (components.count >= 2) { parameters[kWarpY] = @([[components objectAtIndex:1] floatValue]); }
            if (components.count >= 3) { parameters[kScale] = @([[components objectAtIndex:2] floatValue]); }
            [hWarpFile closeFile];
        }
    }
    return;
}

- (void) readHiddenConfig {
    // search for dotfiles
    NSString *hiddenConfigFilePath = [self getFilePath: @".AutoRaise"];
    if (!hiddenConfigFilePath) { hiddenConfigFilePath = [self getFilePath: @".config/AutoRaise/config"]; }

    if (hiddenConfigFilePath) {
        NSError *error;
        NSString *configContent = [[NSString alloc]
            initWithContentsOfFile: hiddenConfigFilePath
            encoding: NSUTF8StringEncoding error: &error];

        NSArray *configLines = [configContent componentsSeparatedByString:@"\n"];
        NSString *trimmedLine, *trimmedKey, *trimmedValue, *noQuotesValue;
        NSArray *components;
        for (NSString *line in configLines) {
            trimmedLine = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            if (not [trimmedLine hasPrefix:@"#"]) {
                components = [trimmedLine componentsSeparatedByString:@"="];
                if ([components count] == 2) {
                    for (id key in parametersDictionary) {
                       trimmedKey = [components[0] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       trimmedValue = [components[1] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       noQuotesValue = [trimmedValue stringByReplacingOccurrencesOfString:@"\"" withString:@""];
                       if ([trimmedKey isEqual: key]) { parameters[key] = noQuotesValue; }
                    }
                }
            }
        }
    } else {
        [self readOriginalConfig];
    }
    return;
}

- (void) validateParameters {
    // validate and fix wrong/absent parameters
#ifdef FOCUS_FIRST
    if (!parameters[kFocusDelay] && !parameters[kDelay]) {
#else
    if (!parameters[kDelay]) {
#endif
        parameters[kDelay] = @"1";
    }
    if ([parameters[kPollMillis] intValue] < 20) { parameters[kPollMillis] = @"50"; }
    if ([parameters[kMouseDelta] floatValue] < 0) { parameters[kMouseDelta] = @"0"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    if (!parameters[kDisableKey]) { parameters[kDisableKey] = @"control"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
#ifdef ALTERNATIVE_TASK_SWITCHER
    if (!parameters[kAltTaskSwitcher]) { parameters[kAltTaskSwitcher] = @"true"; }
#endif
#ifdef FOCUS_FIRST
    if (![parameters[kDelay] intValue] && !parameters[kFocusDelay]) { parameters[kFocusDelay] = @"1"; }
    if (!parameters[kDelay] && ![parameters[kFocusDelay] intValue]) { parameters[kDelay] = @"1"; }
#endif
    return;
}
@end // ConfigClass

//------------------------------------------where it all happens--------------------------------------------

void spaceChanged() {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}

bool appActivated() {
    if (verbose) { NSLog(@"App activated"); }
    if (!altTaskSwitcher) {
        if (!activated_by_task_switcher) { return false; }
        activated_by_task_switcher = false;
    }
    appWasActivated = true;

    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmost_pid = frontmostApp.processIdentifier;

    AXUIElementRef _activatedWindow = NULL;
    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
    AXUIElementCopyAttributeValue(_frontmostApp,
        kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
    if (!_activatedWindow) {
        if (verbose) { NSLog(@"No main window, trying focused window"); }
        AXUIElementCopyAttributeValue(_frontmostApp,
            kAXFocusedWindowAttribute, (CFTypeRef *) &_activatedWindow);
    }
    CFRelease(_frontmostApp);

    if (verbose) { NSLog(@"BundleIdentifier: %@", frontmostApp.bundleIdentifier); }
    bool finder_app = [frontmostApp.bundleIdentifier isEqual: Finder];
    if (finder_app) {
        if (_activatedWindow) {
            if (desktop_window(_activatedWindow)) {
                CFRelease(_activatedWindow);
                _activatedWindow = _previousFinderWindow;
            } else {
                if (_previousFinderWindow) { CFRelease(_previousFinderWindow); }
                _previousFinderWindow = _activatedWindow;
            }
        } else { _activatedWindow = _previousFinderWindow; }
    }

    if (altTaskSwitcher) {
        CGEventRef _event = CGEventCreate(NULL);
        CGPoint mousePoint = CGEventGetLocation(_event);
        if (_event) { CFRelease(_event); }

        bool ignoreActivated = false;
        // TODO: is the uncorrected mousePoint good enough?
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            if (!activated_by_task_switcher) {
                // Checking for mouse movement reduces the problem of the mouse being warped
                // when changing spaces and simultaneously moving the mouse to another screen
                ignoreActivated = fabs(mousePoint.x-oldPoint.x) > 0;
                ignoreActivated = ignoreActivated || fabs(mousePoint.y-oldPoint.y) > 0;
            }
            if (!ignoreActivated) {
                // Check if the mouse is already hovering above the frontmost app. If
                // for example we only change spaces, we don't want the mouse to warp
                pid_t mouseWindow_pid;
                ignoreActivated = AXUIElementGetPid(_mouseWindow,
                    &mouseWindow_pid) == kAXErrorSuccess &&
                    mouseWindow_pid == frontmost_pid;
            }
            CFRelease(_mouseWindow);
        } else { // dock or top menu
            // Comment the line below if clicking the dock icons should also
            // warp the mouse. Note this may introduce some unexpected warps
            ignoreActivated = true;
        }

        activated_by_task_switcher = false; // used in the previous code block

        if (ignoreActivated) {
            if (verbose) { NSLog(@"Ignoring app activated"); }
            if (!finder_app && _activatedWindow) { CFRelease(_activatedWindow); }
            return false;
        }
    }

    if (_activatedWindow) {
        if (verbose) { NSLog(@"Warp mouse"); }
        CGWarpMouseCursorPosition(get_mousepoint(_activatedWindow));
        if (!finder_app) { CFRelease(_activatedWindow); }
    }

    return true;
}

void onTick() {
    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    float mouse_x_diff = mousePoint.x-oldPoint.x;
    float mouse_y_diff = mousePoint.y-oldPoint.y;
    oldPoint = mousePoint;

    bool mouseMoved = fabs(mouse_x_diff) > mouseDelta;
    mouseMoved = mouseMoved || fabs(mouse_y_diff) > mouseDelta;
    mouseMoved = mouseMoved || propagateMouseMoved;
    propagateMouseMoved = false;

    // delayCount = 0 -> warp only
#ifdef FOCUS_FIRST
    if (altTaskSwitcher && !delayCount && !raiseDelayCount) { return; }
#else
    if (altTaskSwitcher && !delayCount) { return; }
#endif

    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) { delayTicks--; }

#if MAC_OS_X_VERSION_MIN_REQUIRED >= __MAC_12_00_0
    // the correction should be applied before we return
    // under certain conditions in the code after it. This
    // ensures oldCorrectedPoint always has a recent value.
    if (mouseMoved) {
        NSScreen * screen = findScreen(mousePoint);
        mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
        mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
        if (screen) {
            float menuBarHeight =
                NSHeight(screen.frame) - NSHeight(screen.visibleFrame) -
                (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1;
            NSScreen * main_screen = NSScreen.screens[0];
            float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);
            if (mousePoint.y < screenOriginY + menuBarHeight + MENUBAR_CORRECTION) {
                if (verbose) { NSLog(@"Menu bar correction"); }
                mousePoint.y = screenOriginY;
            }
        }
        oldCorrectedPoint = mousePoint;
    } else {
        mousePoint = oldCorrectedPoint;
    }
#endif

    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (appWasActivated) {
        appWasActivated = false;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the delay
        if (mouseMoved) { return; }
        else if (!ignoreSpaceChanged) {
            raiseTimes = 3;
            delayTicks = 0;
        }
        spaceHasChanged = false;
    } else if (delayTicks && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        propagateMouseMoved = true;
        return;
    }

    // mouseMoved: we have to decide if the window needs raising
    // delayTicks: count down as long as the mouse doesn't move
    // raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        // don't raise for as long as something is being dragged (resizing a window for instance)
        bool abort = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
            launchpad_active();

        if (!abort && disableKey) {
            CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
            CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
            if (_keyDownEvent) { CFRelease(_keyDownEvent); }
            abort = (flags & disableKey) == disableKey;
        }

        if (abort) {
            if (verbose) { NSLog(@"Abort focus/raise"); }
            raiseTimes = 0;
            delayTicks = 0;
            return;
        }

        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                bool needs_raise = true;
                AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
#ifdef FOCUS_FIRST
                bool app_main_window = false;
                bool temporary_workaround_for_intellij_raising_its_subwindows_on_focus = false;
                if (delayCount && raiseDelayCount != 1 && titleEquals(_mouseWindow, @[NoTitle])) {
                    if (!titleEquals(_mouseWindowApp, @[Photos])) {
                        needs_raise = false;
                        if (verbose) { NSLog(@"Excluding window"); }
                    } else { app_main_window = true; }
                } else
#endif
                if (titleEquals(_mouseWindow, @[BartenderBar])) {
                    needs_raise = false;
                    if (verbose) { NSLog(@"Excluding window"); }
                } else {
                    if (titleEquals(_mouseWindowApp, ignoreApps)) {
                        needs_raise = false;
                        if (verbose) { NSLog(@"Excluding app"); }
                    }
#ifdef FOCUS_FIRST
                    temporary_workaround_for_intellij_raising_its_subwindows_on_focus =
                        titleEquals(_mouseWindowApp, @[IntelliJ]);
#endif
                }
                CFRelease(_mouseWindowApp);
                CGWindowID mouseWindow_id;
                CGWindowID focusedWindow_id;
#ifdef FOCUS_FIRST
                ProcessSerialNumber mouseWindow_psn;
                ProcessSerialNumber focusedWindow_psn;
                ProcessSerialNumber * _focusedWindow_psn = NULL;
#endif
                if (needs_raise) {
                    _AXUIElementGetWindow(_mouseWindow, &mouseWindow_id);
                    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
                    needs_raise = ![stayFocusedBundleIds containsObject: frontmostApp.bundleIdentifier];
                    if (needs_raise) {
                        pid_t frontmost_pid = frontmostApp.processIdentifier;
                        AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                        if (_frontmostApp) {
                            AXUIElementRef _focusedWindow = NULL;
                            AXUIElementCopyAttributeValue(
                                _frontmostApp,
                                kAXFocusedWindowAttribute,
                                (CFTypeRef *) &_focusedWindow);
                            if (_focusedWindow) {
                                _AXUIElementGetWindow(_focusedWindow, &focusedWindow_id);
                                needs_raise = mouseWindow_id != focusedWindow_id;
#ifdef FOCUS_FIRST
                                if (delayCount && raiseDelayCount != 1) {
                                    if (needs_raise) {
                                        needs_raise = raiseTimes || mouseWindow_id != lastFocusedWindow_id;
                                    } else { lastFocusedWindow_id = 0; }
                                    if (raiseDelayCount) {
                                        needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
                                    } else {
                                        if (temporary_workaround_for_intellij_raising_its_subwindows_on_focus) {
                                            needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
                                        }
                                        needs_raise = needs_raise && (app_main_window || main_window(_focusedWindow));
                                    }
                                    if (needs_raise) {
                                        OSStatus error = GetProcessForPID(frontmost_pid, &focusedWindow_psn);
                                        if (!error) { _focusedWindow_psn = &focusedWindow_psn; }
                                    }
                                } else {
#endif
                                needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
#ifdef FOCUS_FIRST
                                }
#endif
                                CFRelease(_focusedWindow);
                            }
                            CFRelease(_frontmostApp);
                        }
                    } else if (verbose) { NSLog(@"Stay focused"); }
                }

                if (needs_raise) {
                    if (!delayTicks) {
                        // start the delay
                        delayTicks = delayCount;
                    }
                    if (raiseTimes || delayTicks == 1) {
                        delayTicks = 0; // disable delay

                        if (raiseTimes) { raiseTimes--; }
                        else { raiseTimes = 3; }
#ifdef FOCUS_FIRST
                        if (delayCount && raiseDelayCount != 1) {
                            OSStatus error = GetProcessForPID(mouseWindow_pid, &mouseWindow_psn);
                            if (!error) {
                                window_manager_focus_window_without_raise(&mouseWindow_psn,
                                    mouseWindow_id, _focusedWindow_psn, focusedWindow_id);
                                if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
                                _lastFocusedWindow = _mouseWindow;
                                lastFocusedWindow_pid = mouseWindow_pid;
                                lastFocusedWindow_id = mouseWindow_id;
                                if (raiseDelayCount) { [workspaceWatcher windowFocused: _lastFocusedWindow]; }
                            }
                        } else {
#endif
                        raiseAndActivate(_mouseWindow, mouseWindow_pid);
#ifdef FOCUS_FIRST
                        }
#endif
                    }
                } else {
                    raiseTimes = 0;
                    delayTicks = 0;
                }
            }
#ifdef FOCUS_FIRST
            if (_mouseWindow != _lastFocusedWindow) {
#endif
                CFRelease(_mouseWindow);
#ifdef FOCUS_FIRST
            }
#endif
        } else {
            raiseTimes = 0;
            delayTicks = 0;
        }
    }
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    static bool commandTabPressed = false;
    if (type == kCGEventFlagsChanged && commandTabPressed) {
        if (!activated_by_task_switcher) {
            activated_by_task_switcher = true;
            ignoreTimes = 3;
        }
    }

    commandTabPressed = false;
    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandTabPressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
        }
    } else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (verbose) { NSLog(@"Got event tap disabled event, re-enabling..."); }
        CGEventTapEnable(eventTap, true);
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config validateParameters];

        delayCount         = [parameters[kDelay] intValue];
        warpX              = [parameters[kWarpX] floatValue];
        warpY              = [parameters[kWarpY] floatValue];
        cursorScale        = [parameters[kScale] floatValue];
        verbose            = [parameters[kVerbose] boolValue];
        altTaskSwitcher    = [parameters[kAltTaskSwitcher] boolValue];
        mouseDelta         = [parameters[kMouseDelta] floatValue];
        pollMillis         = [parameters[kPollMillis] intValue];
        ignoreSpaceChanged = [parameters[kIgnoreSpaceChanged] boolValue];

        printf("\nv%s by sbmpost(c) 2023, usage:\n\nAutoRaise\n", AUTORAISE_VERSION);
        printf("  -pollMillis <20, 30, 40, 50, ...>\n");
        printf("  -delay <0=no-raise, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#ifdef FOCUS_FIRST
        printf("  -focusDelay <0=no-focus, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#endif
        printf("  -warpX <0.5> -warpY <0.5> -scale <2.0>\n");
        printf("  -altTaskSwitcher <true|false>\n");
        printf("  -ignoreSpaceChanged <true|false>\n");
        printf("  -ignoreApps \"<App1,App2, ...>\"\n");
        printf("  -stayFocusedBundleIds \"<Id1,Id2, ...>\"\n");
        printf("  -disableKey <control|option|disabled>\n");
        printf("  -mouseDelta <0.1>\n");
        printf("  -verbose <true|false>\n\n");

        printf("Started with:\n");
        printf("  * pollMillis: %dms\n", pollMillis);
        if (delayCount) {
            printf("  * delay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            printf("  * delay: disabled\n");
        }
#ifdef FOCUS_FIRST
        if ([parameters[kFocusDelay] intValue]) {
            raiseDelayCount = delayCount;
            delayCount = [parameters[kFocusDelay] intValue];
            printf("  * focusDelay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            raiseDelayCount = 1;
            printf("  * focusDelay: disabled\n");
        }
#endif

        if (warpMouse) {
            printf("  * warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale);
            printf("  * altTaskSwitcher: %s\n", altTaskSwitcher ? "true" : "false");
        }

        printf("  * ignoreSpaceChanged: %s\n", ignoreSpaceChanged ? "true" : "false");

        NSMutableArray * ignore;
        if (parameters[kIgnoreApps]) {
            ignore = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreApps] componentsSeparatedByString:@","]];
        } else { ignore = [[NSMutableArray alloc] init]; }

        for (id ignoreApp in ignore) {
            printf("  * ignoreApp: %s\n", [ignoreApp UTF8String]);
        }
        [ignore addObject: AssistiveControl];
        ignoreApps = [ignore copy];

        NSMutableArray * stayFocused;
        if (parameters[kStayFocusedBundleIds]) {
            stayFocused = [[NSMutableArray alloc] initWithArray:
                [parameters[kStayFocusedBundleIds] componentsSeparatedByString:@","]];
        } else { stayFocused = [[NSMutableArray alloc] init]; }

        for (id stayFocusedBundleId in stayFocused) {
            printf("  * stayFocusedBundleId: %s\n", [stayFocusedBundleId UTF8String]);
        }
        stayFocusedBundleIds = [stayFocused copy];

        if ([parameters[kDisableKey] isEqualToString: @"control"]) {
            printf("  * disableKey: control\n");
            disableKey = kCGEventFlagMaskControl;
        } else if ([parameters[kDisableKey] isEqualToString: @"option"]) {
            printf("  * disableKey: option\n");
            disableKey = kCGEventFlagMaskAlternate;
        } else { printf("  * disableKey: disabled\n"); }

        if (mouseDelta) { printf("  * mouseDelta: %.1f\n", mouseDelta); }

        printf("  * verbose: %s\n", verbose ? "true" : "false");
#if defined OLD_ACTIVATION_METHOD or defined FOCUS_FIRST or defined ALTERNATIVE_TASK_SWITCHER
        printf("\nCompiled with:\n");
#ifdef OLD_ACTIVATION_METHOD
        printf("  * OLD_ACTIVATION_METHOD\n");
#endif
#ifdef FOCUS_FIRST
        printf("  * EXPERIMENTAL_FOCUS_FIRST\n");
#endif
#ifdef ALTERNATIVE_TASK_SWITCHER
        printf("  * ALTERNATIVE_TASK_SWITCHER\n");
#endif
#endif
        printf("\n");

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        if (verbose) { NSLog(@"System cursor scale: %f", oldScale); }

        CFRunLoopSourceRef runLoopSource = NULL;
        eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
            CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged),
            eventTapHandler, NULL);
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }
        if (verbose) { NSLog(@"Got run loop source: %s", runLoopSource ? "YES" : "NO"); }

        workspaceWatcher = [[MDWorkspaceWatcher alloc] init];
#ifdef FOCUS_FIRST
        if (altTaskSwitcher || raiseDelayCount || delayCount) {
#else
        if (altTaskSwitcher || delayCount) {
#endif
            [workspaceWatcher onTick: [NSNumber numberWithFloat: pollMillis/1000.0]];
        }

        _dock_app = findDockApplication();
        desktopOrigin = findDesktopOrigin();
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
