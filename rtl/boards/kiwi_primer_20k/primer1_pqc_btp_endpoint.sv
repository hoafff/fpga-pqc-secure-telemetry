// Compatibility source path for older simulation/source manifests.
// Production/Gowin manifests include primer1_pqc_btp_endpoint_v2.sv directly.
// The dedicated Icarus wire regression applies its simulator-only import
// workaround to a build-time copy of the v2 implementation.
`include "rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv"
