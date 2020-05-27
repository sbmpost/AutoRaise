/*
 * Copyright (C) 2020 sbmpost
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

// g++ -o AutoRaise AutoRaise.mm -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out) __attribute__((weak_import));
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static CGPoint oldPoint = {0, 0};
static bool spaceHasChanged = false;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;

AXUIElementRef window_get_from_point(CGPoint point) {
    AXUIElementRef _window = nullptr;
    AXUIElementRef _element = nullptr;
    CFStringRef _element_role = nullptr;

    if (AXUIElementCopyElementAtPosition(
        _accessibility_object,
        point.x,
        point.y,
        &_element) == kAXErrorSuccess) {

        if (AXUIElementCopyAttributeValue(
            _element,
            kAXRoleAttribute,
            (CFTypeRef *) &_element_role) == kAXErrorSuccess) {

            if (CFStringCompare(kAXWindowRole, _element_role, 0) == kCFCompareEqualTo) {
                _window = _element;
                _element = nullptr;
            } else {
                AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *)&_window);
            }
        }
    }

    if (_element) { CFRelease(_element); }
    if (_element_role) { CFRelease(_element_role); }

    return _window;
}

// google chrome specific fix
bool unknownRole(AXUIElementRef _focusedApp) {
    bool unknown = false;
    CFTypeRef _uiElement = nullptr;
    CFStringRef _element_role = nullptr;

    if (AXUIElementCopyAttributeValue(
        _focusedApp,
        (CFStringRef) kAXFocusedUIElementAttribute,
        &_uiElement) == kAXErrorSuccess && _uiElement) {

        unknown = AXUIElementCopyAttributeValue(
            (AXUIElementRef) _uiElement,
            kAXRoleAttribute,
            (CFTypeRef *) &_element_role) == kAXErrorSuccess &&
            CFStringCompare(kAXUnknownRole, _element_role, 0) == kCFCompareEqualTo;
    }

    if (_uiElement) { CFRelease(_uiElement); }
    if (_element_role) { CFRelease(_element_role); }

    return unknown;
}

bool equal_window(AXUIElementRef _window1, AXUIElementRef _window2) {
    CGWindowID window1_id, window2_id;
    _AXUIElementGetWindow(_window1, &window1_id);
    _AXUIElementGetWindow(_window2, &window2_id);
    return window1_id == window2_id;
}

class MyClass {
private:
    void * workspaceWatcher;
public:
    MyClass();
    ~MyClass();
    const void spaceChanged(void * anNSnotification);
    void startTimer(float timerInterval);
    const void onTick(void * anNSTimer);
};

@interface MDWorkspaceWatcher : NSObject {
    MyClass * myClass;
    NSTimer * myTimer;
}
- (id)initWithMyClass:(MyClass *)aMyClass;
- (void)startTimer:(float)timerInterval;
@end

@implementation MDWorkspaceWatcher
- (id)initWithMyClass:(MyClass *)aMyClass {
    myTimer = nil;
    if ((self = [super init])) {
        myClass = aMyClass;
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:self
            selector:@selector(spaceChanged:)
            name:NSWorkspaceActiveSpaceDidChangeNotification
            object:nil];
    }
    return self;
}
- (void)startTimer:(float)timerInterval {
    NSMethodSignature * sgn = [self methodSignatureForSelector:@selector(onTick:)];
    NSInvocation * inv = [NSInvocation invocationWithMethodSignature: sgn];
    [inv setTarget: self];
    [inv setSelector: @selector(onTick:)];
    if (myTimer) {
        [myTimer invalidate];
    }
    myTimer = [NSTimer timerWithTimeInterval: timerInterval invocation:inv repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer: myTimer forMode:NSRunLoopCommonModes];
}
- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [super dealloc];
}
- (void)spaceChanged:(NSNotification *)notification {
    myClass->spaceChanged(notification);
}
- (void)onTick:(NSTimer *)timer {
    myClass->onTick(timer);
}
@end

MyClass::MyClass() {
    workspaceWatcher = [[MDWorkspaceWatcher alloc] initWithMyClass:this];
}
MyClass::~MyClass() {
    [(MDWorkspaceWatcher *) workspaceWatcher release];
}
void MyClass::startTimer(float timerInterval) {
    [(MDWorkspaceWatcher *) workspaceWatcher startTimer: timerInterval];
}
const void MyClass::spaceChanged(void * anNSNotification) {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}
const void MyClass::onTick(void * anNSTimer) {
    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) {
        delayTicks--;
    }
    
    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    bool mouseMoved = fabs(mousePoint.x-oldPoint.x) > 2;
    mouseMoved = mouseMoved || fabs(mousePoint.y-oldPoint.y) > 2;
    oldPoint = mousePoint;

    // spaceHasChanged has priority
    // over waiting for the delay
    if (spaceHasChanged) {
        if (mouseMoved) {
            return;
        }
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
    // 2. delayTicks: start to count down if the mouse didn't move
    // 3. raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        pid_t mouseWindow_pid;
        AXUIElementRef _mouseWindow = window_get_from_point(mousePoint);
        if (_mouseWindow && AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
            Boolean needs_raise = true;
            CFTypeRef _focusedApp = nullptr;
            AXUIElementCopyAttributeValue(
                _accessibility_object,
                (CFStringRef) kAXFocusedApplicationAttribute,
                (CFTypeRef*) &_focusedApp);

            if (_focusedApp) {
                pid_t focusedApp_pid;
                AXUIElementRef _focusedAppElement = (AXUIElementRef) _focusedApp;
                if (AXUIElementGetPid(_focusedAppElement, &focusedApp_pid) == kAXErrorSuccess) {
                    CFTypeRef _focusedWindow;
                    if (AXUIElementCopyAttributeValue(
                        _focusedAppElement,
                        (CFStringRef) kAXFocusedWindowAttribute,
                        (CFTypeRef*) &_focusedWindow) == kAXErrorSuccess && _focusedWindow) {

                        needs_raise = !equal_window(_mouseWindow, (AXUIElementRef) _focusedWindow) &&
                            (focusedApp_pid != mouseWindow_pid || !unknownRole(_focusedAppElement));

                        CFRelease(_focusedWindow);
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
                    if (raiseTimes) {
                        raiseTimes--;
                    } else {
                        raiseTimes = 3;
                    }

                    if (AXUIElementPerformAction(_mouseWindow, kAXRaiseAction) == kAXErrorSuccess) {
                        [[NSRunningApplication runningApplicationWithProcessIdentifier: mouseWindow_pid]
                            activateWithOptions: NSApplicationActivateIgnoringOtherApps];
                    }
                }
            } else {
                raiseTimes = 0;
                delayTicks = 0;
            }
            CFRelease(_mouseWindow);
        } else {
            raiseTimes = 0;
            delayTicks = 0;
        }
    }
}

#define POLLING_MS 50
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc == 3) {
            NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
            delayCount = abs((int) [standardDefaults integerForKey:@"delay"]);
        } else {
            NSString *path = [NSString stringWithFormat:@"%@/AutoRaise.delay", NSHomeDirectory()];
            NSFileHandle *myFile = [NSFileHandle fileHandleForReadingAtPath:path];
            delayCount = abs([[[NSString alloc] initWithData:[myFile readDataOfLength:1]
                encoding:NSUTF8StringEncoding] intValue]);
            [myFile closeFile];
        }
        if (!delayCount) {
            delayCount = 1;
        }
        printf("\nBy sbmpost(c) 2020, usage:\nAutoRaise -delay <1=%dms> (or use 'echo 1 > AutoRaise.delay')"
               "\nStarted with %d ms delay...\n", POLLING_MS, delayCount*POLLING_MS);
        NSDictionary *options = @{(id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((CFDictionaryRef)options);
        MyClass myClass = MyClass();
        myClass.startTimer(POLLING_MS/1000.0);
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
