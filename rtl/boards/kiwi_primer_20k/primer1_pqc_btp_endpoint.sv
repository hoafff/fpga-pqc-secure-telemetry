// Portable source wrapper for the Primer #1 PQC BTP endpoint.
//
// Icarus 12 currently misses OP_PQC_POLY_ADD_SUB from the wildcard package
// import inside this module and otherwise creates an implicit one-bit wire.
// An explicit compilation-unit import is standard SystemVerilog and makes the
// normative package constant visible without duplicating or changing its value.
import fpst_btp_pkg::OP_PQC_POLY_ADD_SUB;
`include "rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv"
