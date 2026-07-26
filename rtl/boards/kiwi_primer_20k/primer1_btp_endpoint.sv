// Kiwi Primer 20K #1 deployment endpoint for FPST-SYS-SPEC-001 v1.1.
//
// This block owns the BTP frame parser/CRC32, duplicate-response cache,
// atomic TX session loading, forward-NTT command adapter, and STP telemetry
// encryption path.  Physical SPI shifting is isolated in btp_spi_slave.sv.
//
// IMPORTANT deployment rule: malformed BTP frames (bad SOF/version/reserved,
// impossible length, bad CRC) are rejected without side effects and without a
// response.  The MCU times out and retries.  Valid frames always receive a BTP
// response, including explicit errors for unsupported/unavailable operations.
module primer1_btp_endpoint #(
    parameter integer MAX_PAYLOAD_BYTES   = 1024,
    parameter integer MAX_FRAME_BYTES     = 1038,
    parameter integer CACHE_TIMEOUT_CYCLES = 27_000_000
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,
    input  logic        secure_enable_i,

    input  logic        request_txn_start_i,
    input  logic        request_byte_valid_i,
    input  logic [7:0]  request_byte_i,
    input  logic        request_txn_end_i,

    output logic        response_pending_o,
    output logic [10:0] response_length_o,
    input  logic [10:0] response_addr_i,
    output logic [7:0]  response_data_o,
    input  logic        response_read_done_i,

    output logic        busy_o,
    output logic        fault_o,
    output logic        key_valid_o,
    output logic        session_active_o,
    output logic [15:0] last_error_o,
    output logic [31:0] protocol_error_count_o
);
    localparam logic [15:0] ERR_OK                  = 16'h0000;
    localparam logic [15:0] ERR_TRANSACTION_COLLISION = 16'h0207;
    localparam logic [15:0] ERR_STP_LENGTH          = 16'h0206;
    localparam logic [15:0] ERR_BUSY                = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE       = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY              = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED     = 16'h0304;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT          = 16'h0505;

    localparam logic [7:0] OP_GET_DEVICE_ID       = 8'h01;
    localparam logic [7:0] OP_GET_STATUS          = 8'h02;
    localparam logic [7:0] OP_GET_ERROR           = 8'h03;
    localparam logic [7:0] OP_CLEAR_ERROR         = 8'h04;
    localparam logic [7:0] OP_SOFT_RESET          = 8'h05;
    localparam logic [7:0] OP_PQC_WRITE_COEFF     = 8'h20;
    localparam logic [7:0] OP_PQC_READ_COEFF      = 8'h21;
    localparam logic [7:0] OP_PQC_LOAD_POLY       = 8'h22;
    localparam logic [7:0] OP_PQC_READ_POLY       = 8'h23;
    localparam logic [7:0] OP_PQC_START_NTT       = 8'h24;
    localparam logic [7:0] OP_PQC_START_INTT      = 8'h25;
    localparam logic [7:0] OP_PQC_POINTWISE_MUL   = 8'h26;
    localparam logic [7:0] OP_PQC_POLY_ADD_SUB    = 8'h27;
    localparam logic [7:0] OP_PQC_GET_RESULT      = 8'h28;
    localparam logic [7:0] OP_KEY_LOAD_BEGIN      = 8'h40;
    localparam logic [7:0] OP_KEY_LOAD_CHUNK      = 8'h41;
    localparam logic [7:0] OP_KEY_LOAD_COMMIT     = 8'h42;
    localparam logic [7:0] OP_KEY_LOAD_ABORT      = 8'h43;
    localparam logic [7:0] OP_KEY_STATUS          = 8'h44;
    localparam logic [7:0] OP_ZEROIZE             = 8'h45;
    localparam logic [7:0] OP_SESSION_ACTIVATE    = 8'h46;
    localparam logic [7:0] OP_TELEMETRY_TX_SAMPLE = 8'h60;
    localparam logic [7:0] OP_STP_GET_COUNTERS    = 8'h62;
    localparam logic [7:0] OP_PING                = 8'h7f;

    localparam logic [31:0] DEVICE_ID_PRIMER1 = 32'h5051_4331; // "PQC1"
    localparam logic [31:0] RTL_VERSION        = 32'h0001_0001; // v1.1
    localparam logic [31:0] CAPABILITIES       = 32'h0000_0007; // NTT|ASCON_TX|STP_TX

    typedef enum logic [5:0] {
        S_IDLE,
        S_VALIDATE,
        S_RX_CRC,
        S_CACHE_COMPARE,
        S_CACHE_COPY_RSP,
        S_DISPATCH,
        S_KEY_ACTION_WAIT,
        S_KEY_CHUNK,
        S_KEY_CHUNK_WAIT,
        S_PQC_WRITE_ONE,
        S_PQC_READ_REQ,
        S_PQC_READ_WAIT,
        S_PQC_LOAD,
        S_PQC_READ_POLY_REQ,
        S_PQC_READ_POLY_WAIT,
        S_STP_DISCARD,
        S_STP_START,
        S_STP_WAIT,
        S_STP_COPY,
        S_BUILD_FRAME,
        S_BUILD_CRC,
        S_CACHE_COPY_REQ,
        S_CACHE_COPY_RSP_STORE
    } state_t;

    state_t state_q;

    logic [7:0] request_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] response_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] cache_request_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] cache_response_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] extra_mem [0:MAX_PAYLOAD_BYTES-13];

    logic receiving_q;
    logic [10:0] request_count_q;
    logic [10:0] request_length_q;
    logic [15:0] request_payload_len_q;
    logic [7:0]  request_opcode_q;
    logic [15:0] request_txid_q;

    logic [31:0] rx_crc_q;
    logic [10:0] crc_index_q;
    logic [10:0] crc_last_q;

    logic        cache_valid_q;
    logic [15:0] cache_txid_q;
    logic [10:0] cache_request_len_q;
    logic [10:0] cache_response_len_q;
    logic [24:0] cache_age_q;
    logic [10:0] cache_copy_index_q;
    logic        cache_compare_equal_q;
    logic        cache_update_q;

    logic [15:0] response_status_q;
    logic [15:0] response_detail_q;
    logic [31:0] response_state_q;
    logic [31:0] response_value_q;
    logic [10:0] extra_len_q;
    logic        response_error_flag_q;
    logic        response_commits_sequence_q;

    logic [10:0] build_index_q;
    logic [10:0] build_payload_len_q;
    logic [31:0] build_crc_q;
    logic [31:0] build_crc_final_q;
    logic [2:0]  build_crc_byte_q;

    logic [15:0] last_error_q;
    logic        fatal_q;

    // Session context controls.
    logic session_begin_q;
    logic [31:0] session_begin_id_q;
    logic [7:0] session_begin_direction_q;
    logic [15:0] session_begin_len_q;
    logic session_chunk_valid_q;
    logic [15:0] session_chunk_offset_q;
    logic [7:0] session_chunk_data_q;
    logic session_commit_q;
    logic [31:0] session_commit_id_q;
    logic session_abort_q;
    logic session_activate_q;
    logic [31:0] session_activate_id_q;
    logic session_sequence_commit_q;
    logic command_zeroize_q;

    logic session_key_loading;
    logic session_staging_complete;
    logic session_key_valid;
    logic session_active;
    logic [31:0] session_id;
    logic [127:0] traffic_key;
    logic [63:0] nonce_prefix;
    logic [63:0] tx_sequence;
    logic session_error_valid;
    logic [15:0] session_error_code;

    // STP transmitter controls.
    logic stp_start_q;
    logic stp_discard_q;
    logic [191:0] telemetry_q;
    logic stp_ready;
    logic stp_packet_valid;
    logic [6:0] stp_packet_length;
    logic [6:0] stp_packet_addr_q;
    logic [7:0] stp_packet_data;
    logic stp_done;
    logic stp_error_valid;
    logic [15:0] stp_error_code;

    // Forward NTT adapter.
    logic ntt_start_q;
    logic ntt_busy;
    logic ntt_done;
    logic ntt_done_latched_q;
    logic ntt_host_re_q;
    logic ntt_host_we_q;
    logic [7:0] ntt_host_addr_q;
    logic [15:0] ntt_host_wdata_q;
    logic ntt_host_ready;
    logic ntt_host_rvalid;
    logic [15:0] ntt_host_rdata;
    logic [2:0] ntt_stage;
    logic ntt_stage_barrier;
    logic ntt_active_bank;
    logic [31:0] ntt_cycle_q;
    logic [31:0] ntt_last_cycle_q;

    logic [15:0] loop_count_q;
    logic [15:0] loop_index_q;
    logic [15:0] key_chunk_base_q;
    logic [15:0] pending_key_error_q;
    logic [15:0] pqc_read_count_q;
    logic [15:0] pqc_read_index_q;

    wire secret_zeroize = zeroize_i || command_zeroize_q;

    assign response_data_o = (response_addr_i < response_length_o)
        ? response_mem[response_addr_i] : 8'h00;
    assign key_valid_o      = session_key_valid;
    assign session_active_o = session_active;
    assign last_error_o     = last_error_q;
    assign fault_o          = fatal_q;
    assign busy_o           = (state_q != S_IDLE) || receiving_q || ntt_busy || !stp_ready;

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data_in
    );
        logic [31:0] c;
        logic [7:0] d;
        integer k;
        begin
            c = crc_in;
            d = data_in;
            for (k = 0; k < 8; k = k + 1) begin
                if ((c[0] ^ d[0]) != 1'b0)
                    c = (c >> 1) ^ 32'hedb8_8320;
                else
                    c = c >> 1;
                d = d >> 1;
            end
            crc32_byte = c;
        end
    endfunction

    function automatic logic [7:0] generic_payload_byte(
        input logic [3:0] index,
        input logic [15:0] status,
        input logic [15:0] detail,
        input logic [31:0] device_state,
        input logic [31:0] value
    );
        begin
            case (index)
                4'd0:  generic_payload_byte = status[15:8];
                4'd1:  generic_payload_byte = status[7:0];
                4'd2:  generic_payload_byte = detail[15:8];
                4'd3:  generic_payload_byte = detail[7:0];
                4'd4:  generic_payload_byte = device_state[31:24];
                4'd5:  generic_payload_byte = device_state[23:16];
                4'd6:  generic_payload_byte = device_state[15:8];
                4'd7:  generic_payload_byte = device_state[7:0];
                4'd8:  generic_payload_byte = value[31:24];
                4'd9:  generic_payload_byte = value[23:16];
                4'd10: generic_payload_byte = value[15:8];
                4'd11: generic_payload_byte = value[7:0];
                default: generic_payload_byte = 8'h00;
            endcase
        end
    endfunction

    function automatic logic [31:0] device_state_value;
        begin
            if (fatal_q)
                device_state_value = 32'h0000_0004;
            else if (session_active)
                device_state_value = 32'h0000_0003;
            else if (session_key_valid)
                device_state_value = 32'h0000_0002;
            else if (session_key_loading)
                device_state_value = 32'h0000_0001;
            else
                device_state_value = 32'h0000_0000;
        end
    endfunction

    logic [7:0] build_byte;
    always_comb begin
        build_byte = 8'h00;
        if (build_index_q == 11'd0) build_byte = 8'ha5;
        else if (build_index_q == 11'd1) build_byte = 8'h5a;
        else if (build_index_q == 11'd2) build_byte = 8'h01;
        else if (build_index_q == 11'd3) build_byte = request_opcode_q;
        else if (build_index_q == 11'd4)
            build_byte = 8'h01 | (response_error_flag_q ? 8'h02 : 8'h00);
        else if (build_index_q == 11'd5) build_byte = 8'h00;
        else if (build_index_q == 11'd6) build_byte = request_txid_q[15:8];
        else if (build_index_q == 11'd7) build_byte = request_txid_q[7:0];
        else if (build_index_q == 11'd8) build_byte = build_payload_len_q[15:8];
        else if (build_index_q == 11'd9) build_byte = build_payload_len_q[7:0];
        else if ((build_index_q >= 11'd10) && (build_index_q < 11'd22))
            build_byte = generic_payload_byte(build_index_q - 11'd10,
                                              response_status_q,
                                              response_detail_q,
                                              response_state_q,
                                              response_value_q);
        else if (build_index_q < (11'd10 + build_payload_len_q))
            build_byte = extra_mem[build_index_q - 11'd22];
    end

    primer1_session_context u_session (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .zeroize_i                (secret_zeroize),
        .begin_i                  (session_begin_q),
        .begin_session_id_i       (session_begin_id_q),
        .begin_direction_i        (session_begin_direction_q),
        .begin_total_len_i        (session_begin_len_q),
        .chunk_valid_i            (session_chunk_valid_q),
        .chunk_offset_i           (session_chunk_offset_q),
        .chunk_data_i             (session_chunk_data_q),
        .commit_i                 (session_commit_q),
        .commit_session_id_i      (session_commit_id_q),
        .abort_i                  (session_abort_q),
        .activate_i               (session_activate_q),
        .activate_session_id_i    (session_activate_id_q),
        .sequence_commit_i        (session_sequence_commit_q),
        .key_loading_o            (session_key_loading),
        .staging_complete_o       (session_staging_complete),
        .key_valid_o              (session_key_valid),
        .session_active_o         (session_active),
        .session_id_o             (session_id),
        .traffic_key_o            (traffic_key),
        .nonce_prefix_o           (nonce_prefix),
        .tx_sequence_o            (tx_sequence),
        .error_valid_o            (session_error_valid),
        .error_code_o             (session_error_code)
    );

    stp_tx_telemetry u_stp_tx (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .zeroize_i           (secret_zeroize),
        .start_i             (stp_start_q),
        .ready_o             (stp_ready),
        .session_id_i        (session_id),
        .sequence_i          (tx_sequence),
        .traffic_key_i       (traffic_key),
        .nonce_prefix_i      (nonce_prefix),
        .telemetry_i         (telemetry_q),
        .flags_i             (16'h0000),
        .discard_retained_i  (stp_discard_q),
        .packet_valid_o      (stp_packet_valid),
        .packet_length_o     (stp_packet_length),
        .packet_addr_i       (stp_packet_addr_q),
        .packet_data_o       (stp_packet_data),
        .done_o              (stp_done),
        .error_valid_o       (stp_error_valid),
        .error_code_o        (stp_error_code)
    );

    forward_ntt_core u_forward_ntt (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .start_i          (ntt_start_q),
        .busy_o           (ntt_busy),
        .done_o           (ntt_done),
        .host_re_i        (ntt_host_re_q),
        .host_we_i        (ntt_host_we_q),
        .host_addr_i      (ntt_host_addr_q),
        .host_wdata_i     (ntt_host_wdata_q),
        .host_ready_o     (ntt_host_ready),
        .host_rvalid_o    (ntt_host_rvalid),
        .host_rdata_o     (ntt_host_rdata),
        .stage_o          (ntt_stage),
        .stage_barrier_o  (ntt_stage_barrier),
        .active_bank_o    (ntt_active_bank)
    );

    integer i;
    logic [15:0] observed_crc16_unused;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q                    <= S_IDLE;
            receiving_q                <= 1'b0;
            request_count_q            <= 11'd0;
            request_length_q           <= 11'd0;
            request_payload_len_q      <= 16'd0;
            request_opcode_q           <= 8'h00;
            request_txid_q             <= 16'h0000;
            rx_crc_q                    <= 32'hffff_ffff;
            crc_index_q                <= 11'd0;
            crc_last_q                 <= 11'd0;
            response_pending_o         <= 1'b0;
            response_length_o          <= 11'd0;
            cache_valid_q              <= 1'b0;
            cache_txid_q               <= 16'h0000;
            cache_request_len_q        <= 11'd0;
            cache_response_len_q       <= 11'd0;
            cache_age_q                <= 25'd0;
            cache_copy_index_q         <= 11'd0;
            cache_compare_equal_q      <= 1'b1;
            cache_update_q             <= 1'b0;
            response_status_q          <= ERR_OK;
            response_detail_q          <= 16'h0000;
            response_state_q           <= 32'h0;
            response_value_q           <= 32'h0;
            extra_len_q                <= 11'd0;
            response_error_flag_q      <= 1'b0;
            response_commits_sequence_q <= 1'b0;
            build_index_q              <= 11'd0;
            build_payload_len_q        <= 11'd12;
            build_crc_q                <= 32'hffff_ffff;
            build_crc_final_q          <= 32'h0;
            build_crc_byte_q           <= 3'd0;
            last_error_q               <= 16'h0000;
            protocol_error_count_o     <= 32'h0;
            fatal_q                    <= 1'b0;
            session_begin_q            <= 1'b0;
            session_begin_id_q         <= 32'h0;
            session_begin_direction_q  <= 8'h0;
            session_begin_len_q        <= 16'h0;
            session_chunk_valid_q      <= 1'b0;
            session_chunk_offset_q     <= 16'h0;
            session_chunk_data_q       <= 8'h0;
            session_commit_q           <= 1'b0;
            session_commit_id_q        <= 32'h0;
            session_abort_q            <= 1'b0;
            session_activate_q         <= 1'b0;
            session_activate_id_q      <= 32'h0;
            session_sequence_commit_q  <= 1'b0;
            command_zeroize_q          <= 1'b0;
            stp_start_q                <= 1'b0;
            stp_discard_q              <= 1'b0;
            telemetry_q                <= 192'h0;
            stp_packet_addr_q          <= 7'd0;
            ntt_start_q                <= 1'b0;
            ntt_done_latched_q         <= 1'b0;
            ntt_host_re_q              <= 1'b0;
            ntt_host_we_q              <= 1'b0;
            ntt_host_addr_q            <= 8'h0;
            ntt_host_wdata_q           <= 16'h0;
            ntt_cycle_q                <= 32'h0;
            ntt_last_cycle_q           <= 32'h0;
            loop_count_q               <= 16'h0;
            loop_index_q               <= 16'h0;
            key_chunk_base_q           <= 16'h0;
            pending_key_error_q        <= 16'h0;
            pqc_read_count_q           <= 16'h0;
            pqc_read_index_q           <= 16'h0;
            observed_crc16_unused      <= 16'h0;
            for (i = 0; i < MAX_FRAME_BYTES; i = i + 1) begin
                request_mem[i]        <= 8'h00;
                response_mem[i]       <= 8'h00;
                cache_request_mem[i]  <= 8'h00;
                cache_response_mem[i] <= 8'h00;
            end
            for (i = 0; i < (MAX_PAYLOAD_BYTES-12); i = i + 1)
                extra_mem[i] <= 8'h00;
        end else if (zeroize_i) begin
            // External/supervisor zeroize invalidates transport caches as well
            // as all secret state.  A new session and a new BTP command are
            // required after the signal is released.
            state_q                    <= S_IDLE;
            receiving_q                <= 1'b0;
            request_count_q            <= 11'd0;
            response_pending_o         <= 1'b0;
            response_length_o          <= 11'd0;
            cache_valid_q              <= 1'b0;
            cache_age_q                <= 25'd0;
            last_error_q               <= 16'h0000;
            fatal_q                    <= 1'b0;
            response_commits_sequence_q <= 1'b0;
            session_begin_q            <= 1'b0;
            session_chunk_valid_q      <= 1'b0;
            session_commit_q           <= 1'b0;
            session_abort_q            <= 1'b0;
            session_activate_q         <= 1'b0;
            session_sequence_commit_q  <= 1'b0;
            command_zeroize_q          <= 1'b0;
            stp_start_q                <= 1'b0;
            stp_discard_q              <= 1'b0;
            ntt_start_q                <= 1'b0;
            ntt_host_re_q              <= 1'b0;
            ntt_host_we_q              <= 1'b0;
            ntt_done_latched_q         <= 1'b0;
            ntt_cycle_q                <= 32'h0;
            ntt_last_cycle_q           <= 32'h0;
        end else begin
            session_begin_q           <= 1'b0;
            session_chunk_valid_q     <= 1'b0;
            session_commit_q          <= 1'b0;
            session_abort_q           <= 1'b0;
            session_activate_q        <= 1'b0;
            session_sequence_commit_q <= 1'b0;
            command_zeroize_q         <= 1'b0;
            stp_start_q               <= 1'b0;
            stp_discard_q             <= 1'b0;
            ntt_start_q               <= 1'b0;
            ntt_host_re_q             <= 1'b0;
            ntt_host_we_q             <= 1'b0;

            if (cache_valid_q) begin
                if (cache_age_q >= CACHE_TIMEOUT_CYCLES-1) begin
                    cache_valid_q <= 1'b0;
                    cache_age_q   <= 25'd0;
                end else begin
                    cache_age_q <= cache_age_q + 1'b1;
                end
            end

            if (ntt_start_q) begin
                ntt_cycle_q        <= 32'h0;
                ntt_done_latched_q <= 1'b0;
            end else if (ntt_busy) begin
                ntt_cycle_q <= ntt_cycle_q + 1'b1;
            end
            if (ntt_done) begin
                ntt_done_latched_q <= 1'b1;
                ntt_last_cycle_q   <= ntt_cycle_q;
            end

            if (session_error_valid)
                last_error_q <= session_error_code;
            if (stp_error_valid)
                last_error_q <= stp_error_code;

            if (response_read_done_i && response_pending_o) begin
                response_pending_o <= 1'b0;
                if (response_commits_sequence_q) begin
                    session_sequence_commit_q   <= 1'b1;
                    response_commits_sequence_q <= 1'b0;
                end
            end

            if (request_txn_start_i && !response_pending_o && (state_q == S_IDLE)) begin
                receiving_q     <= 1'b1;
                request_count_q <= 11'd0;
            end

            if (request_byte_valid_i && receiving_q) begin
                if (request_count_q < MAX_FRAME_BYTES) begin
                    request_mem[request_count_q] <= request_byte_i;
                    request_count_q <= request_count_q + 1'b1;
                end else begin
                    receiving_q <= 1'b0;
                    protocol_error_count_o <= protocol_error_count_o + 1'b1;
                end
            end

            if (request_txn_end_i && receiving_q) begin
                receiving_q      <= 1'b0;
                request_length_q <= request_count_q;
                state_q          <= S_VALIDATE;
            end

            case (state_q)
                S_IDLE: begin
                    // RX activity is handled above.
                end

                S_VALIDATE: begin
                    if ((request_length_q < 11'd14) ||
                        (request_mem[0] != 8'ha5) ||
                        (request_mem[1] != 8'h5a) ||
                        (request_mem[2] != 8'h01) ||
                        ((request_mem[4] & 8'hf9) != 8'h00) ||
                        (request_mem[5] != 8'h00) ||
                        ({request_mem[8], request_mem[9]} > MAX_PAYLOAD_BYTES) ||
                        (request_length_q !=
                         (11'd14 + {request_mem[8], request_mem[9]}))) begin
                        protocol_error_count_o <= protocol_error_count_o + 1'b1;
                        state_q <= S_IDLE;
                    end else begin
                        request_opcode_q      <= request_mem[3];
                        request_txid_q        <= {request_mem[6], request_mem[7]};
                        request_payload_len_q <= {request_mem[8], request_mem[9]};
                        rx_crc_q              <= 32'hffff_ffff;
                        crc_index_q           <= 11'd2;
                        crc_last_q            <= 11'd9 + {request_mem[8], request_mem[9]};
                        state_q               <= S_RX_CRC;
                    end
                end

                S_RX_CRC: begin
                    if (crc_index_q <= crc_last_q) begin
                        rx_crc_q     <= crc32_byte(rx_crc_q, request_mem[crc_index_q]);
                        crc_index_q  <= crc_index_q + 1'b1;
                    end else if ((rx_crc_q ^ 32'hffff_ffff) !=
                                 {request_mem[10+request_payload_len_q],
                                  request_mem[11+request_payload_len_q],
                                  request_mem[12+request_payload_len_q],
                                  request_mem[13+request_payload_len_q]}) begin
                        protocol_error_count_o <= protocol_error_count_o + 1'b1;
                        state_q <= S_IDLE;
                    end else if (cache_valid_q &&
                                 (request_txid_q == cache_txid_q)) begin
                        cache_copy_index_q    <= 11'd0;
                        cache_compare_equal_q <=
                            (request_length_q == cache_request_len_q);
                        state_q <= S_CACHE_COMPARE;
                    end else begin
                        state_q <= S_DISPATCH;
                    end
                end

                S_CACHE_COMPARE: begin
                    if (cache_copy_index_q < request_length_q) begin
                        if (request_mem[cache_copy_index_q] !=
                            cache_request_mem[cache_copy_index_q])
                            cache_compare_equal_q <= 1'b0;
                        cache_copy_index_q <= cache_copy_index_q + 1'b1;
                    end else if (cache_compare_equal_q) begin
                        cache_copy_index_q <= 11'd0;
                        state_q <= S_CACHE_COPY_RSP;
                    end else begin
                        // Same transaction_id with different content.
                        response_status_q     <= ERR_TRANSACTION_COLLISION;
                        response_detail_q     <= 16'h0000;
                        response_state_q      <= device_state_value();
                        response_value_q      <= 32'h0;
                        extra_len_q           <= 11'd0;
                        response_error_flag_q <= 1'b1;
                        cache_update_q        <= 1'b0;
                        response_commits_sequence_q <= 1'b0;
                        last_error_q          <= ERR_TRANSACTION_COLLISION;
                        build_index_q         <= 11'd0;
                        build_payload_len_q   <= 11'd12;
                        build_crc_q           <= 32'hffff_ffff;
                        state_q               <= S_BUILD_FRAME;
                    end
                end

                S_CACHE_COPY_RSP: begin
                    if (cache_copy_index_q < cache_response_len_q) begin
                        response_mem[cache_copy_index_q] <=
                            cache_response_mem[cache_copy_index_q];
                        cache_copy_index_q <= cache_copy_index_q + 1'b1;
                    end else begin
                        response_length_o           <= cache_response_len_q;
                        response_pending_o          <= 1'b1;
                        response_commits_sequence_q <= 1'b0;
                        cache_age_q                 <= 25'd0;
                        state_q                     <= S_IDLE;
                    end
                end

                S_DISPATCH: begin
                    response_status_q     <= ERR_OK;
                    response_detail_q     <= 16'h0000;
                    response_state_q      <= device_state_value();
                    response_value_q      <= 32'h0;
                    extra_len_q           <= 11'd0;
                    response_error_flag_q <= 1'b0;
                    cache_update_q        <= 1'b1;
                    response_commits_sequence_q <= 1'b0;

                    case (request_opcode_q)
                        OP_GET_DEVICE_ID: begin
                            if (request_payload_len_q != 0) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                            end else begin
                                extra_mem[0]  <= DEVICE_ID_PRIMER1[31:24];
                                extra_mem[1]  <= DEVICE_ID_PRIMER1[23:16];
                                extra_mem[2]  <= DEVICE_ID_PRIMER1[15:8];
                                extra_mem[3]  <= DEVICE_ID_PRIMER1[7:0];
                                extra_mem[4]  <= RTL_VERSION[31:24];
                                extra_mem[5]  <= RTL_VERSION[23:16];
                                extra_mem[6]  <= RTL_VERSION[15:8];
                                extra_mem[7]  <= RTL_VERSION[7:0];
                                extra_mem[8]  <= CAPABILITIES[31:24];
                                extra_mem[9]  <= CAPABILITIES[23:16];
                                extra_mem[10] <= CAPABILITIES[15:8];
                                extra_mem[11] <= CAPABILITIES[7:0];
                                extra_len_q <= 11'd12;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd24;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_GET_STATUS: begin
                            response_value_q <= {24'h0,
                                fatal_q, secure_enable_i, session_active,
                                session_key_valid, session_key_loading,
                                ntt_done_latched_q, ntt_busy, stp_packet_valid};
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_GET_ERROR: begin
                            extra_mem[0] <= last_error_q[15:8];
                            extra_mem[1] <= last_error_q[7:0];
                            extra_len_q  <= 11'd2;
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd14;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_CLEAR_ERROR: begin
                            if (request_payload_len_q == 16'd2)
                                last_error_q <= 16'h0000;
                            else begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_SOFT_RESET: begin
                            if ((request_payload_len_q != 16'd2) || ntt_busy || !stp_ready) begin
                                response_status_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                            end else begin
                                session_abort_q <= 1'b1;
                                stp_discard_q   <= 1'b1;
                                ntt_done_latched_q <= 1'b0;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_PQC_WRITE_COEFF: begin
                            if ((request_payload_len_q != 16'd4) || !ntt_host_ready) begin
                                response_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else if (({request_mem[10],request_mem[11]} >= 16'd256) ||
                                         ({request_mem[12],request_mem[13]} >= 16'd3329)) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                ntt_host_addr_q  <= request_mem[11];
                                ntt_host_wdata_q <= {request_mem[12],request_mem[13]};
                                state_q <= S_PQC_WRITE_ONE;
                            end
                        end

                        OP_PQC_READ_COEFF: begin
                            if ((request_payload_len_q != 16'd2) || !ntt_host_ready ||
                                ({request_mem[10],request_mem[11]} >= 16'd256)) begin
                                response_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                ntt_host_addr_q <= request_mem[11];
                                state_q <= S_PQC_READ_REQ;
                            end
                        end

                        OP_PQC_LOAD_POLY: begin
                            loop_count_q <= {request_mem[10],request_mem[11]};
                            loop_index_q <= 16'd0;
                            if ((request_payload_len_q < 16'd2) || !ntt_host_ready ||
                                ({request_mem[10],request_mem[11]} > 16'd256) ||
                                (request_payload_len_q !=
                                 (16'd2 + ({request_mem[10],request_mem[11]} << 1)))) begin
                                response_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                state_q <= S_PQC_LOAD;
                            end
                        end

                        OP_PQC_READ_POLY: begin
                            pqc_read_count_q <= {request_mem[10],request_mem[11]};
                            pqc_read_index_q <= 16'd0;
                            if ((request_payload_len_q != 16'd2) || !ntt_host_ready ||
                                ({request_mem[10],request_mem[11]} > 16'd256)) begin
                                response_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                extra_mem[0] <= request_mem[10];
                                extra_mem[1] <= request_mem[11];
                                state_q <= S_PQC_READ_POLY_REQ;
                            end
                        end

                        OP_PQC_START_NTT: begin
                            if ((request_payload_len_q != 16'd4) || ntt_busy || !ntt_host_ready) begin
                                response_status_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                            end else begin
                                ntt_start_q <= 1'b1;
                                ntt_done_latched_q <= 1'b0;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_PQC_GET_RESULT: begin
                            response_value_q <= ntt_last_cycle_q;
                            extra_mem[0] <= {5'h0, ntt_stage};
                            extra_mem[1] <= {5'h0, ntt_stage_barrier,
                                             ntt_active_bank, ntt_done_latched_q};
                            extra_len_q <= 11'd2;
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd14;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_PQC_START_INTT,
                        OP_PQC_POINTWISE_MUL,
                        OP_PQC_POLY_ADD_SUB: begin
                            // Deployment interface is present, but these
                            // datapaths are not silently faked. They return an
                            // explicit unavailable-state error until verified
                            // cores are added.
                            response_status_q     <= ERR_INVALID_STATE;
                            response_error_flag_q <= 1'b1;
                            last_error_q          <= ERR_INVALID_STATE;
                            build_index_q         <= 11'd0;
                            build_payload_len_q   <= 11'd12;
                            build_crc_q           <= 32'hffff_ffff;
                            state_q               <= S_BUILD_FRAME;
                        end

                        OP_KEY_LOAD_BEGIN: begin
                            if (request_payload_len_q != 16'd7) begin
                                response_status_q <= ERR_KEY_COMMIT;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_KEY_COMMIT;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                session_begin_id_q <= {request_mem[10],request_mem[11],
                                                       request_mem[12],request_mem[13]};
                                session_begin_direction_q <= request_mem[14];
                                session_begin_len_q <= {request_mem[15],request_mem[16]};
                                session_begin_q <= 1'b1;
                                pending_key_error_q <= 16'h0000;
                                state_q <= S_KEY_ACTION_WAIT;
                            end
                        end

                        OP_KEY_LOAD_CHUNK: begin
                            if ((request_payload_len_q < 16'd3) || !session_key_loading) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                key_chunk_base_q <= {request_mem[10],request_mem[11]};
                                loop_count_q <= request_payload_len_q - 16'd2;
                                loop_index_q <= 16'd0;
                                pending_key_error_q <= 16'h0000;
                                state_q <= S_KEY_CHUNK;
                            end
                        end

                        OP_KEY_LOAD_COMMIT: begin
                            if (request_payload_len_q != 16'd4) begin
                                response_status_q <= ERR_KEY_COMMIT;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_KEY_COMMIT;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                session_commit_id_q <= {request_mem[10],request_mem[11],
                                                        request_mem[12],request_mem[13]};
                                session_commit_q <= 1'b1;
                                pending_key_error_q <= 16'h0000;
                                state_q <= S_KEY_ACTION_WAIT;
                            end
                        end

                        OP_KEY_LOAD_ABORT: begin
                            if (request_payload_len_q != 16'd0) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                            end else begin
                                session_abort_q <= 1'b1;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_KEY_STATUS: begin
                            extra_mem[0] <= session_id[31:24];
                            extra_mem[1] <= session_id[23:16];
                            extra_mem[2] <= session_id[15:8];
                            extra_mem[3] <= session_id[7:0];
                            extra_mem[4] <= {5'h0, session_active,
                                             session_key_valid, session_key_loading};
                            extra_mem[5] <= session_staging_complete ? 8'h01 : 8'h00;
                            extra_mem[6] <= 8'h00;
                            extra_mem[7] <= 8'h00;
                            extra_mem[8] <= tx_sequence[63:56];
                            extra_mem[9] <= tx_sequence[55:48];
                            extra_mem[10] <= tx_sequence[47:40];
                            extra_mem[11] <= tx_sequence[39:32];
                            extra_mem[12] <= tx_sequence[31:24];
                            extra_mem[13] <= tx_sequence[23:16];
                            extra_mem[14] <= tx_sequence[15:8];
                            extra_mem[15] <= tx_sequence[7:0];
                            extra_len_q <= 11'd16;
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd28;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_ZEROIZE: begin
                            if (request_payload_len_q != 16'd2) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                            end else begin
                                command_zeroize_q <= 1'b1;
                                last_error_q <= 16'h0000;
                            end
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_SESSION_ACTIVATE: begin
                            if (request_payload_len_q != 16'd4) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else begin
                                session_activate_id_q <= {request_mem[10],request_mem[11],
                                                          request_mem[12],request_mem[13]};
                                session_activate_q <= 1'b1;
                                pending_key_error_q <= 16'h0000;
                                state_q <= S_KEY_ACTION_WAIT;
                            end
                        end

                        OP_TELEMETRY_TX_SAMPLE: begin
                            if (request_payload_len_q != 16'd24) begin
                                response_status_q <= ERR_STP_LENGTH;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_STP_LENGTH;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else if (!secure_enable_i) begin
                                response_status_q <= ERR_SECURE_DISABLED;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_SECURE_DISABLED;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else if (!session_key_valid) begin
                                response_status_q <= ERR_NO_KEY;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_NO_KEY;
                                build_index_q       <= 11'd0;
                                build_payload_len_q <= 11'd12;
                                build_crc_q         <= 32'hffff_ffff;
                                state_q             <= S_BUILD_FRAME;
                            end else if (!session_active || !stp_ready) begin
                                // A retained previous packet is discarded only
                                // when a new unique sample command is accepted.
                                if (session_active && stp_packet_valid) begin
                                    for (i = 0; i < 24; i = i + 1)
                                        telemetry_q[8*i +: 8] <= request_mem[10+i];
                                    stp_discard_q <= 1'b1;
                                    state_q <= S_STP_DISCARD;
                                end else begin
                                    response_status_q <= !session_active ? ERR_INVALID_STATE : ERR_BUSY;
                                    response_error_flag_q <= 1'b1;
                                    last_error_q <= !session_active ? ERR_INVALID_STATE : ERR_BUSY;
                                    build_index_q       <= 11'd0;
                                    build_payload_len_q <= 11'd12;
                                    build_crc_q         <= 32'hffff_ffff;
                                    state_q             <= S_BUILD_FRAME;
                                end
                            end else begin
                                for (i = 0; i < 24; i = i + 1)
                                    telemetry_q[8*i +: 8] <= request_mem[10+i];
                                state_q <= S_STP_START;
                            end
                        end

                        OP_STP_GET_COUNTERS: begin
                            extra_mem[0] <= tx_sequence[63:56];
                            extra_mem[1] <= tx_sequence[55:48];
                            extra_mem[2] <= tx_sequence[47:40];
                            extra_mem[3] <= tx_sequence[39:32];
                            extra_mem[4] <= tx_sequence[31:24];
                            extra_mem[5] <= tx_sequence[23:16];
                            extra_mem[6] <= tx_sequence[15:8];
                            extra_mem[7] <= tx_sequence[7:0];
                            extra_len_q <= 11'd8;
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd20;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end

                        OP_PING: begin
                            if (request_payload_len_q > (MAX_PAYLOAD_BYTES-12)) begin
                                response_status_q <= ERR_INVALID_STATE;
                                response_error_flag_q <= 1'b1;
                                last_error_q <= ERR_INVALID_STATE;
                                extra_len_q <= 11'd0;
                                build_payload_len_q <= 11'd12;
                            end else begin
                                for (i = 0; i < (MAX_PAYLOAD_BYTES-12); i = i + 1)
                                    if (i < request_payload_len_q)
                                        extra_mem[i] <= request_mem[10+i];
                                extra_len_q <= request_payload_len_q;
                                build_payload_len_q <= 11'd12 + request_payload_len_q;
                            end
                            build_index_q <= 11'd0;
                            build_crc_q   <= 32'hffff_ffff;
                            state_q       <= S_BUILD_FRAME;
                        end

                        default: begin
                            response_status_q     <= ERR_INVALID_STATE;
                            response_error_flag_q <= 1'b1;
                            last_error_q          <= ERR_INVALID_STATE;
                            build_index_q         <= 11'd0;
                            build_payload_len_q   <= 11'd12;
                            build_crc_q           <= 32'hffff_ffff;
                            state_q               <= S_BUILD_FRAME;
                        end
                    endcase
                end

                S_KEY_ACTION_WAIT: begin
                    if (session_error_valid) begin
                        response_status_q     <= session_error_code;
                        response_error_flag_q <= 1'b1;
                        last_error_q          <= session_error_code;
                    end
                    response_state_q      <= device_state_value();
                    build_index_q         <= 11'd0;
                    build_payload_len_q   <= 11'd12;
                    build_crc_q           <= 32'hffff_ffff;
                    state_q               <= S_BUILD_FRAME;
                end

                S_KEY_CHUNK: begin
                    if (loop_index_q < loop_count_q) begin
                        session_chunk_offset_q <= key_chunk_base_q + loop_index_q;
                        session_chunk_data_q   <= request_mem[12 + loop_index_q];
                        session_chunk_valid_q  <= 1'b1;
                        if (session_error_valid)
                            pending_key_error_q <= session_error_code;
                        loop_index_q <= loop_index_q + 1'b1;
                    end else begin
                        state_q <= S_KEY_CHUNK_WAIT;
                    end
                end

                S_KEY_CHUNK_WAIT: begin
                    if (session_error_valid)
                        pending_key_error_q <= session_error_code;
                    if ((pending_key_error_q != 16'h0000) || session_error_valid) begin
                        response_status_q <= session_error_valid ? session_error_code : pending_key_error_q;
                        response_error_flag_q <= 1'b1;
                        last_error_q <= session_error_valid ? session_error_code : pending_key_error_q;
                    end
                    response_state_q      <= device_state_value();
                    build_index_q         <= 11'd0;
                    build_payload_len_q   <= 11'd12;
                    build_crc_q           <= 32'hffff_ffff;
                    state_q               <= S_BUILD_FRAME;
                end

                S_PQC_WRITE_ONE: begin
                    ntt_host_we_q <= 1'b1;
                    response_value_q <= {16'h0, ntt_host_wdata_q};
                    build_index_q       <= 11'd0;
                    build_payload_len_q <= 11'd12;
                    build_crc_q         <= 32'hffff_ffff;
                    state_q             <= S_BUILD_FRAME;
                end

                S_PQC_READ_REQ: begin
                    ntt_host_re_q <= 1'b1;
                    state_q <= S_PQC_READ_WAIT;
                end

                S_PQC_READ_WAIT: begin
                    if (ntt_host_rvalid) begin
                        extra_mem[0] <= ntt_host_rdata[15:8];
                        extra_mem[1] <= ntt_host_rdata[7:0];
                        extra_len_q  <= 11'd2;
                        response_value_q <= {16'h0,ntt_host_rdata};
                        build_index_q       <= 11'd0;
                        build_payload_len_q <= 11'd14;
                        build_crc_q         <= 32'hffff_ffff;
                        state_q             <= S_BUILD_FRAME;
                    end
                end

                S_PQC_LOAD: begin
                    if (loop_index_q < loop_count_q) begin
                        if ({request_mem[12+2*loop_index_q],
                             request_mem[13+2*loop_index_q]} >= 16'd3329) begin
                            response_status_q <= ERR_INVALID_STATE;
                            response_error_flag_q <= 1'b1;
                            last_error_q <= ERR_INVALID_STATE;
                            build_index_q       <= 11'd0;
                            build_payload_len_q <= 11'd12;
                            build_crc_q         <= 32'hffff_ffff;
                            state_q             <= S_BUILD_FRAME;
                        end else begin
                            ntt_host_addr_q  <= loop_index_q[7:0];
                            ntt_host_wdata_q <= {request_mem[12+2*loop_index_q],
                                                 request_mem[13+2*loop_index_q]};
                            ntt_host_we_q    <= 1'b1;
                            loop_index_q     <= loop_index_q + 1'b1;
                        end
                    end else begin
                        response_value_q      <= {16'h0, loop_count_q};
                        build_index_q         <= 11'd0;
                        build_payload_len_q   <= 11'd12;
                        build_crc_q           <= 32'hffff_ffff;
                        state_q               <= S_BUILD_FRAME;
                    end
                end

                S_PQC_READ_POLY_REQ: begin
                    if (pqc_read_index_q < pqc_read_count_q) begin
                        ntt_host_addr_q <= pqc_read_index_q[7:0];
                        ntt_host_re_q   <= 1'b1;
                        state_q         <= S_PQC_READ_POLY_WAIT;
                    end else begin
                        extra_len_q          <= 11'd2 + (pqc_read_count_q << 1);
                        response_value_q     <= {16'h0,pqc_read_count_q};
                        build_index_q        <= 11'd0;
                        build_payload_len_q  <= 11'd14 + (pqc_read_count_q << 1);
                        build_crc_q          <= 32'hffff_ffff;
                        state_q              <= S_BUILD_FRAME;
                    end
                end

                S_PQC_READ_POLY_WAIT: begin
                    if (ntt_host_rvalid) begin
                        extra_mem[2 + 2*pqc_read_index_q] <= ntt_host_rdata[15:8];
                        extra_mem[3 + 2*pqc_read_index_q] <= ntt_host_rdata[7:0];
                        pqc_read_index_q <= pqc_read_index_q + 1'b1;
                        state_q <= S_PQC_READ_POLY_REQ;
                    end
                end

                S_STP_DISCARD: begin
                    // discard_retained_i is consumed by stp_tx_telemetry on
                    // the previous edge; ready must now become true.
                    if (stp_ready)
                        state_q <= S_STP_START;
                end

                S_STP_START: begin
                    if (stp_ready) begin
                        stp_start_q <= 1'b1;
                        state_q <= S_STP_WAIT;
                    end
                end

                S_STP_WAIT: begin
                    if (stp_error_valid) begin
                        response_status_q     <= stp_error_code;
                        response_error_flag_q <= 1'b1;
                        last_error_q          <= stp_error_code;
                        build_index_q         <= 11'd0;
                        build_payload_len_q   <= 11'd12;
                        build_crc_q           <= 32'hffff_ffff;
                        state_q               <= S_BUILD_FRAME;
                    end else if (stp_done && stp_packet_valid) begin
                        extra_mem[0] <= tx_sequence[63:56];
                        extra_mem[1] <= tx_sequence[55:48];
                        extra_mem[2] <= tx_sequence[47:40];
                        extra_mem[3] <= tx_sequence[39:32];
                        extra_mem[4] <= tx_sequence[31:24];
                        extra_mem[5] <= tx_sequence[23:16];
                        extra_mem[6] <= tx_sequence[15:8];
                        extra_mem[7] <= tx_sequence[7:0];
                        extra_mem[8] <= 8'h00;
                        extra_mem[9] <= stp_packet_length;
                        loop_index_q <= 16'd0;
                        stp_packet_addr_q <= 7'd0;
                        state_q <= S_STP_COPY;
                    end
                end

                S_STP_COPY: begin
                    if (loop_index_q < stp_packet_length) begin
                        extra_mem[10 + loop_index_q] <= stp_packet_data;
                        loop_index_q <= loop_index_q + 1'b1;
                        stp_packet_addr_q <= stp_packet_addr_q + 1'b1;
                    end else begin
                        extra_len_q                 <= 11'd10 + stp_packet_length;
                        response_value_q            <= {25'h0,stp_packet_length};
                        response_commits_sequence_q <= 1'b1;
                        build_index_q               <= 11'd0;
                        build_payload_len_q         <= 11'd22 + stp_packet_length;
                        build_crc_q                 <= 32'hffff_ffff;
                        state_q                     <= S_BUILD_FRAME;
                    end
                end

                S_BUILD_FRAME: begin
                    response_mem[build_index_q] <= build_byte;
                    if (build_index_q >= 11'd2)
                        build_crc_q <= crc32_byte(build_crc_q, build_byte);

                    if (build_index_q == (11'd9 + build_payload_len_q)) begin
                        build_crc_final_q <=
                            crc32_byte(build_crc_q, build_byte) ^ 32'hffff_ffff;
                        build_crc_byte_q <= 3'd0;
                        state_q <= S_BUILD_CRC;
                    end else begin
                        build_index_q <= build_index_q + 1'b1;
                    end
                end

                S_BUILD_CRC: begin
                    case (build_crc_byte_q)
                        3'd0: response_mem[10+build_payload_len_q] <= build_crc_final_q[31:24];
                        3'd1: response_mem[11+build_payload_len_q] <= build_crc_final_q[23:16];
                        3'd2: response_mem[12+build_payload_len_q] <= build_crc_final_q[15:8];
                        3'd3: response_mem[13+build_payload_len_q] <= build_crc_final_q[7:0];
                        default: ;
                    endcase
                    if (build_crc_byte_q == 3'd3) begin
                        response_length_o <= 11'd14 + build_payload_len_q;
                        if (cache_update_q) begin
                            cache_copy_index_q <= 11'd0;
                            state_q <= S_CACHE_COPY_REQ;
                        end else begin
                            response_pending_o <= 1'b1;
                            state_q <= S_IDLE;
                        end
                    end else begin
                        build_crc_byte_q <= build_crc_byte_q + 1'b1;
                    end
                end

                S_CACHE_COPY_REQ: begin
                    if (cache_copy_index_q < request_length_q) begin
                        cache_request_mem[cache_copy_index_q] <=
                            request_mem[cache_copy_index_q];
                        cache_copy_index_q <= cache_copy_index_q + 1'b1;
                    end else begin
                        cache_request_len_q <= request_length_q;
                        cache_copy_index_q  <= 11'd0;
                        state_q <= S_CACHE_COPY_RSP_STORE;
                    end
                end

                S_CACHE_COPY_RSP_STORE: begin
                    if (cache_copy_index_q < response_length_o) begin
                        cache_response_mem[cache_copy_index_q] <=
                            response_mem[cache_copy_index_q];
                        cache_copy_index_q <= cache_copy_index_q + 1'b1;
                    end else begin
                        cache_response_len_q <= response_length_o;
                        cache_txid_q         <= request_txid_q;
                        cache_valid_q        <= 1'b1;
                        cache_age_q          <= 25'd0;
                        response_pending_o   <= 1'b1;
                        state_q              <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (response_length_o <= MAX_FRAME_BYTES)
                else $error("primer1_btp_endpoint: response frame overflow");
            assert (!(response_commits_sequence_q && response_error_flag_q))
                else $error("primer1_btp_endpoint: error response cannot commit sequence");
        end
    end
`endif
endmodule
