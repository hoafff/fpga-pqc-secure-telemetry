# FPST PC Host Deployment

This directory contains the deployable PC-side control application for `FPST-SYS-SPEC-001 v1.1`.

## Current hardware contract

```text
PC
  |
  | UART0 115200 8N1
  v
SONiX SN32F407F
  |
  | SPI0 Mode 0, 3 MHz + sidebands
  v
Primer #1 / FPST hardware
```

The PC does not talk directly to a Primer or Tiny 1P5. The SN32F407F remains the control/security-session owner and bridge.

## What is deployable now

The host works with the line-oriented SN32 firmware already present in the repository:

```text
help
wiring
ping
caps
status
zeroize
reset
```

It provides:

- serial-port enumeration;
- robust prompt-delimited UART transactions;
- `wiring` / `ping` / `caps` / `status` commands;
- explicit confirmation for `zeroize` and `reset`;
- non-destructive bring-up sequence;
- repeated command latency benchmark;
- JSON output for automation;
- append-only JSONL result logging with obvious secret-bearing fields redacted;
- unit tests that do not require hardware.

The parser accepts future `key=value` status lines before the final `OK`/`ERR`, so SN32 can expose richer machine-readable status without breaking the host.

## Install

Python 3.10 or newer is required.

### Windows

```powershell
cd software/host
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -e .
python -m unittest discover -s tests -v
```

### Linux

```bash
cd software/host
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -e .
python -m unittest discover -s tests -v
```

## Find the board

```bash
fpst-host ports
```

Examples of port names:

```text
Windows: COM5
Linux:   /dev/ttyUSB0 or /dev/ttyACM0
```

## Bring-up

```bash
fpst-host probe --port COM5
fpst-host demo  --port COM5
```

`demo` is deliberately non-destructive and runs:

```text
wiring -> ping -> caps -> status
```

If the firmware still reports `wiring=UNVERIFIED`, SPI mailbox commands may intentionally fail or be blocked. This is expected until the physical MCU-Primer harness gate is closed.

## Individual commands

```bash
fpst-host ping   --port COM5
fpst-host caps   --port COM5
fpst-host status --port COM5
fpst-host wiring --port COM5
```

Machine-readable output:

```bash
fpst-host --json status --port COM5
```

## State-changing commands

The host refuses these unless the operator explicitly confirms them:

```bash
fpst-host zeroize --port COM5 --yes
fpst-host reset   --port COM5 --yes
```

Do not put key material, shared secrets, private seeds, passwords or tokens on the command line or into result logs.

## Benchmark

Example:

```bash
fpst-host bench ping --port COM5 --count 100
```

Reported metrics:

```text
count
success/failure count
min latency
mean latency
p50 latency
p95 latency
max latency
```

These are host-observed round-trip latencies, not FPGA cycle counts. Hardware cycle counters must be reported separately by the endpoint when that telemetry interface becomes available.

## Result logging

```bash
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
fpst-host bench ping --port COM5 --count 100 --log results/pc/ping.jsonl
```

The logger redacts fields whose names indicate key/secret/seed/private/password/token data. This is defense-in-depth only; secret material must never be intentionally passed to logging APIs.

## Current end-to-end boundary

The PC transport itself is now frozen to the verified SN32 UART profile. However, the current SN32 CLI only exposes the seven commands listed above. Therefore these higher-level capabilities remain gated by corresponding MCU/Primer implementation:

```text
ML-KEM session establishment UI
stage/commit context from PC
STP telemetry transmit command
RX authentication/replay display
plaintext/ciphertext/tag structured display
FPGA cycle-count and throughput telemetry
supervisor event stream
```

The host package is intentionally layered so those commands can be added in `fpst_host/protocol.py` without replacing the serial transport, logging, CLI shell or benchmark code.

## Acceptance gate

PC deployment is considered hardware-verified only after:

1. unit tests pass on the deployment PC;
2. the correct serial port is detected;
3. SN32 banner/CLI responds at 115200 8N1;
4. `wiring` reflects the actual harness state;
5. non-destructive `demo` passes on real hardware;
6. `zeroize` and `reset` are observed on hardware under controlled testing;
7. no secret material is present in captured logs;
8. later telemetry/session commands pass after their SN32/Primer owners are implemented.
