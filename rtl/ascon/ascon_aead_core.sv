module ascon_aead_core #(
    parameter integer MAX_DATA_BYTES = 128
) (
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
    localparam logic [15:0] ERR_BUSY = 16'h0301;

    logic active_q;
    logic decrypt_q;
    logic busy_start_error_q;

    logic enc_ready;
    logic enc_in_ready;
    logic enc_out_valid;
    logic [7:0] enc_out_data;
    logic enc_out_last;
    logic enc_tag_valid;
    logic [127:0] enc_tag;
    logic enc_done;
    logic enc_error_valid;
    logic [15:0] enc_error_code;

    logic dec_ready;
    logic dec_in_ready;
    logic dec_tag_ready;
    logic dec_out_valid;
    logic [7:0] dec_out_data;
    logic dec_out_last;
    logic dec_done;
    logic dec_auth_valid;
    logic dec_auth_ok;
    logic dec_error_valid;
    logic [15:0] dec_error_code;

    logic selected_done;

    assign ready_o = !active_q && enc_ready && dec_ready;
    assign selected_done = decrypt_q ? dec_done : enc_done;

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            active_q           <= 1'b0;
            decrypt_q          <= 1'b0;
            busy_start_error_q <= 1'b0;
        end else begin
            busy_start_error_q <= 1'b0;
            if (start_i) begin
                if (ready_o) begin
                    active_q  <= 1'b1;
                    decrypt_q <= mode_decrypt_i;
                end else begin
                    busy_start_error_q <= 1'b1;
                end
            end
            if (active_q && selected_done)
                active_q <= 1'b0;
        end
    end

    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(MAX_DATA_BYTES)
    ) u_encrypt (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .zeroize_i     (zeroize_i),
        .start_i       (start_i && ready_o && !mode_decrypt_i),
        .ready_o       (enc_ready),
        .key_i         (key_i),
        .nonce_i       (nonce_i),
        .ad_len_i      (ad_len_i),
        .data_len_i    (data_len_i),
        .in_valid_i    (in_valid_i && active_q && !decrypt_q),
        .in_ready_o    (enc_in_ready),
        .in_data_i     (in_data_i),
        .in_last_i     (in_last_i),
        .out_valid_o   (enc_out_valid),
        .out_ready_i   (out_ready_i && active_q && !decrypt_q),
        .out_data_o    (enc_out_data),
        .out_last_o    (enc_out_last),
        .tag_valid_o   (enc_tag_valid),
        .tag_ready_i   (tag_ready_i && active_q && !decrypt_q),
        .tag_o         (enc_tag),
        .done_o        (enc_done),
        .error_valid_o (enc_error_valid),
        .error_code_o  (enc_error_code)
    );

    ascon_aead_decrypt #(
        .MAX_DATA_BYTES(MAX_DATA_BYTES)
    ) u_decrypt (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .zeroize_i     (zeroize_i),
        .start_i       (start_i && ready_o && mode_decrypt_i),
        .ready_o       (dec_ready),
        .key_i         (key_i),
        .nonce_i       (nonce_i),
        .ad_len_i      (ad_len_i),
        .data_len_i    (data_len_i),
        .in_valid_i    (in_valid_i && active_q && decrypt_q),
        .in_ready_o    (dec_in_ready),
        .in_data_i     (in_data_i),
        .in_last_i     (in_last_i),
        .tag_valid_i   (tag_valid_i && active_q && decrypt_q),
        .tag_ready_o   (dec_tag_ready),
        .tag_i         (tag_i),
        .out_valid_o   (dec_out_valid),
        .out_ready_i   (out_ready_i && active_q && decrypt_q),
        .out_data_o    (dec_out_data),
        .out_last_o    (dec_out_last),
        .done_o        (dec_done),
        .auth_valid_o  (dec_auth_valid),
        .auth_ok_o     (dec_auth_ok),
        .error_valid_o (dec_error_valid),
        .error_code_o  (dec_error_code)
    );

    always_comb begin
        in_ready_o    = 1'b0;
        tag_ready_o   = 1'b0;
        out_valid_o   = 1'b0;
        out_data_o    = 8'h00;
        out_last_o    = 1'b0;
        tag_valid_o   = 1'b0;
        tag_o         = 128'h0;
        done_o        = 1'b0;
        auth_valid_o  = 1'b0;
        auth_ok_o     = 1'b0;
        error_valid_o = busy_start_error_q;
        error_code_o  = busy_start_error_q ? ERR_BUSY : 16'h0000;

        if (active_q) begin
            if (decrypt_q) begin
                in_ready_o    = dec_in_ready;
                tag_ready_o   = dec_tag_ready;
                out_valid_o   = dec_out_valid;
                out_data_o    = dec_out_data;
                out_last_o    = dec_out_last;
                done_o        = dec_done;
                auth_valid_o  = dec_auth_valid;
                auth_ok_o     = dec_auth_ok;
                if (dec_error_valid) begin
                    error_valid_o = 1'b1;
                    error_code_o  = dec_error_code;
                end
            end else begin
                in_ready_o  = enc_in_ready;
                out_valid_o = enc_out_valid;
                out_data_o  = enc_out_data;
                out_last_o  = enc_out_last;
                tag_valid_o = enc_tag_valid;
                tag_o       = enc_tag;
                done_o      = enc_done;
                if (enc_error_valid) begin
                    error_valid_o = 1'b1;
                    error_code_o  = enc_error_code;
                end
            end
        end
    end
endmodule
