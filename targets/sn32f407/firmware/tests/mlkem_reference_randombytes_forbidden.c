#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/*
 * The differential test calls only *_derand entry points.  The monolithic
 * upstream object nevertheless contains convenience APIs that reference the
 * conventional randombytes symbol.  Resolve that link dependency with a hard
 * test failure so an accidental implicit-randomness call can never pass CI.
 */
void randombytes(uint8_t *out, size_t len) {
    (void)out;
    (void)len;
    abort();
}
