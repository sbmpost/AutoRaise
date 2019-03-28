/*
 * metamove - XFree86 window movement for OS X
 * Copyright (C) 2013 jmgao, heavily modified by sbmpost
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

#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include "AutoRaise.hpp"

#define nullptr NULL

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out) __attribute__((weak_import));
static AXUIElementRef accessibility_object = AXUIElementCreateSystemWide();
static CGPoint oldPoint = {0, 0};
static bool spaceHasChanged = false;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;

CGPoint window_get_position(AXUIElementRef window)
{
    AXValueRef position_wrapper = nullptr;
    CGPoint result;
    
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, (CFTypeRef *)&position_wrapper) != kAXErrorSuccess) {
        assert(false && "Unable to get AXValueRef for window position");
    }
    
#ifdef MAC_OS_X_VERSION_10_11
#define kAXValueCGPointType kAXValueTypeCGPoint
#define kAXValueCGSizeType kAXValueTypeCGSize
#endif
    
    assert(AXValueGetType(position_wrapper) == kAXValueCGPointType);
    if (!AXValueGetValue(position_wrapper, kAXValueCGPointType, &result)) {
        assert(false && "Unable to get CGPoint for window position");
    }
    
    CFRelease(position_wrapper);
    return result;
}

/*
 void window_set_position(AXUIElementRef window, CGPoint position)
 {
 AXValueRef position_wrapper = AXValueCreate(kAXValueCGPointType, &position);
 AXUIElementSetAttributeValue(window, kAXPositionAttribute, position_wrapper);
 CFRelease(position_wrapper);
 }
 */

CGSize window_get_size(AXUIElementRef window)
{
    AXValueRef size_wrapper = nullptr;
    CGSize result;
    
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, (CFTypeRef *)&size_wrapper) != kAXErrorSuccess) {
        assert(false && "Unable to get AXValueRef for window size");
    }
    
    assert(AXValueGetType(size_wrapper) == kAXValueCGSizeType);
    if (!AXValueGetValue(size_wrapper, kAXValueCGSizeType, &result)) {
        assert(false && "Unable to get CGSize for window size");
    }
    
    CFRelease(size_wrapper);
    return result;
}

/*
void window_set_size(AXUIElementRef window, CGSize size)
{
    AXValueRef size_wrapper = AXValueCreate(kAXValueCGSizeType, &size);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, size_wrapper);
    CFRelease(size_wrapper);
}

AXUIElementRef window_copy_application(AXUIElementRef window)
{
    AXUIElementRef current = nullptr;
    AXUIElementCopyAttributeValue(window, kAXParentAttribute, (CFTypeRef *)&current);
    
    while (current) {
        CFStringRef role = nullptr;
        if (AXUIElementCopyAttributeValue(current, kAXRoleAttribute, (CFTypeRef *)&role) != kAXErrorSuccess) {
            NSLog(@"Unable to copy role for element, aborting");
            current = nullptr;
            break;
        }
        
        if (CFStringCompare(role, kAXApplicationRole, 0) != 0) {
            AXUIElementRef last = current;
            AXUIElementCopyAttributeValue(current, kAXParentAttribute, (CFTypeRef *)&current);
            CFRelease(last);
            CFRelease(role);
        } else {
            CFRelease(role);
            break;
        }
    }
    
    return current;
}
*/

