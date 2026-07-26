module primer2_stp_rx #(
    parameter integer MAX_PAYLOAD_BYTES = 128,
    parameter integer MAX_PACKET_BYTES = 168
) (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         secure_enable_i,
    input  logic         fatal_latched_i,
    input  logic         key_valid_i,
    input  logic         session_active_i,
    input  logic [31:0]  session_id_i,
    input  logic [127:0] traffic_key_i,
    input  logic [63:0]  nonce_prefix_i,
    input  logic [63:0]  expected_sequence_i,

    input  logic         packet_wr_en_i,
    input  logic [7:0]   packet_wr_addr_i,
    input  logic [7:0]   packet_wr_data_i,
    input  logic [7:0]   packet_len_i,
    input  logic         start_i,
    output logic         ready_o,
    output logic         busy_o,
    output logic         done_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o,

    output logic         sequence_commit_o,
    output logic [63:0]  result_sequence_o,
    output logic         release_valid_o,
    output logic [7:0]   release_len_o,
    input  logic [7:0]   release_rd_addr_i,
    output logic [7:0]   release_rd_data_o,

    output logic [31:0]  accepted_count_o,
    output logic [31:0]  replay_count_o,
    output logic [31:0]  auth_fail_count_o,
    output logic [1:0]   consecutive_auth_fail_o,
    output logic         fatal_request_o
);
    import fpst_btp_pkg::*;

    localparam integer STP_HEADER_BYTES = 24;
    localparam integer STP_TAG_BYTES = 16;
    localparam logic [15:0] STP_MAGIC = 16'h5051;
    localparam logic [7:0]  STP_VERSION = 8'h01;
    localparam logic [7:0]  STP_TELEMETRY_DATA = 8'h03;
    localparam logic [7:0]  STP_PAYLOAD_FORMAT_TELEMETRY = 8'h01;
    localparam integer TELEMETRY_BYTES = 24;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PRECHECK,
        ST_CORE_START,
        ST_CORE_FEED,
        ST_CORE_TAG,
        ST_CORE_WAIT
    } state_t;

    state_t state_q;
    logic [7:0] packet_q [0:MAX_PACKET_BYTES-1];
    logic [7:0] release_q [0:MAX_PAYLOAD_BYTES-1];

    logic [7:0] packet_len_q;
    logic [15:0] payload_len_q;
    logic [63:0] packet_sequence_q;
    logic [127:0] nonce_q;
    logic [7:0] feed_index_q;
    logic [7:0] release_write_index_q;
    logic auth_success_seen_q;
    logic pending_crypto_error_q;
    logic [15:0] pending_crypto_error_code_q;

    logic [15:0] wire_magic;
    logic [15:0] wire_flags;
    logic [15:0] wire_header_len;
    logic [31:0] wire_session_id;
    logic [63:0] wire_sequence;
    logic [15:0] wire_payload_len;
    logic [127:0] wire_tag;
    logic [15:0] expected_packet_len;

    logic core_start;
    logic core_ready;
    logic core_in_valid;
    logic core_in_ready;
    logic [7:0] core_in_data;
    logic core_in_last;
    logic core_tag_valid;
    logic core_tag_ready;
    logic core_out_valid;
    logic [7:0] core_out_data;
    logic core_out_last;
    logic core_done;
    logic core_auth_valid;
    logic core_auth_ok;
    logic core_error_valid;
    logic [15:0] core_error_code;

    integer i;

    function automatic logic [127:0] build_nonce(
        input logic [63:0] prefix,
        input logic [63:0] sequence_number
    );
        logic [127:0] value;
        integer n;
        begin
            value = '0;
            /* Prefix storage and nonce byte packing mirror Primer #1 exactly. */
            for (n = 0; n < 8; n = n + 1)
                value[8*n +: 8] = prefix[8*n +: 8];
            for (n = 0; n < 8; n = n + 1)
                value[8*(8+n) +: 8] = sequence_number[63-8*n -: 8];
            build_nonce = value;
        end
    endfunction

    assign ready_o = (state_q == ST_IDLE);
    assign busy_o = (state_q != ST_IDLE);
    assign release_rd_data_o = release_q[release_rd_addr_i];

    always_comb begin
        wire_magic = {packet_q[0],packet_q[1]};
        wire_flags = {packet_q[4],packet_q[5]};
        wire_header_len = {packet_q[6],packet_q[7]};
        wire_session_id = {packet_q[8],packet_q[9],packet_q[10],packet_q[11]};
        wire_sequence = {
            packet_q[12],packet_q[13],packet_q[14],packet_q[15],
            packet_q[16],packet_q[17],packet_q[18],packet_q[19]
        };
        wire_payload_len = {packet_q[20],packet_q[21]};
        expected_packet_len = STP_HEADER_BYTES + wire_payload_len + STP_TAG_BYTES;
        wire_tag = '0;
        for (i = 0; i < STP_TAG_BYTES; i = i + 1)
            wire_tag[8*i +: 8] = packet_q[STP_HEADER_BYTES + wire_payload_len + i];
    end

    assign core_start = (state_q == ST_CORE_START) && core_ready;
    assign core_in_valid = (state_q == ST_CORE_FEED);
    assign core_in_data = packet_q[feed_index_q];
    assign core_in_last = core_in_valid &&
                          (feed_index_q + 1'b1 == STP_HEADER_BYTES + payload_len_q);
    assign core_tag_valid = (state_q == ST_CORE_TAG);

    ascon_aead_core #(
        .MAX_DATA_BYTES(MAX_PAYLOAD_BYTES)
    ) u_ascon_core (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .mode_decrypt_i (1'b1),
        .start_i        (core_start),
        .ready_o        (core_ready),
        .key_i          (traffic_key_i),
        .nonce_i        (nonce_q),
        .ad_len_i       (16'd24),
        .data_len_i     (payload_len_q),
        .in_valid_i     (core_in_valid),
        .in_ready_o     (core_in_ready),
        .in_data_i      (core_in_data),
        .in_last_i      (core_in_last),
        .tag_valid_i    (core_tag_valid),
        .tag_ready_o    (core_tag_ready),
        .tag_i          (wire_tag),
        .out_valid_o    (core_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (core_out_data),
        .out_last_o     (core_out_last),
        .tag_valid_o    (),
        .tag_ready_i    (1'b1),
        .tag_o          (),
        .done_o         (core_done),
        .auth_valid_o   (core_auth_valid),
        .auth_ok_o      (core_auth_ok),
        .error_valid_o  (core_error_valid),
        .error_code_o   (core_error_code)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q                     <= ST_IDLE;
            packet_len_q                <= '0;
            payload_len_q               <= '0;
            packet_sequence_q           <= '0;
            nonce_q                     <= '0;
            feed_index_q                <= '0;
            release_write_index_q       <= '0;
            auth_success_seen_q          <= 1'b0;
            pending_crypto_error_q       <= 1'b0;
            pending_crypto_error_code_q  <= ERR_OK;
            done_o                      <= 1'b0;
            error_valid_o               <= 1'b0;
            error_code_o                <= ERR_OK;
            sequence_commit_o           <= 1'b0;
            result_sequence_o           <= '0;
            release_valid_o             <= 1'b0;
            release_len_o               <= '0;
            accepted_count_o            <= '0;
            replay_count_o              <= '0;
            auth_fail_count_o           <= '0;
            consecutive_auth_fail_o     <= '0;
            fatal_request_o             <= 1'b0;
            for (i = 0; i < MAX_PACKET_BYTES; i = i + 1)
                packet_q[i] <= 8'h00;
            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                release_q[i] <= 8'h00;
        end else begin
            done_o            <= 1'b0;
            error_valid_o     <= 1'b0;
            error_code_o      <= ERR_OK;
            sequence_commit_o <= 1'b0;

            if (packet_wr_en_i && (state_q == ST_IDLE) &&
                (packet_wr_addr_i < MAX_PACKET_BYTES))
                packet_q[packet_wr_addr_i] <= packet_wr_data_i;

            case (state_q)
                ST_IDLE: begin
                    if (start_i) begin
                        packet_len_q               <= packet_len_i;
                        payload_len_q              <= '0;
                        packet_sequence_q          <= '0;
                        nonce_q                    <= '0;
                        feed_index_q               <= '0;
                        release_write_index_q      <= '0;
                        auth_success_seen_q         <= 1'b0;
                        pending_crypto_error_q      <= 1'b0;
                        pending_crypto_error_code_q <= ERR_OK;
                        release_valid_o            <= 1'b0;
                        release_len_o              <= '0;
                        for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                            release_q[i] <= 8'h00;
                        state_q <= ST_PRECHECK;
                    end
                end

                ST_PRECHECK: begin
                    if (fatal_latched_i || fatal_request_o) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_SAFE_LOCKED;
                        state_q       <= ST_IDLE;
                    end else if (!secure_enable_i) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_SECURE_DISABLED;
                        state_q       <= ST_IDLE;
                    end else if (!key_valid_i) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_NO_KEY;
                        state_q       <= ST_IDLE;
                    end else if (!session_active_i || (session_id_i == 32'h0)) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_INVALID_STATE;
                        state_q       <= ST_IDLE;
                    end else if ((packet_len_q < STP_HEADER_BYTES + STP_TAG_BYTES) ||
                                 (packet_len_q > MAX_PACKET_BYTES)) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_LENGTH;
                        state_q       <= ST_IDLE;
                    end else if (wire_magic != STP_MAGIC) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_MAGIC;
                        state_q       <= ST_IDLE;
                    end else if (packet_q[2] != STP_VERSION) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_VERSION;
                        state_q       <= ST_IDLE;
                    end else if ((wire_header_len != STP_HEADER_BYTES) ||
                                 (wire_flags[15:3] != 0) ||
                                 (packet_q[23] != 8'h00) ||
                                 (packet_q[3] != STP_TELEMETRY_DATA)) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_FORMAT;
                        state_q       <= ST_IDLE;
                    end else if ((wire_payload_len > MAX_PAYLOAD_BYTES) ||
                                 (expected_packet_len != packet_len_q)) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_LENGTH;
                        state_q       <= ST_IDLE;
                    end else if ((packet_q[22] != STP_PAYLOAD_FORMAT_TELEMETRY) ||
                                 (wire_payload_len != TELEMETRY_BYTES)) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_STP_FORMAT;
                        state_q       <= ST_IDLE;
                    end else if (wire_session_id != session_id_i) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_SESSION_MISMATCH;
                        result_sequence_o <= expected_sequence_i;
                        state_q       <= ST_IDLE;
                    end else if (wire_sequence < expected_sequence_i) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_REPLAY;
                        result_sequence_o <= expected_sequence_i;
                        replay_count_o <= replay_count_o + 1'b1;
                        state_q       <= ST_IDLE;
                    end else if (wire_sequence > expected_sequence_i) begin
                        done_o        <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_SEQUENCE_GAP;
                        result_sequence_o <= expected_sequence_i;
                        state_q       <= ST_IDLE;
                    end else begin
                        payload_len_q     <= wire_payload_len;
                        packet_sequence_q <= wire_sequence;
                        nonce_q           <= build_nonce(nonce_prefix_i,wire_sequence);
                        result_sequence_o <= wire_sequence;
                        feed_index_q      <= '0;
                        state_q           <= ST_CORE_START;
                    end
                end

                ST_CORE_START: begin
                    if (core_ready)
                        state_q <= ST_CORE_FEED;
                end

                ST_CORE_FEED: begin
                    if (core_in_valid && core_in_ready) begin
                        if (feed_index_q + 1'b1 == STP_HEADER_BYTES + payload_len_q) begin
                            feed_index_q <= '0;
                            state_q <= ST_CORE_TAG;
                        end else begin
                            feed_index_q <= feed_index_q + 1'b1;
                        end
                    end
                end

                ST_CORE_TAG: begin
                    if (core_tag_valid && core_tag_ready)
                        state_q <= ST_CORE_WAIT;
                end

                ST_CORE_WAIT: begin
                    if (core_auth_valid) begin
                        if (core_auth_ok) begin
                            auth_success_seen_q <= 1'b1;
                        end else begin
                            auth_success_seen_q <= 1'b0;
                            auth_fail_count_o <= auth_fail_count_o + 1'b1;
                            pending_crypto_error_q <= 1'b1;
                            if (consecutive_auth_fail_o >= 2) begin
                                consecutive_auth_fail_o <= 2'd3;
                                pending_crypto_error_code_q <= ERR_AUTH_THRESHOLD;
                                fatal_request_o <= 1'b1;
                            end else begin
                                consecutive_auth_fail_o <= consecutive_auth_fail_o + 1'b1;
                                pending_crypto_error_code_q <= ERR_AUTH_TAG;
                            end
                        end
                    end

                    if (core_error_valid) begin
                        pending_crypto_error_q <= 1'b1;
                        if (core_error_code != ERR_AUTH_TAG)
                            pending_crypto_error_code_q <= core_error_code;
                    end

                    if (core_out_valid) begin
                        if (release_write_index_q < MAX_PAYLOAD_BYTES) begin
                            release_q[release_write_index_q] <= core_out_data;
                            release_write_index_q <= release_write_index_q + 1'b1;
                        end else begin
                            pending_crypto_error_q <= 1'b1;
                            pending_crypto_error_code_q <= ERR_ASCON_LENGTH;
                        end
                    end

                    if (core_done) begin
                        if (pending_crypto_error_q || !auth_success_seen_q) begin
                            done_o        <= 1'b1;
                            error_valid_o <= 1'b1;
                            error_code_o  <= pending_crypto_error_q
                                           ? pending_crypto_error_code_q : ERR_AUTH_TAG;
                            release_valid_o <= 1'b0;
                            release_len_o   <= '0;
                            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                                release_q[i] <= 8'h00;
                        end else if (release_write_index_q != payload_len_q) begin
                            done_o        <= 1'b1;
                            error_valid_o <= 1'b1;
                            error_code_o  <= ERR_ASCON_LENGTH;
                            release_valid_o <= 1'b0;
                            release_len_o   <= '0;
                            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                                release_q[i] <= 8'h00;
                        end else begin
                            release_valid_o         <= 1'b1;
                            release_len_o           <= payload_len_q[7:0];
                            result_sequence_o       <= packet_sequence_q;
                            sequence_commit_o       <= 1'b1;
                            accepted_count_o        <= accepted_count_o + 1'b1;
                            consecutive_auth_fail_o <= '0;
                            done_o                  <= 1'b1;
                        end
                        state_q <= ST_IDLE;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase

            if (zeroize_i) begin
                state_q                     <= ST_IDLE;
                packet_len_q                <= '0;
                payload_len_q               <= '0;
                packet_sequence_q           <= '0;
                nonce_q                     <= '0;
                feed_index_q                <= '0;
                release_write_index_q       <= '0;
                auth_success_seen_q          <= 1'b0;
                pending_crypto_error_q       <= 1'b0;
                pending_crypto_error_code_q  <= ERR_OK;
                done_o                      <= 1'b0;
                error_valid_o               <= 1'b0;
                error_code_o                <= ERR_OK;
                sequence_commit_o           <= 1'b0;
                result_sequence_o           <= '0;
                release_valid_o             <= 1'b0;
                release_len_o               <= '0;
                accepted_count_o            <= '0;
                replay_count_o              <= '0;
                auth_fail_count_o           <= '0;
                consecutive_auth_fail_o     <= '0;
                fatal_request_o             <= 1'b0;
                for (i = 0; i < MAX_PACKET_BYTES; i = i + 1)
                    packet_q[i] <= 8'h00;
                for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                    release_q[i] <= 8'h00;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && !zeroize_i) begin
            if (sequence_commit_o)
                assert (release_valid_o)
                    else $error("primer2_stp_rx: sequence commit without authenticated release");
            if (release_valid_o)
                assert (session_active_i && key_valid_i && secure_enable_i)
                    else $error("primer2_stp_rx: plaintext release outside active secure session");
        end
    end
`endif
endmodule
