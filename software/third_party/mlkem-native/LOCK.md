# mlkem-native dependency lock

This file is the controlled dependency record required by `FPST-SYS-SPEC-001 v1.1` for the SN32F407 ML-KEM-512 firmware path.

## Source lock

- Project: `pq-code-package/mlkem-native`
- Upstream: https://github.com/pq-code-package/mlkem-native
- Release tag: `v1.0.0`
- Resolved commit: `048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa`
- Parameter set: `ML-KEM-512`
- Public key bytes: `800`
- Secret key bytes: `1632`
- Ciphertext bytes: `768`
- Shared-secret bytes: `32`
- License expression used by upstream C sources: `Apache-2.0 OR ISC OR MIT`
- Local patches to upstream source: **none**

The upstream source is not silently copied or rewritten. A build that enables the dependency must point `FPST_MLKEM_NATIVE_ROOT` at a checkout whose HEAD is the exact commit above. Release tooling must reject any other revision.

## Build profile

The project uses the pinned upstream portable C primitives and public API for the ML-KEM-512 implementation baseline, with project-owned integration code only where the SN32F407F/Primer #1 deployment requires a hardware adapter or a bounded-memory execution schedule.

```text
MLK_CONFIG_PARAMETER_SET        = 512
MLK_CONFIG_NAMESPACE_PREFIX     = fpst_mlkem512_native
MLK_CONFIG_USE_NATIVE_BACKEND_ARITH = enabled
MLK_CONFIG_ARITH_BACKEND_FILE   = fpst_mlkem512_backend.h
```

Current qualified acceleration hook scope:

```text
forward NTT -> Kiwi Primer #1 BTP PQC path
```

The upstream C implementation remains authoritative for INTT, base multiplication, polynomial reduction/conversion, byte encoding, key generation and decapsulation. In particular, Primer #1 returns canonical standard-domain INTT output, while mlkem-native's `invntt_tomont` contract expects the Montgomery-scaled result. The INTT hook therefore stays disabled until the conversion is independently verified.

### SN32F407F low-RAM sender encapsulation schedule

The unmodified upstream `K-PKE.Encrypt` implementation materializes matrix/vector temporaries whose simultaneous polynomial storage alone exceeds the SN32F407F 8 KiB SRAM budget. The board sender therefore uses the project-owned `fpst_mlkem512_lowram.c` schedule for ML-KEM-512 encapsulation.

This is **not** a patch to the vendored upstream checkout and does not change the ML-KEM wire format or mathematics. It calls internal primitives from the exact pinned revision, processes matrix rows/error polynomials sequentially, and uses the same qualified Primer #1 forward-NTT hook. Its deterministic ciphertext and shared secret are required by CI to match an independent, unmodified pure-C instance of `mlkem-native v1.0.0` byte-for-byte.

The low-RAM schedule is locked to ML-KEM-512 (`K=2`) with compile-time assertions and a 3072-byte persistent KEM workspace. CI also runs a source-level SRAM preflight that reserves 2 KiB for target stack. This preflight is not a substitute for the final ARM Compiler 6 linker map and stack-high-water evidence.

Any change to this schedule, its upstream internal API use, or its RAM assumptions requires architecture review and rerunning the differential/KAT and SRAM gates.

## Acquisition / verification

Recommended checkout:

```bash
git clone https://github.com/pq-code-package/mlkem-native.git software/third_party/mlkem-native/src
git -C software/third_party/mlkem-native/src checkout 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
test "$(git -C software/third_party/mlkem-native/src rev-parse HEAD)" = "048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa"
```

Do not update this dependency without an architecture/change review and re-running the ML-KEM KAT/differential gates.