AXUIElementRef window_get_from_point(CGPoint point)
{
    AXUIElementRef element = nullptr;
    CFStringRef element_role = nullptr;
    AXUIElementRef window_owner = nullptr;
    
    // Naive method, fails for Console's message pane
    if (AXUIElementCopyElementAtPosition(accessibility_object, point.x, point.y, &element) == kAXErrorSuccess) {
        if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, (CFTypeRef *)&element_role) == kAXErrorSuccess) {
            if (CFStringCompare(kAXWindowRole, element_role, 0) != kCFCompareEqualTo) {
                AXUIElementRef window = nullptr;
                if (AXUIElementCopyAttributeValue(element, kAXWindowAttribute, (CFTypeRef *)&window) == kAXErrorSuccess) {
                    if (element != window) {
                        CFRelease(element);
                        element = window;
                    }
                    goto exit;
                } else {
//                    NSLog(@"Unable to copy window for element, using fallback method");
                }
            }
        } else {
//            NSLog(@"Unable to copy role for element, using fallback method");
        }
    } else {
//        NSLog(@"Unable to copy element at position (%f, %f), using fallback method", point.x, point.y);
    }

    if (element) {
        CFRelease(element);
        element = nullptr;
    }
    
    // Fallback method, find the topmost window that contains the cursor
    {
        NSDictionary *selected_window = nullptr;
        NSArray *window_list = [(NSArray *)CGWindowListCopyWindowInfo(
                                                                      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                                      kCGNullWindowID) autorelease];
        NSRect window_bounds = NSZeroRect;
        
        for (NSDictionary *current_window in window_list) {
            NSDictionary *window_bounds_dict = current_window[(NSString *) kCGWindowBounds];
            
            if (![current_window[(id)kCGWindowLayer] isEqual: @0]) {
                continue;
            }
            
            int x = [window_bounds_dict[@"X"] intValue];
            int y = [window_bounds_dict[@"Y"] intValue];
            int width = [window_bounds_dict[@"Width"] intValue];
            int height = [window_bounds_dict[@"Height"] intValue];
            NSRect current_window_bounds = NSMakeRect(x, y, width, height);
            if (NSPointInRect(NSPointFromCGPoint(point), current_window_bounds)) {
                window_bounds = current_window_bounds;
                selected_window = current_window;
                break;
            }
        }
        
        if (!selected_window) {
            // NSLog(@"Unable to find window under cursor");
            goto exit;
        }
        
        // Find the AXUIElement corresponding to the window via its application
        {
            int window_owner_pid = [selected_window[(id)kCGWindowOwnerPID] intValue];
            window_owner = AXUIElementCreateApplication(window_owner_pid);
            CFTypeRef windows_cf = nullptr;
            NSArray *application_windows = nullptr;
            
            if (AXUIElementCopyAttributeValue(window_owner, kAXWindowsAttribute, &windows_cf) != kAXErrorSuccess) {
                // NSLog(@"Failed to find window under cursor");
                goto exit;
            }
            
            application_windows = [(NSArray *) windows_cf autorelease];
            
            // Use a private symbol to get the CGWindowID from the application's windows
            if (_AXUIElementGetWindow) {
                CGWindowID selected_window_id = [selected_window[(id)kCGWindowNumber] intValue];
                
                if (!selected_window_id) {
                    NSLog(@"Unable to get window ID for selected window");
                    goto exit;
                }
                
                for (id application_window in application_windows) {
                    AXUIElementRef application_window_ax = (__bridge AXUIElementRef)application_window;
                    CGWindowID application_window_id = 0;
                    
                    if (_AXUIElementGetWindow(application_window_ax, &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == selected_window_id) {
                            element = application_window_ax;
                            CFRetain(element);
                            goto exit;
                        }
                    } else {
                        // NSLog(@"Unable to get window id from AXUIElement");
                    }
                }
            } else {
                // NSLog(@"Unable to use _AXUIElementGetWindow, falling back to window bounds comparison");
                
                for (id application_window in application_windows) {
                    AXUIElementRef application_window_ax = (__bridge AXUIElementRef)application_window;
                    CGPoint application_window_position = window_get_position(application_window_ax);
                    CGSize application_window_size = window_get_size(application_window_ax);
                    
                    NSRect application_window_bounds =
                    NSMakeRect(application_window_position.x,
                               application_window_position.y,
                               application_window_size.width,
                               application_window_size.height);
                    
                    if (NSEqualRects(application_window_bounds, window_bounds)) {
                        element = application_window_ax;
                        CFRetain(element);
                        goto exit;
                    }
                }
            }
        }
    }
    
exit:
    if (element_role) CFRelease(element_role);
    if (window_owner) CFRelease(window_owner);
    return element;
}

bool equal_window(AXUIElementRef _window1, AXUIElementRef _window2) {
    if (_AXUIElementGetWindow) {
        CGWindowID window1_id, window2_id;
        _AXUIElementGetWindow(_window1, &window1_id);
        _AXUIElementGetWindow(_window2, &window2_id);
        return window1_id == window2_id;
    } else {
        CGPoint window1_pos = window_get_position(_window1);
        CGSize window1_size = window_get_size(_window1);
        NSRect window1_bounds = NSMakeRect(window1_pos.x,
            window1_pos.y, window1_size.width, window1_size.height);
        CGPoint window2_pos = window_get_position(_window2);
        CGSize window2_size = window_get_size(_window2);
        NSRect window2_bounds = NSMakeRect(window2_pos.x,
            window2_pos.y, window2_size.width, window2_size.height);
        return NSEqualRects(window1_bounds, window2_bounds);
    }
}

