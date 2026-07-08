#include "spacecore.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

// --- Undocumented CGEvent field numbers & event-type constants -------------
// Reverse-engineered; may drift across macOS versions.
static const CGEventField kCGSEventTypeField          = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType       = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMotion   = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kCGEventGesturePhase         = (CGEventField)132;

static const int64_t kCGSEventDockControl     = 30;  // CGS event type
static const int64_t kIOHIDEventTypeDockSwipe = 23;  // IOHIDEventType
static const int64_t kMotionHorizontal        = 1;
static const int64_t kPhaseBegan     = 1;
static const int64_t kPhaseChanged   = 2;
static const int64_t kPhaseEnded     = 4;
static const int64_t kPhaseCancelled = 8;

static const double kGestureVelocity = 2000.0;

typedef int32_t  CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID) __attribute__((weak_import));
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID, CFStringRef) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID) __attribute__((weak_import));

static bool cgs_ok(void) {
    return &CGSMainConnectionID && &CGSGetActiveSpace &&
           &CGSCopyManagedDisplaySpaces && &CGSCopyActiveMenuBarDisplayIdentifier;
}

// Pull count + current-space index out of one display dict. Prefers the
// per-display "Current Space" over the global active space (multi-monitor).
static SpaceInfo extract(CFDictionaryRef d, CGSSpaceID globalActive) {
    SpaceInfo info; memset(&info, 0, sizeof(info));

    CFStringRef ident = (CFStringRef)CFDictionaryGetValue(d, CFSTR("Display Identifier"));
    if (ident && CFGetTypeID(ident) == CFStringGetTypeID())
        CFStringGetCString(ident, info.displayID, sizeof(info.displayID), kCFStringEncodingUTF8);

    CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(d, CFSTR("Spaces"));
    if (!spaces || CFGetTypeID(spaces) != CFArrayGetTypeID()) return info;

    CGSSpaceID active = globalActive;
    CFDictionaryRef cur = (CFDictionaryRef)CFDictionaryGetValue(d, CFSTR("Current Space"));
    if (cur && CFGetTypeID(cur) == CFDictionaryGetTypeID()) {
        CFNumberRef id = (CFNumberRef)CFDictionaryGetValue(cur, CFSTR("id64"));
        if (id) CFNumberGetValue(id, kCFNumberSInt64Type, &active);
    }

    CFIndex n = CFArrayGetCount(spaces);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef s = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, i);
        if (!s || CFGetTypeID(s) != CFDictionaryGetTypeID()) continue;
        CFNumberRef id = (CFNumberRef)CFDictionaryGetValue(s, CFSTR("id64"));
        CGSSpaceID sid = 0;
        if (id) CFNumberGetValue(id, kCFNumberSInt64Type, &sid);
        if (sid == active) info.currentIndex = info.spaceCount;
        info.spaceCount++;
    }
    info.ok = info.spaceCount > 0;
    return info;
}

// UUID string of the display currently under the cursor (caller releases).
static CFStringRef cursor_display_uuid(void) {
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CGDirectDisplayID id = 0; uint32_t count = 0;
    if (CGGetDisplaysWithPoint(p, 1, &id, &count) != kCGErrorSuccess || count == 0) return NULL;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(id);
    if (!uuid) return NULL;
    CFStringRef s = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return s;
}

bool space_info(SpaceTarget target, SpaceInfo *out) {
    SpaceInfo none; memset(&none, 0, sizeof(none));
    if (out) *out = none;
    if (!cgs_ok() || !out) return false;

    CGSConnectionID c = CGSMainConnectionID();
    CGSSpaceID globalActive = CGSGetActiveSpace(c);

    CFStringRef uuid = target == SpaceTargetCursor
        ? cursor_display_uuid()
        : CGSCopyActiveMenuBarDisplayIdentifier(c);

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(c, NULL);
    if (!displays) { if (uuid) CFRelease(uuid); return false; }

    // The display argument is not a filter — CGS returns every display, so we
    // iterate and match the identifier ourselves (first display is fallback).
    SpaceInfo result = none;
    CFIndex n = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(displays, i);
        if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
        SpaceInfo info = extract(d, globalActive);
        if (i == 0) result = info;
        if (!uuid) break;
        CFStringRef ident = (CFStringRef)CFDictionaryGetValue(d, CFSTR("Display Identifier"));
        if (ident && CFGetTypeID(ident) == CFStringGetTypeID() && CFEqual(ident, uuid)) {
            result = info;
            break;
        }
    }
    CFRelease(displays);
    if (uuid) CFRelease(uuid);
    *out = result;
    return result.ok;
}

