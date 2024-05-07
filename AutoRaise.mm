/*
 * AutoRaise - Copyright (C) 2024 sbmpost
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

#define AUTORAISE_VERSION "5.3"
#define STACK_THRESHOLD 20

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
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
static CGPoint oldCorrectedPoint = {0, 0};

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
static int raiseDelayCount = 0;
static pid_t lastFocusedWindow_pid;
static AXUIElementRef _lastFocusedWindow = NULL;
#endif

CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * ignoreTitles = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static NSArray * const mainWindowAppsWithoutTitle = @[@"Photos", @"Calculator", @"Podcasts", @"Stickies Pro", @"Reeder"];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const FinderBundleId = @"com.apple.finder";
static NSString * const LittleSnitchBundleId = @"at.obdev.littlesnitch";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool ignoreSpaceChanged = false;
static bool invertIgnoreApps = false;
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

//----------------------------------------yabai focus only methods------------------------------------------

#ifdef FOCUS_FIRST
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
void window_manager_make_key_window(ProcessSerialNumber * _window_psn, uint32_t window_id) {
    uint8_t * bytes = (uint8_t *) malloc(0xf8);
    memset(bytes, 0, 0xf8);

    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;

    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(_window_psn, bytes);

    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(_window_psn, bytes);
    free(bytes);
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
            uint8_t * bytes = (uint8_t *) malloc(0xf8);
            memset(bytes, 0, 0xf8);

            bytes[0x04] = 0xf8;
            bytes[0x08] = 0x0d;
            memcpy(bytes + 0x3c, &focused_window_id, sizeof(uint32_t));
            memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));

            bytes[0x8a] = 0x02;
            SLPSPostEventRecordTo(_focused_window_psn, bytes);

            // @hack
            // Artificially delay the activation by 1ms. This is necessary
            // because some applications appear to be confused if both of
            // the events appear instantaneously.
            usleep(10000);

            bytes[0x8a] = 0x01;
            SLPSPostEventRecordTo(_window_psn, bytes);
            free(bytes);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#ifdef OLD_ACTIVATION_METHOD
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    // Note activateWithOptions does not work properly on OSX 11.1
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

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles, NSArray * _patterns = NULL, bool logTitle = false) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (logTitle) { NSLog(@"element title: %@", _elementTitle); }
    if (_elementTitle) {
        NSString * _title = (__bridge NSString *) _elementTitle;
        equal = [_titles containsObject: _title];
        if (!equal && _patterns) {
            for (NSString * _pattern in _patterns) {
                equal = [_title rangeOfString:_pattern options:NSRegularExpressionSearch].location != NSNotFound;
                if (equal) { break; }
            }
        }
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    if (_focusedUIElement) {
        active = true;
        if (verbose) { NSLog(@"Dock is active"); }
        CFRelease(_focusedUIElement);
    }
    return active;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

        NSRect window_bounds = NSMakeRect(
            [window_bounds_dict[@"X"] intValue],
            [window_bounds_dict[@"Y"] intValue],
            [window_bounds_dict[@"Width"] intValue],
            [window_bounds_dict[@"Height"] intValue]);

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
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
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
                    if (titleEquals(_element, @[XQuartz])) {
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
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window && no_parent) { _window = fallback(point); }
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
    } else if (error == kAXErrorIllegalArgument) {
        // no fallback, happens in (Open, Save) dialogs
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
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

void findDockApplication() {
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: DockBundleId]) {
            _dock_app = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }

    if (verbose && !_dock_app) { NSLog(@"Dock application isn't running"); }
}

void findDesktopOrigin() {
    NSScreen * main_screen = NSScreen.screens[0];
    float mainScreenTop = NSMaxY(main_screen.frame);
    for (NSScreen * screen in [NSScreen screens]) {
        float screenOriginY = mainScreenTop - NSMaxY(screen.frame);
        if (screenOriginY < desktopOrigin.y) { desktopOrigin.y = screenOriginY; }
        if (screen.frame.origin.x < desktopOrigin.x) { desktopOrigin.x = screen.frame.origin.x; }
    }

    if (verbose) { NSLog(@"Desktop origin (%f, %f)", desktopOrigin.x, desktopOrigin.y); }
}

inline NSScreen * findScreen(CGPoint point) {
    NSScreen * main_screen = NSScreen.screens[0];
    point.y = NSMaxY(main_screen.frame) - point.y;
    for (NSScreen * screen in [NSScreen screens]) {
        NSRect screen_bounds = NSMakeRect(
            screen.frame.origin.x,
            screen.frame.origin.y,
            NSWidth(screen.frame) + 1,
            NSHeight(screen.frame) + 1
        );
        if (NSPointInRect(NSPointFromCGPoint(point), screen_bounds)) {
            return screen;
        }
    }
    return NULL;
}

inline bool is_desktop_window(AXUIElementRef _window) {
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

inline bool is_full_screen(AXUIElementRef _window) {
    bool full_screen = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        if (AXValueGetValue(_pos, kAXValueCGPointType, &cg_pos)) {
            NSScreen * screen = findScreen(cg_pos);
            if (screen) {
                AXValueRef _size = NULL;
                AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
                if (_size) {
                    CGSize cg_size;
                    if (AXValueGetValue(_size, kAXValueCGSizeType, &cg_size)) {
                        float menuBarHeight =
                            fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                        NSScreen * main_screen = NSScreen.screens[0];
                        float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);
                        full_screen = cg_pos.x == NSMinX(screen.frame) &&
                                      cg_pos.y == screenOriginY + menuBarHeight &&
                                      cg_size.width == NSWidth(screen.frame) &&
                                      cg_size.height == NSHeight(screen.frame) - menuBarHeight;
                    }
                    CFRelease(_size);
                }
            }
        }
        CFRelease(_pos);
    }

    if (verbose && full_screen) { NSLog(@"Full screen window"); }
    return full_screen;
}

inline bool is_main_window(AXUIElementRef _app, AXUIElementRef _window, bool chrome_app) {
    bool main_window = false;
    CFBooleanRef _result = NULL;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        main_window = CFEqual(_result, kCFBooleanTrue);
        if (main_window) {
            CFStringRef _element_sub_role = NULL;
            AXUIElementCopyAttributeValue(_window, kAXSubroleAttribute, (CFTypeRef *) &_element_sub_role);
            if (_element_sub_role) {
                main_window = !CFEqual(_element_sub_role, kAXDialogSubrole);
                if (verbose && !main_window) { NSLog(@"Dialog window"); }
                CFRelease(_element_sub_role);
            }
        }
        CFRelease(_result);
    }

    bool finder_app = titleEquals(_app, @[Finder]);
    main_window = main_window && (chrome_app || finder_app ||
        !titleEquals(_window, @[NoTitle]) ||
        titleEquals(_app, mainWindowAppsWithoutTitle));

    main_window = main_window || (!finder_app && is_full_screen(_window));

    if (verbose && !main_window) { NSLog(@"Not a main window"); }
    return main_window;
}

inline bool is_chrome_app(NSString * bundleIdentifier) {
    NSArray * components = [bundleIdentifier componentsSeparatedByString: @"."];
    return components.count > 4 && [components[2] isEqual: @"Chrome"] && [components[3] isEqual: @"app"];
}

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
const NSString *kInvertIgnoreApps = @"invertIgnoreApps";
const NSString *kIgnoreApps = @"ignoreApps";
const NSString *kIgnoreTitles = @"ignoreTitles";
const NSString *kMouseDelta = @"mouseDelta";
const NSString *kPollMillis = @"pollMillis";
const NSString *kDisableKey = @"disableKey";
#ifdef FOCUS_FIRST
const NSString *kFocusDelay = @"focusDelay";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kFocusDelay, kIgnoreSpaceChanged, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles,
    kStayFocusedBundleIds, kDisableKey, kMouseDelta, kPollMillis];
#else
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kIgnoreSpaceChanged, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles, kStayFocusedBundleIds,
    kDisableKey, kMouseDelta, kPollMillis];
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
    bool finder_app = [frontmostApp.bundleIdentifier isEqual: FinderBundleId];
    if (finder_app) {
        if (_activatedWindow) {
            if (is_desktop_window(_activatedWindow)) {
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
                pid_t mouseWindow_pid;
                // Checking for mouse movement reduces the problem of the mouse being warped
                // when changing spaces and simultaneously moving the mouse to another screen
                ignoreActivated = fabs(mousePoint.x-oldPoint.x) > 0;
                ignoreActivated = ignoreActivated || fabs(mousePoint.y-oldPoint.y) > 0;
                // Check if the mouse is already hovering above the frontmost app. If
                // for example we only change spaces, we don't want the mouse to warp
                ignoreActivated = ignoreActivated || (AXUIElementGetPid(_mouseWindow,
                    &mouseWindow_pid) == kAXErrorSuccess && mouseWindow_pid == frontmost_pid);
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

#ifdef FOCUS_FIRST
    if (!delayCount || raiseDelayCount == 1) {
#endif
        if (@available(macOS 12.00, *)) {
            // the correction should be applied before we return
            // under certain conditions in the code after it. This
            // ensures oldCorrectedPoint always has a recent value.
            if (mouseMoved) {
                NSScreen * screen = findScreen(mousePoint);
                mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
                mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
                if (screen) {
                    NSScreen * main_screen = NSScreen.screens[0];
                    float screenOriginX = NSMinX(screen.frame) - NSMinX(main_screen.frame);
                    float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);

                    if (oldPoint.x > screenOriginX + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.x = screenOriginX + NSWidth(screen.frame) - 1;
                    } else if (oldPoint.x < screenOriginX + WINDOW_CORRECTION - 1) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.x = screenOriginX + 1;
                    }

                    if (oldPoint.y > screenOriginY + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                        if (verbose) { NSLog(@"Screen edge correction"); }
                        mousePoint.y = screenOriginY + NSHeight(screen.frame) - 1;
                    } else {
                        float menuBarHeight =
                            fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                        if (mousePoint.y < screenOriginY + menuBarHeight + MENUBAR_CORRECTION) {
                            if (verbose) { NSLog(@"Menu bar correction"); }
                            mousePoint.y = screenOriginY;
                        }
                    }
                }
                oldCorrectedPoint = mousePoint;
            } else {
                mousePoint = oldCorrectedPoint;
            }
        }
#ifdef FOCUS_FIRST
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
            dock_active();

        if (!abort && disableKey) {
            CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
            CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
            if (_keyDownEvent) { CFRelease(_keyDownEvent); }
            abort = (flags & disableKey) == disableKey;
        }

        NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        abort = abort || [stayFocusedBundleIds containsObject: frontmostApp.bundleIdentifier];

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
                bool needs_raise = !invertIgnoreApps;
                AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
                if (needs_raise && titleEquals(_mouseWindow, @[NoTitle, Untitled])) {
                    needs_raise = is_main_window(_mouseWindowApp, _mouseWindow, is_chrome_app(
                        [NSRunningApplication runningApplicationWithProcessIdentifier:
                        mouseWindow_pid].bundleIdentifier));
                    if (verbose && !needs_raise) { NSLog(@"Excluding window"); }
                } else if (needs_raise &&
                    titleEquals(_mouseWindow, @[BartenderBar, Zim, AppStoreSearchResults], ignoreTitles)) {
                    // TODO: make these window title exceptions an ignoreWindowTitles setting.
                    needs_raise = false;
                    if (verbose) { NSLog(@"Excluding window"); }
                } else {
                    if (titleEquals(_mouseWindowApp, ignoreApps)) {
                        needs_raise = invertIgnoreApps;
                        if (verbose) {
                            if (invertIgnoreApps) {
                                NSLog(@"Including app");
                            } else {
                                NSLog(@"Excluding app");
                            }
                        }
                    }
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
                    pid_t frontmost_pid = frontmostApp.processIdentifier;
                    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _frontmostApp,
                        kAXFocusedWindowAttribute,
                        (CFTypeRef *) &_focusedWindow);
                    if (_focusedWindow) {
                        if (verbose) {
                            CFStringRef _windowTitle = NULL;
                            AXUIElementCopyAttributeValue(_focusedWindow,
                                kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
                            NSLog(@"Focused window: %@", _windowTitle);
                            if (_windowTitle) { CFRelease(_windowTitle); }
                        }
                        _AXUIElementGetWindow(_focusedWindow, &focusedWindow_id);
                        needs_raise = mouseWindow_id != focusedWindow_id;
#ifdef FOCUS_FIRST
                        if (raiseDelayCount) {
#endif
                            needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
#ifdef FOCUS_FIRST
                        } else {
                            needs_raise = needs_raise && is_main_window(_frontmostApp, _focusedWindow,
                                is_chrome_app(frontmostApp.bundleIdentifier)) && (
                                mouseWindow_pid != frontmost_pid ||
                                !contained_within(_focusedWindow, _mouseWindow));
                        }
                        if (needs_raise && delayCount && raiseDelayCount != 1) {
                            OSStatus error = GetProcessForPID(frontmost_pid, &focusedWindow_psn);
                            if (!error) { _focusedWindow_psn = &focusedWindow_psn; }
                        }
#endif
                        CFRelease(_focusedWindow);
                    } else {
                        if (verbose) { NSLog(@"No focused window"); }
                        AXUIElementRef _activatedWindow = NULL;
                        AXUIElementCopyAttributeValue(_frontmostApp,
                            kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
                        if (_activatedWindow) {
                          needs_raise = false;
                          CFRelease(_activatedWindow);
                        }
                    }
                    CFRelease(_frontmostApp);
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
                                bool floating_window = false;
                                CFStringRef _element_sub_role = NULL;
                                AXUIElementCopyAttributeValue(
                                    _mouseWindow,
                                    kAXSubroleAttribute,
                                    (CFTypeRef *) &_element_sub_role);
                                if (_element_sub_role) {
                                    floating_window =
                                        CFEqual(_element_sub_role, kAXFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXSystemFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXUnknownSubrole);
                                    CFRelease(_element_sub_role);
                                }
                                if (!floating_window) {
                                    // TODO: method below seems unable to focus floating windows
                                    window_manager_focus_window_without_raise(&mouseWindow_psn,
                                        mouseWindow_id, _focusedWindow_psn, focusedWindow_id);
                                } else if (verbose) { NSLog(@"Unable to focus floating window"); }
                                if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
                                _lastFocusedWindow = _mouseWindow;
                                lastFocusedWindow_pid = mouseWindow_pid;
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

    static bool commandGravePressed = false;
    if (type == kCGEventFlagsChanged && commandGravePressed) {
        if (!activated_by_task_switcher) {
            activated_by_task_switcher = true;
            ignoreTimes = 3;
            [workspaceWatcher onAppActivated];
        }
    }

    commandTabPressed = false;
    commandGravePressed = false;
    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandTabPressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
        } else if (warpMouse && keycode == kVK_ANSI_Grave) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandGravePressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
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
        invertIgnoreApps   = [parameters[kInvertIgnoreApps] boolValue];

        printf("\nv%s by sbmpost(c) 2024, usage:\n\nAutoRaise\n", AUTORAISE_VERSION);
        printf("  -pollMillis <20, 30, 40, 50, ...>\n");
        printf("  -delay <0=no-raise, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#ifdef FOCUS_FIRST
        printf("  -focusDelay <0=no-focus, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#endif
        printf("  -warpX <0.5> -warpY <0.5> -scale <2.0>\n");
        printf("  -altTaskSwitcher <true|false>\n");
        printf("  -ignoreSpaceChanged <true|false>\n");
        printf("  -invertIgnoreApps <true|false>\n");
        printf("  -ignoreApps \"<App1,App2,...>\"\n");
        printf("  -ignoreTitles \"<Regex1,Regex2,...>\"\n");
        printf("  -stayFocusedBundleIds \"<Id1,Id2,...>\"\n");
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
        printf("  * invertIgnoreApps: %s\n", invertIgnoreApps ? "true" : "false");

        NSMutableArray * ignoreA;
        if (parameters[kIgnoreApps]) {
            ignoreA = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreApps] componentsSeparatedByString:@","]];
        } else { ignoreA = [[NSMutableArray alloc] init]; }

        for (id ignoreApp in ignoreA) {
            printf("  * ignoreApp: %s\n", [ignoreApp UTF8String]);
        }
        [ignoreA addObject: AssistiveControl];
        ignoreApps = [ignoreA copy];

        NSMutableArray * ignoreT;
        if (parameters[kIgnoreTitles]) {
            ignoreT = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreTitles] componentsSeparatedByString:@","]];
        } else { ignoreT = [[NSMutableArray alloc] init]; }

        for (id ignoreTitle in ignoreT) {
            printf("  * ignoreTitle: %s\n", [ignoreTitle UTF8String]);
        }
        ignoreTitles = [ignoreT copy];

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

        findDockApplication();
        findDesktopOrigin();
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