void window_raise(AXUIElementRef window) {
    // With thanks to http://stackoverflow.com/a/6784991/341371
    if (AXUIElementPerformAction(window, kAXRaiseAction) != kAXErrorSuccess) {
        // NSLog(@"Unable to raise window");
        return;
    }

    pid_t window_pid = 0;
    if (AXUIElementGetPid(window, &window_pid) != kAXErrorSuccess) {
        NSLog(@"Unable to get PID for window");
        return;
    }

    [[NSRunningApplication runningApplicationWithProcessIdentifier: window_pid]
        activateWithOptions: NSApplicationActivateIgnoringOtherApps];

/*
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    ProcessSerialNumber window_process;
    if (GetProcessForPID(window_pid, &window_process) != 0) {
        NSLog(@"Unable to get process for window PID");
        return;
    }
    
    if (SetFrontProcessWithOptions(&window_process, kSetFrontProcessFrontWindowOnly) != 0) {
        NSLog(@"Unable to set front process");
        return;
    }
#pragma clang diagnostic pop
*/
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
    if (_event) {
        CFRelease(_event);
    }
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
        // raiseTimes = 0;
        delayTicks = 0;
        spaceHasChanged = false;
    } else if (delayTicks && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        oldPoint.x = oldPoint.y = 0;
        return;
    }
    
    if (mouseMoved || raiseTimes || delayTicks) {
        AXUIElementRef _mouseWindow = window_get_from_point(mousePoint);
        if (_mouseWindow) {
            Boolean needs_raise = true;
            CFTypeRef _focusedApp = nullptr;
            AXUIElementCopyAttributeValue(
                accessibility_object,
                (CFStringRef) kAXFocusedApplicationAttribute,
                (CFTypeRef*) &_focusedApp);

            if (_focusedApp) {
                pid_t focused_pid;
                if (AXUIElementGetPid (
                    (AXUIElementRef) _focusedApp,
                    &focused_pid) == kAXErrorSuccess) {
                    CFTypeRef _focusedWindow;
                    if (AXUIElementCopyAttributeValue(
                        (AXUIElementRef) _focusedApp,
                        (CFStringRef) kAXFocusedWindowAttribute,
                        (CFTypeRef*) &_focusedWindow) == kAXErrorSuccess && _focusedWindow) {
                        needs_raise = !equal_window(_mouseWindow, (AXUIElementRef) _focusedWindow);
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
                if (raiseTimes || delayTicks <= 1) {
                    delayTicks = 0; // disable delay
                    if (!raiseTimes) {
                        // raise 3 times
                        raiseTimes = 3;
                        // raiseTimes = 0;
                    }
                    // NSLog(@"Raising");
                    window_raise(_mouseWindow);
                }
            } else {
                delayTicks = 0;
            }
            if (raiseTimes) {
                raiseTimes--;
            }
            //NSLog(@"raiseTimes: %@, delayTicks: %@",
            //      [NSString stringWithFormat:@"%d", raiseTimes],
            //      [NSString stringWithFormat:@"%d", delayTicks]);
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
            NSFileHandle *myFile = [NSFileHandle fileHandleForReadingAtPath:@"./AutoRaise.delay"];
            delayCount = abs([[[NSString alloc] initWithData:[myFile readDataOfLength:1]
                encoding:NSUTF8StringEncoding] intValue]);
            [myFile closeFile];
//            fcntl (0, F_SETFL, O_NONBLOCK);
//            char c = fgetc(stdin);
//            delayCount = abs(atoi(&c));
        }
        if (!delayCount) {
            delayCount = 1;
        }
        printf("\nBy sbmpost(c) 2017, usage:\nAutoRaise -delay <1=%dms> (or use 'echo <delay value> > AutoRaise.delay')"
               "\nStarted with %d ms delay...\n", POLLING_MS, delayCount*POLLING_MS);
        NSDictionary *options = @{(id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((CFDictionaryRef)options);
        MyClass myClass = MyClass();
        myClass.startTimer(POLLING_MS/1000.0);
        [[NSApplication sharedApplication] run];
    }
    return 0;
}

/*
NSLog(@"MouseMoved: %@, raiseTimes: %@, delayTicks: %@",
[NSString stringWithFormat:@"%d", mouseMoved],
[NSString stringWithFormat:@"%d", raiseTimes],
[NSString stringWithFormat:@"%d", delayTicks]);

CFTypeRef _focusedTitle;
if (AXUIElementCopyAttributeValue((AXUIElementRef)_focusedWindow, kAXTitleAttribute, (CFTypeRef *) &_focusedTitle) == kAXErrorSuccess && _focusedTitle) {
}
CFTypeRef _windowTitle;
if (AXUIElementCopyAttributeValue((AXUIElementRef)_mouseWindow, kAXTitleAttribute, (CFTypeRef *) &_windowTitle) == kAXErrorSuccess && _windowTitle) {
}
NSLog(@"Raising: %@, currently focused is: %@", (__bridge NSString *) _windowTitle, (__bridge NSString *) _focusedTitle);
if (_focusedTitle) {
    CFRelease(_focusedTitle);
}
if (_windowTitle) {
    CFRelease(_windowTitle);
}
NSString * name = [[NSRunningApplication runningApplicationWithProcessIdentifier:window_pid] bundleIdentifier];
[[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:name options:NSWorkspaceLaunchDefault additionalEventParamDescriptor:nil launchIdentifier:nil];
}
*/