void space_dump_all(void) {
    if (!cgs_ok()) { fprintf(stderr, "CGS symbols missing\n"); return; }
    CGSConnectionID c = CGSMainConnectionID();
    CGSSpaceID globalActive = CGSGetActiveSpace(c);
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(c, NULL);
    if (!displays) { printf("  (no displays)\n"); return; }
    CFIndex n = CFArrayGetCount(displays);
    printf("  CGS reports %ld managed display(s):\n", (long)n);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(displays, i);
        if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
        SpaceInfo info = extract(d, globalActive);
        printf("    [%ld] space %u/%u   display %s\n",
               (long)i, info.currentIndex + 1, info.spaceCount, info.displayID);
    }
    CFRelease(displays);
}

static void post_dock_swipe(int64_t phase, bool right, double velocity) {
    // ±FLT_TRUE_MIN progress is the empirical trick that skips the animation.
    double progress = right ?  (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;
    double vel      = right ?  velocity : -velocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return;
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

// began -> changed -> ended (all three needed for the switch to register).
static void one_switch(bool right, double velocity) {
    post_dock_swipe(kPhaseBegan,   right, velocity);
    post_dock_swipe(kPhaseChanged, right, velocity);
    post_dock_swipe(kPhaseEnded,   right, velocity);
}

void space_switch(bool right) { one_switch(right, kGestureVelocity); }

void space_switch_steps(bool right, unsigned int steps) {
    if (steps == 0) return;
    double velocity = kGestureVelocity * (double)steps;
    for (unsigned int i = 0; i < steps; i++) one_switch(right, velocity);
}

bool event_is_synthetic(CGEventRef event) {
    // Real trackpad events come from the HID system (pid 0); our posts don't.
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0;
}

bool dock_swipe_classify(CGEventRef event, DockSwipeEvent *out) {
    out->phase = DockSwipeNone;
    out->progress = 0;
    out->velocityX = 0;

    if (CGEventGetIntegerValueField(event, kCGSEventTypeField) != kCGSEventDockControl)
        return false;
    if (CGEventGetIntegerValueField(event, kCGEventGestureHIDType) != kIOHIDEventTypeDockSwipe)
        return false;
    if (CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion) != kMotionHorizontal)
        return false;

    int64_t phase = CGEventGetIntegerValueField(event, kCGEventGesturePhase);
    if (phase == kPhaseBegan)          out->phase = DockSwipeBegan;
    else if (phase == kPhaseChanged)   out->phase = DockSwipeChanged;
    else if (phase == kPhaseEnded)     out->phase = DockSwipeEnded;
    else if (phase == kPhaseCancelled) out->phase = DockSwipeCancelled;
    else return false;

    out->progress  = CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
    out->velocityX = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
    return true;
}

// --- Haptics ---------------------------------------------------------------
// MultitouchSupport is private; resolve at runtime via dlopen so a missing
// symbol degrades gracefully instead of failing to link/launch.

typedef CFTypeRef MTDeviceRef;
typedef CFTypeRef MTActuatorRef;

static void *g_actuators[8];
static int g_actuatorCount = 0;
static int (*p_MTActuatorActuate)(MTActuatorRef, int32_t, uint32_t, float, float) = NULL;

bool haptic_init(void) {
    if (g_actuatorCount > 0) return true;

    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return false;

    CFArrayRef (*createList)(void) = dlsym(h, "MTDeviceCreateList");
    int (*getDeviceID)(MTDeviceRef, uint64_t *) = dlsym(h, "MTDeviceGetDeviceID");
    MTActuatorRef (*createActuator)(uint64_t) = dlsym(h, "MTActuatorCreateFromDeviceID");
    int (*openActuator)(MTActuatorRef) = dlsym(h, "MTActuatorOpen");
    p_MTActuatorActuate = dlsym(h, "MTActuatorActuate");

    if (!createList || !getDeviceID || !createActuator || !openActuator || !p_MTActuatorActuate)
        return false;

    CFArrayRef list = createList();
    if (!list) return false;
    CFIndex n = CFArrayGetCount(list);
    // Open every device's actuator; firing on all means whichever trackpad the
    // fingers are on responds (built-in and/or external).
    for (CFIndex i = 0; i < n && g_actuatorCount < 8; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        uint64_t devID = 0;
        getDeviceID(dev, &devID);
        if (devID == 0) continue;
        MTActuatorRef act = createActuator(devID);
        if (!act) continue;
        if (openActuator(act) == 0) g_actuators[g_actuatorCount++] = (void *)act;
        else CFRelease(act);
    }
    CFRelease(list);
    return g_actuatorCount > 0;
}

void haptic_fire(int actuationID) {
    if (!p_MTActuatorActuate) return;
    for (int i = 0; i < g_actuatorCount; i++)
        p_MTActuatorActuate((MTActuatorRef)g_actuators[i], actuationID, 0, 0.0f, 0.0f);
}

void haptic_close(void) {
    for (int i = 0; i < g_actuatorCount; i++)
        if (g_actuators[i]) CFRelease(g_actuators[i]);
    g_actuatorCount = 0;
}
