// Kiwi Primer 20K #1 deployment endpoint, BRAM-oriented revision.
// FPST-SYS-SPEC-001 v1.1.
//
// Design properties relevant to the real FPGA image:
// - BTP request side effects occur only after a complete frame passes CRC32.
// - large request/response storage has no reset loop, preserving BRAM inference;
// - raw key-load bytes are kept only in a 32-byte register window and scrubbed;
// - the response RAM itself is the one-entry response cache;
// - exact duplicate transaction_id/opcode/length/request-CRC replays the cached
//   response without repeating side effects;
// - STP packet/sequence retention is not committed merely because the MCU read
//   a BTP response. A new unique TELEMETRY_TX_SAMPLE is the MCU's implicit
//   indication that the receiver commit acknowledgement for the previous packet
//   was obtained. Exact duplicates therefore resend the identical packet.
module primer1_btp_endpoint_v2 #(
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
    localparam logic [15:0] ERR_OK                    = 16'h0000;
    localparam logic [15:0] ERR_BTP_FRAME             = 16'h0201;
    localparam logic [15:0] ERR_BTP_CRC               = 16'h0202;
    localparam logic [15:0] ERR_STP_LENGTH            = 16'h0206;
    localparam logic [15:0] ERR_TRANSACTION_COLLISION = 16'h0207;
    localparam logic [15:0] ERR_BUSY                  = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE         = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY                = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED       = 16'h0304;
    localparam logic [15:0] ERR_KEY_COMMIT            = 16'h0505;

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

    localparam logic [31:0] DEVICE_ID_PRIMER1 = 32'h5051_4331;
    localparam logic [31:0] RTL_VERSION        = 32'h0001_0100;
    localparam logic [31:0] CAPABILITIES       = 32'h0000_0007;

    typedef enum logic [5:0] {
        S_IDLE,
        S_DISPATCH,
        S_BUILD_START,
        S_BUILD_WAIT,
        S_ACTION_WAIT1,
        S_ACTION_WAIT2,
        S_KEY_CHUNK_FEED,
        S_KEY_CHUNK_DRAIN1,
        S_KEY_CHUNK_DRAIN2,
        S_PQC_LOAD_REQ_HI,
        S_PQC_LOAD_WAIT_HI,
        S_PQC_LOAD_REQ_LO,
        S_PQC_LOAD_WAIT_LO,
        S_PQC_LOAD_WRITE,
        S_PQC_READ_REQ,
        S_PQC_READ_WAIT,
        S_PQC_READ_POLY_REQ,
        S_PQC_READ_POLY_WAIT,
        S_PQC_READ_POLY_STORE_HI,
        S_PQC_READ_POLY_STORE_LO,
        S_TX_COMMIT_PREVIOUS,
        S_TX_COMMIT_WAIT1,
        S_TX_COMMIT_WAIT2,
        S_TX_DISCARD_WAIT,
        S_TX_START,
        S_TX_WAIT,
        S_EXTRA_RAM_REQ,
        S_EXTRA_RAM_WAIT
    } state_t;

    state_t state_q;

    typedef enum logic [3:0] {
        EXTRA_NONE,
        EXTRA_DEVICE_ID,
        EXTRA_PING,
        EXTRA_LAST_ERROR,
        EXTRA_SINGLE_COEFF,
        EXTRA_READ_POLY,
        EXTRA_KEY_STATUS,
        EXTRA_NTT_STATUS,
        EXTRA_TELEMETRY,
        EXTRA_COUNTERS
    } extra_mode_t;

    extra_mode_t extra_mode_q;

    // ---------------------------------------------------------------------
    // Request receive path
    // ---------------------------------------------------------------------
    logic        rx_active_q;
    logic [10:0] rx_index_q;
    logic        rx_header_ok_q;
    logic [7:0]  rx_version_q;
    logic [7:0]  rx_opcode_q;
    logic [7:0]  rx_flags_q;
    logic [7:0]  rx_reserved_q;
    logic [15:0] rx_txid_q;
    logic [15:0] rx_payload_len_q;
    logic [31:0] rx_crc_q;
    logic [31:0] rx_wire_crc_q;
    logic        rx_frame_valid_q;
    logic        rx_frame_error_q;

    logic [7:0] small_payload_q [0:31];
    logic       scrub_small_q;

    logic        request_ram_we_rx;
    logic [10:0] request_ram_waddr_rx;
    logic [7:0]  request_ram_wdata_rx;

    logic        request_ram_we_main_q;
    logic [10:0] request_ram_waddr_main_q;
    logic [7:0]  request_ram_wdata_main_q;
    logic        request_ram_re_q;
    logic [10:0] request_ram_raddr_q;
    logic        request_ram_rvalid;
    logic [7:0]  request_ram_rdata;

    wire request_ram_we = request_ram_we_rx || request_ram_we_main_q;
    wire [10:0] request_ram_waddr = request_ram_we_rx
        ? request_ram_waddr_rx : request_ram_waddr_main_q;
    wire [7:0] request_ram_wdata = request_ram_we_rx
        ? request_ram_wdata_rx : request_ram_wdata_main_q;

    simple_dual_port_ram_2048x8 u_request_ram (
        .clk_i    (clk_i),
        .we_i     (request_ram_we),
        .waddr_i  (request_ram_waddr),
        .wdata_i  (request_ram_wdata),
        .re_i     (request_ram_re_q),
        .raddr_i  (request_ram_raddr_q),
        .rvalid_o (request_ram_rvalid),
        .rdata_o  (request_ram_rdata)
    );

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
                if (c[0] ^ d[0])
                    c = (c >> 1) ^ 32'hedb8_8320;
                else
                    c = c >> 1;
                d = d >> 1;
            end
            crc32_byte = c;
        end
    endfunction

    function automatic logic key_control_opcode(input logic [7:0] opcode);
        begin
            case (opcode)
                OP_KEY_LOAD_BEGIN,
                OP_KEY_LOAD_CHUNK,
                OP_KEY_LOAD_COMMIT,
                OP_KEY_LOAD_ABORT,
                OP_KEY_STATUS,
                OP_ZEROIZE,
                OP_SESSION_ACTIVATE: key_control_opcode = 1'b1;
                default: key_control_opcode = 1'b0;
            endcase
        end
    endfunction

    wire endpoint_accepts_request = (state_q == S_IDLE) && !response_pending_o;
    wire [10:0] rx_payload_index = rx_index_q - 11'd10;

    always_comb begin
        request_ram_we_rx    = 1'b0;
        request_ram_waddr_rx = 11'd0;
        request_ram_wdata_rx = request_byte_i;

        if (rx_active_q && request_byte_valid_i &&
            (rx_index_q >= 11'd10) &&
            (rx_payload_index < rx_payload_len_q) &&
            !key_control_opcode(rx_opcode_q)) begin
            request_ram_we_rx    = 1'b1;
            request_ram_waddr_rx = rx_payload_index;
        end
    end

    integer si;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_active_q      <= 1'b0;
            rx_index_q       <= 11'd0;
            rx_header_ok_q   <= 1'b0;
            rx_version_q     <= 8'h00;
            rx_opcode_q      <= 8'h00;
            rx_flags_q       <= 8'h00;
            rx_reserved_q    <= 8'h00;
            rx_txid_q        <= 16'h0000;
            rx_payload_len_q <= 16'd0;
            rx_crc_q         <= 32'hffff_ffff;
            rx_wire_crc_q    <= 32'h0000_0000;
            rx_frame_valid_q <= 1'b0;
            rx_frame_error_q <= 1'b0;
            for (si = 0; si < 32; si = si + 1)
                small_payload_q[si] <= 8'h00;
        end else begin
            rx_frame_valid_q <= 1'b0;
            rx_frame_error_q <= 1'b0;

            if (zeroize_i || scrub_small_q) begin
                for (si = 0; si < 32; si = si + 1)
                    small_payload_q[si] <= 8'h00;
            end

            if (request_txn_start_i) begin
                if (endpoint_accepts_request) begin
                    rx_active_q      <= 1'b1;
                    rx_index_q       <= 11'd0;
                    rx_header_ok_q   <= 1'b1;
                    rx_version_q     <= 8'h00;
                    rx_opcode_q      <= 8'h00;
                    rx_flags_q       <= 8'h00;
                    rx_reserved_q    <= 8'h00;
                    rx_txid_q        <= 16'h0000;
                    rx_payload_len_q <= 16'd0;
                    rx_crc_q         <= 32'hffff_ffff;
                    rx_wire_crc_q    <= 32'h0000_0000;
                end else begin
                    rx_active_q <= 1'b0;
                end
            end

            if (rx_active_q && request_byte_valid_i) begin
                case (rx_index_q)
                    11'd0: if (request_byte_i != 8'ha5) rx_header_ok_q <= 1'b0;
                    11'd1: if (request_byte_i != 8'h5a) rx_header_ok_q <= 1'b0;
                    11'd2: begin
                        rx_version_q <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd3: begin
                        rx_opcode_q <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd4: begin
                        rx_flags_q <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd5: begin
                        rx_reserved_q <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd6: begin
                        rx_txid_q[15:8] <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd7: begin
                        rx_txid_q[7:0] <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd8: begin
                        rx_payload_len_q[15:8] <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                    end
                    11'd9: begin
                        rx_payload_len_q[7:0] <= request_byte_i;
                        rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                        if ({rx_payload_len_q[15:8],request_byte_i} > 16'd1024)
                            rx_header_ok_q <= 1'b0;
                    end
                    default: begin
                        if (rx_index_q < (11'd10 + rx_payload_len_q)) begin
                            rx_crc_q <= crc32_byte(rx_crc_q, request_byte_i);
                            if ((rx_payload_index < 11'd32) &&
                                key_control_opcode(rx_opcode_q))
                                small_payload_q[rx_payload_index] <= request_byte_i;
                            else if ((rx_payload_index < 11'd32) &&
                                     !key_control_opcode(rx_opcode_q))
                                small_payload_q[rx_payload_index] <= request_byte_i;
                        end else if (rx_index_q < (11'd14 + rx_payload_len_q)) begin
                            rx_wire_crc_q <= {rx_wire_crc_q[23:0], request_byte_i};
                        end else begin
                            rx_header_ok_q <= 1'b0;
                        end
                    end
                endcase
                rx_index_q <= rx_index_q + 1'b1;
            end

            if (request_txn_end_i && rx_active_q) begin
                rx_active_q <= 1'b0;
                if (rx_header_ok_q &&
                    (rx_version_q == 8'h01) &&
                    (rx_flags_q == 8'h00) &&
                    (rx_reserved_q == 8'h00) &&
                    (rx_payload_len_q <= 16'd1024) &&
                    (rx_index_q == (11'd14 + rx_payload_len_q)) &&
                    ((rx_crc_q ^ 32'hffff_ffff) == rx_wire_crc_q)) begin
                    rx_frame_valid_q <= 1'b1;
                end else begin
                    rx_frame_error_q <= 1'b1;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Session context and STP TX
    // ---------------------------------------------------------------------
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

    wire secret_zeroize = zeroize_i || command_zeroize_q;

    primer1_session_context u_session (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .zeroize_i              (secret_zeroize),
        .begin_i                (session_begin_q),
        .begin_session_id_i     (session_begin_id_q),
        .begin_direction_i      (session_begin_direction_q),
        .begin_total_len_i      (session_begin_len_q),
        .chunk_valid_i          (session_chunk_valid_q),
        .chunk_offset_i         (session_chunk_offset_q),
        .chunk_data_i           (session_chunk_data_q),
        .commit_i               (session_commit_q),
        .commit_session_id_i    (session_commit_id_q),
        .abort_i                (session_abort_q),
        .activate_i             (session_activate_q),
        .activate_session_id_i  (session_activate_id_q),
        .sequence_commit_i      (session_sequence_commit_q),
        .key_loading_o          (session_key_loading),
        .staging_complete_o     (session_staging_complete),
        .key_valid_o            (session_key_valid),
        .session_active_o       (session_active),
        .session_id_o           (session_id),
        .traffic_key_o          (traffic_key),
        .nonce_prefix_o         (nonce_prefix),
        .tx_sequence_o          (tx_sequence),
        .error_valid_o          (session_error_valid),
        .error_code_o           (session_error_code)
    );

    logic stp_start_q;
    logic stp_discard_q;
    logic [191:0] telemetry_q;
    logic stp_ready;
    logic stp_packet_valid;
    logic [6:0] stp_packet_length;
    logic [6:0] stp_packet_addr;
    logic [7:0] stp_packet_data;
    logic stp_done;
    logic stp_error_valid;
    logic [15:0] stp_error_code;
    logic tx_packet_pending_q;
    logic [63:0] tx_packet_sequence_q;

    stp_tx_telemetry u_stp_tx (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .zeroize_i          (secret_zeroize),
        .start_i            (stp_start_q),
        .ready_o            (stp_ready),
        .session_id_i       (session_id),
        .sequence_i         (tx_sequence),
        .traffic_key_i      (traffic_key),
        .nonce_prefix_i     (nonce_prefix),
        .telemetry_i        (telemetry_q),
        .flags_i            (16'h0000),
        .discard_retained_i (stp_discard_q),
        .packet_valid_o     (stp_packet_valid),
        .packet_length_o    (stp_packet_length),
        .packet_addr_i      (stp_packet_addr),
        .packet_data_o      (stp_packet_data),
        .done_o             (stp_done),
        .error_valid_o      (stp_error_valid),
        .error_code_o       (stp_error_code)
    );

    // ---------------------------------------------------------------------
    // Forward NTT adapter
    // ---------------------------------------------------------------------
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

    forward_ntt_core u_forward_ntt (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .start_i         (ntt_start_q),
        .busy_o          (ntt_busy),
        .done_o          (ntt_done),
        .host_re_i       (ntt_host_re_q),
        .host_we_i       (ntt_host_we_q),
        .host_addr_i     (ntt_host_addr_q),
        .host_wdata_i    (ntt_host_wdata_q),
        .host_ready_o    (ntt_host_ready),
        .host_rvalid_o   (ntt_host_rvalid),
        .host_rdata_o    (ntt_host_rdata),
        .stage_o         (ntt_stage),
        .stage_barrier_o (ntt_stage_barrier),
        .active_bank_o   (ntt_active_bank)
    );

    // ---------------------------------------------------------------------
    // Response RAM/cache and builder
    // ---------------------------------------------------------------------
    logic response_ram_we;
    logic [10:0] response_ram_waddr;
    logic [7:0] response_ram_wdata;
    logic response_ram_rvalid;
    logic [7:0] response_ram_rdata;

    simple_dual_port_ram_2048x8 u_response_ram (
        .clk_i    (clk_i),
        .we_i     (response_ram_we),
        .waddr_i  (response_ram_waddr),
        .wdata_i  (response_ram_wdata),
        .re_i     (1'b1),
        .raddr_i  (response_addr_i),
        .rvalid_o (response_ram_rvalid),
        .rdata_o  (response_ram_rdata)
    );

    assign response_data_o = response_ram_rdata;

    logic builder_start_q;
    logic builder_ready;
    logic builder_extra_request;
    logic [10:0] builder_extra_index;
    logic builder_extra_valid;
    logic [7:0] builder_extra_data;
    logic builder_done;
    logic [10:0] builder_frame_length;

    logic [15:0] build_status_q;
    logic [15:0] build_detail_q;
    logic [31:0] build_state_q;
    logic [31:0] build_value_q;
    logic        build_error_q;
    logic [10:0] build_extra_length_q;

    btp_response_builder u_response_builder (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .abort_i           (zeroize_i),
        .start_i           (builder_start_q),
        .ready_o           (builder_ready),
        .opcode_i          (rx_opcode_q),
        .transaction_id_i  (rx_txid_q),
        .error_i           (build_error_q),
        .status_i          (build_status_q),
        .detail_i          (build_detail_q),
        .device_state_i    (build_state_q),
        .value_i           (build_value_q),
        .extra_length_i    (build_extra_length_q),
        .extra_request_o   (builder_extra_request),
        .extra_index_o     (builder_extra_index),
        .extra_valid_i     (builder_extra_valid),
        .extra_data_i      (builder_extra_data),
        .ram_we_o          (response_ram_we),
        .ram_waddr_o       (response_ram_waddr),
        .ram_wdata_o       (response_ram_wdata),
        .done_o            (builder_done),
        .frame_length_o    (builder_frame_length)
    );

    logic        cache_valid_q;
    logic [15:0] cache_txid_q;
    logic [7:0]  cache_opcode_q;
    logic [15:0] cache_payload_len_q;
    logic [31:0] cache_request_crc_q;
    logic [10:0] cache_response_len_q;
    logic [24:0] cache_age_q;

    // ---------------------------------------------------------------------
    // Common status and response-extra source
    // ---------------------------------------------------------------------
    logic [15:0] last_error_q;
    logic fatal_q;
    logic [15:0] single_coeff_q;
    logic [15:0] poly_count_q;
    logic [15:0] poly_index_q;
    logic [7:0]  poly_hi_q;
    logic [15:0] key_chunk_offset_q;
    logic [15:0] key_chunk_length_q;
    logic [15:0] key_chunk_index_q;
    logic [15:0] action_error_q;
    logic [7:0]  pending_action_q;
    logic        extra_ram_pending_q;

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

    logic extra_direct_valid;
    logic [7:0] extra_direct_data;
    logic extra_needs_ram;

    always_comb begin
        extra_direct_valid = builder_extra_request;
        extra_direct_data  = 8'h00;
        extra_needs_ram     = 1'b0;

        case (extra_mode_q)
            EXTRA_NONE: begin
                extra_direct_data = 8'h00;
            end

            EXTRA_DEVICE_ID: begin
                case (builder_extra_index)
                    11'd0:  extra_direct_data = DEVICE_ID_PRIMER1[31:24];
                    11'd1:  extra_direct_data = DEVICE_ID_PRIMER1[23:16];
                    11'd2:  extra_direct_data = DEVICE_ID_PRIMER1[15:8];
                    11'd3:  extra_direct_data = DEVICE_ID_PRIMER1[7:0];
                    11'd4:  extra_direct_data = RTL_VERSION[31:24];
                    11'd5:  extra_direct_data = RTL_VERSION[23:16];
                    11'd6:  extra_direct_data = RTL_VERSION[15:8];
                    11'd7:  extra_direct_data = RTL_VERSION[7:0];
                    11'd8:  extra_direct_data = CAPABILITIES[31:24];
                    11'd9:  extra_direct_data = CAPABILITIES[23:16];
                    11'd10: extra_direct_data = CAPABILITIES[15:8];
                    11'd11: extra_direct_data = CAPABILITIES[7:0];
                    default: extra_direct_data = 8'h00;
                endcase
            end

            EXTRA_PING: begin
                extra_direct_valid = 1'b0;
                extra_needs_ram = builder_extra_request;
            end

            EXTRA_LAST_ERROR: begin
                extra_direct_data = (builder_extra_index == 0)
                    ? last_error_q[15:8] : last_error_q[7:0];
            end

            EXTRA_SINGLE_COEFF: begin
                extra_direct_data = (builder_extra_index == 0)
                    ? single_coeff_q[15:8] : single_coeff_q[7:0];
            end

            EXTRA_READ_POLY: begin
                if (builder_extra_index == 0)
                    extra_direct_data = poly_count_q[15:8];
                else if (builder_extra_index == 1)
                    extra_direct_data = poly_count_q[7:0];
                else begin
                    extra_direct_valid = 1'b0;
                    extra_needs_ram = builder_extra_request;
                end
            end

            EXTRA_KEY_STATUS: begin
                case (builder_extra_index)
                    11'd0: extra_direct_data = session_id[31:24];
                    11'd1: extra_direct_data = session_id[23:16];
                    11'd2: extra_direct_data = session_id[15:8];
                    11'd3: extra_direct_data = session_id[7:0];
                    11'd4: extra_direct_data = {5'h0,session_active,
                                                session_key_valid,session_key_loading};
                    11'd5: extra_direct_data = session_staging_complete ? 8'h01 : 8'h00;
                    11'd6: extra_direct_data = 8'h00;
                    11'd7: extra_direct_data = 8'h00;
                    11'd8: extra_direct_data = tx_sequence[63:56];
                    11'd9: extra_direct_data = tx_sequence[55:48];
                    11'd10: extra_direct_data = tx_sequence[47:40];
                    11'd11: extra_direct_data = tx_sequence[39:32];
                    11'd12: extra_direct_data = tx_sequence[31:24];
                    11'd13: extra_direct_data = tx_sequence[23:16];
                    11'd14: extra_direct_data = tx_sequence[15:8];
                    11'd15: extra_direct_data = tx_sequence[7:0];
                    default: extra_direct_data = 8'h00;
                endcase
            end

            EXTRA_NTT_STATUS: begin
                if (builder_extra_index == 0)
                    extra_direct_data = {5'h0,ntt_stage};
                else
                    extra_direct_data = {5'h0,ntt_stage_barrier,
                                         ntt_active_bank,ntt_done_latched_q};
            end

            EXTRA_TELEMETRY: begin
                if (builder_extra_index < 8) begin
                    case (builder_extra_index)
                        11'd0: extra_direct_data = tx_packet_sequence_q[63:56];
                        11'd1: extra_direct_data = tx_packet_sequence_q[55:48];
                        11'd2: extra_direct_data = tx_packet_sequence_q[47:40];
                        11'd3: extra_direct_data = tx_packet_sequence_q[39:32];
                        11'd4: extra_direct_data = tx_packet_sequence_q[31:24];
                        11'd5: extra_direct_data = tx_packet_sequence_q[23:16];
                        11'd6: extra_direct_data = tx_packet_sequence_q[15:8];
                        default: extra_direct_data = tx_packet_sequence_q[7:0];
                    endcase
                end else if (builder_extra_index == 8)
                    extra_direct_data = 8'h00;
                else if (builder_extra_index == 9)
                    extra_direct_data = {1'b0,stp_packet_length};
                else
                    extra_direct_data = stp_packet_data;
            end

            EXTRA_COUNTERS: begin
                case (builder_extra_index)
                    11'd0: extra_direct_data = tx_sequence[63:56];
                    11'd1: extra_direct_data = tx_sequence[55:48];
                    11'd2: extra_direct_data = tx_sequence[47:40];
                    11'd3: extra_direct_data = tx_sequence[39:32];
                    11'd4: extra_direct_data = tx_sequence[31:24];
                    11'd5: extra_direct_data = tx_sequence[23:16];
                    11'd6: extra_direct_data = tx_sequence[15:8];
                    default: extra_direct_data = tx_sequence[7:0];
                endcase
            end

            default: extra_direct_data = 8'h00;
        endcase
    end

    assign stp_packet_addr = (extra_mode_q == EXTRA_TELEMETRY &&
                              builder_extra_index >= 11'd10)
        ? builder_extra_index[6:0] - 7'd10 : 7'd0;

    // RAM-backed extra byte handshaking. The response builder holds the same
    // extra_index until extra_valid is asserted.
    assign builder_extra_valid = extra_direct_valid ||
                                 (request_ram_rvalid && extra_ram_pending_q);
    assign builder_extra_data = extra_direct_valid
        ? extra_direct_data : request_ram_rdata;

    // ---------------------------------------------------------------------
    // Endpoint control FSM
    // ---------------------------------------------------------------------
    logic [7:0] build_opcode_q;
    logic [15:0] build_txid_q;
    logic [15:0] current_request_payload_len_q;
    logic [31:0] current_request_crc_q;

    // Builder uses live RX opcode/transaction_id ports. During response build
    // those RX registers are stable because the endpoint does not accept a new
    // request. Aliases below document that dependency.
    always_comb begin
        build_opcode_q = rx_opcode_q;
        build_txid_q   = rx_txid_q;
    end

    assign key_valid_o      = session_key_valid;
    assign session_active_o = session_active;
    assign last_error_o     = last_error_q;
    assign fault_o          = fatal_q;
    assign busy_o           = (state_q != S_IDLE) || rx_active_q ||
                              response_pending_o || ntt_busy || !stp_ready;

    // The response RAM has one-cycle synchronous read latency. Address zero is
    // continuously requested before CS falls and every subsequent byte has far
    // more than one 27 MHz clock of setup at the 1 MHz bring-up SPI rate.
    logic response_ram_rvalid_unused;
    always_comb response_ram_rvalid_unused = response_ram_rvalid;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q                    <= S_IDLE;
            response_pending_o         <= 1'b0;
            response_length_o          <= 11'd0;
            protocol_error_count_o     <= 32'h0000_0000;
            last_error_q               <= 16'h0000;
            fatal_q                    <= 1'b0;
            cache_valid_q              <= 1'b0;
            cache_txid_q               <= 16'h0000;
            cache_opcode_q             <= 8'h00;
            cache_payload_len_q        <= 16'd0;
            cache_request_crc_q        <= 32'h0000_0000;
            cache_response_len_q       <= 11'd0;
            cache_age_q                <= 25'd0;
            build_status_q             <= ERR_OK;
            build_detail_q             <= 16'h0000;
            build_state_q              <= 32'h0000_0000;
            build_value_q              <= 32'h0000_0000;
            build_error_q              <= 1'b0;
            build_extra_length_q       <= 11'd0;
            extra_mode_q               <= EXTRA_NONE;
            builder_start_q            <= 1'b0;
            scrub_small_q              <= 1'b0;
            request_ram_we_main_q      <= 1'b0;
            request_ram_waddr_main_q   <= 11'd0;
            request_ram_wdata_main_q   <= 8'h00;
            request_ram_re_q           <= 1'b0;
            request_ram_raddr_q        <= 11'd0;
            extra_ram_pending_q        <= 1'b0;
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
            tx_packet_pending_q        <= 1'b0;
            tx_packet_sequence_q       <= 64'h0;
            ntt_start_q                <= 1'b0;
            ntt_done_latched_q         <= 1'b0;
            ntt_host_re_q              <= 1'b0;
            ntt_host_we_q              <= 1'b0;
            ntt_host_addr_q            <= 8'h0;
            ntt_host_wdata_q           <= 16'h0;
            ntt_cycle_q                <= 32'h0;
            ntt_last_cycle_q           <= 32'h0;
            single_coeff_q             <= 16'h0;
            poly_count_q               <= 16'h0;
            poly_index_q               <= 16'h0;
            poly_hi_q                  <= 8'h0;
            key_chunk_offset_q         <= 16'h0;
            key_chunk_length_q         <= 16'h0;
            key_chunk_index_q          <= 16'h0;
            action_error_q             <= 16'h0;
            pending_action_q           <= 8'h0;
            current_request_payload_len_q <= 16'h0;
            current_request_crc_q      <= 32'h0;
        end else if (zeroize_i) begin
            state_q                    <= S_IDLE;
            response_pending_o         <= 1'b0;
            response_length_o          <= 11'd0;
            last_error_q               <= 16'h0000;
            fatal_q                    <= 1'b0;
            cache_valid_q              <= 1'b0;
            cache_age_q                <= 25'd0;
            builder_start_q            <= 1'b0;
            scrub_small_q              <= 1'b1;
            request_ram_we_main_q      <= 1'b0;
            request_ram_re_q           <= 1'b0;
            extra_ram_pending_q        <= 1'b0;
            session_begin_q            <= 1'b0;
            session_chunk_valid_q      <= 1'b0;
            session_commit_q           <= 1'b0;
            session_abort_q            <= 1'b0;
            session_activate_q         <= 1'b0;
            session_sequence_commit_q  <= 1'b0;
            command_zeroize_q          <= 1'b0;
            stp_start_q                <= 1'b0;
            stp_discard_q              <= 1'b0;
            tx_packet_pending_q        <= 1'b0;
            tx_packet_sequence_q       <= 64'h0;
            ntt_start_q                <= 1'b0;
            ntt_host_re_q              <= 1'b0;
            ntt_host_we_q              <= 1'b0;
            ntt_done_latched_q         <= 1'b0;
        end else begin
            builder_start_q           <= 1'b0;
            scrub_small_q             <= 1'b0;
            request_ram_we_main_q     <= 1'b0;
            request_ram_re_q          <= 1'b0;
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

            if (rx_frame_error_q) begin
                protocol_error_count_o <= protocol_error_count_o + 1'b1;
                last_error_q <= ERR_BTP_FRAME;
            end

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

            if (response_read_done_i && response_pending_o)
                response_pending_o <= 1'b0;

            // Response-builder RAM source request.
            if (builder_extra_request && extra_needs_ram && !extra_ram_pending_q) begin
                request_ram_re_q <= 1'b1;
                if (extra_mode_q == EXTRA_READ_POLY)
                    request_ram_raddr_q <= builder_extra_index - 11'd2;
                else
                    request_ram_raddr_q <= builder_extra_index;
                extra_ram_pending_q <= 1'b1;
            end
            if (request_ram_rvalid && extra_ram_pending_q)
                extra_ram_pending_q <= 1'b0;

            case (state_q)
                S_IDLE: begin
                    if (rx_frame_valid_q) begin
                        current_request_payload_len_q <= rx_payload_len_q;
                        current_request_crc_q <= rx_wire_crc_q;

                        if (cache_valid_q && (rx_txid_q == cache_txid_q)) begin
                            if ((rx_opcode_q == cache_opcode_q) &&
                                (rx_payload_len_q == cache_payload_len_q) &&
                                (rx_wire_crc_q == cache_request_crc_q)) begin
                                response_length_o  <= cache_response_len_q;
                                response_pending_o <= 1'b1;
                                cache_age_q         <= 25'd0;
                            end else begin
                                // Collision invalidates the old cache because
                                // this transaction id can no longer be trusted.
                                cache_valid_q          <= 1'b0;
                                build_status_q         <= ERR_TRANSACTION_COLLISION;
                                build_detail_q         <= 16'h0000;
                                build_state_q          <= device_state_value();
                                build_value_q          <= 32'h0;
                                build_error_q          <= 1'b1;
                                build_extra_length_q   <= 11'd0;
                                extra_mode_q           <= EXTRA_NONE;
                                last_error_q           <= ERR_TRANSACTION_COLLISION;
                                state_q                <= S_BUILD_START;
                            end
                        end else begin
                            state_q <= S_DISPATCH;
                        end
                    end
                end

                S_DISPATCH: begin
                    build_status_q       <= ERR_OK;
                    build_detail_q       <= 16'h0000;
                    build_state_q        <= device_state_value();
                    build_value_q        <= 32'h0000_0000;
                    build_error_q        <= 1'b0;
                    build_extra_length_q <= 11'd0;
                    extra_mode_q         <= EXTRA_NONE;
                    action_error_q       <= 16'h0000;
                    pending_action_q     <= rx_opcode_q;

                    case (rx_opcode_q)
                        OP_GET_DEVICE_ID: begin
                            if (rx_payload_len_q != 0) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end else begin
                                extra_mode_q         <= EXTRA_DEVICE_ID;
                                build_extra_length_q <= 11'd12;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_GET_STATUS: begin
                            if (rx_payload_len_q != 0) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end
                            build_value_q <= {24'h0,fatal_q,secure_enable_i,
                                              session_active,session_key_valid,
                                              session_key_loading,ntt_done_latched_q,
                                              ntt_busy,tx_packet_pending_q};
                            state_q <= S_BUILD_START;
                        end

                        OP_GET_ERROR: begin
                            if (rx_payload_len_q != 0) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end else begin
                                extra_mode_q         <= EXTRA_LAST_ERROR;
                                build_extra_length_q <= 11'd2;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_CLEAR_ERROR: begin
                            if (rx_payload_len_q == 16'd2)
                                last_error_q <= 16'h0000;
                            else begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_SOFT_RESET: begin
                            if ((rx_payload_len_q != 16'd2) || ntt_busy || !stp_ready) begin
                                build_status_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                            end else begin
                                session_abort_q     <= 1'b1;
                                stp_discard_q       <= 1'b1;
                                tx_packet_pending_q <= 1'b0;
                                ntt_done_latched_q  <= 1'b0;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_PING: begin
                            if (rx_payload_len_q > 16'd1012) begin
                                build_status_q <= ERR_STP_LENGTH;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_STP_LENGTH;
                            end else begin
                                extra_mode_q         <= EXTRA_PING;
                                build_extra_length_q <= rx_payload_len_q[10:0];
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_PQC_WRITE_COEFF: begin
                            if ((rx_payload_len_q != 16'd4) || !ntt_host_ready ||
                                ({small_payload_q[0],small_payload_q[1]} >= 16'd256) ||
                                ({small_payload_q[2],small_payload_q[3]} >= 16'd3329)) begin
                                build_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                state_q        <= S_BUILD_START;
                            end else begin
                                ntt_host_addr_q  <= small_payload_q[1];
                                ntt_host_wdata_q <= {small_payload_q[2],small_payload_q[3]};
                                ntt_host_we_q    <= 1'b1;
                                build_value_q    <= {16'h0,small_payload_q[2],small_payload_q[3]};
                                state_q          <= S_BUILD_START;
                            end
                        end

                        OP_PQC_READ_COEFF: begin
                            if ((rx_payload_len_q != 16'd2) || !ntt_host_ready ||
                                ({small_payload_q[0],small_payload_q[1]} >= 16'd256)) begin
                                build_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                state_q        <= S_BUILD_START;
                            end else begin
                                ntt_host_addr_q <= small_payload_q[1];
                                state_q <= S_PQC_READ_REQ;
                            end
                        end

                        OP_PQC_LOAD_POLY: begin
                            poly_count_q <= {small_payload_q[0],small_payload_q[1]};
                            poly_index_q <= 16'd0;
                            if ((rx_payload_len_q < 16'd2) || !ntt_host_ready ||
                                ({small_payload_q[0],small_payload_q[1]} > 16'd256) ||
                                (rx_payload_len_q !=
                                 (16'd2 + ({small_payload_q[0],small_payload_q[1]} << 1)))) begin
                                build_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                state_q        <= S_BUILD_START;
                            end else begin
                                state_q <= S_PQC_LOAD_REQ_HI;
                            end
                        end

                        OP_PQC_READ_POLY: begin
                            poly_count_q <= {small_payload_q[0],small_payload_q[1]};
                            poly_index_q <= 16'd0;
                            if ((rx_payload_len_q != 16'd2) || !ntt_host_ready ||
                                ({small_payload_q[0],small_payload_q[1]} > 16'd256)) begin
                                build_status_q <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= !ntt_host_ready ? ERR_BUSY : ERR_INVALID_STATE;
                                state_q        <= S_BUILD_START;
                            end else begin
                                state_q <= S_PQC_READ_POLY_REQ;
                            end
                        end

                        OP_PQC_START_NTT: begin
                            if ((rx_payload_len_q != 16'd4) || ntt_busy || !ntt_host_ready) begin
                                build_status_q <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ntt_busy ? ERR_BUSY : ERR_INVALID_STATE;
                            end else begin
                                ntt_start_q       <= 1'b1;
                                ntt_done_latched_q <= 1'b0;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_PQC_GET_RESULT: begin
                            build_value_q        <= ntt_last_cycle_q;
                            extra_mode_q         <= EXTRA_NTT_STATUS;
                            build_extra_length_q <= 11'd2;
                            state_q              <= S_BUILD_START;
                        end

                        OP_PQC_START_INTT,
                        OP_PQC_POINTWISE_MUL,
                        OP_PQC_POLY_ADD_SUB: begin
                            build_status_q <= ERR_INVALID_STATE;
                            build_error_q  <= 1'b1;
                            last_error_q   <= ERR_INVALID_STATE;
                            state_q        <= S_BUILD_START;
                        end

                        OP_KEY_LOAD_BEGIN: begin
                            if (rx_payload_len_q != 16'd7) begin
                                build_status_q <= ERR_KEY_COMMIT;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_KEY_COMMIT;
                                scrub_small_q  <= 1'b1;
                                state_q        <= S_BUILD_START;
                            end else begin
                                session_begin_id_q <= {small_payload_q[0],small_payload_q[1],
                                                       small_payload_q[2],small_payload_q[3]};
                                session_begin_direction_q <= small_payload_q[4];
                                session_begin_len_q <= {small_payload_q[5],small_payload_q[6]};
                                session_begin_q <= 1'b1;
                                state_q <= S_ACTION_WAIT1;
                            end
                        end

                        OP_KEY_LOAD_CHUNK: begin
                            key_chunk_offset_q <= {small_payload_q[0],small_payload_q[1]};
                            key_chunk_length_q <= rx_payload_len_q - 16'd2;
                            key_chunk_index_q  <= 16'd0;
                            if ((rx_payload_len_q < 16'd3) ||
                                (rx_payload_len_q > 16'd26) || !session_key_loading ||
                                (({small_payload_q[0],small_payload_q[1]} +
                                  (rx_payload_len_q - 16'd2)) > 16'd24)) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                                scrub_small_q  <= 1'b1;
                                state_q        <= S_BUILD_START;
                            end else begin
                                state_q <= S_KEY_CHUNK_FEED;
                            end
                        end

                        OP_KEY_LOAD_COMMIT: begin
                            if (rx_payload_len_q != 16'd4) begin
                                build_status_q <= ERR_KEY_COMMIT;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_KEY_COMMIT;
                                scrub_small_q  <= 1'b1;
                                state_q        <= S_BUILD_START;
                            end else begin
                                session_commit_id_q <= {small_payload_q[0],small_payload_q[1],
                                                        small_payload_q[2],small_payload_q[3]};
                                session_commit_q <= 1'b1;
                                state_q <= S_ACTION_WAIT1;
                            end
                        end

                        OP_KEY_LOAD_ABORT: begin
                            if (rx_payload_len_q != 0) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end else begin
                                session_abort_q <= 1'b1;
                            end
                            scrub_small_q <= 1'b1;
                            state_q <= S_BUILD_START;
                        end

                        OP_KEY_STATUS: begin
                            if (rx_payload_len_q != 0) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end else begin
                                extra_mode_q         <= EXTRA_KEY_STATUS;
                                build_extra_length_q <= 11'd16;
                            end
                            state_q <= S_BUILD_START;
                        end

                        OP_ZEROIZE: begin
                            if (rx_payload_len_q != 16'd2) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                            end else begin
                                command_zeroize_q   <= 1'b1;
                                tx_packet_pending_q <= 1'b0;
                                last_error_q        <= 16'h0000;
                            end
                            scrub_small_q <= 1'b1;
                            state_q <= S_BUILD_START;
                        end

                        OP_SESSION_ACTIVATE: begin
                            if (rx_payload_len_q != 16'd4) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                                scrub_small_q  <= 1'b1;
                                state_q        <= S_BUILD_START;
                            end else begin
                                session_activate_id_q <= {small_payload_q[0],small_payload_q[1],
                                                          small_payload_q[2],small_payload_q[3]};
                                session_activate_q <= 1'b1;
                                state_q <= S_ACTION_WAIT1;
                            end
                        end

                        OP_TELEMETRY_TX_SAMPLE: begin
                            if (rx_payload_len_q != 16'd24) begin
                                build_status_q <= ERR_STP_LENGTH;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_STP_LENGTH;
                                state_q        <= S_BUILD_START;
                            end else if (!secure_enable_i) begin
                                build_status_q <= ERR_SECURE_DISABLED;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_SECURE_DISABLED;
                                state_q        <= S_BUILD_START;
                            end else if (!session_key_valid) begin
                                build_status_q <= ERR_NO_KEY;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_NO_KEY;
                                state_q        <= S_BUILD_START;
                            end else if (!session_active) begin
                                build_status_q <= ERR_INVALID_STATE;
                                build_error_q  <= 1'b1;
                                last_error_q   <= ERR_INVALID_STATE;
                                state_q        <= S_BUILD_START;
                            end else begin
                                for (si = 0; si < 24; si = si + 1)
                                    telemetry_q[8*si +: 8] <= small_payload_q[si];
                                if (tx_packet_pending_q)
                                    state_q <= S_TX_COMMIT_PREVIOUS;
                                else
                                    state_q <= S_TX_START;
                            end
                        end

                        OP_STP_GET_COUNTERS: begin
                            extra_mode_q         <= EXTRA_COUNTERS;
                            build_extra_length_q <= 11'd8;
                            build_value_q        <= {31'h0,tx_packet_pending_q};
                            state_q              <= S_BUILD_START;
                        end

                        default: begin
                            build_status_q <= ERR_INVALID_STATE;
                            build_error_q  <= 1'b1;
                            last_error_q   <= ERR_INVALID_STATE;
                            state_q        <= S_BUILD_START;
                        end
                    endcase
                end

                S_ACTION_WAIT1: begin
                    // Let primer1_session_context consume the one-cycle pulse.
                    state_q <= S_ACTION_WAIT2;
                end

                S_ACTION_WAIT2: begin
                    if (session_error_valid) begin
                        build_status_q <= session_error_code;
                        build_error_q  <= 1'b1;
                        last_error_q   <= session_error_code;
                    end
                    build_state_q <= device_state_value();
                    scrub_small_q <= 1'b1;
                    state_q <= S_BUILD_START;
                end

                S_KEY_CHUNK_FEED: begin
                    if (key_chunk_index_q < key_chunk_length_q) begin
                        session_chunk_offset_q <= key_chunk_offset_q + key_chunk_index_q;
                        session_chunk_data_q   <= small_payload_q[2 + key_chunk_index_q];
                        session_chunk_valid_q  <= 1'b1;
                        key_chunk_index_q      <= key_chunk_index_q + 1'b1;
                        if (session_error_valid)
                            action_error_q <= session_error_code;
                    end else begin
                        state_q <= S_KEY_CHUNK_DRAIN1;
                    end
                end

                S_KEY_CHUNK_DRAIN1: begin
                    if (session_error_valid)
                        action_error_q <= session_error_code;
                    state_q <= S_KEY_CHUNK_DRAIN2;
                end

                S_KEY_CHUNK_DRAIN2: begin
                    if (session_error_valid)
                        action_error_q <= session_error_code;
                    if ((action_error_q != 16'h0000) || session_error_valid) begin
                        build_status_q <= session_error_valid
                            ? session_error_code : action_error_q;
                        build_error_q <= 1'b1;
                        last_error_q <= session_error_valid
                            ? session_error_code : action_error_q;
                    end
                    build_state_q <= device_state_value();
                    scrub_small_q <= 1'b1;
                    state_q <= S_BUILD_START;
                end

                S_PQC_LOAD_REQ_HI: begin
                    if (poly_index_q < poly_count_q) begin
                        request_ram_raddr_q <= 11'd2 + (poly_index_q << 1);
                        request_ram_re_q <= 1'b1;
                        state_q <= S_PQC_LOAD_WAIT_HI;
                    end else begin
                        build_value_q <= {16'h0,poly_count_q};
                        state_q <= S_BUILD_START;
                    end
                end

                S_PQC_LOAD_WAIT_HI: begin
                    if (request_ram_rvalid) begin
                        poly_hi_q <= request_ram_rdata;
                        state_q <= S_PQC_LOAD_REQ_LO;
                    end
                end

                S_PQC_LOAD_REQ_LO: begin
                    request_ram_raddr_q <= 11'd3 + (poly_index_q << 1);
                    request_ram_re_q <= 1'b1;
                    state_q <= S_PQC_LOAD_WAIT_LO;
                end

                S_PQC_LOAD_WAIT_LO: begin
                    if (request_ram_rvalid) begin
                        if ({poly_hi_q,request_ram_rdata} >= 16'd3329) begin
                            build_status_q <= ERR_INVALID_STATE;
                            build_error_q  <= 1'b1;
                            last_error_q   <= ERR_INVALID_STATE;
                            state_q        <= S_BUILD_START;
                        end else begin
                            ntt_host_addr_q  <= poly_index_q[7:0];
                            ntt_host_wdata_q <= {poly_hi_q,request_ram_rdata};
                            state_q          <= S_PQC_LOAD_WRITE;
                        end
                    end
                end

                S_PQC_LOAD_WRITE: begin
                    if (ntt_host_ready) begin
                        ntt_host_we_q <= 1'b1;
                        poly_index_q  <= poly_index_q + 1'b1;
                        state_q       <= S_PQC_LOAD_REQ_HI;
                    end
                end

                S_PQC_READ_REQ: begin
                    ntt_host_re_q <= 1'b1;
                    state_q <= S_PQC_READ_WAIT;
                end

                S_PQC_READ_WAIT: begin
                    if (ntt_host_rvalid) begin
                        single_coeff_q       <= ntt_host_rdata;
                        build_value_q        <= {16'h0,ntt_host_rdata};
                        extra_mode_q         <= EXTRA_SINGLE_COEFF;
                        build_extra_length_q <= 11'd2;
                        state_q              <= S_BUILD_START;
                    end
                end

                S_PQC_READ_POLY_REQ: begin
                    if (poly_index_q < poly_count_q) begin
                        ntt_host_addr_q <= poly_index_q[7:0];
                        ntt_host_re_q   <= 1'b1;
                        state_q         <= S_PQC_READ_POLY_WAIT;
                    end else begin
                        extra_mode_q         <= EXTRA_READ_POLY;
                        build_extra_length_q <= 11'd2 + (poly_count_q << 1);
                        build_value_q        <= {16'h0,poly_count_q};
                        state_q              <= S_BUILD_START;
                    end
                end

                S_PQC_READ_POLY_WAIT: begin
                    if (ntt_host_rvalid) begin
                        single_coeff_q <= ntt_host_rdata;
                        state_q <= S_PQC_READ_POLY_STORE_HI;
                    end
                end

                S_PQC_READ_POLY_STORE_HI: begin
                    request_ram_we_main_q    <= 1'b1;
                    request_ram_waddr_main_q <= poly_index_q << 1;
                    request_ram_wdata_main_q <= single_coeff_q[15:8];
                    state_q <= S_PQC_READ_POLY_STORE_LO;
                end

                S_PQC_READ_POLY_STORE_LO: begin
                    request_ram_we_main_q    <= 1'b1;
                    request_ram_waddr_main_q <= (poly_index_q << 1) + 1'b1;
                    request_ram_wdata_main_q <= single_coeff_q[7:0];
                    poly_index_q <= poly_index_q + 1'b1;
                    state_q <= S_PQC_READ_POLY_REQ;
                end

                S_TX_COMMIT_PREVIOUS: begin
                    // A new unique TX request is only legal after firmware has
                    // received the previous receiver commit acknowledgement.
                    // That new request therefore commits the retained sequence.
                    session_sequence_commit_q <= 1'b1;
                    state_q <= S_TX_COMMIT_WAIT1;
                end

                S_TX_COMMIT_WAIT1: begin
                    state_q <= S_TX_COMMIT_WAIT2;
                end

                S_TX_COMMIT_WAIT2: begin
                    stp_discard_q       <= 1'b1;
                    tx_packet_pending_q <= 1'b0;
                    state_q             <= S_TX_DISCARD_WAIT;
                end

                S_TX_DISCARD_WAIT: begin
                    if (stp_ready)
                        state_q <= S_TX_START;
                end

                S_TX_START: begin
                    if (stp_ready) begin
                        stp_start_q <= 1'b1;
                        state_q <= S_TX_WAIT;
                    end
                end

                S_TX_WAIT: begin
                    if (stp_error_valid) begin
                        build_status_q <= stp_error_code;
                        build_error_q  <= 1'b1;
                        last_error_q   <= stp_error_code;
                        state_q        <= S_BUILD_START;
                    end else if (stp_done && stp_packet_valid) begin
                        tx_packet_pending_q  <= 1'b1;
                        tx_packet_sequence_q <= tx_sequence;
                        extra_mode_q         <= EXTRA_TELEMETRY;
                        build_extra_length_q <= 11'd74;
                        build_value_q        <= {25'h0,stp_packet_length};
                        state_q              <= S_BUILD_START;
                    end
                end

                S_BUILD_START: begin
                    if (builder_ready) begin
                        build_state_q   <= device_state_value();
                        builder_start_q <= 1'b1;
                        state_q         <= S_BUILD_WAIT;
                    end
                end

                S_BUILD_WAIT: begin
                    if (builder_done) begin
                        response_length_o       <= builder_frame_length;
                        response_pending_o      <= 1'b1;
                        cache_valid_q           <= 1'b1;
                        cache_txid_q            <= rx_txid_q;
                        cache_opcode_q          <= rx_opcode_q;
                        cache_payload_len_q     <= current_request_payload_len_q;
                        cache_request_crc_q     <= current_request_crc_q;
                        cache_response_len_q    <= builder_frame_length;
                        cache_age_q             <= 25'd0;
                        state_q                 <= S_IDLE;
                    end
                end

                // These states are reserved for future extra-source pipelines;
                // current RAM-backed builder handshake runs concurrently above.
                S_EXTRA_RAM_REQ: state_q <= S_EXTRA_RAM_WAIT;
                S_EXTRA_RAM_WAIT: state_q <= S_BUILD_WAIT;

                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(response_pending_o && rx_active_q))
                else $error("primer1_btp_endpoint_v2: RX active while response pending");
            if (session_key_valid)
                assert (session_id != 32'h0000_0000)
                    else $error("primer1_btp_endpoint_v2: key_valid with zero session_id");
        end
    end
`endif
endmodule
