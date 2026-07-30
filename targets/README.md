# Deployment Targets

Thư mục này là điểm vào để xác định **code nào dùng cho thiết bị nào**, **build bằng công cụ nào** và **artifact nào cần nạp/chạy**.

## Target index

| Target | Thiết bị | Vai trò | Trạng thái hiện tại |
|---|---|---|---|
| [`primer20k_1`](primer20k_1/README.md) | Kiwi Primer 20K #1 | NTT/INTT, Ascon encrypt, STP TX | Code/RTL integration complete + CI/generic synth PASS; chờ exact Gowin build và hardware evidence |
| [`primer20k_2`](primer20k_2/README.md) | Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay/auth | Code/RTL integration complete + CI/generic synth PASS; chờ exact Gowin build và hardware evidence |
| [`tiny1p5`](tiny1p5/README.md) | Kiwi FPGA Tiny 1P5 | Hardware safety supervisor cho hai Primer trong MVP | RTL/CST/SDC/integration tests complete; chờ exact Gowin build và physical evidence |
| [`sn32f407`](sn32f407/README.md) | SONiX SN32F407F EVK | Control/session firmware + PC↔dual-Primer bridge | Final dual-Primer firmware/host regressions complete; chờ ARM Compiler 6 `.map/.hex` và hardware evidence |
| [`pc`](pc/README.md) | Laptop/PC | UART host, session provisioning, logs, benchmark | Final Python host matches dual-MCU CLI; Python 3.10/3.12 CI PASS; chờ UART/end-to-end hardware run |

## Artifact map

```text
Primer 20K #1  <- Gowin .fs
Primer 20K #2  <- Gowin .fs
Tiny 1P5       <- Gowin .fs
SN32F407F      <- ARM Compiler/Keil .hex
PC             <- Python fpst-host package/tools
```

## MVP Policy B

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software session/CSPRNG/transient-state hygiene
```

Tiny `SYSTEM_RESET_N` is not connected to SN32 in the MVP and is not an MVP release blocker. A future asynchronous MCU-containment path requires a separate architecture decision plus schematic/electrical evidence.

## Layout rule

```text
targets/<target>/
├── README.md       role, top, build, programming and status
├── sources.f       FPGA source manifest when applicable
├── constraints/    target-specific constraints
├── rtl/            target top/wrapper only
├── firmware/       MCU target only
└── scripts/        target build/program helpers
```

Reusable NTT, Ascon, telemetry, supervisor and transport logic remains under `rtl/`; targets reference shared cores rather than copying them.

## Evidence/authority rule

When a target document disagrees with another source, use this order:

1. real hardware / schematic / pinout / electrical constraints;
2. official organizer/manufacturer board documentation and SDK;
3. current RTL/firmware/CST/SDC plus executable-test behavior;
4. project integration decisions/deployment profiles;
5. `FPST-SYS-SPEC-001 v1.1` as reference baseline;
6. Git history.

Do not invent a pin/protocol/electrical behavior to satisfy a lower-authority or historical document.

## Hardware-ready boundary

A target being code-complete does not mean it is hardware-qualified. Exact vendor builds and physical evidence are tracked in `docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`.
