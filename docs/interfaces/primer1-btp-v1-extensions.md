# Primer #1 BTP v1 integration extensions

This note closes one implementation gap in `FPST-SYS-SPEC-001 v1.1` without changing the frozen BTP v1 frame format.

The system sequence policy requires the MCU to tell Primer #1 whether Primer #2 committed the retained STP packet, but the recovered Appendix B registry does not provide a request for that MCU -> Primer #1 action. Appendix B.2 permits backward-compatible opcode additions while retaining BTP version `0x01`, so this integration baseline allocates two previously unused opcodes.

| Opcode | Name | Request payload | Success effect |
|---:|---|---|---|
| `0x64` | `STP_TX_COMMIT` | `committed_sequence` as BE64 | Require `committed_sequence == tx_sequence`; invalidate the retained packet and increment `tx_sequence` exactly once. |
| `0x65` | `STP_TX_RECONCILE` | `receiver_expected_sequence` as BE64 | If equal to `tx_sequence`, keep retained bytes and request resend. If equal to `tx_sequence + 1`, invalidate retained bytes and increment once. Any other value returns `ERR_SEQUENCE_DESYNC (0x0610)` and stops the active TX session. |

Both requests use the normal generic BTP response payload. They participate in the same byte-exact duplicate suppression and 1000 ms response-cache policy as every other non-idempotent request.

These values are project-owned implementation extensions, not claims that the original system specification assigned them. MCU firmware and Primer #1 RTL must be changed together if the allocation is ever revised.
