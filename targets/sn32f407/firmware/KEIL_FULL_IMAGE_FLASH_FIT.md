# SN32F407F full dual-Primer Flash-fit profile

This profile applies to the complete production image selected by
`KEIL_DUAL_PRIMER_BUILD.md`. It does not remove ML-KEM, either Primer endpoint,
session provisioning, telemetry, entropy conditioning, the host UART protocol,
or zeroization/recovery behavior.

## Root cause addressed

The failing ARM Compiler 6 image linked two independent Keccak-f1600/SHAKE256
implementations:

```text
fpst_sha3.o       -> keccakf1600.rc
mlkem_native.o    -> mlk_KeccakF_RoundConstants
```

When `FPST_MLKEM_NATIVE_ENABLED=1`, `fpst_sha3.c` now delegates SHAKE256 to the
already-linked, pinned mlkem-native FIPS-202 backend. Host-only/non-native builds
retain the standalone fallback implementation.

The pinned ML-KEM translation unit also receives ARMClang `minsize` attributes
through `fpst_mlkem512_config.h`. This is a code-generation policy only; it does
not change ML-KEM-512 parameters, arithmetic, API, wire format, randomness flow,
or the qualified Primer #1 forward-NTT hook.

## Required Keil settings

Use ARM Compiler 6 and set the production target as follows:

```text
Options for Target -> C/C++ (AC6)
  Optimization                  : -Oz
  One ELF Section per Function  : enabled
  Link-Time Optimization        : enabled

Options for Target -> Target
  IROM1 Start                   : 0x00000000
  IROM1 Size                    : 0x00008000
  IRAM1 Start                   : 0x20000000
  IRAM1 Size                    : 0x00002000

Options for Target -> Output
  Create HEX File               : enabled
```

Keep the production defines:

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE="fpst_mlkem512_config.h"
```

Set `FPST_SN32F407_HARNESS_VERIFIED` according to the physical acceptance gate;
it is not a Flash-size switch.

## Required source set

Keep the entire final source list from `KEIL_DUAL_PRIMER_BUILD.md`, including:

```text
fpst_sha3.c
fpst_kdf.c
fpst_transport.c
fpst_fpga_link.c
fpst_primer1.c
fpst_primer2.c
fpst_pair_bridge.c
fpst_session.c
fpst_csprng.c
fpst_entropy_rng.c
fpst_telemetry.c
fpst_mlkem512_lowram.c
fpst_mlkem512_wrapper.c
fpst_mlkem_session.c
fpst_sn32f407_port.c
fpst_sn32f407_multiport.c
fpst_sn32f407_dual_main.c
mlkem_native.c
```

Do not enlarge IROM beyond `0x8000`, do not remove production functionality, and
do not reduce the stack reservation merely to pass the linker.

## Clean rebuild and acceptance

After applying the branch:

1. Close uVision.
2. Delete the target's `Objects` and `Listings` output directories, or run
   `Project -> Clean Targets` followed by `Rebuild all target files`.
3. Confirm the compile command uses `-Oz` and LTO.
4. Retain the complete build log, `.map`, `.axf`, and `.hex`.
5. Accept only when the linker reports no `L6406E/L6407E`, Flash usage is at most
   `0x8000`, and static RAM plus verified worst-case stack is at most `0x2000`.
6. Run the existing host/firmware tests and then the full hardware sequence:
   discover, selftest, KEM pair-session establishment, both key-status checks,
   telemetry commit, receiver counters, retry, zeroize, fault, and recovery.

The vendor warning about an uninitialized `AHB_prescaler` in the organizer DFP's
`system_SN32F400.c` is independent of the Flash overflow. It must not be hidden
by increasing the memory region; treat any behavioral clock issue separately.
