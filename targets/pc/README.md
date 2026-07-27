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

Implemented on the repair branch:

```text
Python 3.10+ host package
pyserial UART transport
serial-port enumeration
final dual-Primer SN32 command registry
non-destructive probe/demo
interactive ML-KEM-512 public-key/ciphertext session exchange
explicit confirmation for state-changing commands
JSON output
secret-redacted JSONL logging
read-only command RTT benchmark
hardware-independent unit tests
```

The final MCU commands are:

```text
read-only:
  help wiring ping ping2 discover selftest id id2 status status2
  key-status key-status2 pqc-status rx-counters adc rng-status fault

state-changing:
  rng-reseed zeroize telemetry kem-session
```

`caps` and `reset` are not present in the final dual-Primer dispatcher and have been removed from the PC adapter.

## 3. Code locations

```text
software/host/
├── pyproject.toml
├── README.md
├── fpst_host/
│   ├── models.py
│   ├── transport.py
│   ├── protocol.py
│   ├── benchmark.py
│   ├── result_log.py
│   └── cli.py
└── tests/
```

Golden/reference models remain under `software/reference/`. Do not merge reference implementations into production transport logic; independent models are required to catch byte-order and algorithm mistakes.

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
```

FIX-008 freezes the demo order to:

```text
wiring -> discover -> selftest -> status -> status2 -> rng-status
```

Representative diagnostics:

```bash
fpst-host ping        --port COM5
fpst-host ping2       --port COM5
fpst-host key-status  --port COM5
fpst-host key-status2 --port COM5
fpst-host rx-counters --port COM5
```

State-changing operations require confirmation:

```bash
fpst-host rng-reseed --port COM5 --yes
fpst-host telemetry  --port COM5 --yes
fpst-host zeroize    --port COM5 --yes
```

ML-KEM pair session uses the dedicated streaming path:

```bash
fpst-host kem-session \
  --port COM5 \
  --public-key receiver_mlkem512_pk.bin \
  --session-id 0x10203040 \
  --ciphertext-out session.ct \
  --yes
```

The host waits for `KEM_PK_READY`, streams exactly 800 public-key bytes as 1600 hex digits, validates the 768-byte ciphertext CRC and requires `kem-pair-session=ACTIVE` before accepting the result.

## 6. Benchmark and results

```bash
fpst-host bench ping --port COM5 --count 100
fpst-host demo --port COM5 --log results/pc/bringup.jsonl
```

Host RTT is not an FPGA cycle-count measurement. Endpoint cycle/throughput metrics must be reported independently by firmware/RTL instrumentation.

Never log private keys, ML-KEM shared secrets, `K_TX`, `NP_TX`, private seeds, passwords or tokens.

## 7. Verification responsibilities

Golden/reference responsibilities include NTT/INTT, Ascon-AEAD128, ML-KEM/KDF, STP encode/decode and deterministic negative/retry/replay cases.

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

The PC target is not hardware-verified until the package runs on the intended deployment PC, the real SN32 UART responds at 115200 8N1, Gate-B dual-Primer demo passes, interactive `kem-session` is validated against real hardware, controlled state-changing operations are observed, and captured logs are checked for accidental secret exposure.

See `../../software/host/README.md` for the host application guide and `../sn32f407/README.md` for the board-side contract.
