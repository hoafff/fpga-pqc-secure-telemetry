module ascon_encrypt_kat_selftest (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,

    output logic        running_o,
    output logic        complete_o,
    output logic        done_o,
    output logic        pass_o,
    output logic        fail_o,
    output logic        core_busy_o,
    output logic [5:0]  mismatch_index_o,
    output logic [7:0]  mismatch_observed_o,
    output logic [7:0]  mismatch_expected_o,
    output logic [15:0] core_error_code_o
);
    localparam logic [127:0] KAT_KEY_BUS =
        128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    localparam logic [127:0] KAT_NONCE_BUS =
        128'h1f1e_1d1c_1b1a_1918_1716_1514_1312_1110;
    localparam logic [127:0] KAT_TAG_BUS =
        128'h59ae_4270_2c02_9d01_9bec_0552_44af_ebdf;

    typedef enum logic [2:0] {
        SELFTEST_IDLE,
        SELFTEST_START,
        SELFTEST_FEED,
        SELFTEST_WAIT,
        SELFTEST_FINISH
    } selftest_state_t;

    selftest_state_t state_q;

    logic        core_start;
    logic        core_ready;
    logic        core_in_valid;
    logic        core_in_ready;
    logic [7:0]  core_in_data;
    logic        core_in_last;
    logic        core_out_valid;
    logic [7:0]  core_out_data;
    logic        core_out_last;
    logic        core_tag_valid;
    logic [127:0] core_tag;
    logic        core_done;
    logic        core_error_valid;
    logic [15:0] core_error_code;

    logic [5:0] input_index_q;
    logic [4:0] ciphertext_index_q;
    logic       mismatch_q;

    function automatic logic [7:0] expected_ciphertext_byte (
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0:  expected_ciphertext_byte = 8'h9d;
                5'd1:  expected_ciphertext_byte = 8'h29;
                5'd2:  expected_ciphertext_byte = 8'hf9;
                5'd3:  expected_ciphertext_byte = 8'hd5;
                5'd4:  expected_ciphertext_byte = 8'h2a;
                5'd5:  expected_ciphertext_byte = 8'hdf;
                5'd6:  expected_ciphertext_byte = 8'h94;
                5'd7:  expected_ciphertext_byte = 8'h70;
                5'd8:  expected_ciphertext_byte = 8'haf;
                5'd9:  expected_ciphertext_byte = 8'h4c;
                5'd10: expected_ciphertext_byte = 8'hbc;
                5'd11: expected_ciphertext_byte = 8'he0;
                5'd12: expected_ciphertext_byte = 8'ha4;
                5'd13: expected_ciphertext_byte = 8'h48;
                5'd14: expected_ciphertext_byte = 8'h1a;
                5'd15: expected_ciphertext_byte = 8'hc7;
                5'd16: expected_ciphertext_byte = 8'hfc;
                5'd17: expected_ciphertext_byte = 8'hb1;
                5'd18: expected_ciphertext_byte = 8'hb3;
                5'd19: expected_ciphertext_byte = 8'h29;
                5'd20: expected_ciphertext_byte = 8'h76;
                5'd21: expected_ciphertext_byte = 8'h46;
                5'd22: expected_ciphertext_byte = 8'h98;
                5'd23: expected_ciphertext_byte = 8'h92;
                default: expected_ciphertext_byte = 8'h00;
            endcase
        end
    endfunction

    assign running_o  = (state_q != SELFTEST_IDLE) &&
                        (state_q != SELFTEST_FINISH);
    assign core_busy_o = !core_ready;

    assign core_start = (state_q == SELFTEST_START);
    assign core_in_valid = (state_q == SELFTEST_FEED);
    assign core_in_data = (input_index_q < 6'd24)
        ? (8'h30 + input_index_q[4:0])
        : (8'h20 + (input_index_q - 6'd24));
    assign core_in_last = (input_index_q == 6'd47);

    ascon_aead_encrypt u_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (1'b0),
        .start_i        (core_start),
        .ready_o        (core_ready),
        .key_i          (KAT_KEY_BUS),
        .nonce_i        (KAT_NONCE_BUS),
        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),
        .in_valid_i     (core_in_valid),
        .in_ready_o     (core_in_ready),
        .in_data_i      (core_in_data),
        .in_last_i      (core_in_last),
        .out_valid_o    (core_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (core_out_data),
        .out_last_o     (core_out_last),
        .tag_valid_o    (core_tag_valid),
        .tag_ready_i    (1'b1),
        .tag_o          (core_tag),
        .done_o         (core_done),
        .error_valid_o  (core_error_valid),
        .error_code_o   (core_error_code)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q                <= SELFTEST_IDLE;
            input_index_q          <= '0;
            ciphertext_index_q     <= '0;
            mismatch_q             <= 1'b0;
            complete_o             <= 1'b0;
            done_o                 <= 1'b0;
            pass_o                 <= 1'b0;
            fail_o                 <= 1'b0;
            mismatch_index_o       <= '0;
            mismatch_observed_o    <= '0;
            mismatch_expected_o    <= '0;
            core_error_code_o      <= '0;
        end else begin
            done_o <= 1'b0;

            if (core_error_valid) begin
                mismatch_q        <= 1'b1;
                core_error_code_o <= core_error_code;
            end

            if (core_out_valid) begin
                if ((core_out_data !=
                     expected_ciphertext_byte(ciphertext_index_q)) &&
                    !mismatch_q) begin
                    mismatch_q          <= 1'b1;
                    mismatch_index_o    <= {1'b0, ciphertext_index_q};
                    mismatch_observed_o <= core_out_data;
                    mismatch_expected_o <=
                        expected_ciphertext_byte(ciphertext_index_q);
                end

                if ((ciphertext_index_q == 5'd23) && !core_out_last &&
                    !mismatch_q) begin
                    mismatch_q          <= 1'b1;
                    mismatch_index_o    <= 6'd23;
                    mismatch_observed_o <= 8'h00;
                    mismatch_expected_o <= 8'h01;
                end

                ciphertext_index_q <= ciphertext_index_q + 1'b1;
            end

            if (core_tag_valid && (core_tag != KAT_TAG_BUS) && !mismatch_q) begin
                mismatch_q          <= 1'b1;
                mismatch_index_o    <= 6'd24;
                mismatch_observed_o <= core_tag[7:0];
                mismatch_expected_o <= KAT_TAG_BUS[7:0];
            end

            case (state_q)
                SELFTEST_IDLE: begin
                    if (start_i) begin
                        input_index_q       <= '0;
                        ciphertext_index_q  <= '0;
                        mismatch_q          <= 1'b0;
                        complete_o          <= 1'b0;
                        pass_o              <= 1'b0;
                        fail_o              <= 1'b0;
                        mismatch_index_o    <= '0;
                        mismatch_observed_o <= '0;
                        mismatch_expected_o <= '0;
                        core_error_code_o   <= '0;
                        state_q             <= SELFTEST_START;
                    end
                end

                SELFTEST_START: begin
                    state_q <= SELFTEST_FEED;
                end

                SELFTEST_FEED: begin
                    if (core_in_valid && core_in_ready) begin
                        if (input_index_q == 6'd47)
                            state_q <= SELFTEST_WAIT;
                        else
                            input_index_q <= input_index_q + 1'b1;
                    end
                end

                SELFTEST_WAIT: begin
                    if (core_done)
                        state_q <= SELFTEST_FINISH;
                end

                SELFTEST_FINISH: begin
                    complete_o <= 1'b1;
                    pass_o     <= !mismatch_q &&
                                  (ciphertext_index_q == 5'd24) &&
                                  (core_error_code_o == 16'h0000);
                    fail_o     <= mismatch_q ||
                                  (ciphertext_index_q != 5'd24) ||
                                  (core_error_code_o != 16'h0000);
                    done_o     <= 1'b1;
                    state_q    <= SELFTEST_IDLE;
                end

                default: state_q <= SELFTEST_IDLE;
            endcase
        end
    end
endmodule
