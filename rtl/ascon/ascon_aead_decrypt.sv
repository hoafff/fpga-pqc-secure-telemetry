module ascon_aead_decrypt #(
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

    input  logic         tag_valid_i,
    output logic         tag_ready_o,
    input  logic [127:0] tag_i,

    output logic         out_valid_o,
    input  logic         out_ready_i,
    output logic [7:0]   out_data_o,
    output logic         out_last_o,

    output logic         done_o,
    output logic         auth_valid_o,
    output logic         auth_ok_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [63:0] ASCON_AEAD128_IV = 64'h0000_1000_808c_0001;

    localparam logic [15:0] ERR_BUSY          = 16'h0301;
    localparam logic [15:0] ERR_ASCON_LENGTH = 16'h0501;
    localparam logic [15:0] ERR_AUTH_TAG      = 16'h0502;

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
        ST_DATA_FINAL_APPLY,
        ST_WAIT_TAG,
        ST_FINAL_KEY_XOR,
        ST_FINAL_PERM_START,
        ST_FINAL_PERM_WAIT,
        ST_RELEASE,
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
    logic [127:0] received_tag_q;

    logic [7:0] quarantine_q [0:MAX_DATA_BYTES-1];
    logic [7:0] release_index_q;

    logic         permutation_start;
    logic [3:0]   permutation_rounds;
    logic [319:0] permutation_state_i;
    logic         permutation_busy;
    logic         permutation_done;
    logic [319:0] permutation_state_o;

    logic input_fire;
    logic output_fire;
    logic tag_fire;
    logic expected_input_last;
    logic input_last_mismatch;

    logic [319:0] absorb_full_state;
    logic [319:0] absorb_padded_state;
    logic [319:0] decrypt_full_state;
    logic [319:0] decrypt_partial_state_value;
    logic [127:0] decrypt_plain_block;
    logic [127:0] computed_tag;

    integer i;

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

    function automatic logic [319:0] decrypt_partial_state (
        input logic [319:0] current_state,
        input logic [127:0] ciphertext_block,
        input logic [4:0]   valid_bytes
    );
        logic [319:0] result;
        integer j;
        integer pad_bit;
        begin
            result = current_state;
            for (j = 0; j < 16; j = j + 1) begin
                if (j < valid_bytes)
                    result[8*j +: 8] = ciphertext_block[8*j +: 8];
            end
            pad_bit = valid_bytes * 8;
            if (valid_bytes < 16)
                result[pad_bit] = result[pad_bit] ^ 1'b1;
            decrypt_partial_state = result;
        end
    endfunction

    assign ready_o = (state_q == ST_IDLE);

    assign in_ready_o = (state_q == ST_AD_RECV) ||
                        (state_q == ST_DATA_RECV);
    assign input_fire = in_valid_i && in_ready_o;

    assign tag_ready_o = (state_q == ST_WAIT_TAG);
    assign tag_fire = tag_valid_i && tag_ready_o;

    assign out_valid_o = (state_q == ST_RELEASE) && (data_len_q != 0);
    assign output_fire = out_valid_o && out_ready_i;
    assign out_data_o = quarantine_q[release_index_q];
    assign out_last_o = out_valid_o &&
                        (release_index_q + 1'b1 == data_len_q);

    assign expected_input_last = (input_count_q + 1'b1 == total_input_q);
    assign input_last_mismatch = input_fire &&
                                 (in_last_i != expected_input_last);

    assign absorb_full_state = xor_rate(state_words_q, block_q);
    assign absorb_padded_state = xor_rate(
        state_words_q,
        padded_block(block_q, block_count_q)
    );

    always_comb begin
        decrypt_full_state = state_words_q;
        decrypt_full_state[127:0] = block_q;
        decrypt_partial_state_value = decrypt_partial_state(
            state_words_q,
            block_q,
            block_count_q
        );
        decrypt_plain_block = state_words_q[127:0] ^ block_q;
        computed_tag = {
            permutation_state_o[319:256] ^ key_q[127:64],
            permutation_state_o[255:192] ^ key_q[63:0]
        };
    end

    always_comb begin
        permutation_start   = 1'b0;
        permutation_rounds  = 4'd8;
        permutation_state_i = state_words_q;

        case (state_q)
            ST_INIT_START: begin
                permutation_start  = 1'b1;
                permutation_rounds = 4'd12;
                /* Same state/byte packing as ascon_aead_encrypt. */
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
                permutation_state_i = decrypt_full_state;
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
            state_q          <= ST_IDLE;
            key_q            <= '0;
            nonce_q          <= '0;
            ad_len_q         <= '0;
            data_len_q       <= '0;
            total_input_q    <= '0;
            ad_count_q       <= '0;
            data_count_q     <= '0;
            input_count_q    <= '0;
            state_words_q    <= '0;
            block_q          <= '0;
            block_count_q    <= '0;
            received_tag_q   <= '0;
            release_index_q  <= '0;
            done_o           <= 1'b0;
            auth_valid_o     <= 1'b0;
            auth_ok_o        <= 1'b0;
            error_valid_o    <= 1'b0;
            error_code_o     <= 16'h0000;
            for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                quarantine_q[i] <= 8'h00;
        end else if (zeroize_i) begin
            state_q          <= ST_IDLE;
            key_q            <= '0;
            nonce_q          <= '0;
            ad_len_q         <= '0;
            data_len_q       <= '0;
            total_input_q    <= '0;
            ad_count_q       <= '0;
            data_count_q     <= '0;
            input_count_q    <= '0;
            state_words_q    <= '0;
            block_q          <= '0;
            block_count_q    <= '0;
            received_tag_q   <= '0;
            release_index_q  <= '0;
            done_o           <= 1'b0;
            auth_valid_o     <= 1'b0;
            auth_ok_o        <= 1'b0;
            error_valid_o    <= 1'b0;
            error_code_o     <= 16'h0000;
            for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                quarantine_q[i] <= 8'h00;
        end else begin
            done_o        <= 1'b0;
            auth_valid_o  <= 1'b0;
            auth_ok_o     <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            if (start_i && !ready_o) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_BUSY;
            end

            if (input_last_mismatch) begin
                state_q         <= ST_IDLE;
                key_q           <= '0;
                nonce_q         <= '0;
                state_words_q   <= '0;
                block_q         <= '0;
                block_count_q   <= '0;
                received_tag_q  <= '0;
                release_index_q <= '0;
                error_valid_o   <= 1'b1;
                error_code_o    <= ERR_ASCON_LENGTH;
                for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                    quarantine_q[i] <= 8'h00;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i) begin
                            if (data_len_i > MAX_DATA_BYTES) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_ASCON_LENGTH;
                            end else begin
                                key_q           <= key_i;
                                nonce_q         <= nonce_i;
                                ad_len_q        <= ad_len_i;
                                data_len_q      <= data_len_i;
                                total_input_q   <= {1'b0,ad_len_i} + {1'b0,data_len_i};
                                ad_count_q      <= '0;
                                data_count_q    <= '0;
                                input_count_q   <= '0;
                                state_words_q   <= '0;
                                block_q         <= '0;
                                block_count_q   <= '0;
                                received_tag_q  <= '0;
                                release_index_q <= '0;
                                for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                                    quarantine_q[i] <= 8'h00;
                                state_q <= ST_INIT_START;
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
                        for (i = 0; i < 16; i = i + 1)
                            quarantine_q[data_count_q-16+i] <= decrypt_plain_block[8*i +: 8];
                        state_q <= ST_DATA_FULL_WAIT;
                    end

                    ST_DATA_FULL_WAIT: begin
                        if (permutation_done) begin
                            state_words_q <= permutation_state_o;
                            block_q       <= '0;
                            block_count_q <= '0;
                            if (data_count_q == data_len_q)
                                state_q <= ST_DATA_FINAL_APPLY;
                            else
                                state_q <= ST_DATA_RECV;
                        end
                    end

                    ST_DATA_FINAL_APPLY: begin
                        state_words_q <= decrypt_partial_state_value;
                        for (i = 0; i < 16; i = i + 1) begin
                            if (i < block_count_q)
                                quarantine_q[data_count_q-block_count_q+i] <=
                                    decrypt_plain_block[8*i +: 8];
                        end
                        block_q       <= '0;
                        block_count_q <= '0;
                        state_q       <= ST_WAIT_TAG;
                    end

                    ST_WAIT_TAG: begin
                        if (tag_fire) begin
                            received_tag_q <= tag_i;
                            state_q <= ST_FINAL_KEY_XOR;
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
                            auth_valid_o <= 1'b1;
                            if (computed_tag == received_tag_q) begin
                                auth_ok_o       <= 1'b1;
                                release_index_q <= '0;
                                if (data_len_q == 0)
                                    state_q <= ST_DONE;
                                else
                                    state_q <= ST_RELEASE;
                            end else begin
                                auth_ok_o     <= 1'b0;
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_AUTH_TAG;
                                key_q         <= '0;
                                nonce_q       <= '0;
                                state_words_q <= '0;
                                received_tag_q <= '0;
                                for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                                    quarantine_q[i] <= 8'h00;
                                state_q <= ST_DONE;
                            end
                        end
                    end

                    ST_RELEASE: begin
                        if (output_fire) begin
                            if (release_index_q + 1'b1 == data_len_q) begin
                                release_index_q <= '0;
                                state_q <= ST_DONE;
                            end else begin
                                release_index_q <= release_index_q + 1'b1;
                            end
                        end
                    end

                    ST_DONE: begin
                        done_o          <= 1'b1;
                        key_q           <= '0;
                        nonce_q         <= '0;
                        state_words_q   <= '0;
                        block_q         <= '0;
                        block_count_q   <= '0;
                        received_tag_q  <= '0;
                        release_index_q <= '0;
                        for (i = 0; i < MAX_DATA_BYTES; i = i + 1)
                            quarantine_q[i] <= 8'h00;
                        state_q <= ST_IDLE;
                    end

                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    logic unused_permutation_busy;
    always_comb unused_permutation_busy = permutation_busy;
`endif
endmodule
