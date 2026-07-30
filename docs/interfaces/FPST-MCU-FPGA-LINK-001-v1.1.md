# OBSOLETE / NOT FOR DEPLOYMENT — FPST-MCU-FPGA-LINK-001 v1.1

> [!CAUTION]
> This path is retained only as a tombstone so old links fail loudly instead of silently presenting an obsolete transport as current.

The former content at this path described the **pre-direct-BTP** single-Primer interface:

```text
A1/A2 memory-burst commands
CRC-16/CCITT-FALSE
mailbox/register framing
3 MHz initial SPI profile
legacy P0.x route notes
```

That profile is **not used by the current FPST v1.1 dual-Primer deployment**.

Current deployment contract:

```text
direct BTP v1
SOF A5 5A
version 01
CRC-32/ISO-HDLC
SPI Mode 0, MSB first
1 MHz initial bring-up
<=5 MHz only after measured qualification
shared SCK/MOSI/MISO + separate CS1/IRQ1 and CS2/IRQ2
```

Use these current sources instead:

1. `docs/spec-delta/FPST-v1.1-implementation-decisions.md`
2. `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`
3. `targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`
4. `docs/hardware/FPST-WIRING-GUIDE-v1.1.md`
5. current target board profiles/CST/SDC and executable RTL/firmware.

The detailed obsolete protocol document and legacy C helpers have been removed
from the working tree. They remain recoverable through Git history if an audit
requires them.

**Do not restore A1/A2, CRC-16 or 3 MHz bring-up to production code to make it match historical material.**
