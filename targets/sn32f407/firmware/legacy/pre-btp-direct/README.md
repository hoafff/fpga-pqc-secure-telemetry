# OBSOLETE / NOT FOR DEPLOYMENT — pre-direct-BTP firmware

This directory preserves the old A1/A2 SPI memory-burst and CRC-16 helpers only for historical reference.

They were removed from the active `include/` and `src/` trees by FIX-006 because the current dual-Primer deployment uses direct BTP v1 with CRC-32/ISO-HDLC and a 1 MHz initial SPI rate.

**Rules:**

- never add this directory to the production Keil target or CMake core;
- never reintroduce `0xA1/0xA2` mailbox framing to Primer deployment RTL;
- never use the legacy 3 MHz initial bring-up requirement;
- current source of truth is `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`, `targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md` and the current board profiles.

The pre-repair repository state is preserved at audit baseline commit `150dee70e88f6270bc82be6bd30549e64501d1d9`.
