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

typedef int CGSConnectionID;
static float oldScale = 1;
static float cursorScale = 2;
static bool activated_by_task_switcher = false;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static CFStringRef XQuartz = CFSTR("XQuartz");
static CGPoint oldPoint = {0, 0};
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool warpMouse = false;
static float warpX = 0.5;
static float warpY = 0.5;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;

//---------------------------------------------helper methods-----------------------------------------------

void activate(pid_t pid) {
    // [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
    //   activateWithOptions: NSApplicationActivateIgnoringOtherApps];
    // Temporary solution as NSRunningApplication does not work properly on OSX 11.1
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
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

AXUIElementRef get_raiseable_window(AXUIElementRef _element, CGPoint point) {
    if (_element) {
        CFStringRef _element_role = NULL;
        AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
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
                AXUIElementRef _window = NULL;
                AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                    _window = get_raiseable_window(_window, point);
                }
                CFRelease(_element_role);
                CFRelease(_element);
                return _window;
            }
        } else {
            CFRelease(_element);
        }
    } else {
        return fallback(point);
    }

    return NULL;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);
    return get_raiseable_window(_element, point);
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

//-----------------------------------------------notifications----------------------------------------------

class CppClass;
@interface MDWorkspaceWatcher : NSObject {
    CppClass * cppClass;
}
- (id)initWithCppClass:(CppClass *)aCppClass;
@end

class CppClass {
private:
    MDWorkspaceWatcher * workspaceWatcher;
public:
    CppClass();
    ~CppClass();
    const void spaceChanged(NSNotification * notification);
    const void appActivated(NSNotification * notification);
    void scheduleScale(float scale, float scaleDelay);
    void startTimer(float timerInterval);
    const void onTick();
};

@implementation MDWorkspaceWatcher
- (id)initWithCppClass:(CppClass *)aCppClass {
    if ((self = [super init])) {
        cppClass = aCppClass;
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
        }
    }
    return self;
}
- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}
- (void)spaceChanged:(NSNotification *)notification {
    cppClass->spaceChanged(notification);
}
- (void)appActivated:(NSNotification *)notification {
    cppClass->appActivated(notification);
}
- (void)scheduleScale:(NSNumber *)scale :(NSNumber *)scaleDelay {
    [self performSelector: @selector(onSetCursorScale:)
        withObject: scale
        afterDelay: scaleDelay.floatValue];
    [self performSelector: @selector(onSetCursorScale:)
        withObject: [NSNumber numberWithFloat: oldScale]
        afterDelay: scaleDelay.floatValue*3];
}
- (void)onSetCursorScale:(NSNumber *)scale {
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}
- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector: @selector(onTick:)
        withObject: timerInterval
        afterDelay: timerInterval.floatValue];
    cppClass->onTick();
}
@end

CppClass::CppClass() {
    workspaceWatcher = [[MDWorkspaceWatcher alloc] initWithCppClass: this];
}
CppClass::~CppClass() {}
void CppClass::startTimer(float timerInterval) {
    [(MDWorkspaceWatcher *) workspaceWatcher onTick: [NSNumber numberWithFloat: timerInterval]];
}
void CppClass::scheduleScale(float scale, float scaleDelay) {
    [(MDWorkspaceWatcher *) workspaceWatcher scheduleScale:
        [NSNumber numberWithFloat: scale]:
        [NSNumber numberWithFloat: scaleDelay]];
}
const void CppClass::spaceChanged(NSNotification * notification) {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}

//----------------------------------------------configuration-----------------------------------------------

const NSString *kDelay = @"delay";
const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale];
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
        [self readOriginalConfig];
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
    } else {
        [self readHiddenConfig];
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
    }
    return;
}

- (void) validateParameters {
    // validate and fix wrong/absent parameters
    if ([parameters[kDelay] intValue] < 1) { parameters[kDelay] = @"2"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
    return;
}

@end

//------------------------------------------where it all happens--------------------------------------------

#define SCALEDELAY_MS 300
const void CppClass::appActivated(NSNotification * notification) {
    if (!activated_by_task_switcher) { return; }
    activated_by_task_switcher = false;
    appWasActivated = true;

    pid_t focusedApp_pid = ((NSRunningApplication *) notification.userInfo[
        NSWorkspaceApplicationKey]).processIdentifier;
    AXUIElementRef _focusedWindow = NULL;
    AXUIElementRef _focusedApp = AXUIElementCreateApplication(focusedApp_pid);
    AXUIElementCopyAttributeValue(
        (AXUIElementRef) _focusedApp,
        kAXFocusedWindowAttribute,
        (CFTypeRef *) &_focusedWindow);
    CFRelease(_focusedApp);

    if (_focusedWindow) {
        CGWarpMouseCursorPosition(get_mousepoint((AXUIElementRef) _focusedWindow));
        CFRelease(_focusedWindow);
    }

    if (cursorScale != oldScale) {
        scheduleScale(cursorScale, SCALEDELAY_MS/1000.0);
    }
}

const void CppClass::onTick() {
    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) { delayTicks--; }

    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    bool mouseMoved = fabs(mousePoint.x-oldPoint.x) > 0;
    mouseMoved = mouseMoved || fabs(mousePoint.y-oldPoint.y) > 0;
    oldPoint = mousePoint;

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
                AXUIElementRef _focusedApp = AXUIElementCreateApplication(frontmost_pid);
                if (_focusedApp) {
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _focusedApp,
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
                    CFRelease(_focusedApp);
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
    activated_by_task_switcher = type == kCGEventFlagsChanged && commandTabPressed;
    commandTabPressed = false;
    if (type == kCGEventKeyUp) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            CGEventFlags flags = CGEventGetFlags(event);
            commandTabPressed = (flags & kCGEventFlagMaskCommand) == kCGEventFlagMaskCommand;
        }
    }

    return event;
}

#define POLLING_MS 20
#define VERSION "1.9"
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("\nv%s by sbmpost(c) 2021, usage:\nAutoRaise -delay <1=%dms> [-warpX <0.5> -warpY <0.5> -scale <2.0>]", VERSION, POLLING_MS);
        
        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config validateParameters];

        delayCount  = [parameters[@"delay"] intValue];
        warpX       = [parameters[@"warpX"] floatValue];
        warpY       = [parameters[@"warpY"] floatValue];
        cursorScale = [parameters[@"scale"] floatValue];

        printf("\nStarted with %d ms delay%s", delayCount*POLLING_MS, warpMouse ? ", " : "\n");
        if (warpMouse) { printf("warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale); }

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        CFMachPortRef eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0,
            (1 << kCGEventKeyUp) | (1 << kCGEventFlagsChanged), eventTapHandler, NULL);
        if (eventTap) {
            CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }

        CppClass cppClass = CppClass();
        cppClass.startTimer(POLLING_MS/1000.0);
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
