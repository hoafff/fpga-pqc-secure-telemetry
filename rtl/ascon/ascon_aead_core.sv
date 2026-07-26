// FPST Ascon-AEAD128 encrypt integration boundary.
//
// The deployment endpoint/session/STP logic intentionally lives above this
// module.  This wrapper keeps the frozen AEAD datapath boundary stable while
// allowing the encrypt engine implementation underneath to evolve.
module ascon_aead_core #(
    parameter integer MAX_DATA_BYTES = 128
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         start_i,
    output logic         ready_o,

    input  logic [127:0] key_i,
    input  logic [127:0] nonce_i,
    input  logic [15:0]  ad_len_i,
    input  logic [15:0]  data_len_i,

    input  logic         in_valid_i,
    output logic         in_ready_o,
    input  logic [7:0]   in_data_i,
    input  logic         in_last_i,

    output logic         out_valid_o,
    input  logic         out_ready_i,
    output logic [7:0]   out_data_o,
    output logic         out_last_o,

    output logic         tag_valid_o,
    input  logic         tag_ready_i,
    output logic [127:0] tag_o,

    output logic         done_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(MAX_DATA_BYTES)
    ) u_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .start_i        (start_i),
        .ready_o        (ready_o),
        .key_i          (key_i),
        .nonce_i        (nonce_i),
        .ad_len_i       (ad_len_i),
        .data_len_i     (data_len_i),
        .in_valid_i     (in_valid_i),
        .in_ready_o     (in_ready_o),
        .in_data_i      (in_data_i),
        .in_last_i      (in_last_i),
        .out_valid_o    (out_valid_o),
        .out_ready_i    (out_ready_i),
        .out_data_o     (out_data_o),
        .out_last_o     (out_last_o),
        .tag_valid_o    (tag_valid_o),
        .tag_ready_i    (tag_ready_i),
        .tag_o          (tag_o),
        .done_o         (done_o),
        .error_valid_o  (error_valid_o),
        .error_code_o   (error_code_o)
    );
endmodule
