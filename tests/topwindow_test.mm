// Regression test for topwindow() / is_window_under_cursor().
//
// Replays a real CGWindowList capture (tests/fixture-telegram-photo-viewer.json,
// taken while Telegram's photo viewer was open and the cursor sat outside Telegram's
// main window) through the shipping predicate, and mutates it to cover the windows
// that must NOT be mistaken for the window under the cursor.
//
// The bug this pins down: with a layer-0-only filter, topwindow() looks straight
// through a full-screen overlay and returns whichever ordinary window sits behind it,
// so AutoRaise focuses another app through the overlay and Telegram hides the viewer.
//
// Built by `make test`, which compiles AutoRaise.mm with -Dmain=autoraise_main so the
// real implementation is linked in rather than a copy that could drift from it.
#import <Cocoa/Cocoa.h>

bool is_window_under_cursor(NSDictionary * window, CGPoint point,
    pid_t frontmost_pid, bool frontmost_is_regular);

static int failures = 0;
static int checks = 0;

static void check(bool ok, NSString * what) {
    checks++;
    if (!ok) { failures++; }
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
}

// topwindow()'s loop, minus the live CGWindowList call. Kept to three lines so the
// interesting logic stays in the shipping predicate rather than in the test.
static NSDictionary * pick(NSArray * windows, CGPoint point, pid_t pid, bool regular) {
    for (NSDictionary * w in windows) {
        if (is_window_under_cursor(w, point, pid, regular)) { return w; }
    }
    return nil;
}

// the pre-fix behaviour, kept so the test states what actually regressed
static NSDictionary * pick_layer_zero_only(NSArray * windows, CGPoint point) {
    for (NSDictionary * w in windows) {
        if ([w[(__bridge id) kCGWindowLayer] intValue] != 0) { continue; }
        NSDictionary * b = w[(__bridge id) kCGWindowBounds];
        NSRect r = NSMakeRect([b[@"X"] intValue], [b[@"Y"] intValue],
                              [b[@"Width"] intValue], [b[@"Height"] intValue]);
        if (NSPointInRect(NSPointFromCGPoint(point), r)) { return w; }
    }
    return nil;
}

static pid_t pidOf(NSDictionary * w) {
    return w ? [w[(__bridge id) kCGWindowOwnerPID] intValue] : 0;
}
static int layerOf(NSDictionary * w) {
    return w ? [w[(__bridge id) kCGWindowLayer] intValue] : -9999;
}

// Rebuild a CGWindowList-shaped dictionary from the fixture, mapping the captured
// display rect onto the live one so covers_display() -- which reads the live display
// list -- judges the same geometry it was captured with.
static NSDictionary * windowFrom(NSDictionary * f, double sx, double sy, double ox, double oy) {
    return @{
        (__bridge id) kCGWindowOwnerPID:  f[@"pid"],
        (__bridge id) kCGWindowOwnerName: f[@"owner"],
        (__bridge id) kCGWindowLayer:     f[@"layer"],
        (__bridge id) kCGWindowAlpha:     f[@"alpha"],
        (__bridge id) kCGWindowNumber:    f[@"number"],
        (__bridge id) kCGWindowBounds: @{
            @"X":      @([f[@"x"] doubleValue] * sx + ox),
            @"Y":      @([f[@"y"] doubleValue] * sy + oy),
            @"Width":  @([f[@"w"] doubleValue] * sx),
            @"Height": @([f[@"h"] doubleValue] * sy),
        },
    };
}

