# Primer #1 Deployment Status

## Functional RTL

**Complete on `primer1-complete-pqc`.**

The release-oriented top is `kiwi_primer20k_fpst_tx_top` and includes:

- FPST BTP v1 over SPI mode 0 with CRC-32/ISO-HDLC;
- separate request/response CS transactions, IRQ and cached response retry;
- duplicate/collision protection across control and PQC endpoint routing;
- atomic K_TX/NP_TX stage/commit/activate/zeroize;
- complete polynomial primitive path `PQC_* 0x20..0x28` including NTT, INTT, MultiplyNTTs and add/sub;
- Ascon-AEAD128 encryption and STP v1 telemetry packet construction;
- retained 64-byte packet and commit-gated TX sequence advancement;
- synchronized/fail-safe Tiny supervisor inputs;
- 100 ms heartbeat generated from the 27 MHz board clock.

## Frozen build inputs

```text
Top        : kiwi_primer20k_fpst_tx_top
Device     : GW2A-LV18PG256C8/I7
Sources    : targets/primer20k_1/sources-fpst-deployment.f
CST        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
SDC        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

The `.cst` freezes the Primer J2 FPGA-side harness mapping. The `.sdc` constrains 27 MHz `sys_clk`, a 5 MHz SPI implementation envelope, and declares the two clock domains asynchronous.

## Host verification gates

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/sim/run_primer1_pqc_wire_test.sh
bash scripts/synth/check_kiwi_primer20k_fpst_deployment_yosys.sh
```

The final promotion commit must have a green GitHub Actions verification run: SystemVerilog unit/integration tests, complete PQC SPI wire regression, arithmetic/memory synthesis, NTT and Ascon board-top synthesis, and complete Primer #1 deployment-top Yosys synthesis all pass; the aggregate failure-report step must be skipped.

## Remaining before hardware-ready claim

These are evidence/board steps, not missing Primer #1 datapath code:

1. Wire the SN32/Tiny harness to the frozen J2 profile and continuity-check every signal/ground.
2. Run Gowin synthesis, place-and-route and timing for the exact `GW2A-LV18PG256C8/I7` target using the frozen CST/SDC.
3. Generate/program the `.fs` only after the vendor reports are clean.
4. Start BTP bring-up at 1 MHz SPI and capture SCK/MOSI/MISO/CS/IRQ with a logic analyzer.
5. Qualify retry, CRC fault, reset, zeroize, secure-disable and fatal behavior on real hardware.

Generic Yosys success is not a substitute for Gowin P&R/timing or real-board evidence.
