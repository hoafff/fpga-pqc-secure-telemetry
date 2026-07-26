module ascon_aead_encrypt #(
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
    localparam logic [63:0] ASCON_AEAD128_IV = 64'h0000_1000_808c_0001;

    localparam logic [15:0] ERR_BUSY          = 16'h0301;
    localparam logic [15:0] ERR_ASCON_LENGTH = 16'h0501;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_INIT_START,
        ST_INIT_WAIT,
        ST_AD_RECV,
        ST_AD_FULL_START,
        ST_AD_FULL_WAIT,
        ST_AD_FINAL_START,
        ST_AD_FINAL_WAIT,
        ST_DOMAIN_SEPARATE,
        ST_DATA_RECV,
        ST_DATA_FULL_START,
        ST_DATA_FULL_WAIT,
        ST_DATA_FULL_OUTPUT,
        ST_DATA_FINAL_APPLY,
        ST_DATA_FINAL_OUTPUT,
        ST_FINAL_KEY_XOR,
        ST_FINAL_PERM_START,
        ST_FINAL_PERM_WAIT,
        ST_EMIT_TAG,
        ST_DONE
    } state_t;

    state_t state_q;

    logic [127:0] key_q;
    logic [127:0] nonce_q;
    logic [15:0]  ad_len_q;
    logic [15:0]  data_len_q;
    logic [16:0]  total_input_q;

    logic [15:0] ad_count_q;
    logic [15:0] data_count_q;
    logic [16:0] input_count_q;

    logic [319:0] state_words_q;
    logic [127:0] block_q;
    logic [4:0]   block_count_q;

    logic [127:0] ciphertext_q;
    logic [4:0]   ciphertext_valid_bytes_q;
    logic [4:0]   ciphertext_index_q;
    logic         ciphertext_is_last_q;

    logic [127:0] tag_q;

    logic         permutation_start;
    logic [3:0]   permutation_rounds;
    logic [319:0] permutation_state_i;
    logic         permutation_busy;
    logic         permutation_done;
    logic [319:0] permutation_state_o;

    logic         input_fire;
    logic         output_fire;
    logic         tag_fire;
    logic         expected_input_last;
    logic         input_last_mismatch;

    logic [319:0] absorb_full_state;
    logic [319:0] absorb_padded_state;

    function automatic logic [127:0] padded_block (
        input logic [127:0] partial_block,
        input logic [4:0]   valid_bytes
    );
        logic [127:0] result;
        integer bit_index;
        begin
            result = partial_block;
            bit_index = valid_bytes * 8;
            if (valid_bytes < 16)
                result[bit_index] = 1'b1;
            padded_block = result;
        end
    endfunction

    function automatic logic [319:0] xor_rate (
        input logic [319:0] current_state,
        input logic [127:0] rate_block
    );
        logic [319:0] result;
        begin
            result = current_state;
            result[127:0] = current_state[127:0] ^ rate_block;
            xor_rate = result;
        end
    endfunction

    assign ready_o = (state_q == ST_IDLE);

    assign in_ready_o = (state_q == ST_AD_RECV) ||
                        (state_q == ST_DATA_RECV);
    assign input_fire = in_valid_i && in_ready_o;

    assign out_valid_o = (state_q == ST_DATA_FULL_OUTPUT) ||
                         (state_q == ST_DATA_FINAL_OUTPUT);
    assign output_fire = out_valid_o && out_ready_i;
    assign out_data_o = ciphertext_q[8*ciphertext_index_q +: 8];
    assign out_last_o = out_valid_o && ciphertext_is_last_q &&
                        (ciphertext_index_q == ciphertext_valid_bytes_q - 1'b1);

    assign tag_valid_o = (state_q == ST_EMIT_TAG);
    assign tag_fire = tag_valid_o && tag_ready_i;
    assign tag_o = tag_q;

    assign expected_input_last = (input_count_q + 1'b1 == total_input_q);
    assign input_last_mismatch = input_fire &&
                                 (in_last_i != expected_input_last);

    assign absorb_full_state = xor_rate(state_words_q, block_q);
    assign absorb_padded_state = xor_rate(
        state_words_q,
        padded_block(block_q, block_count_q)
    );

    always_comb begin
        permutation_start   = 1'b0;
        permutation_rounds  = 4'd8;
        permutation_state_i = state_words_q;

        case (state_q)
            ST_INIT_START: begin
                permutation_start  = 1'b1;
                permutation_rounds = 4'd12;
                // State packing is S4||S3||S2||S1||S0. Byte 0 of each
                // external 128-bit bus is carried in bits [7:0].
                permutation_state_i = {
                    nonce_q[127:64], nonce_q[63:0],
                    key_q[127:64], key_q[63:0], ASCON_AEAD128_IV
                };
            end

            ST_AD_FULL_START: begin
                permutation_start   = 1'b1;
                permutation_rounds  = 4'd8;
                permutation_state_i = absorb_full_state;
            end

            ST_AD_FINAL_START: begin
                permutation_start   = 1'b1;
                permutation_rounds  = 4'd8;
                permutation_state_i = absorb_padded_state;
            end

            ST_DATA_FULL_START: begin
                permutation_start   = 1'b1;
                permutation_rounds  = 4'd8;
                permutation_state_i = absorb_full_state;
            end

            ST_FINAL_PERM_START: begin
                permutation_start   = 1'b1;
                permutation_rounds  = 4'd12;
                permutation_state_i = state_words_q;
            end

            default: begin
            end
        endcase
    end

    ascon_permutation u_permutation (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .zeroize_i  (zeroize_i),
        .start_i    (permutation_start),
        .rounds_i   (permutation_rounds),
        .state_i    (permutation_state_i),
        .busy_o     (permutation_busy),
        .done_o     (permutation_done),
        .state_o    (permutation_state_o)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q                    <= ST_IDLE;
            key_q                      <= '0;
            nonce_q                    <= '0;
            ad_len_q                   <= '0;
            data_len_q                 <= '0;
            total_input_q              <= '0;
            ad_count_q                 <= '0;
            data_count_q               <= '0;
            input_count_q              <= '0;
            state_words_q              <= '0;
            block_q                    <= '0;
            block_count_q              <= '0;
            ciphertext_q               <= '0;
            ciphertext_valid_bytes_q   <= '0;
            ciphertext_index_q         <= '0;
            ciphertext_is_last_q       <= 1'b0;
            tag_q                      <= '0;
            done_o                     <= 1'b0;
            error_valid_o              <= 1'b0;
            error_code_o               <= 16'h0000;
        end else if (zeroize_i) begin
            state_q                    <= ST_IDLE;
            key_q                      <= '0;
            nonce_q                    <= '0;
            ad_len_q                   <= '0;
            data_len_q                 <= '0;
            total_input_q              <= '0;
            ad_count_q                 <= '0;
            data_count_q               <= '0;
            input_count_q              <= '0;
            state_words_q              <= '0;
            block_q                    <= '0;
            block_count_q              <= '0;
            ciphertext_q               <= '0;
            ciphertext_valid_bytes_q   <= '0;
            ciphertext_index_q         <= '0;
            ciphertext_is_last_q       <= 1'b0;
            tag_q                      <= '0;
            done_o                     <= 1'b0;
            error_valid_o              <= 1'b0;
            error_code_o               <= 16'h0000;
        end else begin
            done_o        <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            // A busy start is rejected without disturbing the active operation.
            if (start_i && !ready_o) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_BUSY;
            end

            // in_last_i is only a consistency check. Length registers remain
            // authoritative for the AD/plaintext boundary and total input size.
            if (input_last_mismatch) begin
                state_q                    <= ST_IDLE;
                key_q                      <= '0;
                nonce_q                    <= '0;
                state_words_q              <= '0;
                block_q                    <= '0;
                block_count_q              <= '0;
                ciphertext_q               <= '0;
                ciphertext_valid_bytes_q   <= '0;
                ciphertext_index_q         <= '0;
                ciphertext_is_last_q       <= 1'b0;
                tag_q                      <= '0;
                error_valid_o              <= 1'b1;
                error_code_o               <= ERR_ASCON_LENGTH;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i) begin
                            if (data_len_i > MAX_DATA_BYTES) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_ASCON_LENGTH;
                            end else begin
                                key_q                    <= key_i;
                                nonce_q                  <= nonce_i;
                                ad_len_q                 <= ad_len_i;
                                data_len_q               <= data_len_i;
                                total_input_q            <= {1'b0, ad_len_i} +
                                                            {1'b0, data_len_i};
                                ad_count_q               <= '0;
                                data_count_q             <= '0;
                                input_count_q            <= '0;
                                state_words_q            <= '0;
                                block_q                  <= '0;
                                block_count_q            <= '0;
                                ciphertext_q             <= '0;
                                ciphertext_valid_bytes_q <= '0;
                                ciphertext_index_q       <= '0;
                                ciphertext_is_last_q     <= 1'b0;
                                tag_q                    <= '0;
                                state_q                  <= ST_INIT_START;
                            end
                        end
                    end

                    ST_INIT_START: begin
                        state_q <= ST_INIT_WAIT;
                    end

                    ST_INIT_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            state_words_q[255:192] <=
                                permutation_state_o[255:192] ^ key_q[63:0];
                            state_words_q[319:256] <=
                                permutation_state_o[319:256] ^ key_q[127:64];
                            block_q       <= '0;
                            block_count_q <= '0;

                            if (ad_len_q == 0)
                                state_q <= ST_DOMAIN_SEPARATE;
                            else
                                state_q <= ST_AD_RECV;
                        end
                    end

                    ST_AD_RECV: begin
                        if (input_fire) begin
                            block_q[8*block_count_q +: 8] <= in_data_i;
                            ad_count_q    <= ad_count_q + 1'b1;
                            input_count_q <= input_count_q + 1'b1;

                            if (block_count_q == 5'd15) begin
                                block_count_q <= 5'd16;
                                state_q       <= ST_AD_FULL_START;
                            end else begin
                                block_count_q <= block_count_q + 1'b1;
                                if (ad_count_q + 1'b1 == ad_len_q)
                                    state_q <= ST_AD_FINAL_START;
                            end
                        end
                    end

                    ST_AD_FULL_START: begin
                        state_q <= ST_AD_FULL_WAIT;
                    end

                    ST_AD_FULL_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            block_q       <= '0;
                            block_count_q <= '0;

                            if (ad_count_q == ad_len_q)
                                state_q <= ST_AD_FINAL_START;
                            else
                                state_q <= ST_AD_RECV;
                        end
                    end

                    ST_AD_FINAL_START: begin
                        state_q <= ST_AD_FINAL_WAIT;
                    end

                    ST_AD_FINAL_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            block_q       <= '0;
                            block_count_q <= '0;
                            state_q       <= ST_DOMAIN_SEPARATE;
                        end
                    end

                    ST_DOMAIN_SEPARATE: begin
                        state_words_q[319:256] <=
                            state_words_q[319:256] ^ 64'h8000_0000_0000_0000;
                        block_q       <= '0;
                        block_count_q <= '0;

                        if (data_len_q == 0)
                            state_q <= ST_DATA_FINAL_APPLY;
                        else
                            state_q <= ST_DATA_RECV;
                    end

                    ST_DATA_RECV: begin
                        if (input_fire) begin
                            block_q[8*block_count_q +: 8] <= in_data_i;
                            data_count_q  <= data_count_q + 1'b1;
                            input_count_q <= input_count_q + 1'b1;

                            if (block_count_q == 5'd15) begin
                                block_count_q <= 5'd16;
                                state_q       <= ST_DATA_FULL_START;
                            end else begin
                                block_count_q <= block_count_q + 1'b1;
                                if (data_count_q + 1'b1 == data_len_q)
                                    state_q <= ST_DATA_FINAL_APPLY;
                            end
                        end
                    end

                    ST_DATA_FULL_START: begin
                        ciphertext_q             <= absorb_full_state[127:0];
                        ciphertext_valid_bytes_q <= 5'd16;
                        ciphertext_index_q       <= '0;
                        ciphertext_is_last_q     <= (data_count_q == data_len_q);
                        state_q                  <= ST_DATA_FULL_WAIT;
                    end

                    ST_DATA_FULL_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            state_q       <= ST_DATA_FULL_OUTPUT;
                        end
                    end

                    ST_DATA_FULL_OUTPUT: begin
                        if (output_fire) begin
                            if (ciphertext_index_q ==
                                ciphertext_valid_bytes_q - 1'b1) begin
                                ciphertext_index_q <= '0;
                                block_q             <= '0;
                                block_count_q       <= '0;

                                if (data_count_q == data_len_q)
                                    state_q <= ST_DATA_FINAL_APPLY;
                                else
                                    state_q <= ST_DATA_RECV;
                            end else begin
                                ciphertext_index_q <= ciphertext_index_q + 1'b1;
                            end
                        end
                    end

                    ST_DATA_FINAL_APPLY: begin
                        state_words_q              <= absorb_padded_state;
                        ciphertext_q               <= absorb_padded_state[127:0];
                        ciphertext_valid_bytes_q   <= block_count_q;
                        ciphertext_index_q         <= '0;
                        ciphertext_is_last_q       <= 1'b1;

                        if (block_count_q == 0)
                            state_q <= ST_FINAL_KEY_XOR;
                        else
                            state_q <= ST_DATA_FINAL_OUTPUT;
                    end

                    ST_DATA_FINAL_OUTPUT: begin
                        if (output_fire) begin
                            if (ciphertext_index_q ==
                                ciphertext_valid_bytes_q - 1'b1) begin
                                ciphertext_index_q <= '0;
                                block_q             <= '0;
                                block_count_q       <= '0;
                                state_q             <= ST_FINAL_KEY_XOR;
                            end else begin
                                ciphertext_index_q <= ciphertext_index_q + 1'b1;
                            end
                        end
                    end

                    ST_FINAL_KEY_XOR: begin
                        state_words_q[191:128] <=
                            state_words_q[191:128] ^ key_q[63:0];
                        state_words_q[255:192] <=
                            state_words_q[255:192] ^ key_q[127:64];
                        state_q <= ST_FINAL_PERM_START;
                    end

                    ST_FINAL_PERM_START: begin
                        state_q <= ST_FINAL_PERM_WAIT;
                    end

                    ST_FINAL_PERM_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            tag_q[63:0] <=
                                permutation_state_o[255:192] ^ key_q[63:0];
                            tag_q[127:64] <=
                                permutation_state_o[319:256] ^ key_q[127:64];
                            state_q <= ST_EMIT_TAG;
                        end
                    end

                    ST_EMIT_TAG: begin
                        if (tag_fire)
                            state_q <= ST_DONE;
                    end

                    ST_DONE: begin
                        done_o                     <= 1'b1;
                        key_q                      <= '0;
                        nonce_q                    <= '0;
                        state_words_q              <= '0;
                        block_q                    <= '0;
                        block_count_q              <= '0;
                        ciphertext_q               <= '0;
                        ciphertext_valid_bytes_q   <= '0;
                        ciphertext_index_q         <= '0;
                        ciphertext_is_last_q       <= 1'b0;
                        tag_q                      <= '0;
                        state_q                    <= ST_IDLE;
                    end

                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    // The busy output is intentionally internal to the engine. Keep a use here
    // so lint/synthesis diagnostics still catch an accidentally removed link.
    logic unused_permutation_busy;
    always_comb unused_permutation_busy = permutation_busy;
`endif
endmodule
