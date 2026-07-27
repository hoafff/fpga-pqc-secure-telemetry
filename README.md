# FPGA PQC Secure Telemetry

Hệ thống telemetry an toàn nhiều thiết bị dùng ML-KEM-512, FPGA PQC/NTT, Ascon-AEAD128, STP secure telemetry, Tiny 1P5 supervisor và SONiX SN32F407F control/session node.

> `main` là **integration baseline hiện hành**. Khi một thay đổi đã merge vào `main`, branch/PR cũ chỉ còn giá trị lịch sử. Trạng thái `main` có thể là code-complete nhưng vẫn chưa hardware-qualified; exact vendor build và đo mạch được theo dõi riêng trong sign-off checklist.

## 0. Source-of-truth hierarchy

Khi tài liệu hoặc source bất đồng, dùng thứ tự sau:

1. **phần cứng thật, schematic, pinout và electrical constraints**;
2. **tài liệu chính thức của ban tổ chức / nhà sản xuất board / SDK**;
3. **RTL, firmware, CST, SDC hiện hành và behavior đã được executable test xác nhận**;
4. **quyết định integration của project** trong decision register/deployment profiles;
5. **`FPST-SYS-SPEC-001 v1.1` chỉ là reference baseline**;
6. archive/legacy chỉ dùng để truy vết lịch sử, không dùng để build/deploy.

Nếu source/constraint/profile mâu thuẫn với nguồn có thẩm quyền cao hơn: **STOP**, không tự đổi pin hoặc dây để khớp một file cũ.

## 1. Deployment map

| Target | Vai trò | Artifact |
|---|---|---|
| Kiwi Primer 20K #1 | PQC/NTT/INTT, Ascon encrypt, STP TX | Gowin `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay/auth handling | Gowin `.fs` |
| Kiwi Tiny 1P5 | Hardware safety supervisor cho hai Primer trong MVP | Gowin `.fs` |
| SONiX SN32F407F EVK | ML-KEM/KDF/session control, dual-Primer SPI bridge, telemetry | `.hex`/`.bin` |
| PC | UART host, bring-up, logs, benchmark | Python package/tools |

Chi tiết target/build: [`targets/`](targets/README.md).

## 2. Current MVP topology

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |
   | shared SPI0: Mode 0, MSB-first
   | project bring-up: 1 MHz
   | measured qualification only: 1 -> 2 -> 3 -> 4 -> 5 MHz
   |
   +---- CS1/IRQ1 ----> Primer #1 TX/PQC
   |
   +---- CS2/IRQ2 ----> Primer #2 RX/verify

Heartbeat/liveness:
  SN32 ----------------------> Tiny
  Primer #1 -----------------> Tiny
  Primer #2 -----------------> Tiny

Project local crypto fault:
  Primer #2 J2-12/T13 -------> Tiny J1-11/pin15
  [project-assigned route; physical continuity/levels still require measurement]

Tiny hardware controls in MVP:
  Tiny SECURE_ENABLE --------> Primer #1 + Primer #2
  Tiny ZEROIZE_N ------------> Primer #1 + Primer #2
  Tiny FAULT_LATCH ----------> Primer #1 + Primer #2

Tiny SYSTEM_RESET_N ---------> NOT CONNECTED TO SN32 IN MVP POLICY B
```

### MVP Policy B security boundary

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software session/CSPRNG/transient-secret hygiene
```

A dedicated Tiny→SN32 hardware reset/zeroize path is **optional future hardening**, not an MVP requirement. The project does not claim asynchronous hardware containment of MCU-resident state if SN32 itself is wedged/compromised.

## 3. Current code status

### Primer #1

Code/RTL is complete for the current MVP integration and repository regression covers:

- direct BTP v1 + CRC-32/ISO-HDLC;
- duplicate-safe response cache/retry;
- PQC command path, NTT/INTT/MultiplyNTTs/add-sub;
- atomic key/session context;
- Ascon-AEAD128 encrypt + STP TX;
- retained encrypted packet and commit-gated sequence;
- heartbeat liveness behavior through secure-disable/zeroize/fatal;
- generic deployment synthesis.

Next gate: exact Gowin build for `GW2A-LV18PG256C8/I7` and generated `.fs`.

### Primer #2

Code/RTL is complete for the current MVP integration and covers:

- Ascon authenticated decrypt + quarantine;
- replay/gap/session checks;
- auth-failure counters and threshold fault;
- local `auth_threshold_fault` exported on J2-12/T13;
- heartbeat remains liveness-only after crypto fault/zeroize;
- BTP endpoint/shared-MISO behavior;
- P1→P2 cross-endpoint regression and deployment synthesis.

Tiny J1-11/pin15 is confirmed as usable General I/O. The actual P2 J2-12→Tiny J1-11 jumper remains **PHYSICAL-PENDING** until continuity/electrical measurement.

### Tiny 1P5

Current supervisor package includes:

- three heartbeat watchdogs;
- tamper/manual/P2-local-crypto-fault arbitration;
- startup/qualification/monitor/zeroize/safe-lock/recovery FSM;
- zeroize-before-local-reset-output ordering;
- blocked clear while cause remains active;
- integrated Tiny + P1 + P2 security-plane regression.

