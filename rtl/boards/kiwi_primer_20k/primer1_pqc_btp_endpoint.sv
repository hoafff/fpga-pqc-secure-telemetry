// Portable source wrapper for the Primer #1 PQC BTP endpoint.
//
// Icarus resolves the wildcard-imported OP_PQC_POLY_ADD_SUB identifier as an
// implicit one-bit net in this module even though fpst_btp_pkg defines it as
// 8'h27; the adjacent PQC opcode constants resolve normally. Pin the normative
// Appendix-B value only while preprocessing the endpoint implementation. This
// keeps the protocol registry in fpst_btp_pkg authoritative while avoiding an
// Icarus-only dispatch failure. Vendor/Yosys builds see the exact same opcode.
`define OP_PQC_POLY_ADD_SUB 8'h27
`include "rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv"
`undef OP_PQC_POLY_ADD_SUB
