module primer1_telemetry_tx (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         start_i,
    input  logic [191:0] telemetry_i,
    input  logic [15:0]  stp_flags_i,

    input  logic         secure_enable_i,
    input  logic         key_valid_i,
    input  logic         session_active_i,
    input  logic [31:0]  session_id_i,
    input  logic [127:0] traffic_key_i,
    input  logic [63:0]  nonce_prefix_i,
    input  logic [63:0]  tx_sequence_i,

    input  logic         release_retained_i,

    input  logic [6:0]   packet_raddr_i,
    output logic [7:0]   packet_rdata_o,
    output logic [6:0]   packet_len_o,
    output logic         retained_valid_o,
    output logic [63:0]  retained_sequence_o,

    output logic         busy_o,
    output logic         done_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [15:0] ERR_BUSY            = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE   = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY          = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED = 16'h0304;
    localparam logic [15:0] ERR_ASCON_TIMEOUT   = 16'h0503;

    localparam integer PACKET_BYTES = 64;
    localparam integer ASCON_TIMEOUT_CYCLES = 27_000_000 / 20; /* 50 ms */

    typedef enum logic [2:0] {
        TX_IDLE,
        TX_CORE_START,
        TX_FEED,
        TX_WAIT,
        TX_COMPLETE,
        TX_ERROR
    } tx_state_t;

    tx_state_t state_q;

    logic [7:0] packet_mem [0:PACKET_BYTES-1];
    logic [191:0] header_bus;
    logic [191:0] telemetry_q;
    logic [47:0]  feed_index_q;
    logic [4:0]   ciphertext_index_q;
    logic [31:0]  timeout_count_q;
    logic [127:0] nonce_bus;

    logic core_start;
    logic core_ready;
    logic core_in_valid;
    logic core_in_ready;
    logic [7:0] core_in_data;
    logic core_in_last;
    logic core_out_valid;
    logic [7:0] core_out_data;
    logic core_tag_valid;
    logic [127:0] core_tag;
    logic core_done;
    logic core_error_valid;
    logic [15:0] core_error_code;

    integer i;

    stp_v1_header_builder u_header (
        .flags_i      (stp_flags_i),
        .session_id_i (session_id_i),
        .sequence_i   (tx_sequence_i),
        .header_o     (header_bus)
    );

    always_comb begin
        nonce_bus = '0;
        for (i = 0; i < 8; i = i + 1)
            nonce_bus[8*i +: 8] = nonce_prefix_i[8*i +: 8];
        nonce_bus[8*8  +: 8] = tx_sequence_i[63:56];
        nonce_bus[8*9  +: 8] = tx_sequence_i[55:48];
        nonce_bus[8*10 +: 8] = tx_sequence_i[47:40];
        nonce_bus[8*11 +: 8] = tx_sequence_i[39:32];
        nonce_bus[8*12 +: 8] = tx_sequence_i[31:24];
        nonce_bus[8*13 +: 8] = tx_sequence_i[23:16];
        nonce_bus[8*14 +: 8] = tx_sequence_i[15:8];
        nonce_bus[8*15 +: 8] = tx_sequence_i[7:0];
    end

    assign packet_rdata_o = (packet_raddr_i < PACKET_BYTES) ?
                            packet_mem[packet_raddr_i] : 8'h00;
    assign packet_len_o = retained_valid_o ? 7'd64 : 7'd0;
    assign busy_o = (state_q != TX_IDLE);

    assign core_start = (state_q == TX_CORE_START);
    assign core_in_valid = (state_q == TX_FEED);
    assign core_in_data = (feed_index_q < 48'd24)
        ? header_bus[8*feed_index_q[4:0] +: 8]
        : telemetry_q[8*(feed_index_q[4:0] - 5'd24) +: 8];
    assign core_in_last = (feed_index_q == 48'd47);

    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(128)
    ) u_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .start_i        (core_start),
        .ready_o        (core_ready),
        .key_i          (traffic_key_i),
        .nonce_i        (nonce_bus),
        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),
        .in_valid_i     (core_in_valid),
        .in_ready_o     (core_in_ready),
        .in_data_i      (core_in_data),
        .in_last_i      (core_in_last),
        .out_valid_o    (core_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (core_out_data),
        .out_last_o     (),
        .tag_valid_o    (core_tag_valid),
        .tag_ready_i    (1'b1),
        .tag_o          (core_tag),
        .done_o         (core_done),
        .error_valid_o  (core_error_valid),
        .error_code_o   (core_error_code)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            state_q               <= TX_IDLE;
            telemetry_q           <= '0;
            feed_index_q          <= '0;
            ciphertext_index_q    <= '0;
            timeout_count_q       <= '0;
            retained_valid_o      <= 1'b0;
            retained_sequence_o   <= '0;
            done_o                <= 1'b0;
            error_valid_o         <= 1'b0;
            error_code_o          <= 16'h0000;
            for (i = 0; i < PACKET_BYTES; i = i + 1)
                packet_mem[i] <= 8'h00;
        end else begin
            done_o        <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            if (release_retained_i) begin
                retained_valid_o    <= 1'b0;
                retained_sequence_o <= '0;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_mem[i] <= 8'h00;
            end

            if ((state_q != TX_IDLE) && (timeout_count_q < ASCON_TIMEOUT_CYCLES))
                timeout_count_q <= timeout_count_q + 32'd1;

            if ((state_q != TX_IDLE) &&
                (timeout_count_q >= ASCON_TIMEOUT_CYCLES-1)) begin
                state_q       <= TX_ERROR;
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_ASCON_TIMEOUT;
            end else if (core_error_valid) begin
                state_q       <= TX_ERROR;
                error_valid_o <= 1'b1;
                error_code_o  <= core_error_code;
            end else begin
                if (core_out_valid && (ciphertext_index_q < 5'd24)) begin
                    packet_mem[24 + ciphertext_index_q] <= core_out_data;
                    ciphertext_index_q <= ciphertext_index_q + 5'd1;
                end

                if (core_tag_valid) begin
                    for (i = 0; i < 16; i = i + 1)
                        packet_mem[48 + i] <= core_tag[8*i +: 8];
                end

                case (state_q)
                    TX_IDLE: begin
                        timeout_count_q <= '0;
                        if (start_i) begin
                            if (retained_valid_o) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_BUSY;
                            end else if (!secure_enable_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_SECURE_DISABLED;
                            end else if (!key_valid_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_NO_KEY;
                            end else if (!session_active_i || !core_ready) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_INVALID_STATE;
                            end else begin
                                telemetry_q        <= telemetry_i;
                                feed_index_q       <= '0;
                                ciphertext_index_q <= '0;
                                retained_sequence_o <= tx_sequence_i;
                                for (i = 0; i < 24; i = i + 1)
                                    packet_mem[i] <= header_bus[8*i +: 8];
                                state_q <= TX_CORE_START;
                            end
                        end
                    end

                    TX_CORE_START: begin
                        state_q <= TX_FEED;
                    end

                    TX_FEED: begin
                        if (core_in_valid && core_in_ready) begin
                            if (feed_index_q == 48'd47)
                                state_q <= TX_WAIT;
                            else
                                feed_index_q <= feed_index_q + 48'd1;
                        end
                    end

                    TX_WAIT: begin
                        if (core_done) begin
                            if (ciphertext_index_q == 5'd24) begin
                                retained_valid_o <= 1'b1;
                                state_q <= TX_COMPLETE;
                            end else begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_INVALID_STATE;
                                state_q <= TX_ERROR;
                            end
                        end
                    end

                    TX_COMPLETE: begin
                        done_o  <= 1'b1;
                        state_q <= TX_IDLE;
                    end

                    TX_ERROR: begin
                        /* Do not expose a partial packet after a failed AEAD. */
                        retained_valid_o    <= 1'b0;
                        retained_sequence_o <= '0;
                        telemetry_q         <= '0;
                        for (i = 0; i < PACKET_BYTES; i = i + 1)
                            packet_mem[i] <= 8'h00;
                        state_q <= TX_IDLE;
                    end

                    default: state_q <= TX_ERROR;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && !zeroize_i) begin
            assert (!retained_valid_o || (packet_len_o == 7'd64))
                else $error("primer1_telemetry_tx: invalid retained packet length");
        end
    end
`endif
endmodule
