module primer2_btp_endpoint_deploy #(
    parameter integer CLOCK_HZ = 27_000_000,
    parameter logic [7:0] KEY_DIRECTION_ID = 8'h02,
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic transport_zeroize_i,
    input  logic secure_enable_i,
    input  logic fatal_latched_i,

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

    input  logic tx_frame_ready_i,
    input  logic tx_frame_consumed_i,
    output logic tx_frame_commit_o,
    output logic [COUNT_W-1:0] tx_frame_len_o,
    output logic tx_wr_en_o,
    output logic [COUNT_W-1:0] tx_wr_addr_o,
    output logic [7:0] tx_wr_data_o,

    output logic irq_pending_o,
    output logic busy_o,
    output logic key_valid_o,
    output logic session_active_o,
    output logic [63:0] expected_sequence_o,
    output logic auth_threshold_fault_o,
    output logic [15:0] last_error_code_o
);
    import fpst_btp_pkg::*;

    localparam integer CACHE_CYCLES = CLOCK_HZ;
    localparam integer CACHE_COUNT_W = $clog2(CACHE_CYCLES + 1);
    localparam integer MAX_STP_PACKET_BYTES = 168;

    localparam logic [15:0] DETAIL_COMMIT_ACCEPTED = 16'h0001;
    localparam logic [15:0] DETAIL_EXPECTED_SEQUENCE = 16'h0002;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_ARG_READ,
        ST_EXEC_ARG,
        ST_KEY_BEGIN_PULSE,
        ST_KEY_CHUNK_OFF_HI,
        ST_KEY_CHUNK_OFF_LO,
        ST_KEY_CHUNK_DATA,
        ST_KEY_COMMIT_PULSE,
        ST_KEY_COMMIT_WAIT,
        ST_KEY_ABORT_PULSE,
        ST_SESSION_PULSE,
        ST_SESSION_WAIT,
        ST_SECRET_ZEROIZE_PULSE,
        ST_RX_COPY,
        ST_RX_START,
        ST_RX_WAIT,
        ST_CLEAR_COUNTERS_READ,
        ST_RESP_FILL,
        ST_RESP_START,
        ST_RESP_WAIT,
        ST_RESP_COMMIT,
        ST_CACHE_RESTORE,
        ST_CACHE_RECOMMIT
    } state_t;

    typedef enum logic [2:0] {
        ARG_NONE,
        ARG_KEY_BEGIN,
        ARG_KEY_COMMIT,
        ARG_SESSION
    } arg_kind_t;

    typedef enum logic [3:0] {
        RESP_GENERIC,
        RESP_DEVICE_ID,
        RESP_KEY_STATUS,
        RESP_PING,
        RESP_RX_COMMIT,
        RESP_RX_SEQUENCE,
        RESP_COUNTERS
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
    logic [3:0] arg_expected_q;

    logic [15:0] chunk_base_q;
    logic [5:0] chunk_index_q;
    logic [7:0] rx_copy_index_q;

    logic [15:0] response_status_q;
    logic [15:0] response_detail_q;
    logic [31:0] response_device_state_q;
    logic [31:0] response_data_len_q;
    logic [15:0] response_payload_len_q;
    logic response_error_q;
    logic response_accept_after_fill_q;
    logic response_cache_capture_q;
    logic [9:0] response_fill_index_q;
    logic [7:0] response_fill_byte;

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

    logic [7:0] cache_mem [0:MAX_FRAME_BYTES-1];
    logic cache_valid_q;
    logic [15:0] cache_transaction_id_q;
    logic [7:0] cache_opcode_q;
    logic [15:0] cache_payload_len_q;
    logic [31:0] cache_request_crc32_q;
    logic [COUNT_W-1:0] cache_frame_len_q;
    logic [CACHE_COUNT_W-1:0] cache_age_q;
    logic [COUNT_W-1:0] cache_restore_index_q;

    logic session_zeroize;
    logic session_load_begin;
    logic session_load_chunk;
    logic session_load_commit;
    logic session_load_abort;
    logic session_activate;
    logic session_key_loading;
    logic [31:0] session_id;
    logic [127:0] traffic_key;
    logic [63:0] nonce_prefix;
    logic session_sequence_commit;
    logic session_staging_complete;
    logic session_staging_conflict;
    logic session_commit_ok;
    logic session_commit_failed;
    logic [31:0] loading_session_id_q;
    logic [7:0] loading_direction_q;
    logic [15:0] loading_total_len_q;

    logic rx_packet_wr_en;
    logic [7:0] rx_packet_wr_addr;
    logic [7:0] rx_packet_wr_data;
    logic rx_start;
    logic rx_ready;
    logic rx_busy;
    logic rx_done;
    logic rx_error_valid;
    logic [15:0] rx_error_code;
    logic [63:0] rx_result_sequence;
    logic rx_release_valid;
    logic [7:0] rx_release_len;
    logic [7:0] rx_release_rd_addr;
    logic [7:0] rx_release_rd_data;
    logic [31:0] rx_accepted_count;
    logic [31:0] rx_replay_count;
    logic [31:0] rx_auth_fail_count;
    logic [1:0] rx_consecutive_auth_fail;
    logic rx_fatal_request;

    logic [31:0] accepted_counter_base_q;
    logic [31:0] replay_counter_base_q;
    logic [31:0] auth_counter_base_q;
    logic [7:0] clear_counter_mask_q;

    logic [31:0] device_state_now;
    logic [15:0] last_error_code_q;

    integer i;

    assign irq_pending_o = tx_frame_ready_i;
    assign busy_o = (state_q != ST_IDLE) || builder_busy || rx_busy;
    assign last_error_code_o = last_error_code_q;
    assign auth_threshold_fault_o = rx_fatal_request;

    always_comb begin
        device_state_now = 32'h0;
        device_state_now[0] = session_key_loading;
        device_state_now[1] = key_valid_o;
        device_state_now[2] = session_active_o;
        device_state_now[3] = rx_busy;
        device_state_now[4] = rx_release_valid;
        device_state_now[6] = secure_enable_i;
        device_state_now[7] = (rx_consecutive_auth_fail != 0);
        device_state_now[8] = rx_fatal_request;
        device_state_now[31] = fatal_latched_i;
    end

    assign session_load_begin = (state_q == ST_KEY_BEGIN_PULSE);
    assign session_load_chunk = (state_q == ST_KEY_CHUNK_DATA);
    assign session_load_commit = (state_q == ST_KEY_COMMIT_PULSE);
    assign session_load_abort = (state_q == ST_KEY_ABORT_PULSE);
    assign session_activate = (state_q == ST_SESSION_PULSE);

    /* Self-detected auth threshold invalidates the RX key immediately but keeps BTP alive. */
    assign session_zeroize = transport_zeroize_i || fatal_latched_i || rx_fatal_request ||
                             (state_q == ST_SECRET_ZEROIZE_PULSE);

    assign rx_packet_wr_en = (state_q == ST_RX_COPY);
    assign rx_packet_wr_addr = rx_copy_index_q;
    assign rx_packet_wr_data = request_payload_rd_data_i;
    assign rx_start = (state_q == ST_RX_START) && rx_ready;

    always_comb begin
        request_payload_rd_addr_o = 10'd0;
        case (state_q)
            ST_ARG_READ:
                request_payload_rd_addr_o = arg_index_q;
            ST_KEY_CHUNK_OFF_HI:
                request_payload_rd_addr_o = 10'd0;
            ST_KEY_CHUNK_OFF_LO:
                request_payload_rd_addr_o = 10'd1;
            ST_KEY_CHUNK_DATA:
                request_payload_rd_addr_o = 10'd2 + chunk_index_q;
            ST_RX_COPY:
                request_payload_rd_addr_o = rx_copy_index_q;
            ST_CLEAR_COUNTERS_READ:
                request_payload_rd_addr_o = 10'd0;
            ST_RESP_FILL: begin
                if ((response_kind_q == RESP_PING) &&
                    (response_fill_index_q >= 10'd12))
                    request_payload_rd_addr_o = response_fill_index_q - 10'd12;
            end
            default: begin end
        endcase
    end

    always_comb begin
        response_fill_byte = 8'h00;
        rx_release_rd_addr = 8'h00;

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
                case (response_kind_q)
                    RESP_DEVICE_ID: begin
                        case (response_fill_index_q - 10'd12)
                            10'd0: response_fill_byte = 8'h50; /* P */
                            10'd1: response_fill_byte = 8'h52; /* R */
                            10'd2: response_fill_byte = 8'h32; /* 2 */
                            10'd3: response_fill_byte = 8'h52; /* R */
                            10'd4: response_fill_byte = 8'h58; /* X */
                            10'd5: response_fill_byte = 8'h31; /* 1 */
                            10'd6: response_fill_byte = 8'h2e; /* . */
                            default: response_fill_byte = 8'h31; /* 1 */
                        endcase
                    end

                    RESP_KEY_STATUS: begin
                        case (response_fill_index_q - 10'd12)
                            10'd0: response_fill_byte = {7'h0,session_key_loading};
                            10'd1: response_fill_byte = {7'h0,key_valid_o};
                            10'd2: response_fill_byte = {7'h0,session_active_o};
                            10'd3: response_fill_byte = {7'h0,session_staging_conflict};
                            10'd4: response_fill_byte = session_id[31:24];
                            10'd5: response_fill_byte = session_id[23:16];
                            10'd6: response_fill_byte = session_id[15:8];
                            10'd7: response_fill_byte = session_id[7:0];
                            10'd8: response_fill_byte = expected_sequence_o[63:56];
                            10'd9: response_fill_byte = expected_sequence_o[55:48];
                            10'd10: response_fill_byte = expected_sequence_o[47:40];
                            10'd11: response_fill_byte = expected_sequence_o[39:32];
                            10'd12: response_fill_byte = expected_sequence_o[31:24];
                            10'd13: response_fill_byte = expected_sequence_o[23:16];
                            10'd14: response_fill_byte = expected_sequence_o[15:8];
                            default: response_fill_byte = expected_sequence_o[7:0];
                        endcase
                    end

                    RESP_PING:
                        response_fill_byte = request_payload_rd_data_i;

                    RESP_RX_COMMIT: begin
                        case (response_fill_index_q - 10'd12)
                            10'd0: response_fill_byte = rx_result_sequence[63:56];
                            10'd1: response_fill_byte = rx_result_sequence[55:48];
                            10'd2: response_fill_byte = rx_result_sequence[47:40];
                            10'd3: response_fill_byte = rx_result_sequence[39:32];
                            10'd4: response_fill_byte = rx_result_sequence[31:24];
                            10'd5: response_fill_byte = rx_result_sequence[23:16];
                            10'd6: response_fill_byte = rx_result_sequence[15:8];
                            10'd7: response_fill_byte = rx_result_sequence[7:0];
                            10'd8: response_fill_byte = 8'h00;
                            10'd9: response_fill_byte = rx_release_len;
                            default: begin
                                rx_release_rd_addr = response_fill_index_q - 10'd22;
                                response_fill_byte = rx_release_rd_data;
                            end
                        endcase
                    end

                    RESP_RX_SEQUENCE: begin
                        case (response_fill_index_q - 10'd12)
                            10'd0: response_fill_byte = rx_result_sequence[63:56];
                            10'd1: response_fill_byte = rx_result_sequence[55:48];
                            10'd2: response_fill_byte = rx_result_sequence[47:40];
                            10'd3: response_fill_byte = rx_result_sequence[39:32];
                            10'd4: response_fill_byte = rx_result_sequence[31:24];
                            10'd5: response_fill_byte = rx_result_sequence[23:16];
                            10'd6: response_fill_byte = rx_result_sequence[15:8];
                            default: response_fill_byte = rx_result_sequence[7:0];
                        endcase
                    end

                    RESP_COUNTERS: begin
                        case (response_fill_index_q - 10'd12)
                            10'd0: response_fill_byte = (rx_accepted_count-accepted_counter_base_q)[31:24];
                            10'd1: response_fill_byte = (rx_accepted_count-accepted_counter_base_q)[23:16];
                            10'd2: response_fill_byte = (rx_accepted_count-accepted_counter_base_q)[15:8];
                            10'd3: response_fill_byte = (rx_accepted_count-accepted_counter_base_q)[7:0];
                            10'd4: response_fill_byte = (rx_replay_count-replay_counter_base_q)[31:24];
                            10'd5: response_fill_byte = (rx_replay_count-replay_counter_base_q)[23:16];
                            10'd6: response_fill_byte = (rx_replay_count-replay_counter_base_q)[15:8];
                            10'd7: response_fill_byte = (rx_replay_count-replay_counter_base_q)[7:0];
                            10'd8: response_fill_byte = (rx_auth_fail_count-auth_counter_base_q)[31:24];
                            10'd9: response_fill_byte = (rx_auth_fail_count-auth_counter_base_q)[23:16];
                            10'd10: response_fill_byte = (rx_auth_fail_count-auth_counter_base_q)[15:8];
                            10'd11: response_fill_byte = (rx_auth_fail_count-auth_counter_base_q)[7:0];
                            10'd12: response_fill_byte = expected_sequence_o[63:56];
                            10'd13: response_fill_byte = expected_sequence_o[55:48];
                            10'd14: response_fill_byte = expected_sequence_o[47:40];
                            10'd15: response_fill_byte = expected_sequence_o[39:32];
                            10'd16: response_fill_byte = expected_sequence_o[31:24];
                            10'd17: response_fill_byte = expected_sequence_o[23:16];
                            10'd18: response_fill_byte = expected_sequence_o[15:8];
                            default: response_fill_byte = expected_sequence_o[7:0];
                        endcase
                    end

                    default: response_fill_byte = 8'h00;
                endcase
            end
        endcase
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
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .zeroize_i         (transport_zeroize_i),
        .payload_wr_en_i   (builder_payload_wr_en),
        .payload_wr_addr_i (builder_payload_wr_addr),
        .payload_wr_data_i (builder_payload_wr_data),
        .start_i           (builder_start),
        .opcode_i          (current_opcode_q),
        .transaction_id_i  (current_transaction_id_q),
        .payload_len_i     (response_payload_len_q),
        .error_i           (response_error_q),
        .busy_o            (builder_busy),
        .done_o            (builder_done),
        .frame_len_o       (builder_frame_len),
        .tx_wr_en_o        (builder_tx_wr_en),
        .tx_wr_addr_o      (builder_tx_wr_addr),
        .tx_wr_data_o      (builder_tx_wr_data)
    );

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

    primer2_session_context u_session (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .zeroize_i             (session_zeroize),
        .load_begin_i          (session_load_begin),
        .load_session_id_i     ({arg_q[0],arg_q[1],arg_q[2],arg_q[3]}),
        .load_total_len_i      ({arg_q[5],arg_q[6]}),
        .load_chunk_i          (session_load_chunk),
        .load_offset_i         (chunk_base_q[5:0] + chunk_index_q),
        .load_byte_i           (request_payload_rd_data_i),
        .load_commit_i         (session_load_commit),
        .load_abort_i          (session_load_abort),
        .session_activate_i    (session_activate),
        .activate_session_id_i ({arg_q[0],arg_q[1],arg_q[2],arg_q[3]}),
        .key_loading_o         (session_key_loading),
        .key_valid_o           (key_valid_o),
        .session_active_o      (session_active_o),
        .session_id_o          (session_id),
        .traffic_key_o         (traffic_key),
        .nonce_prefix_o        (nonce_prefix),
        .expected_sequence_o   (expected_sequence_o),
        .sequence_commit_i     (session_sequence_commit),
        .staging_complete_o    (session_staging_complete),
        .staging_conflict_o    (session_staging_conflict),
        .commit_ok_o           (session_commit_ok),
        .commit_failed_o       (session_commit_failed)
    );

    primer2_stp_rx #(
        .MAX_PAYLOAD_BYTES(128),
        .MAX_PACKET_BYTES(MAX_STP_PACKET_BYTES)
    ) u_stp_rx (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .zeroize_i                (transport_zeroize_i || fatal_latched_i ||
                                   (state_q == ST_SECRET_ZEROIZE_PULSE)),
        .secure_enable_i          (secure_enable_i),
        .fatal_latched_i          (fatal_latched_i),
        .key_valid_i              (key_valid_o),
        .session_active_i         (session_active_o),
        .session_id_i             (session_id),
        .traffic_key_i            (traffic_key),
        .nonce_prefix_i           (nonce_prefix),
        .expected_sequence_i      (expected_sequence_o),
        .packet_wr_en_i           (rx_packet_wr_en),
        .packet_wr_addr_i         (rx_packet_wr_addr),
        .packet_wr_data_i         (rx_packet_wr_data),
        .packet_len_i             (current_payload_len_q[7:0]),
        .start_i                  (rx_start),
        .ready_o                  (rx_ready),
        .busy_o                   (rx_busy),
        .done_o                   (rx_done),
        .error_valid_o            (rx_error_valid),
        .error_code_o             (rx_error_code),
        .sequence_commit_o        (session_sequence_commit),
        .result_sequence_o        (rx_result_sequence),
        .release_valid_o          (rx_release_valid),
        .release_len_o            (rx_release_len),
        .release_rd_addr_i        (rx_release_rd_addr),
        .release_rd_data_o        (rx_release_rd_data),
        .accepted_count_o         (rx_accepted_count),
        .replay_count_o           (rx_replay_count),
        .auth_fail_count_o        (rx_auth_fail_count),
        .consecutive_auth_fail_o  (rx_consecutive_auth_fail),
        .fatal_request_o          (rx_fatal_request)
    );

    task automatic queue_response(
        input logic [15:0] status,
        input logic [15:0] detail,
        input response_kind_t kind,
        input logic [15:0] data_len,
        input logic accept_after_fill,
        input logic cache_capture
    );
        begin
            response_status_q <= status;
            response_detail_q <= detail;
            response_device_state_q <= device_state_now;
            response_data_len_q <= {16'h0,data_len};
            response_payload_len_q <= 16'd12 + data_len;
            response_error_q <= (status != ERR_OK);
            response_kind_q <= kind;
            response_accept_after_fill_q <= accept_after_fill;
            response_cache_capture_q <= cache_capture;
            response_fill_index_q <= '0;
            if (status != ERR_OK)
                last_error_code_q <= status;
            state_q <= ST_RESP_FILL;
        end
    endtask

    task automatic start_arg_read(
        input arg_kind_t kind,
        input logic [3:0] byte_count
    );
        begin
            arg_kind_q <= kind;
            arg_expected_q <= byte_count;
            arg_index_q <= '0;
            state_q <= ST_ARG_READ;
        end
    endtask

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            arg_kind_q <= ARG_NONE;
            arg_index_q <= '0;
            arg_expected_q <= '0;
            current_opcode_q <= '0;
            current_transaction_id_q <= '0;
            current_payload_len_q <= '0;
            current_request_crc32_q <= '0;
            chunk_base_q <= '0;
            chunk_index_q <= '0;
            rx_copy_index_q <= '0;
            response_status_q <= ERR_OK;
            response_detail_q <= '0;
            response_device_state_q <= '0;
            response_data_len_q <= '0;
            response_payload_len_q <= '0;
            response_error_q <= 1'b0;
            response_kind_q <= RESP_GENERIC;
            response_accept_after_fill_q <= 1'b0;
            response_cache_capture_q <= 1'b0;
            response_fill_index_q <= '0;
            cache_valid_q <= 1'b0;
            cache_transaction_id_q <= '0;
            cache_opcode_q <= '0;
            cache_payload_len_q <= '0;
            cache_request_crc32_q <= '0;
            cache_frame_len_q <= '0;
            cache_age_q <= '0;
            cache_restore_index_q <= '0;
            loading_session_id_q <= '0;
            loading_direction_q <= '0;
            loading_total_len_q <= '0;
            accepted_counter_base_q <= '0;
            replay_counter_base_q <= '0;
            auth_counter_base_q <= '0;
            clear_counter_mask_q <= '0;
            last_error_code_q <= ERR_OK;
            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;
            tx_frame_len_o <= '0;
            for (i = 0; i < 8; i = i + 1)
                arg_q[i] <= 8'h00;
        end else begin
            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;

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

            if (builder_tx_wr_en && response_cache_capture_q)
                cache_mem[builder_tx_wr_addr] <= builder_tx_wr_data;

            case (state_q)
                ST_IDLE: begin
                    if (request_valid_i && !tx_frame_ready_i && !builder_busy) begin
                        current_opcode_q <= request_opcode_i;
                        current_transaction_id_q <= request_transaction_id_i;
                        current_payload_len_q <= request_payload_len_i;
                        current_request_crc32_q <= request_crc32_i;

                        if (request_error_i) begin
                            request_accept_o <= 1'b1;
                            queue_response(request_error_code_i,16'h0,
                                RESP_GENERIC,16'd0,1'b0,1'b0);
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
                                request_accept_o <= 1'b1;
                                queue_response(ERR_BTP_TRANSACTION,16'h0001,
                                    RESP_GENERIC,16'd0,1'b0,1'b0);
                            end
                        end else begin
                            case (request_opcode_i)
                                OP_GET_DEVICE_ID: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        queue_response(ERR_OK,16'h0,RESP_DEVICE_ID,
                                            16'd8,1'b0,1'b1);
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_GET_STATUS: begin
                                    request_accept_o <= 1'b1;
                                    queue_response(request_payload_len_i==0 ? ERR_OK : ERR_ARGUMENT,
                                        16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                                end

                                OP_GET_ERROR: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        queue_response(last_error_code_q,last_error_code_q,
                                            RESP_GENERIC,16'd0,1'b0,1'b1);
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_CLEAR_ERROR: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i != 16'd2)
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    else if (fatal_latched_i || rx_fatal_request)
                                        queue_response(ERR_SAFE_LOCKED,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    else begin
                                        last_error_code_q <= ERR_OK;
                                        queue_response(ERR_OK,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_PING: begin
                                    if (request_payload_len_i <= 16'd1012)
                                        queue_response(ERR_OK,16'h0,RESP_PING,
                                            request_payload_len_i,1'b1,1'b1);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_BTP_LENGTH,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_KEY_LOAD_BEGIN: begin
                                    if (request_payload_len_i == 16'd7)
                                        start_arg_read(ARG_KEY_BEGIN,4'd7);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_KEY_LOAD_CHUNK: begin
                                    if ((request_payload_len_i >= 16'd3) &&
                                        (request_payload_len_i <= 16'd26))
                                        state_q <= ST_KEY_CHUNK_OFF_HI;
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_KEY_LOAD_COMMIT: begin
                                    if (request_payload_len_i == 16'd7)
                                        start_arg_read(ARG_KEY_COMMIT,4'd7);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_KEY_LOAD_ABORT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        state_q <= ST_KEY_ABORT_PULSE;
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_KEY_STATUS: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        queue_response(ERR_OK,16'h0,RESP_KEY_STATUS,
                                            16'd16,1'b0,1'b1);
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_ZEROIZE: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 16'd2)
                                        state_q <= ST_SECRET_ZEROIZE_PULSE;
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_SESSION_ACTIVATE: begin
                                    if (request_payload_len_i == 16'd4)
                                        start_arg_read(ARG_SESSION,4'd4);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_STP_RX_PACKET: begin
                                    if ((request_payload_len_i >= 16'd40) &&
                                        (request_payload_len_i <= MAX_STP_PACKET_BYTES)) begin
                                        rx_copy_index_q <= '0;
                                        state_q <= ST_RX_COPY;
                                    end else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_STP_LENGTH,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                OP_STP_GET_COUNTERS: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0)
                                        queue_response(ERR_OK,16'h0,RESP_COUNTERS,
                                            16'd20,1'b0,1'b1);
                                    else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                end

                                OP_STP_CLEAR_COUNTERS: begin
                                    if (request_payload_len_i == 16'd1)
                                        state_q <= ST_CLEAR_COUNTERS_READ;
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                            16'd0,1'b0,1'b1);
                                    end
                                end

                                default: begin
                                    request_accept_o <= 1'b1;
                                    queue_response(ERR_UNSUPPORTED_OPCODE,16'h0,RESP_GENERIC,
                                        16'd0,1'b0,1'b1);
                                end
                            endcase
                        end
                    end
                end

                ST_ARG_READ: begin
                    arg_q[arg_index_q] <= request_payload_rd_data_i;
                    if (arg_index_q + 1'b1 >= arg_expected_q) begin
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
                                {arg_q[5],arg_q[6]} != 16'd24)
                                queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                    16'd0,1'b0,1'b1);
                            else if (fatal_latched_i || rx_fatal_request)
                                queue_response(ERR_SAFE_LOCKED,16'h0,RESP_GENERIC,
                                    16'd0,1'b0,1'b1);
                            else begin
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
                                !session_staging_complete)
                                queue_response(ERR_KEY_LOAD_INCOMPLETE,16'h0,RESP_GENERIC,
                                    16'd0,1'b0,1'b1);
                            else
                                state_q <= ST_KEY_COMMIT_PULSE;
                        end

                        ARG_SESSION: begin
                            if (!key_valid_o ||
                                ({arg_q[0],arg_q[1],arg_q[2],arg_q[3]} != session_id))
                                queue_response(ERR_INVALID_STATE,16'h0,RESP_GENERIC,
                                    16'd0,1'b0,1'b1);
                            else
                                state_q <= ST_SESSION_PULSE;
                        end

                        default:
                            queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                                16'd0,1'b0,1'b1);
                    endcase
                end

                ST_KEY_BEGIN_PULSE:
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);

                ST_KEY_CHUNK_OFF_HI: begin
                    chunk_base_q[15:8] <= request_payload_rd_data_i;
                    state_q <= ST_KEY_CHUNK_OFF_LO;
                end

                ST_KEY_CHUNK_OFF_LO: begin
                    chunk_base_q[7:0] <= request_payload_rd_data_i;
                    chunk_index_q <= '0;
                    if (!session_key_loading ||
                        ({chunk_base_q[15:8],request_payload_rd_data_i} +
                         (current_payload_len_q-16'd2) > 16'd24)) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,
                            16'd0,1'b0,1'b1);
                    end else begin
                        state_q <= ST_KEY_CHUNK_DATA;
                    end
                end

                ST_KEY_CHUNK_DATA: begin
                    if (chunk_index_q + 16'd3 >= current_payload_len_q) begin
                        chunk_index_q <= '0;
                        request_accept_o <= 1'b1;
                        queue_response(ERR_OK,16'h0,RESP_GENERIC,
                            16'd0,1'b0,1'b1);
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
                        queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                    end else if (session_commit_failed) begin
                        queue_response(ERR_KEY_COMMIT,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                    end
                end

                ST_KEY_ABORT_PULSE: begin
                    loading_session_id_q <= '0;
                    loading_direction_q <= '0;
                    loading_total_len_q <= '0;
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                end

                ST_SESSION_PULSE:
                    state_q <= ST_SESSION_WAIT;

                ST_SESSION_WAIT: begin
                    if (session_active_o)
                        queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                    else
                        queue_response(ERR_INVALID_STATE,16'h0,RESP_GENERIC,
                            16'd0,1'b0,1'b1);
                end

                ST_SECRET_ZEROIZE_PULSE: begin
                    loading_session_id_q <= '0;
                    loading_direction_q <= '0;
                    loading_total_len_q <= '0;
                    accepted_counter_base_q <= rx_accepted_count;
                    replay_counter_base_q <= rx_replay_count;
                    auth_counter_base_q <= rx_auth_fail_count;
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                end

                ST_RX_COPY: begin
                    if (rx_copy_index_q + 1'b1 >= current_payload_len_q) begin
                        rx_copy_index_q <= '0;
                        request_accept_o <= 1'b1;
                        state_q <= ST_RX_START;
                    end else begin
                        rx_copy_index_q <= rx_copy_index_q + 1'b1;
                    end
                end

                ST_RX_START: begin
                    if (rx_ready)
                        state_q <= ST_RX_WAIT;
                    else
                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b0,1'b1);
                end

                ST_RX_WAIT: begin
                    if (rx_error_valid) begin
                        if ((rx_error_code == ERR_REPLAY) ||
                            (rx_error_code == ERR_SEQUENCE_GAP))
                            queue_response(rx_error_code,DETAIL_EXPECTED_SEQUENCE,
                                RESP_RX_SEQUENCE,16'd8,1'b0,1'b1);
                        else
                            queue_response(rx_error_code,16'h0,
                                RESP_GENERIC,16'd0,1'b0,1'b1);
                    end else if (rx_done) begin
                        if (rx_release_valid)
                            queue_response(ERR_OK,DETAIL_COMMIT_ACCEPTED,
                                RESP_RX_COMMIT,16'd10 + rx_release_len,1'b0,1'b1);
                        else
                            queue_response(ERR_AUTH_TAG,16'h0,
                                RESP_GENERIC,16'd0,1'b0,1'b1);
                    end
                end

                ST_CLEAR_COUNTERS_READ: begin
                    clear_counter_mask_q <= request_payload_rd_data_i;
                    request_accept_o <= 1'b1;
                    if (request_payload_rd_data_i[0])
                        accepted_counter_base_q <= rx_accepted_count;
                    if (request_payload_rd_data_i[1])
                        replay_counter_base_q <= rx_replay_count;
                    if (request_payload_rd_data_i[2])
                        auth_counter_base_q <= rx_auth_fail_count;
                    if (request_payload_rd_data_i[7:3] != 0)
                        queue_response(ERR_RESERVED_FIELD,16'h0,RESP_GENERIC,
                            16'd0,1'b0,1'b1);
                    else
                        queue_response(ERR_OK,16'h0,RESP_GENERIC,
                            16'd0,1'b0,1'b1);
                end

                ST_RESP_FILL: begin
                    if (response_fill_index_q + 1'b1 >= response_payload_len_q) begin
                        if (response_accept_after_fill_q)
                            request_accept_o <= 1'b1;
                        response_fill_index_q <= '0;
                        state_q <= ST_RESP_START;
                    end else begin
                        response_fill_index_q <= response_fill_index_q + 1'b1;
                    end
                end

                ST_RESP_START:
                    state_q <= ST_RESP_WAIT;

                ST_RESP_WAIT: begin
                    if (builder_done)
                        state_q <= ST_RESP_COMMIT;
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

                default:
                    state_q <= ST_IDLE;
            endcase

            if (transport_zeroize_i) begin
                state_q <= ST_IDLE;
                request_accept_o <= 1'b0;
                tx_frame_commit_o <= 1'b0;
                cache_valid_q <= 1'b0;
                cache_age_q <= '0;
                response_cache_capture_q <= 1'b0;
                loading_session_id_q <= '0;
                loading_direction_q <= '0;
                loading_total_len_q <= '0;
                accepted_counter_base_q <= '0;
                replay_counter_base_q <= '0;
                auth_counter_base_q <= '0;
                clear_counter_mask_q <= '0;
                last_error_code_q <= ERR_OK;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if (tx_frame_commit_o)
                assert (tx_frame_len_o != 0)
                    else $error("primer2_btp_endpoint_deploy: zero response length");
            if (session_active_o)
                assert (key_valid_o)
                    else $error("primer2_btp_endpoint_deploy: active session without key");
            if (rx_release_valid)
                assert (!rx_fatal_request)
                    else $error("primer2_btp_endpoint_deploy: release retained after fatal auth threshold");
        end
    end
`endif

    logic unused_inputs;
    always_comb unused_inputs = ^{request_flags_i,tx_frame_consumed_i,clear_counter_mask_q};
endmodule
