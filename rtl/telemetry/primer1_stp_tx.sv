module primer1_stp_tx (
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
    input  logic [63:0]  tx_sequence_i,

    input  logic         start_i,
    input  logic [191:0] telemetry_record_i,
    output logic         ready_o,
    output logic         busy_o,
    output logic         done_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o,

    output logic         retained_valid_o,
    output logic [63:0]  retained_sequence_o,
    output logic [6:0]   retained_len_o,
    input  logic [5:0]   packet_rd_addr_i,
    output logic [7:0]   packet_rd_data_o,

    /* Assert only after receiver COMMIT_ACCEPTED/reconciliation. */
    input  logic         packet_commit_i,
    output logic         sequence_commit_o
);
    import fpst_btp_pkg::*;

    localparam integer STP_HEADER_BYTES = 24;
    localparam integer TELEMETRY_BYTES = 24;
    localparam integer TAG_BYTES = 16;
    localparam integer PACKET_BYTES = STP_HEADER_BYTES + TELEMETRY_BYTES + TAG_BYTES;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_START_CORE,
        ST_FEED,
        ST_WAIT_CRYPTO,
        ST_WAIT_DONE
    } state_t;

    state_t state_q;
    logic [7:0] packet_q [0:PACKET_BYTES-1];
    logic [191:0] sample_q;
    logic [127:0] key_q;
    logic [127:0] nonce_q;
    logic [5:0] feed_index_q;
    logic [5:0] ciphertext_index_q;

    logic core_start;
    logic core_ready;
    logic core_in_valid;
    logic core_in_ready;
    logic [7:0] core_in_data;
    logic core_in_last;
    logic core_out_valid;
    logic [7:0] core_out_data;
    logic core_out_last;
    logic core_tag_valid;
    logic [127:0] core_tag;
    logic core_done;
    logic core_error_valid;
    logic [15:0] core_error_code;

    integer i;

    function automatic logic [7:0] sample_byte(
        input logic [191:0] sample,
        input integer index
    );
        sample_byte = sample[8*index +: 8];
    endfunction

    function automatic logic [31:0] sample_be32(
        input logic [191:0] sample,
        input integer index
    );
        sample_be32 = {
            sample[8*index +: 8],
            sample[8*(index+1) +: 8],
            sample[8*(index+2) +: 8],
            sample[8*(index+3) +: 8]
        };
    endfunction

    function automatic logic [127:0] build_nonce(
        input logic [63:0] prefix,
        input logic [63:0] sequence_number
    );
        logic [127:0] value;
        integer n;
        begin
            value = '0;
            /* prefix is stored with wire byte 0 at bits [7:0]. */
            for (n = 0; n < 8; n = n + 1)
                value[8*n +: 8] = prefix[8*n +: 8];
            /* Sequence is an integer; serialize it big-endian into nonce bytes 8..15. */
            for (n = 0; n < 8; n = n + 1)
                value[8*(8+n) +: 8] = sequence_number[63-8*n -: 8];
            build_nonce = value;
        end
    endfunction

    assign packet_rd_data_o = packet_q[packet_rd_addr_i];
    assign retained_len_o = retained_valid_o ? 7'd64 : 7'd0;
    assign ready_o = (state_q == ST_IDLE) && !retained_valid_o;
    assign busy_o = (state_q != ST_IDLE);

    assign core_start = (state_q == ST_START_CORE);
    assign core_in_valid = (state_q == ST_FEED);
    assign core_in_data = (feed_index_q < STP_HEADER_BYTES)
                        ? packet_q[feed_index_q]
                        : sample_q[8*(feed_index_q-STP_HEADER_BYTES) +: 8];
    assign core_in_last = (state_q == ST_FEED) &&
                          (feed_index_q == (STP_HEADER_BYTES + TELEMETRY_BYTES - 1));

    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(128)
    ) u_ascon_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .start_i        (core_start),
        .ready_o        (core_ready),
        .key_i          (key_q),
        .nonce_i        (nonce_q),
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
            state_q <= ST_IDLE;
            sample_q <= '0;
            key_q <= '0;
            nonce_q <= '0;
            feed_index_q <= '0;
            ciphertext_index_q <= '0;
            retained_valid_o <= 1'b0;
            retained_sequence_o <= '0;
            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= ERR_OK;
            sequence_commit_o <= 1'b0;
            for (i = 0; i < PACKET_BYTES; i = i + 1)
                packet_q[i] <= 8'h00;
        end else begin
            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= ERR_OK;
            sequence_commit_o <= 1'b0;

            if (packet_commit_i && retained_valid_o && session_active_i && key_valid_i) begin
                retained_valid_o <= 1'b0;
                retained_sequence_o <= '0;
                sequence_commit_o <= 1'b1;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_q[i] <= 8'h00;
            end

            /* Session invalidation destroys any retained packet. */
            if (retained_valid_o && (!session_active_i || !key_valid_i)) begin
                retained_valid_o <= 1'b0;
                retained_sequence_o <= '0;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_q[i] <= 8'h00;
            end

            /*
             * Ascon is a streaming producer.  A full 16-byte plaintext block can
             * be emitted while this wrapper is still feeding later plaintext
             * bytes.  Capture every accepted output beat for the entire active
             * transaction; waiting until ST_WAIT_CRYPTO would drop early blocks.
             */
            if (core_out_valid && (state_q != ST_IDLE)) begin
                if (ciphertext_index_q < TELEMETRY_BYTES) begin
                    packet_q[STP_HEADER_BYTES + ciphertext_index_q] <= core_out_data;
                    ciphertext_index_q <= ciphertext_index_q + 1'b1;
                end else begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_ASCON_LENGTH;
                end
            end

            if (core_error_valid && (state_q != ST_IDLE)) begin
                state_q <= ST_IDLE;
                sample_q <= '0;
                key_q <= '0;
                nonce_q <= '0;
                feed_index_q <= '0;
                ciphertext_index_q <= '0;
                error_valid_o <= 1'b1;
                error_code_o <= core_error_code;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_q[i] <= 8'h00;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i) begin
                            if (retained_valid_o) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_BUSY;
                            end else if (fatal_latched_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_SAFE_LOCKED;
                            end else if (!secure_enable_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_SECURE_DISABLED;
                            end else if (!key_valid_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_NO_KEY;
                            end else if (!session_active_i || (session_id_i == 32'h0)) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_INVALID_STATE;
                            end else if (sample_be32(telemetry_record_i, 16) > 32'd100000) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_PAYLOAD_RANGE;
                            end else begin
                                sample_q <= telemetry_record_i;
                                key_q <= traffic_key_i;
                                nonce_q <= build_nonce(nonce_prefix_i, tx_sequence_i);
                                retained_sequence_o <= tx_sequence_i;
                                feed_index_q <= '0;
                                ciphertext_index_q <= '0;

                                /* STP v1 fixed 24-byte clear header, wire big-endian. */
                                packet_q[0] <= 8'h50;
                                packet_q[1] <= 8'h51;
                                packet_q[2] <= 8'h01;
                                packet_q[3] <= 8'h03;
                                packet_q[4] <= 8'h00;
                                packet_q[5] <= 8'h00;
                                packet_q[6] <= 8'h00;
                                packet_q[7] <= 8'h18;
                                packet_q[8] <= session_id_i[31:24];
                                packet_q[9] <= session_id_i[23:16];
                                packet_q[10] <= session_id_i[15:8];
                                packet_q[11] <= session_id_i[7:0];
                                packet_q[12] <= tx_sequence_i[63:56];
                                packet_q[13] <= tx_sequence_i[55:48];
                                packet_q[14] <= tx_sequence_i[47:40];
                                packet_q[15] <= tx_sequence_i[39:32];
                                packet_q[16] <= tx_sequence_i[31:24];
                                packet_q[17] <= tx_sequence_i[23:16];
                                packet_q[18] <= tx_sequence_i[15:8];
                                packet_q[19] <= tx_sequence_i[7:0];
                                packet_q[20] <= 8'h00;
                                packet_q[21] <= 8'h18;
                                packet_q[22] <= 8'h01;
                                packet_q[23] <= 8'h00;
                                state_q <= ST_START_CORE;
                            end
                        end
                    end

                    ST_START_CORE: begin
                        if (core_ready)
                            state_q <= ST_FEED;
                    end

                    ST_FEED: begin
                        if (core_in_valid && core_in_ready) begin
                            if (feed_index_q == 6'd47) begin
                                feed_index_q <= '0;
                                state_q <= ST_WAIT_CRYPTO;
                            end else begin
                                feed_index_q <= feed_index_q + 1'b1;
                            end
                        end
                    end

                    ST_WAIT_CRYPTO: begin
                        if (core_tag_valid) begin
                            for (i = 0; i < TAG_BYTES; i = i + 1)
                                packet_q[STP_HEADER_BYTES + TELEMETRY_BYTES + i] <=
                                    core_tag[8*i +: 8];
                            state_q <= ST_WAIT_DONE;
                        end
                    end

                    ST_WAIT_DONE: begin
                        if (core_done) begin
                            if (ciphertext_index_q != TELEMETRY_BYTES) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_ASCON_LENGTH;
                                retained_sequence_o <= '0;
                                for (i = 0; i < PACKET_BYTES; i = i + 1)
                                    packet_q[i] <= 8'h00;
                            end else begin
                                retained_valid_o <= 1'b1;
                                done_o <= 1'b1;
                            end
                            sample_q <= '0;
                            key_q <= '0;
                            nonce_q <= '0;
                            state_q <= ST_IDLE;
                        end
                    end

                    default: state_q <= ST_IDLE;
                endcase
            end

            if (zeroize_i) begin
                state_q <= ST_IDLE;
                sample_q <= '0;
                key_q <= '0;
                nonce_q <= '0;
                feed_index_q <= '0;
                ciphertext_index_q <= '0;
                retained_valid_o <= 1'b0;
                retained_sequence_o <= '0;
                done_o <= 1'b0;
                error_valid_o <= 1'b0;
                error_code_o <= ERR_OK;
                sequence_commit_o <= 1'b0;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_q[i] <= 8'h00;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && retained_valid_o) begin
            assert (retained_len_o == 7'd64)
                else $error("primer1_stp_tx: retained packet length changed");
        end
        if (rst_ni && core_out_valid) begin
            assert (ciphertext_index_q < TELEMETRY_BYTES)
                else $error("primer1_stp_tx: ciphertext overflow");
        end
        if (rst_ni && core_tag_valid) begin
            assert (ciphertext_index_q == TELEMETRY_BYTES)
                else $error("primer1_stp_tx: tag arrived before all ciphertext bytes");
        end
        if (rst_ni && sequence_commit_o) begin
            assert (!retained_valid_o)
                else $error("primer1_stp_tx: retained packet not released on commit");
        end
    end
`endif

    logic unused_core_out_last;
    always_comb unused_core_out_last = core_out_last;
endmodule
