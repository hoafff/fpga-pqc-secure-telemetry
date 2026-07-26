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

The project uses the upstream portable C frontend for FIPS 203 encoding/control and the project-owned arithmetic backend interface only where an FPGA hook has been qualified.

```text
MLK_CONFIG_PARAMETER_SET        = 512
MLK_CONFIG_NAMESPACE_PREFIX     = fpst_mlkem512_native
MLK_CONFIG_USE_NATIVE_BACKEND_ARITH = enabled
MLK_CONFIG_ARITH_BACKEND_FILE   = fpst_mlkem512_backend.h
```

Current qualified hook scope:

```text
forward NTT -> Kiwi Primer #1 BTP PQC path
```

The upstream C implementation remains authoritative for INTT, base multiplication, polynomial reduction/conversion, byte encoding and all KEM control until the corresponding FPGA adapter passes differential/KAT verification.

In particular, Primer #1 returns canonical standard-domain INTT output, while mlkem-native's `invntt_tomont` contract expects the Montgomery-scaled result. The INTT hook therefore stays disabled until the conversion is independently verified.

## Acquisition / verification

Recommended checkout:

```bash
git clone https://github.com/pq-code-package/mlkem-native.git software/third_party/mlkem-native/src
git -C software/third_party/mlkem-native/src checkout 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
test "$(git -C software/third_party/mlkem-native/src rev-parse HEAD)" = "048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa"
```

Do not update this dependency without an architecture/change review and re-running the ML-KEM KAT/differential gates.