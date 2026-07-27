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

## Package

Python 3.10+:

```text
fpst-host
```

Implemented host functions include:

- serial-port enumeration through `pyserial`;
- prompt-delimited UART transport;
- parser for the line-oriented SN32 CLI;
- `wiring`, `ping`, `caps`, `status` and non-destructive bring-up flows;
- guarded `zeroize` / `reset` operations requiring explicit confirmation;
- JSON output for automation;
- append-only JSONL result logging with secret-field redaction;
- command round-trip benchmark;
- hardware-independent unit tests.

The consolidated SN32 firmware on `main` exposes richer ML-KEM/session/telemetry diagnostics than the current Python adapter. Those commands can be added to `fpst_host/protocol.py` without replacing serial transport, logging or benchmark code.

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

Non-destructive board probe/demo:

```bash
fpst-host probe --port COM5
fpst-host demo  --port COM5
```

Individual commands:

```bash
fpst-host wiring --port COM5
fpst-host ping   --port COM5
fpst-host caps   --port COM5
fpst-host status --port COM5
```

State-changing operations require confirmation:

```bash
fpst-host zeroize --port COM5 --yes
fpst-host reset   --port COM5 --yes
```

On Linux replace `COM5` with the appropriate `/dev/ttyUSB*` or `/dev/ttyACM*` device.

## Benchmark and logging

```bash
fpst-host bench ping --port COM5 --count 100
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

The benchmark measures PC-observed command RTT, not FPGA cycle counts.

Never put ML-KEM private material, shared secrets, `K_TX`, `NP_TX`, seeds, passwords or tokens into CLI arguments or result logs. Name-based log redaction is defense-in-depth only.

## Automated checks

```bash
cd software/host
python -m unittest discover -s tests -v
fpst-host --help
```

GitHub Actions runs the host package on supported Python versions through `.github/workflows/pc-host.yml`.

## Hardware verification gate

The PC target is hardware-verified only after:

1. package/unit tests pass on the intended deployment PC;
2. the real SN32 serial port is detected and UART responds at 115200 8N1;
3. `wiring` reflects the measured harness state;
4. non-destructive probe/demo pass on programmed hardware;
5. controlled zeroize/reset behavior is observed where supported by the supervisor topology;
6. captured logs contain no secret material;
7. any added ML-KEM/STP host commands pass against the final dual-Primer firmware and boards.
