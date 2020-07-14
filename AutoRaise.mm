/*
 * AutoRaise - Copyright (C) 2020 sbmpost
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

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out) __attribute__((weak_import));
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
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

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = nullptr;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(id) kCGWindowLayer] isEqual: @0]) { continue; }

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
    AXUIElementRef _window = nullptr;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = nullptr;
        AXUIElementRef _window_owner = AXUIElementCreateApplication([top_window[(id) kCGWindowOwnerPID] intValue]);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(id) kCGWindowNumber] intValue];
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
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = nullptr;
    AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);
    if (_element) {
        CFStringRef _element_role = nullptr;
        AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
        if (_element_role) {
            if (CFEqual(_element_role, kAXDockItemRole)) {
                CFRelease(_element_role);
                CFRelease(_element);
            } else if (CFEqual(_element_role, kAXWindowRole)) {
                CFRelease(_element_role);
                return _element;
            } else {
                AXUIElementRef _window = nullptr;
                AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *)&_window);
                if (!_window && !CFEqual(_element_role, kAXMenuItemRole)) {
                    _window = fallback(point);
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

    return nullptr;
}

CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    AXValueRef _size = nullptr;
    AXValueRef _pos = nullptr;

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

//-----------------------------------------------notifications----------------------------------------------

class MyClass;
@interface MDWorkspaceWatcher : NSObject {
    MyClass * myClass;
}
- (id)initWithMyClass:(MyClass *)aMyClass;
@end

class MyClass {
private:
    MDWorkspaceWatcher * workspaceWatcher;
public:
    MyClass();
    ~MyClass();
    const void spaceChanged(NSNotification * notification);
    const void appActivated(NSNotification * notification);
    void startTimer(float timerInterval);
    const void onTick();
};

@implementation MDWorkspaceWatcher
- (id)initWithMyClass:(MyClass *)aMyClass {
    if ((self = [super init])) {
        myClass = aMyClass;
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
    myClass->spaceChanged(notification);
}
- (void)appActivated:(NSNotification *)notification {
    myClass->appActivated(notification);
}
- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector:@selector(onTick:) withObject:timerInterval afterDelay:timerInterval.floatValue];
    myClass->onTick();
}
@end

MyClass::MyClass() {
    workspaceWatcher = [[MDWorkspaceWatcher alloc] initWithMyClass: this];
}
MyClass::~MyClass() {}
void MyClass::startTimer(float timerInterval) {
    [(MDWorkspaceWatcher *) workspaceWatcher onTick: [NSNumber numberWithFloat: timerInterval]];
}
const void MyClass::spaceChanged(NSNotification * notification) {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}

//------------------------------------------where it all happens--------------------------------------------

const void MyClass::appActivated(NSNotification * notification) {
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    bool mouseMoved = fabs(mousePoint.x-oldPoint.x) > 0;
    mouseMoved = mouseMoved || fabs(mousePoint.y-oldPoint.y) > 0;
    if (mouseMoved) { return; }

    appWasActivated = true;
    pid_t application_pid = ((NSRunningApplication *) ((NSWorkspace *)
        notification.object).frontmostApplication).processIdentifier;

    AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
    if (_mouseWindow) {
        bool needs_warp = true;
        pid_t mouseWindow_pid;
        if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
            needs_warp = mouseWindow_pid != application_pid;
        }

        if (needs_warp) {
            CFTypeRef _focusedWindow = nullptr;
            AXUIElementRef _focusedApp = AXUIElementCreateApplication(application_pid);
            AXUIElementCopyAttributeValue(
                (AXUIElementRef) _focusedApp,
                kAXFocusedWindowAttribute,
                &_focusedWindow);
            CFRelease(_focusedApp);

            if (_focusedWindow) {
                CGWarpMouseCursorPosition(get_mousepoint((AXUIElementRef) _focusedWindow));
                CFRelease(_focusedWindow);
            }
        }
        CFRelease(_mouseWindow);
    }
}

const void MyClass::onTick() {
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

    // 1. mouseMoved: we have to decide if the window needs raising
    // 2. delayTicks: count down as long as the mouse doesn't move
    // 3. raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                Boolean needs_raise = true;
                CFTypeRef _focusedApp = nullptr;
                AXUIElementCopyAttributeValue(
                    _accessibility_object,
                    kAXFocusedApplicationAttribute,
                    &_focusedApp);

                if (_focusedApp) {
                    pid_t focusedApp_pid;
                    if (AXUIElementGetPid(
                        (AXUIElementRef) _focusedApp,
                        &focusedApp_pid) == kAXErrorSuccess) {
                        CFTypeRef _focusedWindow = nullptr;
                        AXUIElementCopyAttributeValue(
                            (AXUIElementRef) _focusedApp,
                            kAXFocusedWindowAttribute,
                            &_focusedWindow);

                        if (_focusedWindow) {
                            CGWindowID window1_id, window2_id;
                            _AXUIElementGetWindow(_mouseWindow, &window1_id);
                            _AXUIElementGetWindow((AXUIElementRef) _focusedWindow, &window2_id);
                            CFRelease(_focusedWindow);
                            needs_raise = window1_id != window2_id;
                        }
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
                            [[NSRunningApplication runningApplicationWithProcessIdentifier: mouseWindow_pid]
                                activateWithOptions: NSApplicationActivateIgnoringOtherApps];
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

#define POLLING_MS 20
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc >= 3) {
            NSUserDefaults * standardDefaults = [NSUserDefaults standardUserDefaults];
            delayCount = abs((int) [standardDefaults integerForKey: @"delay"]);
            warpMouse = argc != 3 ;
            if (argc >= 7) {
                warpX = [standardDefaults floatForKey: @"warpX"];
                warpY = [standardDefaults floatForKey: @"warpY"];
            }
        } else {
            NSString * home = NSHomeDirectory();
            NSFileHandle * delayFile = [NSFileHandle fileHandleForReadingAtPath:
                [NSString stringWithFormat: @"%@/AutoRaise.delay", home]];
            if (delayFile) {
                delayCount = abs([[[NSString alloc] initWithData:
                    [delayFile readDataOfLength: 2] encoding:
                    NSUTF8StringEncoding] intValue]);
                [delayFile closeFile];
            }
            NSFileHandle * warpFile = [NSFileHandle fileHandleForReadingAtPath:
                [NSString stringWithFormat: @"%@/AutoRaise.warp", home]];
            if (warpFile) {
                warpMouse = true;
                NSString * line = [[NSString alloc] initWithData:
                    [warpFile readDataOfLength:7] encoding:
                    NSUTF8StringEncoding];
                NSArray * components = [line componentsSeparatedByString: @" "];
                if (components.count) {
                    warpX = [components.firstObject floatValue];
                    warpY = [components.lastObject floatValue];
                }
                [warpFile closeFile];
            }
        }
        if (!delayCount) { delayCount = 2; }

        printf("\nBy sbmpost(c) 2020, usage:\nAutoRaise -delay <1=%dms> [-warpX <0.5> -warpY <0.5>]"
               "\nStarted with %d ms delay%s", POLLING_MS, delayCount*POLLING_MS, warpMouse ? ", " : "\n");
        if (warpMouse) { printf("warpX: %.1f, warpY: %.1f\n", warpX, warpY); }

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);

        MyClass myClass = MyClass();
        myClass.startTimer(POLLING_MS/1000.0);
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
