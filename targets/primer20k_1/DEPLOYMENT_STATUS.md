# Primer #1 deployment readiness status

Baseline: `FPST-SYS-SPEC-001 v1.1`  
Target: OneKiwi Primer 20K v1.0 / `GW2A-LV18PG256C8/I7`  
Deployment top: `kiwi_primer20k_fpst_tx_top`

## Implemented and regression-passing

- BTP SPI Mode 0 endpoint using the normative two-transaction request/response flow.
- BTP v1.1 framing, CRC-32/ISO-HDLC, transaction IDs and one-entry duplicate-response cache.
- 1 MHz real-board bring-up profile.
- IRQ/BUSY/FAULT/LINK_RESET sidebands.
- Tiny supervisor sidebands: `secure_enable`, active-low `zeroize`, independent heartbeat.
- BRAM-oriented request and response storage; CI asserts that the byte RAM and coefficient RAM patterns remain inferred memories before technology mapping.
- Atomic TX key/session stage/chunk/commit/abort/activate/zeroize.
- Key-load scratch window scrub after use.
- Forward NTT command path.
- STP v1 fixed 24-byte telemetry header, `NP_TX || sequence` nonce construction, Ascon-AEAD128 encryption and retained 64-byte packet.
- Retry-safe TX behavior: an exact duplicate BTP request returns the byte-identical cached encrypted response and does not advance the sequence.
- FPGA-side J2 deployment pin mapping and 27 MHz timing constraint.
- Board-top SPI integration tests for PING/CRC/IRQ/cache and session/key/STP/sequence/zeroize.
- Generic deployment-top Yosys synthesis sanity.
- `inverse_ntt_core.sv`: inverse transform implemented and regression-tested by exact forward->inverse round trip for two independent 256-coefficient vectors.

Current CI head `1afc237041d0081d653b2594461916fba65da89c` passes the complete repository verification workflow.

## Deliberately not claimed complete yet

The current BTP endpoint still returns an explicit unavailable/invalid-state response for:

```text
0x25 PQC_START_INTT
0x26 PQC_POINTWISE_MUL
0x27 PQC_POLY_ADD_SUB
```

`inverse_ntt_core.sv` now exists and is verified in regression, but its BTP dispatch/memory-selection path is not wired into the deployment endpoint yet. Pointwise/base multiplication and polynomial add/sub also need their final accelerator allocation/payload profile closed before they are advertised as hardware capabilities.

No unsupported command silently reports success.

## Physical release gates

The source tree is ready for the **Gowin deployment build step**, but it is not yet honest to call the image hardware-signed-off until all of these pass on the actual board:

1. Gowin synthesis on exact `GW2A-LV18PG256C8/I7`.
2. Place-and-route with no unconstrained top-level port.
3. Timing closure at the 27 MHz system clock and the selected I/O constraints.
4. Utilization/BSRAM review with adequate margin.
5. Bitstream generation.
6. Continuity check of every selected Primer J2 signal to the eventual SN32/Tiny harness.
7. Logic-analyzer qualification at 1 MHz SPI Mode 0 with zero frame/CRC errors before considering a faster rate.
8. Real-board zeroize/reset/fault behavior.

## SN32 sequencing

Do not rewrite the SN32 deployment transport until the Primer #1 BTP command surface above is frozen. Once Primer #1 is closed, SN32 should be changed to this exact BTP v1.1 contract rather than the legacy A1/A2 mailbox profile.
