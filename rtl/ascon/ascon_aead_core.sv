module ascon_aead_core (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         mode_decrypt_i,
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
    input  logic         tag_valid_i,
    output logic         tag_ready_o,
    input  logic [127:0] tag_i,
    output logic         out_valid_o,
    input  logic         out_ready_i,
    output logic [7:0]   out_data_o,
    output logic         out_last_o,
    output logic         tag_valid_o,
    input  logic         tag_ready_i,
    output logic [127:0] tag_o,
    output logic         done_o,
    output logic         auth_valid_o,
    output logic         auth_ok_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [15:0] ERR_INVALID_STATE = 16'h0302;

    logic enc_start;
    logic enc_ready;
    logic enc_done;
    logic enc_error_valid;
    logic [15:0] enc_error_code;

    /*
     * FPST v1.1 freezes this common encrypt/decrypt boundary. Primer #1 is an
     * encrypt-only endpoint, so decrypt requests are explicitly rejected rather
     * than leaving the frozen ports undefined. Primer #2 will provide the
     * decrypt implementation behind the same boundary.
     */
    assign enc_start = start_i && !mode_decrypt_i;
    assign ready_o = enc_ready;
    assign tag_ready_o = 1'b0;
    assign auth_valid_o = 1'b0;
    assign auth_ok_o = 1'b0;

    always_comb begin
        done_o = enc_done;
        error_valid_o = enc_error_valid;
        error_code_o = enc_error_code;

        if (start_i && mode_decrypt_i && enc_ready) begin
            done_o = 1'b1;
            error_valid_o = 1'b1;
            error_code_o = ERR_INVALID_STATE;
        end
    end

    /* Dedicated decrypt-tag inputs intentionally unused on Primer #1. */
    logic unused_tag_input;
    assign unused_tag_input = tag_valid_i ^ tag_i[0];

    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(128)
    ) u_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .start_i        (enc_start),
        .ready_o        (enc_ready),
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
        .done_o         (enc_done),
        .error_valid_o  (enc_error_valid),
        .error_code_o   (enc_error_code)
    );
endmodule
