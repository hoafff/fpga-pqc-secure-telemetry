# Target: PC / Host / Verification

## 1. Vai trò

PC không nhận bitstream hoặc MCU firmware. PC chạy chương trình điều khiển demo, verification/golden tools và thu kết quả.

```text
PC host
   |
   | UART0 115200 8N1
   v
SONiX SN32F407F
   |
   +--> session/control
   +--> Primer #1 over SPI mailbox
   +--> telemetry/status forwarding
```

PC không được giả định giao tiếp trực tiếp với Primer #1, Primer #2 hoặc Tiny 1P5.

## 2. Trạng thái deployment

```text
CURRENT / IMPLEMENTED:
  Python 3.10+ host package
  pyserial UART transport
  port enumeration
  SN32 CLI protocol adapter
  wiring/ping/caps/status
  guarded zeroize/reset
  non-destructive bring-up demo
  host RTT benchmark
  JSON output
  secret-safe JSONL result logger
  hardware-independent unit tests

CURRENT SN32 HOST CONTRACT:
  UART0 115200 8N1
  text CLI commands:
    help wiring ping caps status zeroize reset

GATED BY LATER MCU/PRIMER WORK:
  ML-KEM session command flow from PC
  STP telemetry TX/RX commands
  structured plaintext/ciphertext/tag reporting
  authentication/replay result stream
  endpoint cycle counters / throughput metrics
  supervisor event stream
```

The earlier `PC <-> SN32 likely USB/UART, final contract TBD` statement is obsolete. The organizer-backed SN32 implementation profile has now frozen the host link to UART0 115200 8N1.

## 3. Code location

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
    ├── test_protocol.py
    └── test_benchmark.py
```

Golden/reference code remains under:

```text
software/reference/
```

Do not merge the golden implementation into the production host transport/protocol layer.

## 4. Install

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

## 5. Hardware bring-up commands

List ports:

```bash
fpst-host ports
```

Probe the SN32 path:

```bash
fpst-host probe --port COM5
```

Run the non-destructive demo:

```bash
fpst-host demo --port COM5
```

Individual commands:

```bash
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

Linux example replaces `COM5` with `/dev/ttyUSB0` or `/dev/ttyACM0` as appropriate.

## 6. Benchmark/result collection

```bash
fpst-host bench ping --port COM5 --count 100
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

The current benchmark is PC-observed command round-trip latency. FPGA cycle count and datapath throughput remain separate endpoint metrics and must not be inferred from host RTT.

Result logs must never contain secret key material, ML-KEM shared secrets, private seeds or credentials. The host logger performs name-based redaction as defense-in-depth, but producers remain responsible for never supplying secret values to logging code.

## 7. Golden/reference responsibilities

- NTT/INTT output oracle.
- Ascon-AEAD128 byte-for-byte oracle.
- ML-KEM/KDF test vector support.
- STP packet encode/decode model.
- Deterministic seeds/vectors for reproducible failures.

Golden models must remain independent enough to expose RTL/firmware byte-order or algorithm bugs instead of reproducing them.

## 8. Verification matrix

```text
Unit:
  host protocol parser
  benchmark statistics
  secret-safe logging
  arithmetic / crypto reference components

Integration:
  PC -> SN32 UART command path
  SN32 -> Primer mailbox path
  session/key loading
  STP TX -> RX
  supervisor response

Negative:
  missing/incorrect serial port
  UART timeout
  malformed/unknown response
  wiring unverified
  endpoint timeout
  reset
  zeroize
  authentication failure
  replay
```

## 9. Definition of done

The PC target is source-complete for the currently exposed SN32 CLI when:

- package installs on the deployment PC;
- unit tests pass;
- serial port enumeration works;
- SN32 UART responds at 115200 8N1;
- `probe`/`demo` execute against the real board;
- destructive actions require explicit operator confirmation;
- logs contain no secret material.

The **full FPST host feature set** is only end-to-end complete when the still-open ML-KEM/STP/telemetry commands are implemented by their MCU/FPGA owners and then added to `fpst_host/protocol.py`.

See [`software/host/README.md`](../../software/host/README.md) for deployment instructions.
