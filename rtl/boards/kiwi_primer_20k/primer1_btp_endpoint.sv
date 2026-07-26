module primer1_btp_endpoint #(
    parameter integer CLOCK_HZ = 27_000_000,
    parameter logic [7:0] KEY_DIRECTION_ID = 8'h01,
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,

    /* Physical/supervisor security controls. */
    input  logic transport_zeroize_i,
    input  logic secure_enable_i,
    input  logic fatal_latched_i,

    /* Parsed BTP request. Payload remains stable until request_accept_o. */
    input  logic request_valid_i,
    output logic request_accept_o,
    input  logic [7:0] request_opcode_i,
    input  logic [7:0] request_flags_i,
    input  logic [15:0] request_transaction_id_i,
    input  logic [15:0] request_payload_len_i,
    input  logic [31:0] request_crc32_i,
    input  logic request_error_i,
    input  logic [15:0] request_error_code_i,
    output logic [9:0] request_payload_rd_addr_o,
    input  logic [7:0] request_payload_rd_data_i,

    /* SPI response image/cache interface. */
    input  logic tx_frame_ready_i,
    input  logic tx_frame_consumed_i,
    output logic tx_frame_commit_o,
    output logic [COUNT_W-1:0] tx_frame_len_o,
    output logic tx_wr_en_o,
    output logic [COUNT_W-1:0] tx_wr_addr_o,
    output logic [7:0] tx_wr_data_o,

    /* Receiver acknowledgement/reconciliation comes from the system control plane. */
    input  logic packet_commit_i,

    output logic irq_pending_o,
    output logic busy_o,
    output logic key_valid_o,
    output logic session_active_o,
    output logic retained_packet_o,
    output logic ntt_busy_o,
    output logic [15:0] last_error_code_o
);
    import fpst_btp_pkg::*;

    localparam integer CACHE_CYCLES = CLOCK_HZ;
    localparam integer CACHE_COUNT_W = $clog2(CACHE_CYCLES + 1);

    typedef enum logic [5:0] {
        ST_IDLE,
        ST_ARG_READ,
        ST_EXEC_ARG,
        ST_KEY_BEGIN_PULSE,
        ST_KEY_CHUNK_OFFSET_HI,
        ST_KEY_CHUNK_OFFSET_LO,
        ST_KEY_CHUNK_WRITE,
        ST_KEY_COMMIT_PULSE,
        ST_KEY_COMMIT_WAIT,
        ST_KEY_ABORT_PULSE,
        ST_SESSION_ACTIVATE_PULSE,
        ST_SESSION_ACTIVATE_WAIT,
        ST_ZEROIZE_PULSE,
        ST_TELEMETRY_COPY,
        ST_TELEMETRY_START,
        ST_TELEMETRY_WAIT,
        ST_NTT_WRITE_PULSE,
        ST_NTT_READ_PULSE,
        ST_NTT_READ_WAIT,
        ST_NTT_START_PULSE,
        ST_POLY_VALIDATE_HI,
        ST_POLY_VALIDATE_LO,
        ST_POLY_WRITE_HI,
        ST_POLY_WRITE_LO,
        ST_RESP_FILL,
        ST_RESP_START,
        ST_RESP_BUILD_WAIT,
        ST_RESP_COMMIT,
        ST_CACHE_RESTORE,
        ST_CACHE_RECOMMIT
    } state_t;

    typedef enum logic [2:0] {
        ARG_NONE,
        ARG_KEY_BEGIN,
        ARG_KEY_COMMIT,
        ARG_SESSION_ACTIVATE,
        ARG_PQC_WRITE,
        ARG_PQC_READ,
        ARG_PQC_START,
        ARG_POLY_COUNT
    } arg_kind_t;

    typedef enum logic [2:0] {
        RESP_GENERIC,
        RESP_INLINE,
        RESP_PING,
        RESP_TELEMETRY
    } response_kind_t;

    state_t state_q;
    arg_kind_t arg_kind_q;
    response_kind_t response_kind_q;

    logic [7:0] current_opcode_q;
    logic [15:0] current_transaction_id_q;
    logic [15:0] current_payload_len_q;
    logic [31:0] current_request_crc32_q;

    logic [7:0] arg_q [0:7];
    logic [3:0] arg_index_q;
    logic [15:0] chunk_base_q;
    logic [5:0] chunk_index_q;
    logic [191:0] telemetry_sample_q;
    logic [5:0] telemetry_index_q;

    /* Response description. */
    logic [15:0] response_status_q;
    logic [15:0] response_detail_q;
    logic [31:0] response_device_state_q;
    logic [31:0] response_data_len_q;
    logic [15:0] response_payload_len_q;
    logic response_error_q;
    logic response_accept_request_after_fill_q;
    logic response_cache_capture_q;
    logic [127:0] response_inline_data_q;
    logic [9:0] response_fill_index_q;
    logic [7:0] response_fill_byte;

    /* Response builder -> SPI TX memory. */
    logic builder_payload_wr_en;
    logic [9:0] builder_payload_wr_addr;
    logic [7:0] builder_payload_wr_data;
    logic builder_start;
    logic builder_busy;
    logic builder_done;
    logic [COUNT_W-1:0] builder_frame_len;
    logic builder_tx_wr_en;
    logic [COUNT_W-1:0] builder_tx_wr_addr;
    logic [7:0] builder_tx_wr_data;

    /* Independent cached copy of the most recent completed response. */
    logic [7:0] cache_mem [0:MAX_FRAME_BYTES-1];
    logic cache_valid_q;
    logic [15:0] cache_transaction_id_q;
    logic [7:0] cache_opcode_q;
    logic [15:0] cache_payload_len_q;
    logic [31:0] cache_request_crc32_q;
    logic [COUNT_W-1:0] cache_frame_len_q;
    logic [CACHE_COUNT_W-1:0] cache_age_q;
    logic [COUNT_W-1:0] cache_restore_index_q;

    /* Key/session state. */
    logic secret_zeroize;
    logic session_load_begin;
    logic [31:0] session_load_session_id;
    logic [15:0] session_load_total_len;
    logic session_load_chunk;
    logic [5:0] session_load_offset;
    logic [7:0] session_load_byte;
    logic session_load_commit;
    logic session_load_abort;
    logic session_activate;
    logic [31:0] session_activate_id;
    logic session_key_loading;
    logic [31:0] session_id;
    logic [127:0] traffic_key;
    logic [63:0] nonce_prefix;
    logic [63:0] tx_sequence;
    logic session_sequence_commit;
    logic session_staging_complete;
    logic session_staging_conflict;
    logic session_commit_ok;
    logic session_commit_failed;
    logic [31:0] loading_session_id_q;
    logic [7:0] loading_direction_q;
    logic [15:0] loading_total_len_q;

    /* Telemetry TX. */
    logic stp_start;
    logic stp_ready;
    logic stp_busy;
    logic stp_done;
    logic stp_error_valid;
    logic [15:0] stp_error_code;
    logic stp_retained_valid;
    logic [63:0] stp_retained_sequence;
    logic [6:0] stp_retained_len;
    logic [5:0] stp_packet_rd_addr;
    logic [7:0] stp_packet_rd_data;

    /* Forward NTT accelerator. */
    logic ntt_start;
    logic ntt_done;
    logic ntt_host_re;
    logic ntt_host_we;
    logic [7:0] ntt_host_addr;
    logic [15:0] ntt_host_wdata;
    logic ntt_host_ready;
    logic ntt_host_rvalid;
    logic [15:0] ntt_host_rdata;
    logic [2:0] ntt_stage;
    logic ntt_stage_barrier;
    logic ntt_active_bank;
    logic ntt_done_latched_q;
    logic [15:0] ntt_read_value_q;
    logic [15:0] ntt_coeff_value_q;
    logic [8:0] poly_count_q;
    logic [8:0] poly_index_q;
    logic [7:0] poly_coeff_hi_q;

    logic [31:0] device_state_now;
    logic inband_zeroize;
    logic [15:0] last_error_code_q;

    integer i;

    assign secret_zeroize = transport_zeroize_i || fatal_latched_i || inband_zeroize;
    assign irq_pending_o = tx_frame_ready_i;
    assign busy_o = (state_q != ST_IDLE) || builder_busy || stp_busy || ntt_busy_o;
    assign retained_packet_o = stp_retained_valid;
    assign last_error_code_o = last_error_code_q;

    always_comb begin
        device_state_now = 32'h0;
        device_state_now[0] = session_key_loading;
        device_state_now[1] = key_valid_o;
        device_state_now[2] = session_active_o;
        device_state_now[3] = stp_retained_valid;
        device_state_now[4] = ntt_busy_o;
        device_state_now[5] = ntt_done_latched_q;
        device_state_now[6] = secure_enable_i;
        device_state_now[31] = fatal_latched_i;
    end

    /* Session operations are one-cycle states so the context block sees clean pulses. */
    assign session_load_begin = (state_q == ST_KEY_BEGIN_PULSE);
    assign session_load_session_id = {arg_q[0], arg_q[1], arg_q[2], arg_q[3]};
    assign session_load_total_len = {arg_q[5], arg_q[6]};
    assign session_load_chunk = (state_q == ST_KEY_CHUNK_WRITE);
    assign session_load_offset = chunk_base_q[5:0] + chunk_index_q;
    assign session_load_byte = request_payload_rd_data_i;
    assign session_load_commit = (state_q == ST_KEY_COMMIT_PULSE);
    assign session_load_abort = (state_q == ST_KEY_ABORT_PULSE);
    assign session_activate = (state_q == ST_SESSION_ACTIVATE_PULSE);
    assign session_activate_id = {arg_q[0], arg_q[1], arg_q[2], arg_q[3]};
    assign inband_zeroize = (state_q == ST_ZEROIZE_PULSE);

    assign stp_start = (state_q == ST_TELEMETRY_START);

    /* NTT host transactions are accepted only after full command validation. */
    assign ntt_host_we = (state_q == ST_NTT_WRITE_PULSE) ||
                         (state_q == ST_POLY_WRITE_LO);
    assign ntt_host_re = (state_q == ST_NTT_READ_PULSE);
    assign ntt_start = (state_q == ST_NTT_START_PULSE);
    assign ntt_host_addr = (state_q == ST_POLY_WRITE_LO)
                         ? poly_index_q[7:0]
                         : arg_q[1];
    assign ntt_host_wdata = (state_q == ST_POLY_WRITE_LO)
                          ? {poly_coeff_hi_q, request_payload_rd_data_i}
                          : {arg_q[2], arg_q[3]};

    /* Payload address selection while the parser holds rx_mem immutable. */
    always_comb begin
        request_payload_rd_addr_o = 10'd0;
        case (state_q)
            ST_ARG_READ:
                request_payload_rd_addr_o = arg_index_q;
            ST_KEY_CHUNK_OFFSET_HI:
                request_payload_rd_addr_o = 10'd0;
            ST_KEY_CHUNK_OFFSET_LO:
                request_payload_rd_addr_o = 10'd1;
            ST_KEY_CHUNK_WRITE:
                request_payload_rd_addr_o = 10'd2 + chunk_index_q;
            ST_TELEMETRY_COPY:
                request_payload_rd_addr_o = telemetry_index_q;
            ST_POLY_VALIDATE_HI,
            ST_POLY_WRITE_HI:
                request_payload_rd_addr_o = 10'd2 + (poly_index_q << 1);
            ST_POLY_VALIDATE_LO,
            ST_POLY_WRITE_LO:
                request_payload_rd_addr_o = 10'd3 + (poly_index_q << 1);
            ST_RESP_FILL: begin
                if (response_kind_q == RESP_PING && response_fill_index_q >= 10'd12)
                    request_payload_rd_addr_o = response_fill_index_q - 10'd12;
            end
            default: begin end
        endcase
    end

    /* Response payload byte generator. Byte 0 of inline data is bits [7:0]. */
    always_comb begin
        response_fill_byte = 8'h00;
        stp_packet_rd_addr = 6'd0;

        if (response_kind_q == RESP_TELEMETRY) begin
            case (response_fill_index_q)
                10'd0: response_fill_byte = response_status_q[15:8];
                10'd1: response_fill_byte = response_status_q[7:0];
                10'd2: response_fill_byte = stp_retained_sequence[63:56];
                10'd3: response_fill_byte = stp_retained_sequence[55:48];
                10'd4: response_fill_byte = stp_retained_sequence[47:40];
                10'd5: response_fill_byte = stp_retained_sequence[39:32];
                10'd6: response_fill_byte = stp_retained_sequence[31:24];
                10'd7: response_fill_byte = stp_retained_sequence[23:16];
                10'd8: response_fill_byte = stp_retained_sequence[15:8];
                10'd9: response_fill_byte = stp_retained_sequence[7:0];
                10'd10: response_fill_byte = 8'h00;
                10'd11: response_fill_byte = stp_retained_len;
                default: begin
                    stp_packet_rd_addr = response_fill_index_q - 10'd12;
                    response_fill_byte = stp_packet_rd_data;
                end
            endcase
        end else begin
            case (response_fill_index_q)
                10'd0: response_fill_byte = response_status_q[15:8];
                10'd1: response_fill_byte = response_status_q[7:0];
                10'd2: response_fill_byte = response_detail_q[15:8];
                10'd3: response_fill_byte = response_detail_q[7:0];
                10'd4: response_fill_byte = response_device_state_q[31:24];
                10'd5: response_fill_byte = response_device_state_q[23:16];
                10'd6: response_fill_byte = response_device_state_q[15:8];
                10'd7: response_fill_byte = response_device_state_q[7:0];
                10'd8: response_fill_byte = response_data_len_q[31:24];
                10'd9: response_fill_byte = response_data_len_q[23:16];
                10'd10: response_fill_byte = response_data_len_q[15:8];
                10'd11: response_fill_byte = response_data_len_q[7:0];
                default: begin
                    if (response_kind_q == RESP_INLINE)
                        response_fill_byte =
                            response_inline_data_q[8*(response_fill_index_q-10'd12) +: 8];
                    else if (response_kind_q == RESP_PING)
                        response_fill_byte = request_payload_rd_data_i;
                end
            endcase
        end
    end

    assign builder_payload_wr_en = (state_q == ST_RESP_FILL);
    assign builder_payload_wr_addr = response_fill_index_q;
    assign builder_payload_wr_data = response_fill_byte;
    assign builder_start = (state_q == ST_RESP_START);

    btp_response_builder #(
        .MAX_PAYLOAD_BYTES(1024),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_response_builder (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .zeroize_i          (transport_zeroize_i),
        .payload_wr_en_i    (builder_payload_wr_en),
        .payload_wr_addr_i  (builder_payload_wr_addr),
        .payload_wr_data_i  (builder_payload_wr_data),
        .start_i            (builder_start),
        .opcode_i           (current_opcode_q),
        .transaction_id_i   (current_transaction_id_q),
        .payload_len_i      (response_payload_len_q),
        .error_i            (response_error_q),
        .busy_o             (builder_busy),
        .done_o             (builder_done),
        .frame_len_o        (builder_frame_len),
        .tx_wr_en_o         (builder_tx_wr_en),
        .tx_wr_addr_o       (builder_tx_wr_addr),
        .tx_wr_data_o       (builder_tx_wr_data)
    );

    /* Cache restore owns the SPI TX write port; otherwise the builder owns it. */
    always_comb begin
        if (state_q == ST_CACHE_RESTORE) begin
            tx_wr_en_o = 1'b1;
            tx_wr_addr_o = cache_restore_index_q;
            tx_wr_data_o = cache_mem[cache_restore_index_q];
        end else begin
            tx_wr_en_o = builder_tx_wr_en;
            tx_wr_addr_o = builder_tx_wr_addr;
            tx_wr_data_o = builder_tx_wr_data;
        end
    end

    primer1_session_context u_session (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .zeroize_i             (secret_zeroize),
        .load_begin_i          (session_load_begin),
        .load_session_id_i     (session_load_session_id),
        .load_total_len_i      (session_load_total_len),
        .load_chunk_i          (session_load_chunk),
        .load_offset_i         (session_load_offset),
        .load_byte_i           (session_load_byte),
        .load_commit_i         (session_load_commit),
        .load_abort_i          (session_load_abort),
        .session_activate_i    (session_activate),
        .activate_session_id_i (session_activate_id),
        .key_loading_o         (session_key_loading),
        .key_valid_o           (key_valid_o),
        .session_active_o      (session_active_o),
        .session_id_o          (session_id),
        .traffic_key_o         (traffic_key),
        .nonce_prefix_o        (nonce_prefix),
        .tx_sequence_o         (tx_sequence),
        .tx_sequence_commit_i  (session_sequence_commit),
        .staging_complete_o    (session_staging_complete),
        .staging_conflict_o    (session_staging_conflict),
        .commit_ok_o           (session_commit_ok),
        .commit_failed_o       (session_commit_failed)
    );

    primer1_stp_tx u_stp_tx (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .zeroize_i              (secret_zeroize),
        .secure_enable_i        (secure_enable_i),
        .fatal_latched_i        (fatal_latched_i),
        .key_valid_i            (key_valid_o),
        .session_active_i       (session_active_o),
        .session_id_i           (session_id),
        .traffic_key_i          (traffic_key),
        .nonce_prefix_i         (nonce_prefix),
        .tx_sequence_i          (tx_sequence),
        .start_i                (stp_start),
        .telemetry_record_i     (telemetry_sample_q),
        .ready_o                (stp_ready),
        .busy_o                 (stp_busy),
        .done_o                 (stp_done),
        .error_valid_o          (stp_error_valid),
        .error_code_o           (stp_error_code),
        .retained_valid_o       (stp_retained_valid),
        .retained_sequence_o    (stp_retained_sequence),
        .retained_len_o         (stp_retained_len),
        .packet_rd_addr_i       (stp_packet_rd_addr),
        .packet_rd_data_o       (stp_packet_rd_data),
        .packet_commit_i        (packet_commit_i),
        .sequence_commit_o      (session_sequence_commit)
    );

    forward_ntt_core u_forward_ntt (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .start_i          (ntt_start),
        .busy_o           (ntt_busy_o),
        .done_o           (ntt_done),
        .host_re_i        (ntt_host_re),
        .host_we_i        (ntt_host_we),
        .host_addr_i      (ntt_host_addr),
        .host_wdata_i     (ntt_host_wdata),
        .host_ready_o     (ntt_host_ready),
        .host_rvalid_o    (ntt_host_rvalid),
        .host_rdata_o     (ntt_host_rdata),
        .stage_o          (ntt_stage),
        .stage_barrier_o  (ntt_stage_barrier),
        .active_bank_o    (ntt_active_bank)
    );

    /* Helpers centralize response formatting and error-latch policy. */
    task automatic queue_generic_response(
        input logic [15:0] status,
        input logic [15:0] detail,
        input response_kind_t kind,
        input logic [15:0] data_len,
        input logic accept_after_fill,
        input logic capture_cache
    );
        begin
            response_status_q <= status;
            response_detail_q <= detail;
            response_device_state_q <= device_state_now;
            response_data_len_q <= {16'h0, data_len};
            response_payload_len_q <= 16'd12 + data_len;
            response_error_q <= (status != ERR_OK);
            response_kind_q <= kind;
            response_accept_request_after_fill_q <= accept_after_fill;
            response_cache_capture_q <= capture_cache;
            response_fill_index_q <= 10'd0;
            if (status != ERR_OK)
                last_error_code_q <= status;
            state_q <= ST_RESP_FILL;
        end
    endtask

    task automatic queue_telemetry_response(input logic capture_cache);
        begin
            response_status_q <= ERR_OK;
            response_detail_q <= 16'h0;
            response_device_state_q <= device_state_now;
            response_data_len_q <= 32'd74;
            response_payload_len_q <= 16'd76;
            response_error_q <= 1'b0;
            response_kind_q <= RESP_TELEMETRY;
            response_accept_request_after_fill_q <= 1'b0;
            response_cache_capture_q <= capture_cache;
            response_fill_index_q <= 10'd0;
            state_q <= ST_RESP_FILL;
        end
    endtask

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            arg_kind_q <= ARG_NONE;
            current_opcode_q <= '0;
            current_transaction_id_q <= '0;
            current_payload_len_q <= '0;
            current_request_crc32_q <= '0;
            arg_index_q <= '0;
            chunk_base_q <= '0;
            chunk_index_q <= '0;
            telemetry_sample_q <= '0;
            telemetry_index_q <= '0;

            response_status_q <= ERR_OK;
            response_detail_q <= '0;
            response_device_state_q <= '0;
            response_data_len_q <= '0;
            response_payload_len_q <= '0;
            response_error_q <= 1'b0;
            response_kind_q <= RESP_GENERIC;
            response_accept_request_after_fill_q <= 1'b0;
            response_cache_capture_q <= 1'b0;
            response_inline_data_q <= '0;
            response_fill_index_q <= '0;

            cache_valid_q <= 1'b0;
            cache_transaction_id_q <= '0;
            cache_opcode_q <= '0;
            cache_payload_len_q <= '0;
            cache_request_crc32_q <= '0;
            cache_frame_len_q <= '0;
            cache_age_q <= '0;
            cache_restore_index_q <= '0;

            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;
            tx_frame_len_o <= '0;

            loading_session_id_q <= '0;
            loading_direction_q <= '0;
            loading_total_len_q <= '0;
            last_error_code_q <= ERR_OK;

            ntt_done_latched_q <= 1'b0;
            ntt_read_value_q <= '0;
            ntt_coeff_value_q <= '0;
            poly_count_q <= '0;
            poly_index_q <= '0;
            poly_coeff_hi_q <= '0;

            for (i = 0; i < 8; i = i + 1)
                arg_q[i] <= 8'h00;
        end else begin
            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;

            if (ntt_done)
                ntt_done_latched_q <= 1'b1;

            /* One-second duplicate window for the most recent completed response. */
            if (cache_valid_q) begin
                if (cache_age_q >= CACHE_CYCLES-1) begin
                    cache_valid_q <= 1'b0;
                    cache_age_q <= '0;
                end else begin
                    cache_age_q <= cache_age_q + 1'b1;
                end
            end else begin
                cache_age_q <= '0;
            end

            /* Capture byte-identical response bytes into independent retry storage. */
            if (builder_tx_wr_en && response_cache_capture_q)
                cache_mem[builder_tx_wr_addr] <= builder_tx_wr_data;

            case (state_q)
                ST_IDLE: begin
                    if (request_valid_i && !tx_frame_ready_i && !builder_busy) begin
                        current_opcode_q <= request_opcode_i;
                        current_transaction_id_q <= request_transaction_id_i;
                        current_payload_len_q <= request_payload_len_i;
                        current_request_crc32_q <= request_crc32_i;
                        response_inline_data_q <= '0;

                        if (request_error_i) begin
                            request_accept_o <= 1'b1;
                            queue_generic_response(
                                request_error_code_i, 16'h0,
                                RESP_GENERIC, 16'd0, 1'b0, 1'b0);
                        end else if (cache_valid_q &&
                                     request_transaction_id_i == cache_transaction_id_q) begin
                            if ((request_opcode_i == cache_opcode_q) &&
                                (request_payload_len_i == cache_payload_len_q) &&
                                (request_crc32_i == cache_request_crc32_q)) begin
                                request_accept_o <= 1'b1;
                                cache_restore_index_q <= '0;
                                cache_age_q <= '0;
                                state_q <= ST_CACHE_RESTORE;
                            end else begin
                                /* Appendix C collision symbol is reported through the
                                   common BTP transaction error until its separate numeric
                                   registry value is available in the controlled baseline. */
                                request_accept_o <= 1'b1;
                                queue_generic_response(
                                    ERR_BTP_TRANSACTION, 16'h0001,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b0);
                            end
                        end else begin
                            case (request_opcode_i)
                                OP_GET_DEVICE_ID: begin
                                    if (request_payload_len_i != 0) begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        response_inline_data_q[7:0] <= "P";
                                        response_inline_data_q[15:8] <= "R";
                                        response_inline_data_q[23:16] <= "1";
                                        response_inline_data_q[31:24] <= "T";
                                        response_inline_data_q[39:32] <= "X";
                                        response_inline_data_q[47:40] <= "1";
                                        response_inline_data_q[55:48] <= ".";
                                        response_inline_data_q[63:56] <= "1";
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_INLINE, 16'd8, 1'b0, 1'b1);
                                    end
                                end

                                OP_GET_STATUS: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    else
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                end

                                OP_GET_ERROR: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0) begin
                                        response_inline_data_q[7:0] <= last_error_code_q[15:8];
                                        response_inline_data_q[15:8] <= last_error_code_q[7:0];
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_INLINE, 16'd2, 1'b0, 1'b1);
                                    end else begin
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_CLEAR_ERROR: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i != 16'd2) begin
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end else if (fatal_latched_i) begin
                                        queue_generic_response(ERR_SAFE_LOCKED, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end else begin
                                        last_error_code_q <= ERR_OK;
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PING: begin
                                    if (request_payload_len_i <= 16'd1012) begin
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_PING, request_payload_len_i,
                                            1'b1, 1'b1);
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_BTP_LENGTH, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_KEY_LOAD_BEGIN: begin
                                    if (request_payload_len_i == 16'd7) begin
                                        arg_kind_q <= ARG_KEY_BEGIN;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_KEY_LOAD_CHUNK: begin
                                    if ((request_payload_len_i >= 16'd3) &&
                                        (request_payload_len_i <= 16'd26))
                                        state_q <= ST_KEY_CHUNK_OFFSET_HI;
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_KEY_LOAD_COMMIT: begin
                                    if (request_payload_len_i == 16'd7) begin
                                        arg_kind_q <= ARG_KEY_COMMIT;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_KEY_LOAD_ABORT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        state_q <= ST_KEY_ABORT_PULSE;
                                    else
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                end

                                OP_KEY_STATUS: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0) begin
                                        response_inline_data_q[7:0] <= {7'h0, session_key_loading};
                                        response_inline_data_q[15:8] <= {7'h0, key_valid_o};
                                        response_inline_data_q[23:16] <= {7'h0, session_active_o};
                                        response_inline_data_q[31:24] <= {7'h0, session_staging_conflict};
                                        response_inline_data_q[39:32] <= session_id[31:24];
                                        response_inline_data_q[47:40] <= session_id[23:16];
                                        response_inline_data_q[55:48] <= session_id[15:8];
                                        response_inline_data_q[63:56] <= session_id[7:0];
                                        response_inline_data_q[71:64] <= tx_sequence[63:56];
                                        response_inline_data_q[79:72] <= tx_sequence[55:48];
                                        response_inline_data_q[87:80] <= tx_sequence[47:40];
                                        response_inline_data_q[95:88] <= tx_sequence[39:32];
                                        response_inline_data_q[103:96] <= tx_sequence[31:24];
                                        response_inline_data_q[111:104] <= tx_sequence[23:16];
                                        response_inline_data_q[119:112] <= tx_sequence[15:8];
                                        response_inline_data_q[127:120] <= tx_sequence[7:0];
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_INLINE, 16'd16, 1'b0, 1'b1);
                                    end else begin
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_ZEROIZE: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 16'd2)
                                        state_q <= ST_ZEROIZE_PULSE;
                                    else
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                end

                                OP_SESSION_ACTIVATE: begin
                                    if (request_payload_len_i == 16'd4) begin
                                        arg_kind_q <= ARG_SESSION_ACTIVATE;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_TELEMETRY_TX_SAMPLE: begin
                                    if (request_payload_len_i == 16'd24) begin
                                        telemetry_index_q <= '0;
                                        telemetry_sample_q <= '0;
                                        state_q <= ST_TELEMETRY_COPY;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PQC_WRITE_COEFF: begin
                                    if (request_payload_len_i == 16'd4) begin
                                        arg_kind_q <= ARG_PQC_WRITE;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PQC_READ_COEFF: begin
                                    if (request_payload_len_i == 16'd2) begin
                                        arg_kind_q <= ARG_PQC_READ;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PQC_LOAD_POLY: begin
                                    if ((request_payload_len_i >= 16'd4) &&
                                        (request_payload_len_i <= 16'd514)) begin
                                        arg_kind_q <= ARG_POLY_COUNT;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_PQC_LENGTH, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PQC_START_NTT: begin
                                    if (request_payload_len_i == 16'd4) begin
                                        arg_kind_q <= ARG_PQC_START;
                                        arg_index_q <= '0;
                                        state_q <= ST_ARG_READ;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                OP_PQC_GET_RESULT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0) begin
                                        response_inline_data_q[7:0] <= {7'h0, ntt_busy_o};
                                        response_inline_data_q[15:8] <= {7'h0, ntt_done_latched_q};
                                        response_inline_data_q[23:16] <= {5'h0, ntt_stage};
                                        response_inline_data_q[31:24] <= {7'h0, ntt_active_bank};
                                        queue_generic_response(ERR_OK, 16'h0,
                                            RESP_INLINE, 16'd4, 1'b0, 1'b1);
                                    end else begin
                                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                    end
                                end

                                default: begin
                                    request_accept_o <= 1'b1;
                                    queue_generic_response(ERR_UNSUPPORTED_OPCODE, 16'h0,
                                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                                end
                            endcase
                        end
                    end
                end

                ST_ARG_READ: begin
                    arg_q[arg_index_q] <= request_payload_rd_data_i;
                    if (arg_index_q + 1'b1 >= current_payload_len_q) begin
                        request_accept_o <= 1'b1;
                        arg_index_q <= '0;
                        state_q <= ST_EXEC_ARG;
                    end else begin
                        arg_index_q <= arg_index_q + 1'b1;
                    end
                end

                ST_EXEC_ARG: begin
                    case (arg_kind_q)
                        ARG_KEY_BEGIN: begin
                            if ({arg_q[0],arg_q[1],arg_q[2],arg_q[3]} == 32'h0 ||
                                arg_q[4] != KEY_DIRECTION_ID ||
                                {arg_q[5],arg_q[6]} != 16'd24) begin
                                queue_generic_response(ERR_ARGUMENT, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            end else if (fatal_latched_i) begin
                                queue_generic_response(ERR_SAFE_LOCKED, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            end else begin
                                loading_session_id_q <= {arg_q[0],arg_q[1],arg_q[2],arg_q[3]};
                                loading_direction_q <= arg_q[4];
                                loading_total_len_q <= {arg_q[5],arg_q[6]};
                                state_q <= ST_KEY_BEGIN_PULSE;
                            end
                        end

                        ARG_KEY_COMMIT: begin
                            if ({arg_q[0],arg_q[1],arg_q[2],arg_q[3]} != loading_session_id_q ||
                                arg_q[4] != loading_direction_q ||
                                {arg_q[5],arg_q[6]} != loading_total_len_q ||
                                !session_staging_complete || session_staging_conflict) begin
                                queue_generic_response(ERR_KEY_LOAD_INCOMPLETE, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            end else begin
                                state_q <= ST_KEY_COMMIT_PULSE;
                            end
                        end

                        ARG_SESSION_ACTIVATE: begin
                            if (!secure_enable_i)
                                queue_generic_response(ERR_SECURE_DISABLED, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else if (fatal_latched_i)
                                queue_generic_response(ERR_SAFE_LOCKED, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else if (!key_valid_o ||
                                     {arg_q[0],arg_q[1],arg_q[2],arg_q[3]} != session_id)
                                queue_generic_response(ERR_NO_KEY, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else
                                state_q <= ST_SESSION_ACTIVATE_PULSE;
                        end

                        ARG_PQC_WRITE: begin
                            ntt_coeff_value_q <= {arg_q[2], arg_q[3]};
                            if ({arg_q[0],arg_q[1]} >= 16'd256)
                                queue_generic_response(ERR_ARGUMENT, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else if ({arg_q[2],arg_q[3]} >= 16'd3329)
                                queue_generic_response(ERR_COEFF_RANGE, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else if (!ntt_host_ready)
                                queue_generic_response(ERR_BUSY, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else
                                state_q <= ST_NTT_WRITE_PULSE;
                        end

                        ARG_PQC_READ: begin
                            if ({arg_q[0],arg_q[1]} >= 16'd256)
                                queue_generic_response(ERR_ARGUMENT, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else if (!ntt_host_ready)
                                queue_generic_response(ERR_BUSY, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else
                                state_q <= ST_NTT_READ_PULSE;
                        end

                        ARG_PQC_START: begin
                            if (!ntt_host_ready)
                                queue_generic_response(ERR_BUSY, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            else
                                state_q <= ST_NTT_START_PULSE;
                        end

                        ARG_POLY_COUNT: begin
                            poly_count_q <= {arg_q[0], arg_q[1]};
                            poly_index_q <= '0;
                            if ({arg_q[0],arg_q[1]} == 16'd0 ||
                                {arg_q[0],arg_q[1]} > 16'd256 ||
                                current_payload_len_q !=
                                    (16'd2 + ({arg_q[0],arg_q[1]} << 1))) begin
                                queue_generic_response(ERR_PQC_LENGTH, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            end else if (!ntt_host_ready) begin
                                queue_generic_response(ERR_BUSY, 16'h0,
                                    RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                            end else begin
                                state_q <= ST_POLY_VALIDATE_HI;
                            end
                        end

                        default:
                            queue_generic_response(ERR_ARGUMENT, 16'h0,
                                RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    endcase
                end

                ST_KEY_BEGIN_PULSE: begin
                    queue_generic_response(ERR_OK, 16'h0,
                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_KEY_CHUNK_OFFSET_HI: begin
                    chunk_base_q[15:8] <= request_payload_rd_data_i;
                    state_q <= ST_KEY_CHUNK_OFFSET_LO;
                end

                ST_KEY_CHUNK_OFFSET_LO: begin
                    chunk_base_q[7:0] <= request_payload_rd_data_i;
                    chunk_index_q <= '0;
                    if ({chunk_base_q[15:8], request_payload_rd_data_i} >= 16'd24 ||
                        ({chunk_base_q[15:8], request_payload_rd_data_i} +
                         (current_payload_len_q - 16'd2)) > 16'd24) begin
                        request_accept_o <= 1'b1;
                        queue_generic_response(ERR_ARGUMENT, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else if (!session_key_loading) begin
                        request_accept_o <= 1'b1;
                        queue_generic_response(ERR_INVALID_STATE, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else begin
                        state_q <= ST_KEY_CHUNK_WRITE;
                    end
                end

                ST_KEY_CHUNK_WRITE: begin
                    if (chunk_index_q + 16'd3 >= current_payload_len_q) begin
                        request_accept_o <= 1'b1;
                        chunk_index_q <= '0;
                        queue_generic_response(ERR_OK, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else begin
                        chunk_index_q <= chunk_index_q + 1'b1;
                    end
                end

                ST_KEY_COMMIT_PULSE:
                    state_q <= ST_KEY_COMMIT_WAIT;

                ST_KEY_COMMIT_WAIT: begin
                    if (session_commit_ok) begin
                        loading_session_id_q <= '0;
                        loading_direction_q <= '0;
                        loading_total_len_q <= '0;
                        queue_generic_response(ERR_OK, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else if (session_commit_failed) begin
                        queue_generic_response(ERR_KEY_COMMIT, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end
                end

                ST_KEY_ABORT_PULSE: begin
                    loading_session_id_q <= '0;
                    loading_direction_q <= '0;
                    loading_total_len_q <= '0;
                    queue_generic_response(ERR_OK, 16'h0,
                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_SESSION_ACTIVATE_PULSE:
                    state_q <= ST_SESSION_ACTIVATE_WAIT;

                ST_SESSION_ACTIVATE_WAIT: begin
                    if (session_active_o)
                        queue_generic_response(ERR_OK, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    else
                        queue_generic_response(ERR_INVALID_STATE, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_ZEROIZE_PULSE: begin
                    loading_session_id_q <= '0;
                    loading_direction_q <= '0;
                    loading_total_len_q <= '0;
                    telemetry_sample_q <= '0;
                    queue_generic_response(ERR_OK, 16'h0,
                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_TELEMETRY_COPY: begin
                    telemetry_sample_q[8*telemetry_index_q +: 8] <=
                        request_payload_rd_data_i;
                    if (telemetry_index_q == 6'd23) begin
                        telemetry_index_q <= '0;
                        request_accept_o <= 1'b1;
                        state_q <= ST_TELEMETRY_START;
                    end else begin
                        telemetry_index_q <= telemetry_index_q + 1'b1;
                    end
                end

                ST_TELEMETRY_START: begin
                    if (!stp_ready) begin
                        telemetry_sample_q <= '0;
                        queue_generic_response(ERR_BUSY, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else begin
                        state_q <= ST_TELEMETRY_WAIT;
                    end
                end

                ST_TELEMETRY_WAIT: begin
                    if (stp_error_valid) begin
                        telemetry_sample_q <= '0;
                        queue_generic_response(stp_error_code, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else if (stp_done) begin
                        telemetry_sample_q <= '0;
                        queue_telemetry_response(1'b1);
                    end
                end

                ST_NTT_WRITE_PULSE: begin
                    queue_generic_response(ERR_OK, 16'h0,
                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_NTT_READ_PULSE:
                    state_q <= ST_NTT_READ_WAIT;

                ST_NTT_READ_WAIT: begin
                    if (ntt_host_rvalid) begin
                        ntt_read_value_q <= ntt_host_rdata;
                        response_inline_data_q[7:0] <= ntt_host_rdata[15:8];
                        response_inline_data_q[15:8] <= ntt_host_rdata[7:0];
                        queue_generic_response(ERR_OK, 16'h0,
                            RESP_INLINE, 16'd2, 1'b0, 1'b1);
                    end
                end

                ST_NTT_START_PULSE: begin
                    ntt_done_latched_q <= 1'b0;
                    queue_generic_response(ERR_OK, 16'h0,
                        RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                end

                ST_POLY_VALIDATE_HI: begin
                    poly_coeff_hi_q <= request_payload_rd_data_i;
                    state_q <= ST_POLY_VALIDATE_LO;
                end

                ST_POLY_VALIDATE_LO: begin
                    if ({poly_coeff_hi_q, request_payload_rd_data_i} >= 16'd3329) begin
                        request_accept_o <= 1'b1;
                        poly_index_q <= '0;
                        queue_generic_response(ERR_COEFF_RANGE, poly_index_q[15:0],
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else if (poly_index_q + 1'b1 >= poly_count_q) begin
                        poly_index_q <= '0;
                        state_q <= ST_POLY_WRITE_HI;
                    end else begin
                        poly_index_q <= poly_index_q + 1'b1;
                        state_q <= ST_POLY_VALIDATE_HI;
                    end
                end

                ST_POLY_WRITE_HI: begin
                    poly_coeff_hi_q <= request_payload_rd_data_i;
                    state_q <= ST_POLY_WRITE_LO;
                end

                ST_POLY_WRITE_LO: begin
                    if (poly_index_q + 1'b1 >= poly_count_q) begin
                        request_accept_o <= 1'b1;
                        poly_index_q <= '0;
                        queue_generic_response(ERR_OK, 16'h0,
                            RESP_GENERIC, 16'd0, 1'b0, 1'b1);
                    end else begin
                        poly_index_q <= poly_index_q + 1'b1;
                        state_q <= ST_POLY_WRITE_HI;
                    end
                end

                ST_RESP_FILL: begin
                    if (response_fill_index_q + 1'b1 >= response_payload_len_q) begin
                        if (response_accept_request_after_fill_q)
                            request_accept_o <= 1'b1;
                        response_fill_index_q <= '0;
                        state_q <= ST_RESP_START;
                    end else begin
                        response_fill_index_q <= response_fill_index_q + 1'b1;
                    end
                end

                ST_RESP_START:
                    state_q <= ST_RESP_BUILD_WAIT;

                ST_RESP_BUILD_WAIT: begin
                    if (builder_done) begin
                        state_q <= ST_RESP_COMMIT;
                    end
                end

                ST_RESP_COMMIT: begin
                    tx_frame_len_o <= builder_frame_len;
                    tx_frame_commit_o <= 1'b1;
                    if (response_cache_capture_q) begin
                        cache_valid_q <= 1'b1;
                        cache_transaction_id_q <= current_transaction_id_q;
                        cache_opcode_q <= current_opcode_q;
                        cache_payload_len_q <= current_payload_len_q;
                        cache_request_crc32_q <= current_request_crc32_q;
                        cache_frame_len_q <= builder_frame_len;
                        cache_age_q <= '0;
                    end
                    response_cache_capture_q <= 1'b0;
                    state_q <= ST_IDLE;
                end

                ST_CACHE_RESTORE: begin
                    if (cache_restore_index_q + 1'b1 >= cache_frame_len_q) begin
                        cache_restore_index_q <= '0;
                        state_q <= ST_CACHE_RECOMMIT;
                    end else begin
                        cache_restore_index_q <= cache_restore_index_q + 1'b1;
                    end
                end

                ST_CACHE_RECOMMIT: begin
                    tx_frame_len_o <= cache_frame_len_q;
                    tx_frame_commit_o <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase

            if (transport_zeroize_i) begin
                state_q <= ST_IDLE;
                request_accept_o <= 1'b0;
                tx_frame_commit_o <= 1'b0;
                cache_valid_q <= 1'b0;
                cache_age_q <= '0;
                cache_restore_index_q <= '0;
                current_opcode_q <= '0;
                current_transaction_id_q <= '0;
                current_payload_len_q <= '0;
                current_request_crc32_q <= '0;
                response_cache_capture_q <= 1'b0;
                response_inline_data_q <= '0;
                telemetry_sample_q <= '0;
                loading_session_id_q <= '0;
                loading_direction_q <= '0;
                loading_total_len_q <= '0;
                last_error_code_q <= ERR_OK;
                ntt_done_latched_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if (tx_frame_commit_o)
                assert (tx_frame_len_o != 0)
                    else $error("primer1_btp_endpoint: committed zero-length response");
            if (session_active_o)
                assert (key_valid_o)
                    else $error("primer1_btp_endpoint: active session without key_valid");
            if (state_q == ST_POLY_WRITE_LO)
                assert (ntt_host_ready)
                    else $error("primer1_btp_endpoint: poly write while NTT host busy");
        end
    end
`endif

    logic unused_request_flags;
    logic unused_ntt_debug;
    logic unused_sequence_state;
    always_comb begin
        unused_request_flags = ^request_flags_i;
        unused_ntt_debug = ^{ntt_stage_barrier, ntt_read_value_q, ntt_coeff_value_q};
        unused_sequence_state = ^{loading_direction_q, tx_frame_consumed_i};
    end
endmodule
