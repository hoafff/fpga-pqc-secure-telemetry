#include <assert.h>
#include <stddef.h>
#include <stdio.h>

#include "fpst_entropy_rng.h"
#include "fpst_fpga_link.h"
#include "fpst_mlkem512_lowram.h"
#include "fpst_mlkem512_wrapper.h"
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
 * The Keil target still has to prove the final image with ARM Compiler 6.
 */
enum {
    SN32_SRAM_BYTES = 8192u,
    SN32_STACK_PREFLIGHT_RESERVE_BYTES = 2048u,
    SN32_MISC_STATIC_RESERVE_BYTES = 256u,
    EXPECTED_LOWRAM_KEM_WORKSPACE_BYTES = 3072u
};

int main(void) {
    const size_t kem_workspace = fpst_mlkem512_lowram_workspace_bytes();

    /* Large and persistent objects that coexist during live encapsulation. */
    const size_t persistent_preflight =
        kem_workspace +
        sizeof(fpst_platform_t) +
        sizeof(fpst_fpga_link_t) +
        sizeof(fpst_session_manager_t) +
        sizeof(fpst_csprng_t) +
        sizeof(fpst_entropy_rng_t) +
        sizeof(fpst_telemetry_source_t) +
        FPST_MLKEM512_PUBLIC_KEY_BYTES +
        SN32_MISC_STATIC_RESERVE_BYTES;

    printf("SN32 SRAM preflight: kem=%zu link=%zu entropy=%zu persistent=%zu "
           "stack_reserve=%u total=%zu limit=%u\n",
           kem_workspace,
           sizeof(fpst_fpga_link_t),
           sizeof(fpst_entropy_rng_t),
           persistent_preflight,
           SN32_STACK_PREFLIGHT_RESERVE_BYTES,
           persistent_preflight + SN32_STACK_PREFLIGHT_RESERVE_BYTES,
           SN32_SRAM_BYTES);

    /* Algorithm/schedule regression: this must not silently grow. */
    assert(kem_workspace == EXPECTED_LOWRAM_KEM_WORKSPACE_BYTES);

    /* Keep 2 KiB unavailable to persistent state until target stack proof exists. */
    assert(persistent_preflight + SN32_STACK_PREFLIGHT_RESERVE_BYTES <=
           SN32_SRAM_BYTES);

    puts("PASS: SN32F407F ML-KEM SRAM source-level preflight");
    return 0;
}
