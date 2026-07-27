# Target: PC / Host / Verification

## 1. Vai trò

PC chạy ứng dụng điều khiển/bring-up, logging, benchmark và golden/reference tools. PC không nhận FPGA bitstream hay MCU firmware.

```text
PC host
   |
   | UART0 115200 8N1
   v
SONiX SN32F407F
   |
   | direct FPST BTP v1 over shared SPI0
   +--> Primer #1 TX/PQC
   +--> Primer #2 RX/verify

Tiny 1P5 supervises the hardware path independently.
```

PC không giao tiếp trực tiếp với Primer #1, Primer #2 hoặc Tiny 1P5.

## 2. Deployment status

Implemented on `main`:

```text
Python 3.10+ host package
pyserial UART transport
serial-port enumeration
SN32 CLI protocol adapter
wiring/ping/caps/status
non-destructive probe/demo
explicit confirmation for zeroize/reset
JSON output
secret-redacted JSONL logging
command RTT benchmark
hardware-independent unit tests
```

The final SN32 firmware now has richer ML-KEM/session/telemetry/dual-Primer commands. The Python adapter currently exposes the bring-up subset above; extending the adapter does not require changing its serial transport architecture.

## 3. Code locations

Deployment host:

```text
software/host/
├── pyproject.toml
├── README.md
├── fpst_host/
│   ├── __init__.py
│   ├── models.py
│   ├── transport.py
│   ├── protocol.py
│   ├── benchmark.py
│   ├── result_log.py
│   └── cli.py
└── tests/
```

Golden/reference models remain under:

```text
software/reference/
```

Do not merge reference/golden implementations into production transport logic; independent models are required to catch byte-order and algorithm mistakes.

## 4. Install and test

Windows:

```powershell
cd software/host
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
python -m unittest discover -s tests -v
```

Linux:

```bash
cd software/host
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python -m unittest discover -s tests -v
```

## 5. Bring-up commands

```bash
fpst-host ports
fpst-host probe --port COM5
fpst-host demo  --port COM5

fpst-host wiring --port COM5
fpst-host ping   --port COM5
fpst-host caps   --port COM5
fpst-host status --port COM5
```

State-changing operations require explicit confirmation:

```bash
fpst-host zeroize --port COM5 --yes
fpst-host reset   --port COM5 --yes
```

Use the actual `/dev/ttyUSB*` or `/dev/ttyACM*` port on Linux.

## 6. Benchmark and results

```bash
fpst-host bench ping --port COM5 --count 100
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

Host RTT is not an FPGA cycle-count measurement. Endpoint cycle/throughput metrics must be reported independently by firmware/RTL instrumentation.

Never log private keys, ML-KEM shared secrets, `K_TX`, `NP_TX`, private seeds, passwords or tokens.

## 7. Verification responsibilities

Golden/reference responsibilities include:

- NTT/INTT oracle;
- Ascon-AEAD128 encryption/decryption/tag oracle;
- ML-KEM/KDF differential vectors;
- STP packet encode/decode behavior;
- deterministic negative/retry/replay cases.

Integration verification eventually covers:

```text
PC -> SN32 UART
SN32 -> Primer #1/#2 shared SPI BTP
ML-KEM pair session provisioning
Primer #1 STP TX -> Primer #2 STP RX
retry/replay/commit reconciliation
Tiny supervisor fault/zeroize/recovery
```

## 8. Hardware qualification

The PC target is not hardware-verified until the package runs on the intended deployment PC, the real SN32 serial port is identified, UART bring-up succeeds, controlled state-changing operations are observed on hardware, and the captured logs are checked for accidental secret exposure.

See [`../../software/host/README.md`](../../software/host/README.md) for the host application guide and [`../sn32f407/README.md`](../sn32f407/README.md) for the board-side contract.
