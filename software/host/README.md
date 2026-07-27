# FPST PC Host Deployment

`software/host/` contains the deployable PC-side control application for `FPST-SYS-SPEC-001 v1.1`.

## Hardware contract

```text
PC
  |
  | UART0 115200 8N1
  v
SONiX SN32F407F
  |
  | shared SPI0, direct FPST BTP v1
  | Mode 0 / MSB first
  | bring-up 1 MHz, Primer envelope <=5 MHz after qualification
  +---- Primer #1 TX/PQC
  +---- Primer #2 RX/verify
```

The PC never talks directly to Primer #1, Primer #2 or Tiny 1P5. SN32F407F remains the control/session owner and bridge.

## Final MCU command contract

The Python registry is intentionally locked to the final dual-Primer `fpst_sn32f407_dual_main.c` dispatcher.

Read-only commands:

```text
help
wiring
ping
ping2
discover
selftest
id
id2
status
status2
key-status
key-status2
pqc-status
rx-counters
adc
rng-status
fault
```

State-changing commands:

```text
rng-reseed
zeroize
telemetry
kem-session
```

`caps` and `reset` belonged to the earlier host adapter and are **not** commands in the final dual-Primer MCU CLI.

`kem-session` is special and must never be issued as a plain prompt-only command. The host sends:

```text
kem-session SSSSSSSS CCCCCCCC
```

where `S` is the non-zero 32-bit session ID and `C` is CRC-32/ISO-HDLC of the exact 800-byte ML-KEM-512 receiver public key. After `KEM_PK_READY`, the host streams exactly 1600 hex digits. It then validates the 768-byte public ciphertext length, CRC and exact `kem-pair-session=ACTIVE` acknowledgement before writing the ciphertext file.

## Package

Python 3.10+:

```text
fpst-host
```

Implemented host functions include serial-port enumeration, prompt-delimited commands, interactive ML-KEM session streaming, JSON output, secret-safe JSONL result logging, read-only RTT benchmark and hardware-independent unit tests.

## Install

Windows:

```powershell
cd software/host
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -e .
python -m unittest discover -s tests -v
```

Linux:

```bash
cd software/host
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -e .
python -m unittest discover -s tests -v
```

## Bring-up

List serial ports:

```bash
fpst-host ports
```

Electrical/status probe and final non-destructive demo:

```bash
fpst-host probe --port COM5
fpst-host demo  --port COM5
```

The demo sequence is frozen by FIX-008 acceptance as:

```text
wiring -> discover -> selftest -> status -> status2 -> rng-status
```

With `FPST_SN32F407_HARNESS_VERIFIED=0`, commands that require Primer traffic are expected to report `BLOCKED`; that is the correct Gate-A behavior, not a reason to bypass the firmware guard.

Representative individual diagnostics:

```bash
fpst-host wiring      --port COM5
fpst-host ping        --port COM5
fpst-host ping2       --port COM5
fpst-host status      --port COM5
fpst-host status2     --port COM5
fpst-host rx-counters --port COM5
fpst-host rng-status  --port COM5
```

State-changing operations require explicit confirmation:

```bash
fpst-host rng-reseed --port COM5 --yes
fpst-host telemetry  --port COM5 --yes
fpst-host zeroize    --port COM5 --yes
```

Pair-session provisioning:

```bash
fpst-host kem-session \
  --port COM5 \
  --public-key receiver_mlkem512_pk.bin \
  --session-id 0x10203040 \
  --ciphertext-out session.ct \
  --yes
```

On Linux replace `COM5` with the appropriate `/dev/ttyUSB*` or `/dev/ttyACM*` device.

## Benchmark and logging

Only read-only commands are eligible for benchmark mode:

```bash
fpst-host bench ping --port COM5 --count 100
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

The benchmark measures PC-observed command RTT, not FPGA cycle counts.

Never put ML-KEM private material, shared secrets, `K_TX`, `NP_TX`, seeds, passwords or tokens into CLI arguments or result logs. The public receiver key is read from a file and is not persisted in the normal result record; the public ciphertext is written only to the explicit `--ciphertext-out` path.

## Automated checks

```bash
cd software/host
python -m unittest discover -s tests -v
fpst-host --help
```

`.github/workflows/pc-host.yml` runs the host package on Python 3.10 and 3.12. Tests lock the final command registry, removed legacy commands, the six-command demo order and interactive ML-KEM framing/CRC/session validation.

## Hardware verification gate

The PC target is hardware-verified only after:

1. package/unit tests pass on the intended deployment PC;
2. the real SN32 serial port responds at 115200 8N1;
3. `wiring` reflects the measured harness state;
4. Gate-B demo passes on programmed dual-Primer hardware;
5. interactive `kem-session` completes against the actual MCU/Primers and returned ciphertext passes receiver-side use;
6. controlled reseed/telemetry/zeroize behavior is observed;
7. captured logs contain no secret material.

Host CI proves protocol/parser behavior only; it does not satisfy the vendor-build or physical-harness gates in Phase 5.