The current nominal `100 ms` heartbeat, `350 ms` watchdog and `0x0608 ERR_AUTH_THRESHOLD` are **project profile/error values adopted from the FPST reference baseline**, not manufacturer electrical requirements.

Next gate: exact Gowin build for `GW1N-UV1P5QN48XC7/I6` and generated `.fs`.

### SN32F407F

Final dual-Primer firmware includes:

- direct BTP v1 master and bounded duplicate-safe retry;
- shared SPI link with separate P1/P2 CS/IRQ;
- pinned `mlkem-native v1.0.0` ML-KEM-512 integration;
- low-RAM ML-KEM schedule for the 8 KiB device;
- SHAKE256/KDF and atomic pair-session provisioning;
- conditioned ADC entropy/CSPRNG path;
- telemetry bridge/commit reconciliation;
- UART diagnostics and independent MCU heartbeat;
- software zeroize/session/CSPRNG-state hygiene required by Policy B.

Current EVK routes include UART0 J10 `P3.1/P3.2` and shared SPI0 `P1.0/P1.1/P1.2`.

Next gate: exact ARM Compiler 6 build, `.map`/stack review and generated `.hex`.

### PC host

`software/host/` now matches the final dual-MCU dispatcher rather than the old `caps/reset` adapter.

Read-only commands include:

```text
help wiring ping ping2 discover selftest id id2 status status2
key-status key-status2 pqc-status rx-counters adc rng-status fault
```

State-changing commands:

```text
rng-reseed zeroize telemetry kem-session
```

`kem-session` uses the dedicated interactive ML-KEM public-key/ciphertext flow. The non-destructive demo is:

```text
wiring -> discover -> selftest -> status -> status2 -> rng-status
```

Python 3.10/3.12 CI covers the host package.

## 4. Legacy transport policy

The old A1/A2 memory-mailbox + CRC-16 + old 3 MHz bring-up profile is **not part of deployment**.

- current-path tombstone: `docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md`;
- archived documentation: `docs/archive/pre-btp-direct/`;
- archived firmware helpers: `targets/sn32f407/firmware/legacy/pre-btp-direct/`.

Do not add archive/legacy sources back to a production target merely to match historical material.

## 5. What remains before programming/hardware qualification

Code integration is ready for exact vendor builds. Hardware qualification still requires:

1. Primer #1 Gowin synthesis/P&R/timing + `.fs`;
2. Primer #2 Gowin synthesis/P&R/timing + `.fs`;
3. Tiny Gowin synthesis/P&R/timing/utilization + `.fs`;
4. SN32 ARM Compiler 6 build + `.map`/Flash/RAM/stack evidence + `.hex`;
5. Gate-A continuity/common-ground/no-contention/fail-safe checks;
6. Gate-B SPI Mode 0 at 1 MHz, then measured 1→2→3→4→5 MHz qualification;
7. program all four devices and run end-to-end session/telemetry/retry/replay/bad-tag/zeroize/fault/recovery tests.

Controlled evidence checklist:

- [`docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`](docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md)

CI/generic Yosys is functional evidence; it does **not** substitute for exact-device vendor reports or measurements.

## 6. Repository structure

```text
targets/                       device-specific deployment entry points
rtl/                           reusable RTL cores
tb/                            unit/integration testbenches
software/reference/            independent golden/reference models
software/host/                 PC deployment application
software/third_party/          pinned dependency metadata
constraints/                   FPGA constraints
docs/                          architecture/interface/decision/evidence records
scripts/                       simulation/synthesis helpers
results/                       generated verification/benchmark results
```

Rules:

1. reusable algorithms live once under `rtl/`;
2. each hardware target owns its top/source manifest/constraint/build instructions under `targets/<target>/`;
3. testbench/reference code is not deployment RTL;
4. interface changes update both endpoints and the decision register together;
5. third-party crypto revisions remain explicitly pinned;
6. archived material never overrides a maintained deployment profile.

## 7. Maintained deployment entry points

- Primer #1: [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md)
- Primer #2: [`targets/primer20k_2/README.md`](targets/primer20k_2/README.md)
- SN32F407F: [`targets/sn32f407/README.md`](targets/sn32f407/README.md)
- SN32 dual-Primer Keil profile: [`targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`](targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md)
- Tiny 1P5: [`targets/tiny1p5/README.md`](targets/tiny1p5/README.md)
- PC: [`targets/pc/README.md`](targets/pc/README.md)
- Primer #1 deployment profile: [`docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`](docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md)
- Integration decisions: [`docs/spec-delta/FPST-v1.1-implementation-decisions.md`](docs/spec-delta/FPST-v1.1-implementation-decisions.md)
- Wiring guide: [`docs/hardware/FPST-WIRING-GUIDE-v1.1.md`](docs/hardware/FPST-WIRING-GUIDE-v1.1.md)
- Pre-hardware sign-off: [`docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`](docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md)