static NSMutableArray * mutate(NSArray * windows, pid_t pid, int layer,
    NSDictionary * changes, bool drop) {
    NSMutableArray * out = [NSMutableArray array];
    for (NSDictionary * w in windows) {
        if ([w[(__bridge id) kCGWindowOwnerPID] intValue] == pid &&
            [w[(__bridge id) kCGWindowLayer] intValue] == layer) {
            if (drop) { continue; }
            NSMutableDictionary * m = [w mutableCopy];
            [m addEntriesFromDictionary: changes];
            [out addObject: m];
        } else {
            [out addObject: w];
        }
    }
    return out;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString * path = argc > 1
            ? [NSString stringWithUTF8String: argv[1]]
            : @"tests/fixture-telegram-photo-viewer.json";
        NSData * data = [NSData dataWithContentsOfFile: path];
        if (!data) {
            fprintf(stderr, "cannot read fixture: %s\n", path.UTF8String);
            return 2;
        }
        NSDictionary * fx = [NSJSONSerialization JSONObjectWithData: data options: 0 error: nil];

        CGRect live = CGDisplayBounds(CGMainDisplayID());
        NSDictionary * cap = fx[@"display"];
        double sx = live.size.width  / [cap[@"w"] doubleValue];
        double sy = live.size.height / [cap[@"h"] doubleValue];
        double ox = live.origin.x - [cap[@"x"] doubleValue] * sx;
        double oy = live.origin.y - [cap[@"y"] doubleValue] * sy;

        NSMutableArray * windows = [NSMutableArray array];
        for (NSDictionary * f in fx[@"windows"]) {
            [windows addObject: windowFrom(f, sx, sy, ox, oy)];
        }
        CGPoint cursor = CGPointMake([fx[@"cursor"][@"x"] doubleValue] * sx + ox,
                                     [fx[@"cursor"][@"y"] doubleValue] * sy + oy);
        pid_t telegram = [fx[@"frontmost_pid"] intValue];
        pid_t behind   = [fx[@"expect_old_topwindow_pid"] intValue];

        printf("fixture %s\n  cursor (%.0f,%.0f)  frontmost pid %d  display %.0fx%.0f\n\n",
               path.UTF8String, cursor.x, cursor.y, telegram, live.size.width, live.size.height);

        // 1. the bug, stated as an assertion: layer-0-only resolves to the app BEHIND
        //    the overlay, which is what let AutoRaise steal focus through it
        NSDictionary * old = pick_layer_zero_only(windows, cursor);
        check(pidOf(old) == behind,
            ([NSString stringWithFormat:
                @"pre-fix behaviour reproduces: layer-0-only picks pid %d (expected %d, the app behind the overlay)",
                pidOf(old), behind]));

        // 2. happy path: the overlay itself is now the window under the cursor
        NSDictionary * got = pick(windows, cursor, telegram, true);
        check(pidOf(got) == telegram && layerOf(got) > 0,
            ([NSString stringWithFormat:
                @"full-screen overlay of the frontmost app wins: got pid %d layer %d (expected pid %d, layer > 0)",
                pidOf(got), layerOf(got), telegram]));

        // 3. the Dock owns a permanent screen-sized window at level 20; when the Dock
        //    is frontmost (Launchpad) it is not a regular app and must never win
        pid_t dock = 0;
        for (NSDictionary * w in windows) {
            if ([w[(__bridge id) kCGWindowOwnerName] isEqualToString: @"Dock"]) {
                dock = [w[(__bridge id) kCGWindowOwnerPID] intValue];
            }
        }
        check(dock != 0, @"fixture contains the Dock's screen-sized level 20 window");
        check(pidOf(pick(windows, cursor, dock, false)) == behind,
            @"non-regular frontmost app (Dock, level 20, screen sized) is rejected");

        // 4. Migration Assistant keeps a screen-sized backdrop at level -1. It is a
        //    regular app, so only the layer > 0 test excludes it -- which means this
        //    has to be probed somewhere no ordinary window covers the cursor, or a
        //    layer 0 window wins first and the guard is never reached.
        pid_t backdrop = 0;
        for (NSDictionary * w in windows) {
            if ([w[(__bridge id) kCGWindowLayer] intValue] < 0) {
                backdrop = [w[(__bridge id) kCGWindowOwnerPID] intValue];
            }
        }
        check(backdrop != 0, @"fixture contains a negative-level screen-sized backdrop");

        CGPoint bare = CGPointZero;
        for (double y = live.origin.y + live.size.height - 4; y > live.origin.y && bare.y == 0; y -= 8) {
            for (double x = live.origin.x + live.size.width - 4; x > live.origin.x; x -= 8) {
                if (!pick_layer_zero_only(windows, CGPointMake(x, y))) {
                    bare = CGPointMake(x, y); break;
                }
            }
        }
        check(bare.y != 0, ([NSString stringWithFormat:
            @"found a point covered by no ordinary window: (%.0f,%.0f)", bare.x, bare.y]));
        check(pidOf(pick(windows, bare, backdrop, true)) == 0,
            @"negative-level backdrop of a regular frontmost app is rejected even where nothing else covers the cursor");
        check(pidOf(pick(windows, bare, dock, false)) == 0,
            @"Dock's screen-sized level 20 window is rejected even where nothing else covers the cursor");
        check(pidOf(pick(windows, bare, telegram, true)) == telegram,
            @"the overlay still wins where no ordinary window covers the cursor");

        // 5. a fully transparent screen-sized window is a click catcher, not an overlay
        NSArray * clear = mutate(windows, telegram, 101, @{(__bridge id) kCGWindowAlpha: @0}, false);
        check(pidOf(pick(clear, cursor, telegram, true)) == behind,
            @"alpha 0 screen-sized window is rejected (click catcher, not a visible overlay)");

        // 6. content-sized popups keep the old behaviour: Telegram's context menu and
        //    reaction bar must stay invisible to this function. The popup is placed
        //    around the cursor on purpose -- put it anywhere else and NSPointInRect
        //    rejects it first, and the size test is never exercised.
        NSArray * small = mutate(windows, telegram, 101,
            @{(__bridge id) kCGWindowBounds: @{
                @"X": @(cursor.x - 20), @"Y": @(cursor.y - 20), @"Width": @246, @"Height": @320}}, false);
        check(pidOf(pick(small, cursor, telegram, true)) == behind,
            @"content-sized popup (246x320) covering the cursor is rejected, so context menus behave as before");

        // 7. with no overlay at all, the fix must be a no-op
        NSArray * none = mutate(windows, telegram, 101, nil, true);
        check(pidOf(pick(none, cursor, telegram, true)) == pidOf(pick_layer_zero_only(none, cursor)),
            @"no overlay present: new and old behaviour agree");

        // 8. cursor over the frontmost app's own window resolves to that app either way
        CGPoint onTelegram = CGPointMake(400 * sx + ox, 300 * sy + oy);
        check(pidOf(pick(windows, onTelegram, telegram, true)) == telegram &&
              pidOf(pick_layer_zero_only(windows, onTelegram)) == telegram,
            @"cursor over the frontmost app itself resolves to that app under both rules");

        printf("\n%d checks, %d failed\n", checks, failures);
        return failures ? 1 : 0;
    }
}
