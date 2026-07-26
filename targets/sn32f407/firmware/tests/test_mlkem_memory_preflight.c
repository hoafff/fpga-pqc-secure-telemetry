#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "fpst_entropy_rng.h"
#include "fpst_fpga_link.h"
#include "fpst_mlkem512_lowram.h"
#include "fpst_mlkem512_wrapper.h"
#include "fpst_pair_bridge.h"
#include "fpst_platform.h"
#include "fpst_session.h"
#include "fpst_telemetry.h"

/*
 * Source-level SRAM preflight for the 8 KiB SN32F407F target.
 *
 * This is deliberately NOT a linker-map or stack-high-water replacement.
 * Pointer/alignment sizes in the host build are normally >= the Cortex-M0
 * target for these control structs, so this gives a conservative regression
 * alarm for the dominant persistent allocations that the firmware owns.
 *
 * The final dual-Primer image uses TWO small platform descriptors but exactly
 * ONE fpst_fpga_link_t request/response buffer set. Accidentally allocating a
 * second link on the board would consume roughly another 1.3 KiB and must not
 * be hidden by this source-level budget.
 *
 * The Keil target still has to prove the final image with ARM Compiler 6.
 */
enum {
    SN32_SRAM_BYTES = 8192u,
    SN32_STACK_PREFLIGHT_RESERVE_BYTES = 2048u,
    SN32_MISC_STATIC_RESERVE_BYTES = 256u,
    EXPECTED_LOWRAM_KEM_WORKSPACE_BYTES = 3072u
};

/*
 * fpst_mlkem512_lowram.c is one translation unit: asking for its workspace size
 * also makes the linker retain its encapsulation routine and therefore the
 * pinned monolithic mlkem-native object. The real board callbacks live in
 * fpst_mlkem512_wrapper.c, but this size-only test must not pull the hardware
 * integration path merely to inspect static memory. These link-only traps make
 * any accidental crypto execution fail immediately while satisfying the two
 * callback symbols referenced by the pinned upstream object.
 */
void fpst_mlkem512_upstream_randombytes_forbidden(uint8_t *out, size_t len) {
    (void)out;
    (void)len;
    assert(!"memory preflight must not request random bytes");
}

void fpst_mlkem512_backend_ntt(int16_t data[256]) {
    (void)data;
    assert(!"memory preflight must not execute the NTT backend");
}

int main(void) {
    const size_t kem_workspace = fpst_mlkem512_lowram_workspace_bytes();

    /* Large and persistent objects that coexist during live encapsulation. */
    const size_t persistent_preflight =
        kem_workspace +
        (2u * sizeof(fpst_platform_t)) +
        sizeof(fpst_fpga_link_t) +
        sizeof(fpst_session_manager_t) +
        sizeof(fpst_pair_bridge_t) +
        sizeof(fpst_csprng_t) +
        sizeof(fpst_entropy_rng_t) +
        sizeof(fpst_telemetry_source_t) +
        FPST_MLKEM512_PUBLIC_KEY_BYTES +
        SN32_MISC_STATIC_RESERVE_BYTES;

    printf("SN32 dual SRAM preflight: kem=%zu link=%zu platforms=%zu bridge=%zu "
           "entropy=%zu persistent=%zu stack_reserve=%u total=%zu limit=%u\n",
           kem_workspace,
           sizeof(fpst_fpga_link_t),
           2u * sizeof(fpst_platform_t),
           sizeof(fpst_pair_bridge_t),
           sizeof(fpst_entropy_rng_t),
           persistent_preflight,
           SN32_STACK_PREFLIGHT_RESERVE_BYTES,
           persistent_preflight + SN32_STACK_PREFLIGHT_RESERVE_BYTES,
           SN32_SRAM_BYTES);

    assert(kem_workspace == EXPECTED_LOWRAM_KEM_WORKSPACE_BYTES);

    /* Keep 2 KiB unavailable to persistent state until target stack proof exists. */
    assert(persistent_preflight + SN32_STACK_PREFLIGHT_RESERVE_BYTES <=
           SN32_SRAM_BYTES);

    puts("PASS: SN32F407F dual-Primer ML-KEM SRAM source-level preflight");
    return 0;
}
