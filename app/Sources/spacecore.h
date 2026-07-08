// spacecore — reusable core for instant space switching (SIP-free).
//
// Two capabilities, both proven in the `spaces` CLI spike:
//   * read per-display space count + current index (private read-only CGS)
//   * switch space instantly by synthesizing a high-velocity Dock swipe
//
// This is the split the real app will use: a small C core wrapped by Swift.
#ifndef SPACECORE_H
#define SPACECORE_H

#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

typedef enum {
    SpaceTargetCursor,   // the display under the mouse cursor
    SpaceTargetMenuBar,  // the display that currently owns the menu bar (focus)
} SpaceTarget;

typedef struct {
    unsigned int currentIndex; // zero-based index of the active space
    unsigned int spaceCount;   // number of user spaces on that display
    char displayID[128];       // display UUID string
    bool ok;                   // false if state was unavailable
} SpaceInfo;

// Fill `out` with the space state for the requested display. Returns out->ok.
bool space_info(SpaceTarget target, SpaceInfo *out);

// Print raw state for every managed display (debugging).
void space_dump_all(void);

// One instant switch in the given direction (no bounds check).
void space_switch(bool right);

// `steps` instant switches in the given direction, velocity-scaled so a
// multi-space jump still skips the animation. No bounds check.
void space_switch_steps(bool right, unsigned int steps);

// --- Trackpad swipe interception -------------------------------------------

typedef enum {
    DockSwipeNone = 0,
    DockSwipeBegan,
    DockSwipeChanged,
    DockSwipeEnded,
    DockSwipeCancelled,
} DockSwipePhase;

typedef struct {
    DockSwipePhase phase;
    double progress;   // signed swipe progress; sign gives direction
    double velocityX;  // signed fling velocity; sign gives direction
} DockSwipeEvent;

// True if the event was posted synthetically (e.g. our own space_switch), as
// opposed to a real HID trackpad event. Real trackpad events have pid 0.
bool event_is_synthetic(CGEventRef event);

// Classify a horizontal Dock-swipe (the "swipe between spaces" gesture) and
// fill `out`. Returns false for anything else (wrong event type, vertical
// motion, Mission Control, etc.) so the caller passes it through untouched.
bool dock_swipe_classify(CGEventRef event, DockSwipeEvent *out);

// --- Haptics (private MTActuator) ------------------------------------------
// Drives the Taptic Engine directly, including on external Magic Trackpads,
// with selectable actuation patterns (firmer than NSHapticFeedbackManager).

// Open actuators for all multitouch devices. Returns false if unavailable
// (symbols missing / no actuator) so the caller can fall back.
bool haptic_init(void);

// Fire one actuation on every open actuator. `actuationID` selects the pattern
// (known usable values: 1-6, 15, 16); feel varies and is undocumented.
void haptic_fire(int actuationID);

// Release actuators.
void haptic_close(void);

#endif // SPACECORE_H
