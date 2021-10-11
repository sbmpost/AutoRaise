/*
 * AutoRaise - Copyright (C) 2021 sbmpost
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

// g++ -O2 -Wall -fobjc-arc -o AutoRaise AutoRaise.mm -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>

#define AUTORAISE_VERSION "2.5"
#define STACK_THRESHOLD 20

// Lowering the polling interval increases responsiveness, but steals more cpu
// cycles. A workable, yet responsible value seems to be about 20 microseconds.
#define POLLING_MS 20

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static CFStringRef Finder = CFSTR("com.apple.finder");
static CFStringRef XQuartz = CFSTR("XQuartz");
static CGPoint oldPoint = {0, 0};
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool warpMouse = false;
static bool verbose = false;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;

//---------------------------------------------helper methods-----------------------------------------------

void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_11_6
    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
      activateWithOptions: NSApplicationActivateIgnoringOtherApps];
#else
    // Temporary solution as NSRunningApplication does not work properly on OSX 11.1
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#endif
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

AXUIElementRef get_raiseable_window(AXUIElementRef _element, CGPoint point, int count) {
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                CFStringRef _elementTitle = NULL;
                AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
                NSLog(@"element: %@, element title: %@", _element, _elementTitle);
                if (_elementTitle) { CFRelease(_elementTitle); }
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
            return NULL;
        }

        CFStringRef _element_role = NULL;
        AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
        bool check_attributes = !_element_role;
        if (_element_role) {
            if (CFEqual(_element_role, kAXDockItemRole) ||
                CFEqual(_element_role, kAXMenuItemRole)) {
                CFRelease(_element_role);
                CFRelease(_element);
            } else if (
                CFEqual(_element_role, kAXWindowRole) ||
                CFEqual(_element_role, kAXSheetRole) ||
                CFEqual(_element_role, kAXDrawerRole)) {
                CFRelease(_element_role);
                return _element;
            } else if (CFEqual(_element_role, kAXApplicationRole)) { // XQuartz special case
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                        frontmostApplication] processIdentifier];
                    if (application_pid != frontmost_pid) {
                        CFStringRef _applicationTitle;
                        if (AXUIElementCopyAttributeValue(
                            _element,
                            kAXTitleAttribute,
                            (CFTypeRef *) &_applicationTitle
                        ) == kAXErrorSuccess) {
                            if(CFEqual(_applicationTitle, XQuartz)) {
                                activate(application_pid);
                            }
                            CFRelease(_applicationTitle);
                        }
                    }
                }

                CFRelease(_element_role);
                CFRelease(_element);
            } else {
                CFRelease(_element_role);
                check_attributes = true;
            }
        }

        if (check_attributes) {
            AXUIElementRef _window = NULL;
            AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
            if (!_window) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                _window = get_raiseable_window(_window, point, ++count);
            }
            CFRelease(_element);
            return _window;
        }
    } else {
        return fallback(point);
    }

    return NULL;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);
    AXUIElementRef _window = get_raiseable_window(_element, point, 0);
    if (verbose && !_window) { NSLog(@"No raisable window"); }
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
                        contained = cg_pos1.x >= cg_pos2.x && cg_pos1.y >= cg_pos2.y &&
                            cg_pos1.x + cg_size1.width <= cg_pos2.x + cg_size2.width &&
                            cg_pos1.y + cg_size1.height <= cg_pos2.y + cg_size2.height;
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

bool inline desktop_window(AXUIElementRef _window) {
    bool desktop_window = false;

    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        desktop_window = AXValueGetValue(_pos, kAXValueCGPointType, &cg_pos) &&
            cg_pos.x == 0 && cg_pos.y == 0; // TODO: can we do this better?
        CFRelease(_pos);
    }

    if (verbose && desktop_window) { NSLog(@"desktop window"); }
    return desktop_window;
}

//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
bool appActivated();
void onTick();

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

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
@end // MDWorkspaceWatcher

//----------------------------------------------configuration-----------------------------------------------

const NSString *kDelay = @"delay";
const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
const NSString *kVerbose = @"verbose";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kVerbose];
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

        // remove all whitespaces from file
        configContent = [configContent stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSArray *configLines = [configContent componentsSeparatedByString:@"\n"];
        NSArray *components;
        for (NSString *line in configLines) {
            if (not [line hasPrefix:@"#"]) {
                components = [line componentsSeparatedByString:@"="];
                if ([components count] == 2) {
                    for (id key in parametersDictionary) {
                        if ([components[0] isEqual: key]) { parameters[key] = components[1]; }
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
    if (!parameters[kDelay]) { parameters[kDelay] = @"2"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
    if (![parameters[kDelay] intValue] && !warpMouse) {
        parameters[kWarpX] = @"0.5";
        parameters[kWarpY] = @"0.5";
        warpMouse = true;
    }
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
#ifndef ALTERNATIVE_TASK_SWITCHER
    if (!activated_by_task_switcher) { return false; }
    activated_by_task_switcher = false;
#endif
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

    CFStringRef bundleIdentifier = (__bridge CFStringRef) frontmostApp.bundleIdentifier;
    if (verbose) { NSLog(@"bundleIdentifier: %@", bundleIdentifier); }
    bool finder_app = bundleIdentifier && CFEqual(bundleIdentifier, Finder);
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

#ifdef ALTERNATIVE_TASK_SWITCHER
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    bool ignoreActivated = false;
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
#endif

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

    bool mouseMoved = fabs(mousePoint.x-oldPoint.x) > 0;
    mouseMoved = mouseMoved || fabs(mousePoint.y-oldPoint.y) > 0;
    oldPoint = mousePoint;

#ifdef ALTERNATIVE_TASK_SWITCHER
    // delayCount = 0 -> warp only
    if (!delayCount) { return; }
#endif

    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) { delayTicks--; }

    if (appWasActivated) {
        appWasActivated = false;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the delay
        if (mouseMoved) { return; }
        raiseTimes = 3;
        delayTicks = 0;
        spaceHasChanged = false;
    } else if (delayTicks && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        oldPoint.x = oldPoint.y = 0;
        return;
    }

    // don't raise for as long as something is being dragged (resizing a window for instance)
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight)) {
        return;
    }

    // mouseMoved: we have to decide if the window needs raising
    // delayTicks: count down as long as the mouse doesn't move
    // raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                Boolean needs_raise = true;
                pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                    frontmostApplication] processIdentifier];
                AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                if (_frontmostApp) {
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _frontmostApp,
                        kAXFocusedWindowAttribute,
                        (CFTypeRef *) &_focusedWindow);
                    if (_focusedWindow) {
                        CGWindowID window1_id, window2_id;
                        _AXUIElementGetWindow(_mouseWindow, &window1_id);
                        _AXUIElementGetWindow(_focusedWindow, &window2_id);
                        needs_raise = window1_id != window2_id &&
                            !contained_within(_focusedWindow, _mouseWindow);
                        CFRelease(_focusedWindow);
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

                        // raise mousewindow
                        if (AXUIElementPerformAction(_mouseWindow, kAXRaiseAction) == kAXErrorSuccess) {
                            activate(mouseWindow_pid);
                        }
                    }
                } else {
                    raiseTimes = 0;
                    delayTicks = 0;
                }
            }
            CFRelease(_mouseWindow);
        } else {
            raiseTimes = 0;
            delayTicks = 0;
        }
    }
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    static bool commandTabPressed = false;
    activated_by_task_switcher = activated_by_task_switcher ||
        (type == kCGEventFlagsChanged && commandTabPressed);
    commandTabPressed = false;
    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandTabPressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
        }
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("\nv%s by sbmpost(c) 2021, usage:\nAutoRaise -delay <1=%dms, 2=%dms, ..., 0=warp only> "
            "[-warpX <0.5> -warpY <0.5> -scale <2.0> [-verbose <true|false>]]",
            AUTORAISE_VERSION, POLLING_MS, POLLING_MS*2);

        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config validateParameters];

        delayCount  = [parameters[kDelay] intValue];
        warpX       = [parameters[kWarpX] floatValue];
        warpY       = [parameters[kWarpY] floatValue];
        cursorScale = [parameters[kScale] floatValue];
        verbose     = [parameters[kVerbose] boolValue];

        if (delayCount) {
            printf("\n\nStarted with %d ms delay%s", delayCount*POLLING_MS, warpMouse ? ", " : "\n");
        } else {
            printf("\n\nStarted with warp only, ");
        }
        if (warpMouse) { printf("warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale); }

#ifdef ALTERNATIVE_TASK_SWITCHER
        printf("Using alternative task switcher\n");
#endif

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        if (verbose) { NSLog(@"System cursor scale: %f", oldScale); }

        CFRunLoopSourceRef runLoopSource = NULL;
        CFMachPortRef eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0,
            (1 << kCGEventKeyDown) | (1 << kCGEventFlagsChanged), eventTapHandler, NULL);
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }
        if (verbose) { NSLog(@"Got run loop source: %s", runLoopSource ? "YES" : "NO"); }

        MDWorkspaceWatcher * workspaceWatcher = [[MDWorkspaceWatcher alloc] init];
#ifndef ALTERNATIVE_TASK_SWITCHER
        if (delayCount) {
#endif
        [workspaceWatcher onTick: [NSNumber numberWithFloat: POLLING_MS/1000.0]];
#ifndef ALTERNATIVE_TASK_SWITCHER
        }
#endif

        [[NSApplication sharedApplication] run];
    }
    return 0;
}
