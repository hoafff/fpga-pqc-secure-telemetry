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

    /*
     * Primer #2 deployment profile:
     *
     *   clear STP header : 24 bytes
     *   ciphertext       : 24 bytes
     *   authentication tag:16 bytes
     *
     *   complete packet  : 64 bytes
     *
     * The public parameters are retained for source compatibility, but the
     * deployed telemetry profile is deliberately fixed to 24-byte telemetry.
     */
    localparam integer STP_HEADER_BYTES    = 24;
    localparam integer STP_TAG_BYTES       = 16;
    localparam integer TELEMETRY_BYTES     = 24;
    localparam integer PROFILE_PACKET_BYTES =
        STP_HEADER_BYTES + TELEMETRY_BYTES + STP_TAG_BYTES;

    localparam logic [15:0] STP_MAGIC   = 16'h5051;
    localparam logic [7:0]  STP_VERSION = 8'h01;

    localparam logic [7:0] STP_TELEMETRY_DATA =
        8'h03;

    localparam logic [7:0] STP_PAYLOAD_FORMAT_TELEMETRY =
        8'h01;


    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PRECHECK,
        ST_CORE_START,
        ST_CORE_FEED,
        ST_CORE_TAG,
        ST_CORE_WAIT
    } state_t;


    state_t state_q;


    /*
     * The deployment endpoint below instantiates this module with
     * MAX_PACKET_BYTES=64 and MAX_PAYLOAD_BYTES=24.
     *
     * That removes the oversized generic buffers from the actual Primer #2
     * implementation while retaining the parameterized interface.
     */
    logic [7:0] packet_q  [0:MAX_PACKET_BYTES-1];
    logic [7:0] release_q [0:MAX_PAYLOAD_BYTES-1];


    logic [7:0] packet_len_q;

    logic [63:0] packet_sequence_q;
    logic [127:0] nonce_q;

    logic [5:0] feed_index_q;
    logic [5:0] release_write_index_q;

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

            /*
             * Must mirror Primer #1 byte packing exactly.
             */
            for (n = 0; n < 8; n = n + 1)
                value[8*n +: 8] =
                    prefix[8*n +: 8];

            for (n = 0; n < 8; n = n + 1)
                value[8*(8+n) +: 8] =
                    sequence_number[63-8*n -: 8];

            build_nonce = value;
        end
    endfunction


    assign ready_o = (state_q == ST_IDLE);
    assign busy_o  = (state_q != ST_IDLE);


    /*
     * Only authenticated telemetry plaintext is exposed.
     *
     * In the deployment build MAX_PAYLOAD_BYTES=24, so this mux is tiny
     * compared with the former 128-byte generic array.
     */
    always_comb begin
        if (release_rd_addr_i < 8'd24)
            release_rd_data_o =
                release_q[release_rd_addr_i];
        else
            release_rd_data_o = 8'h00;
    end


    /*
     * STP header fields have fixed locations.
     */
    always_comb begin

        wire_magic = {
            packet_q[0],
            packet_q[1]
        };

        wire_flags = {
            packet_q[4],
            packet_q[5]
        };

        wire_header_len = {
            packet_q[6],
            packet_q[7]
        };

        wire_session_id = {
            packet_q[8],
            packet_q[9],
            packet_q[10],
            packet_q[11]
        };

        wire_sequence = {
            packet_q[12],
            packet_q[13],
            packet_q[14],
            packet_q[15],
            packet_q[16],
            packet_q[17],
            packet_q[18],
            packet_q[19]
        };

        wire_payload_len = {
            packet_q[20],
            packet_q[21]
        };


        /*
         * IMPORTANT RESOURCE FIX
         * ----------------------
         *
         * Previous RTL:
         *
         *   packet_q[24 + wire_payload_len + i]
         *
         * forced Gowin to build many large variable-index mux networks.
         *
         * The current FPST deployment profile has payload_len=24, therefore
         * tag bytes are always packet offsets 48..63.
         *
         * Byte packing is identical to the previous loop:
         * wire_tag[7:0] is packet byte 48.
         */
        wire_tag = {
            packet_q[63],
            packet_q[62],
            packet_q[61],
            packet_q[60],
            packet_q[59],
            packet_q[58],
            packet_q[57],
            packet_q[56],
            packet_q[55],
            packet_q[54],
            packet_q[53],
            packet_q[52],
            packet_q[51],
            packet_q[50],
            packet_q[49],
            packet_q[48]
        };

    end


    /*
     * Feed exactly:
     *
     *   bytes 0..23  = associated data/header
     *   bytes 24..47 = ciphertext
     *
     * Tag is supplied separately from bytes 48..63.
     */
    assign core_start =
        (state_q == ST_CORE_START) &&
        core_ready;

    assign core_in_valid =
        (state_q == ST_CORE_FEED);

    assign core_in_data =
        packet_q[feed_index_q];

    assign core_in_last =
        (state_q == ST_CORE_FEED) &&
        (feed_index_q == 6'd47);

    assign core_tag_valid =
        (state_q == ST_CORE_TAG);


    /*
     * IMPORTANT RESOURCE FIX
     * ----------------------
     *
     * Primer #2 is RX-only. Do not instantiate ascon_aead_core here because
     * that wrapper contains both encrypt and decrypt engines.
     *
     * Instantiate the decrypt engine directly.
     *
     * MAX_DATA_BYTES is reduced to the deployed 24-byte telemetry profile,
     * which also reduces the internal authenticated quarantine storage.
     */
    ascon_aead_decrypt #(
        .MAX_DATA_BYTES(MAX_PAYLOAD_BYTES)
    ) u_ascon_decrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),

        .start_i        (core_start),
        .ready_o        (core_ready),

        .key_i          (traffic_key_i),
        .nonce_i        (nonce_q),

        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),

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

        .done_o         (core_done),

        .auth_valid_o   (core_auth_valid),
        .auth_ok_o      (core_auth_ok),

        .error_valid_o  (core_error_valid),
        .error_code_o   (core_error_code)
    );


    always_ff @(posedge clk_i) begin

        if (!rst_ni) begin

            state_q <= ST_IDLE;

            packet_len_q <= '0;
            packet_sequence_q <= '0;
            nonce_q <= '0;

            feed_index_q <= '0;
            release_write_index_q <= '0;

            auth_success_seen_q <= 1'b0;

            pending_crypto_error_q <= 1'b0;
            pending_crypto_error_code_q <= ERR_OK;

            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= ERR_OK;

            sequence_commit_o <= 1'b0;
            result_sequence_o <= '0;

            release_valid_o <= 1'b0;
            release_len_o <= '0;

            accepted_count_o <= '0;
            replay_count_o <= '0;
            auth_fail_count_o <= '0;

            consecutive_auth_fail_o <= '0;
            fatal_request_o <= 1'b0;

            for (i = 0; i < MAX_PACKET_BYTES; i = i + 1)
                packet_q[i] <= 8'h00;

            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                release_q[i] <= 8'h00;

        end else begin

            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= ERR_OK;

            sequence_commit_o <= 1'b0;


            /*
             * Endpoint writes one complete BTP STP_RX_PACKET payload while the
             * RX engine is idle.
             */
            if (packet_wr_en_i &&
                (state_q == ST_IDLE) &&
                (packet_wr_addr_i < MAX_PACKET_BYTES)) begin

                packet_q[packet_wr_addr_i] <=
                    packet_wr_data_i;
            end


            case (state_q)

                ST_IDLE: begin

                    if (start_i) begin

                        packet_len_q <= packet_len_i;
                        packet_sequence_q <= '0;
                        nonce_q <= '0;

                        feed_index_q <= '0;
                        release_write_index_q <= '0;

                        auth_success_seen_q <= 1'b0;

                        pending_crypto_error_q <= 1'b0;
                        pending_crypto_error_code_q <= ERR_OK;

                        release_valid_o <= 1'b0;
                        release_len_o <= '0;

                        for (i = 0;
                             i < MAX_PAYLOAD_BYTES;
                             i = i + 1)
                            release_q[i] <= 8'h00;

                        state_q <= ST_PRECHECK;
                    end
                end


                ST_PRECHECK: begin

                    /*
                     * Current deployment accepts only the fixed 64-byte
                     * TELEMETRY_DATA packet.
                     *
                     * Malformed/generic larger packets fail closed.
                     */
                    if (fatal_latched_i ||
                        fatal_request_o) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_SAFE_LOCKED;
                        state_q <= ST_IDLE;

                    end else if (!secure_enable_i) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_SECURE_DISABLED;
                        state_q <= ST_IDLE;

                    end else if (!key_valid_i) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_NO_KEY;
                        state_q <= ST_IDLE;

                    end else if (!session_active_i ||
                                 (session_id_i == 32'h0000_0000)) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_INVALID_STATE;
                        state_q <= ST_IDLE;

                    end else if (packet_len_q != 8'd64) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_LENGTH;
                        state_q <= ST_IDLE;

                    end else if (wire_magic != STP_MAGIC) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_MAGIC;
                        state_q <= ST_IDLE;

                    end else if (packet_q[2] != STP_VERSION) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_VERSION;
                        state_q <= ST_IDLE;

                    end else if (
                        (wire_header_len != 16'd24) ||
                        (wire_flags[15:3] != 13'd0) ||
                        (packet_q[23] != 8'h00) ||
                        (packet_q[3] != STP_TELEMETRY_DATA)
                    ) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_FORMAT;
                        state_q <= ST_IDLE;

                    end else if (wire_payload_len != 16'd24) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_LENGTH;
                        state_q <= ST_IDLE;

                    end else if (
                        (packet_q[22] !=
                            STP_PAYLOAD_FORMAT_TELEMETRY)
                    ) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_STP_FORMAT;
                        state_q <= ST_IDLE;

                    end else if (
                        wire_session_id != session_id_i
                    ) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_SESSION_MISMATCH;

                        result_sequence_o <=
                            expected_sequence_i;

                        state_q <= ST_IDLE;

                    end else if (
                        wire_sequence < expected_sequence_i
                    ) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_REPLAY;

                        result_sequence_o <=
                            expected_sequence_i;

                        replay_count_o <=
                            replay_count_o + 1'b1;

                        state_q <= ST_IDLE;

                    end else if (
                        wire_sequence > expected_sequence_i
                    ) begin

                        done_o <= 1'b1;
                        error_valid_o <= 1'b1;
                        error_code_o <= ERR_SEQUENCE_GAP;

                        result_sequence_o <=
                            expected_sequence_i;

                        state_q <= ST_IDLE;

                    end else begin

                        packet_sequence_q <=
                            wire_sequence;

                        nonce_q <=
                            build_nonce(
                                nonce_prefix_i,
                                wire_sequence
                            );

                        result_sequence_o <=
                            wire_sequence;

                        feed_index_q <= '0;

                        state_q <= ST_CORE_START;
                    end
                end


                ST_CORE_START: begin

                    if (core_ready)
                        state_q <= ST_CORE_FEED;

                end


                ST_CORE_FEED: begin

                    if (core_in_valid &&
                        core_in_ready) begin

                        if (feed_index_q == 6'd47) begin

                            feed_index_q <= '0;
                            state_q <= ST_CORE_TAG;

                        end else begin

                            feed_index_q <=
                                feed_index_q + 1'b1;

                        end
                    end
                end


                ST_CORE_TAG: begin

                    if (core_tag_valid &&
                        core_tag_ready) begin

                        state_q <= ST_CORE_WAIT;
                    end
                end


                ST_CORE_WAIT: begin

                    /*
                     * ascon_aead_decrypt asserts auth_valid before authenticated
                     * plaintext is released.
                     */
                    if (core_auth_valid) begin

                        if (core_auth_ok) begin

                            auth_success_seen_q <= 1'b1;

                        end else begin

                            auth_success_seen_q <= 1'b0;

                            auth_fail_count_o <=
                                auth_fail_count_o + 1'b1;

                            pending_crypto_error_q <=
                                1'b1;

                            if (consecutive_auth_fail_o >=
                                2'd2) begin

                                consecutive_auth_fail_o <=
                                    2'd3;

                                pending_crypto_error_code_q <=
                                    ERR_AUTH_THRESHOLD;

                                fatal_request_o <=
                                    1'b1;

                            end else begin

                                consecutive_auth_fail_o <=
                                    consecutive_auth_fail_o +
                                    1'b1;

                                pending_crypto_error_code_q <=
                                    ERR_AUTH_TAG;

                            end
                        end
                    end


                    if (core_error_valid) begin

                        pending_crypto_error_q <=
                            1'b1;

                        if (core_error_code !=
                            ERR_AUTH_TAG) begin

                            pending_crypto_error_code_q <=
                                core_error_code;
                        end
                    end


                    /*
                     * The decrypt core itself quarantines plaintext until tag
                     * verification succeeds. Only authenticated output reaches
                     * this second small release buffer.
                     */
                    if (core_out_valid) begin

                        if (release_write_index_q <
                            6'd24) begin

                            release_q[
                                release_write_index_q
                            ] <= core_out_data;

                            release_write_index_q <=
                                release_write_index_q +
                                1'b1;

                        end else begin

                            pending_crypto_error_q <=
                                1'b1;

                            pending_crypto_error_code_q <=
                                ERR_ASCON_LENGTH;
                        end
                    end


                    if (core_done) begin

                        if (pending_crypto_error_q ||
                            !auth_success_seen_q) begin

                            done_o <= 1'b1;
                            error_valid_o <= 1'b1;

                            error_code_o <=
                                pending_crypto_error_q
                                ? pending_crypto_error_code_q
                                : ERR_AUTH_TAG;

                            release_valid_o <= 1'b0;
                            release_len_o <= '0;

                            for (i = 0;
                                 i < MAX_PAYLOAD_BYTES;
                                 i = i + 1)
                                release_q[i] <= 8'h00;

                        end else if (
                            release_write_index_q != 6'd24
                        ) begin

                            done_o <= 1'b1;
                            error_valid_o <= 1'b1;
                            error_code_o <= ERR_ASCON_LENGTH;

                            release_valid_o <= 1'b0;
                            release_len_o <= '0;

                            for (i = 0;
                                 i < MAX_PAYLOAD_BYTES;
                                 i = i + 1)
                                release_q[i] <= 8'h00;

                        end else begin

                            release_valid_o <= 1'b1;
                            release_len_o <= 8'd24;

                            result_sequence_o <=
                                packet_sequence_q;

                            sequence_commit_o <= 1'b1;

                            accepted_count_o <=
                                accepted_count_o + 1'b1;

                            consecutive_auth_fail_o <= '0;

                            done_o <= 1'b1;

                        end

                        state_q <= ST_IDLE;
                    end
                end


                default: begin
                    state_q <= ST_IDLE;
                end

            endcase


            /*
             * Secure zeroize.
             */
            if (zeroize_i) begin

                state_q <= ST_IDLE;

                packet_len_q <= '0;
                packet_sequence_q <= '0;
                nonce_q <= '0;

                feed_index_q <= '0;
                release_write_index_q <= '0;

                auth_success_seen_q <= 1'b0;

                pending_crypto_error_q <= 1'b0;
                pending_crypto_error_code_q <= ERR_OK;

                done_o <= 1'b0;
                error_valid_o <= 1'b0;
                error_code_o <= ERR_OK;

                sequence_commit_o <= 1'b0;
                result_sequence_o <= '0;

                release_valid_o <= 1'b0;
                release_len_o <= '0;

                accepted_count_o <= '0;
                replay_count_o <= '0;
                auth_fail_count_o <= '0;

                consecutive_auth_fail_o <= '0;
                fatal_request_o <= 1'b0;

                for (i = 0;
                     i < MAX_PACKET_BYTES;
                     i = i + 1)
                    packet_q[i] <= 8'h00;

                for (i = 0;
                     i < MAX_PAYLOAD_BYTES;
                     i = i + 1)
                    release_q[i] <= 8'h00;

            end
        end
    end


`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin

        if (rst_ni && !zeroize_i) begin

            if (sequence_commit_o)
                assert (release_valid_o)
                    else $error(
                        "primer2_stp_rx: sequence commit without authenticated release"
                    );

            if (release_valid_o)
                assert (
                    session_active_i &&
                    key_valid_i &&
                    secure_enable_i
                )
                    else $error(
                        "primer2_stp_rx: plaintext release outside active secure session"
                    );
        end
    end
`endif


    /*
     * Keep otherwise informational core signal connected without changing
     * the hardware protocol.
     */
    logic unused_core_out_last;
    always_comb unused_core_out_last = core_out_last;

endmodule