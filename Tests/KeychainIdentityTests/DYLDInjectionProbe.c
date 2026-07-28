#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor))
static void gatebeam_injection_probe_loaded(void) {
    const char *sentinel = getenv("GATEBEAM_DYLD_INJECTION_SENTINEL");
    if (sentinel == NULL || sentinel[0] == '\0') {
        return;
    }

    int descriptor = open(sentinel, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0) {
        return;
    }
    const char marker[] = "injected";
    (void)write(descriptor, marker, sizeof(marker) - 1);
    (void)close(descriptor);
}
