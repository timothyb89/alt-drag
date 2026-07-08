// haptictest — fire each known MTActuator actuation pattern so you can feel
// which is strongest / best for a per-space detent. Rest a couple fingers on
// the trackpad while it runs. Each ID is fired 3 times with a pause between.
//
// Usage:
//   ./haptictest           cycle through all known IDs
//   ./haptictest 6         fire only actuationID 6 (repeatedly)

#include "spacecore.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (!haptic_init()) {
        fprintf(stderr, "no MTActuator available (symbols missing or no device)\n");
        return 1;
    }

    if (argc > 1) {
        int id = atoi(argv[1]);
        printf("firing actuationID %d every 400ms (Ctrl+C to stop)\n", id);
        for (;;) { haptic_fire(id); usleep(400000); }
    }

    const int ids[] = {1, 2, 3, 4, 5, 6, 15, 16};
    printf("rest fingers on the trackpad...\n");
    sleep(2);
    for (int i = 0; i < (int)(sizeof(ids) / sizeof(ids[0])); i++) {
        printf("actuationID %d\n", ids[i]);
        fflush(stdout);
        for (int r = 0; r < 3; r++) { haptic_fire(ids[i]); usleep(180000); }
        usleep(1200000);
    }
    haptic_close();
    return 0;
}
