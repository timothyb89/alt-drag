// alt-space spike — CLI over spacecore. Proves instant, SIP-free space
// switching by synthesizing a high-velocity native Dock swipe.
//
// Usage:
//   ./spaces info          print space state for cursor + menu-bar displays,
//                          plus raw state for every managed display
//   ./spaces left          instant switch one space left  (on the cursor display)
//   ./spaces right         instant switch one space right (on the cursor display)
//
// `left`/`right` re-query ~200ms later and print before/after, so you can see
// which display actually switched. Posting events needs Accessibility for the
// launching terminal; reading space state does not.

#include "spacecore.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void print_info(const char *label, SpaceTarget t) {
    SpaceInfo i;
    if (!space_info(t, &i)) { printf("  %-11s (unavailable)\n", label); return; }
    printf("  %-11s space %u/%u   display %s\n",
           label, i.currentIndex + 1, i.spaceCount, i.displayID);
}

static void dump_state(const char *when) {
    printf("%s\n", when);
    print_info("cursor:", SpaceTargetCursor);
    print_info("menu-bar:", SpaceTargetMenuBar);
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "info";

    if (strcmp(cmd, "info") == 0) {
        dump_state("state:");
        space_dump_all();
        return 0;
    }

    bool right;
    if (strcmp(cmd, "right") == 0)      right = true;
    else if (strcmp(cmd, "left") == 0)  right = false;
    else { fprintf(stderr, "usage: %s [info|left|right]\n", argv[0]); return 2; }

    SpaceInfo before;
    if (space_info(SpaceTargetCursor, &before)) {
        if (right && before.currentIndex + 1 >= before.spaceCount) {
            fprintf(stderr, "already on last space; not switching\n"); return 0;
        }
        if (!right && before.currentIndex == 0) {
            fprintf(stderr, "already on first space; not switching\n"); return 0;
        }
    }

    dump_state("before:");
    space_switch(right);
    usleep(200000);  // CGS's active-space report lags the switch
    dump_state("after:");
    return 0;
}
