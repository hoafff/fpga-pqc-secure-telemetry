module primer1_endpoint_core #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer RESPONSE_CACHE_CYCLES = SYS_CLK_HZ
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        external_zeroize_i,
    input  logic        secure_enable_i,
    input  logic        safe_locked_i,

    /* Complete request buffer from the CS-bounded SPI slave. */
    input  logic        req_valid_i,
    input  logic [10:0] req_len_i,
    output logic        req_take_o,
    output logic [10:0] req_raddr_o,
    input  logic [7:0]  req_rdata_i,

    /* Response-cache write/rearm interface back to the SPI slave. */
    output logic        rsp_we_o,
    output logic [10:0] rsp_waddr_o,
    output logic [7:0]  rsp_wdata_o,
    output logic [10:0] rsp_len_o,
    output logic        rsp_commit_o,
    output logic        rsp_rearm_o,
    input  logic        rsp_consumed_i,

    output logic        endpoint_busy_o,
    output logic        key_valid_o,
    output logic        session_active_o,
    output logic        retained_valid_o,
    output logic [63:0] tx_sequence_o,
    output logic [15:0] last_error_o
);
    localparam logic [15:0] ERR_OK                    = 16'h0000;
    localparam logic [15:0] ERR_BTP_LENGTH            = 16'h0103;
    localparam logic [15:0] ERR_UNSUPPORTED_OPCODE    = 16'h0201;
    localparam logic [15:0] ERR_RESERVED_FIELD        = 16'h0202;
    localparam logic [15:0] ERR_ARGUMENT              = 16'h0203;
    localparam logic [15:0] ERR_TRANSACTION_COLLISION = 16'h0207;
    localparam logic [15:0] ERR_BUSY                  = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE         = 16'h0302;
    localparam logic [15:0] ERR_SAFE_LOCKED           = 16'h0305;
    localparam logic [15:0] ERR_SELF_TEST             = 16'h0801;

    localparam logic [7:0] OP_GET_DEVICE_ID        = 8'h01;
    localparam logic [7:0] OP_GET_STATUS           = 8'h02;
    localparam logic [7:0] OP_GET_ERROR            = 8'h03;
    localparam logic [7:0] OP_CLEAR_ERROR          = 8'h04;
    localparam logic [7:0] OP_SOFT_RESET           = 8'h05;
    localparam logic [7:0] OP_SELF_TEST            = 8'h06;
    localparam logic [7:0] OP_KEY_LOAD_BEGIN       = 8'h40;
    localparam logic [7:0] OP_KEY_LOAD_CHUNK       = 8'h41;
    localparam logic [7:0] OP_KEY_LOAD_COMMIT      = 8'h42;
    localparam logic [7:0] OP_KEY_LOAD_ABORT       = 8'h43;
    localparam logic [7:0] OP_KEY_STATUS           = 8'h44;
    localparam logic [7:0] OP_ZEROIZE              = 8'h45;
    localparam logic [7:0] OP_SESSION_ACTIVATE     = 8'h46;
    localparam logic [7:0] OP_ASCON_KAT            = 8'h50;
    localparam logic [7:0] OP_TELEMETRY_TX_SAMPLE  = 8'h60;
    localparam logic [7:0] OP_STP_GET_COUNTERS     = 8'h62;
    localparam logic [7:0] OP_STP_CLEAR_COUNTERS   = 8'h63;
    localparam logic [7:0] OP_STP_TX_COMMIT        = 8'h64;
    localparam logic [7:0] OP_STP_TX_RECONCILE     = 8'h65;
    localparam logic [7:0] OP_PING                  = 8'h7F;

    typedef enum logic [4:0] {
        E_IDLE,
        E_VALIDATE_START,
        E_VALIDATE_WAIT,
        E_DUP_START,
        E_DUP_WAIT,
        E_PAYLOAD_LOAD,
        E_EXECUTE,
        E_KEY_STREAM,
        E_SM_BEGIN_FIRE,
        E_SM_COMMIT_FIRE,
        E_SM_ABORT_FIRE,
        E_SM_ACTIVATE_FIRE,
        E_SM_TX_COMMIT_FIRE,
        E_SM_RECONCILE_FIRE,
        E_SM_RESULT,
        E_TX_START,
        E_TX_WAIT,
        E_TX_RELEASE,
        E_KAT_START,
        E_KAT_WAIT,
        E_LOCAL_ZEROIZE,
        E_RESPONSE_START,
        E_RESPONSE_WAIT
    } endpoint_state_t;

    typedef enum logic [2:0] {
        ACTION_NONE,
        ACTION_KEY,
        ACTION_TX_COMMIT,
        ACTION_TX_RECONCILE_KEEP,
        ACTION_TX_RECONCILE_ADVANCE
    } pending_action_t;

    typedef enum logic [1:0] {
        APP_NONE,
        APP_STATIC,
        APP_TELEMETRY
    } app_kind_t;

    endpoint_state_t state_q;
    pending_action_t pending_action_q;
    app_kind_t app_kind_q;

    logic [7:0] payload_buf [0:127];
    logic [7:0] app_static [0:31];
    logic [7:0] payload_index_q;
    logic [7:0] chunk_index_q;
    logic [15:0] chunk_base_q;

    logic [7:0]  opcode_q;
    logic [7:0]  request_flags_q;
    logic [15:0] transaction_id_q;
    logic [15:0] payload_len_q;

    logic [15:0] response_status_q;
    logic [15:0] response_detail_q;
    logic [31:0] response_meta_q;
    logic [9:0]  response_app_len_q;
    logic [15:0] last_error_q;

    /* Validator. */
    logic validator_done, validator_valid;
    logic [15:0] validator_error;
    logic [7:0] validator_opcode, validator_flags;
    logic [15:0] validator_txid, validator_payload_len;
    logic [10:0] validator_raddr;

    /* Duplicate guard. */
    logic duplicate_decision_valid;
    logic duplicate_new, duplicate_hit, duplicate_collision;
    logic [10:0] duplicate_raddr;
    logic duplicate_cache_valid;

    /* Response builder. */
    logic response_builder_done;
    logic response_builder_busy;
    logic response_builder_argument_error;
    logic [9:0] response_app_raddr;
    logic [7:0] response_app_rdata;

    /* Session manager. */
    logic sm_load_begin, sm_load_byte, sm_load_commit, sm_load_abort;
    logic sm_activate, sm_tx_commit, sm_reconcile;
    logic [31:0] sm_load_session_id;
    logic [7:0] sm_load_direction;
    logic [15:0] sm_load_total_len;
    logic [15:0] sm_load_offset;
    logic [7:0] sm_load_data;
    logic [31:0] sm_commit_session_id, sm_commit_policy;
    logic [31:0] sm_activate_session_id;
    logic [63:0] sm_tx_commit_sequence, sm_rx_expected_sequence;
    logic sm_staging_valid, sm_key_valid, sm_session_active;
    logic [23:0] sm_staging_mask;
    logic [31:0] sm_session_id, sm_policy;
    logic [127:0] sm_traffic_key;
    logic [63:0] sm_nonce_prefix, sm_tx_sequence;
    logic sm_event_valid;
    logic [15:0] sm_event_code;

    /* Telemetry transmitter. */
    logic tx_start, tx_release;
    logic [191:0] tx_telemetry;
    logic tx_busy, tx_done, tx_error_valid;
    logic [15:0] tx_error_code;
    logic [6:0] tx_packet_raddr;
    logic [7:0] tx_packet_rdata;
    logic [6:0] tx_packet_len;
    logic tx_retained_valid;
    logic [63:0] tx_retained_sequence;

    /* Ascon KAT. */
    logic kat_start, kat_running, kat_complete, kat_done, kat_pass, kat_fail;
    logic kat_core_busy;
    logic [5:0] kat_mismatch_index;
    logic [7:0] kat_mismatch_observed, kat_mismatch_expected;
    logic [15:0] kat_error_code;

    logic local_zeroize;
    logic [31:0] device_state_live;
    integer i;

    assign endpoint_busy_o = (state_q != E_IDLE) || tx_busy || kat_running;
    assign key_valid_o = sm_key_valid;
    assign session_active_o = sm_session_active;
    assign retained_valid_o = tx_retained_valid;
    assign tx_sequence_o = sm_tx_sequence;
    assign last_error_o = last_error_q;

    always_comb begin
        device_state_live = 32'h0000_0001;
        device_state_live[1] = endpoint_busy_o;
        device_state_live[2] = sm_key_valid;
        device_state_live[3] = sm_session_active;
        device_state_live[4] = tx_retained_valid;
        device_state_live[5] = secure_enable_i;
        device_state_live[31] = safe_locked_i;
    end

    /* Request memory is owned by exactly one reader in each state. */
    always_comb begin
        req_raddr_o = 11'd0;
        if (state_q == E_VALIDATE_START || state_q == E_VALIDATE_WAIT)
            req_raddr_o = validator_raddr;
        else if (state_q == E_DUP_START || state_q == E_DUP_WAIT)
            req_raddr_o = duplicate_raddr;
        else if (state_q == E_PAYLOAD_LOAD)
            req_raddr_o = 11'd10 + payload_index_q;
    end

    btp_frame_validator u_validator (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .zeroize_i         (external_zeroize_i),
        .start_i           (state_q == E_VALIDATE_START),
        .frame_len_i       (req_len_i),
        .mem_raddr_o       (validator_raddr),
        .mem_rdata_i       (req_rdata_i),
        .busy_o            (),
        .done_o            (validator_done),
        .valid_o           (validator_valid),
        .error_code_o      (validator_error),
        .opcode_o          (validator_opcode),
        .flags_o           (validator_flags),
        .transaction_id_o  (validator_txid),
        .payload_len_o     (validator_payload_len)
    );

    btp_duplicate_guard #(
        .MAX_FRAME_BYTES(1038),
        .CACHE_CYCLES(RESPONSE_CACHE_CYCLES)
    ) u_duplicate_guard (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .zeroize_i              (external_zeroize_i),
        .check_i                (state_q == E_DUP_START),
        .frame_len_i            (req_len_i),
        .transaction_id_i       (transaction_id_q),
        .opcode_i               (opcode_q),
        .req_raddr_o            (duplicate_raddr),
        .req_rdata_i            (req_rdata_i),
        .response_ready_i       (response_builder_done),
        .busy_o                 (),
        .decision_valid_o       (duplicate_decision_valid),
        .new_request_o          (duplicate_new),
        .duplicate_o            (duplicate_hit),
        .collision_o            (duplicate_collision),
        .cache_valid_o          (duplicate_cache_valid)
    );

    btp_response_builder #(.MAX_PAYLOAD_BYTES(1024)) u_response_builder (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .zeroize_i         (external_zeroize_i),
        .start_i           (state_q == E_RESPONSE_START),
        .opcode_i          (opcode_q),
        .flags_i           ((response_status_q != 16'h0000) ? 8'h02 : 8'h00),
        .transaction_id_i  (transaction_id_q),
        .status_code_i     (response_status_q),
        .detail_code_i     (response_detail_q),
        .device_state_i    (device_state_live),
        .result_meta_i     (response_meta_q),
        .app_len_i         (response_app_len_q),
        .app_raddr_o       (response_app_raddr),
        .app_rdata_i       (response_app_rdata),
        .rsp_we_o          (rsp_we_o),
        .rsp_waddr_o       (rsp_waddr_o),
        .rsp_wdata_o       (rsp_wdata_o),
        .rsp_len_o         (rsp_len_o),
        .rsp_commit_o      (rsp_commit_o),
        .busy_o            (response_builder_busy),
        .done_o            (response_builder_done),
        .argument_error_o  (response_builder_argument_error)
    );

    primer1_session_manager u_session (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .zeroize_i                (external_zeroize_i || local_zeroize),
        .secure_enable_i          (secure_enable_i && !safe_locked_i),
        .load_begin_i             (sm_load_begin),
        .load_session_id_i        (sm_load_session_id),
        .load_direction_i         (sm_load_direction),
        .load_total_len_i         (sm_load_total_len),
        .load_byte_i              (sm_load_byte),
        .load_offset_i            (sm_load_offset),
        .load_data_i              (sm_load_data),
        .load_commit_i            (sm_load_commit),
        .commit_session_id_i      (sm_commit_session_id),
        .commit_policy_flags_i    (sm_commit_policy),
        .load_abort_i             (sm_load_abort),
        .session_activate_i       (sm_activate),
        .activate_session_id_i    (sm_activate_session_id),
        .tx_commit_i              (sm_tx_commit),
        .tx_commit_sequence_i     (sm_tx_commit_sequence),
        .tx_reconcile_i           (sm_reconcile),
        .rx_expected_sequence_i   (sm_rx_expected_sequence),
        .staging_valid_o          (sm_staging_valid),
        .staging_write_mask_o     (sm_staging_mask),
        .key_valid_o              (sm_key_valid),
        .session_active_o         (sm_session_active),
        .session_id_o             (sm_session_id),
        .traffic_key_o            (sm_traffic_key),
        .nonce_prefix_o           (sm_nonce_prefix),
        .tx_sequence_o            (sm_tx_sequence),
        .policy_flags_o           (sm_policy),
        .event_valid_o            (sm_event_valid),
        .event_code_o             (sm_event_code)
    );

    primer1_telemetry_tx #(.SYS_CLK_HZ(SYS_CLK_HZ)) u_tx (
        .clk_i                 (clk_i),
        .rst_ni                (rst_ni),
        .zeroize_i             (external_zeroize_i || local_zeroize),
        .start_i               (tx_start),
        .telemetry_i           (tx_telemetry),
        .stp_flags_i           (16'h0000),
        .secure_enable_i       (secure_enable_i && !safe_locked_i),
        .key_valid_i           (sm_key_valid),
        .session_active_i      (sm_session_active),
        .session_id_i          (sm_session_id),
        .traffic_key_i         (sm_traffic_key),
        .nonce_prefix_i        (sm_nonce_prefix),
        .tx_sequence_i         (sm_tx_sequence),
        .release_retained_i    (tx_release),
        .packet_raddr_i        (tx_packet_raddr),
        .packet_rdata_o        (tx_packet_rdata),
        .packet_len_o          (tx_packet_len),
        .retained_valid_o      (tx_retained_valid),
        .retained_sequence_o   (tx_retained_sequence),
        .busy_o                (tx_busy),
        .done_o                (tx_done),
        .error_valid_o         (tx_error_valid),
        .error_code_o          (tx_error_code)
    );

    ascon_encrypt_kat_selftest u_kat (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .start_i                (kat_start),
        .running_o              (kat_running),
        .complete_o             (kat_complete),
        .done_o                 (kat_done),
        .pass_o                 (kat_pass),
        .fail_o                 (kat_fail),
        .core_busy_o            (kat_core_busy),
        .mismatch_index_o       (kat_mismatch_index),
        .mismatch_observed_o    (kat_mismatch_observed),
        .mismatch_expected_o    (kat_mismatch_expected),
        .core_error_code_o      (kat_error_code)
    );

    /* Session-control pulses are decoded directly from one-cycle FIRE states. */
    always_comb begin
        sm_load_begin = 1'b0;
        sm_load_byte = 1'b0;
        sm_load_commit = 1'b0;
        sm_load_abort = 1'b0;
        sm_activate = 1'b0;
        sm_tx_commit = 1'b0;
        sm_reconcile = 1'b0;

        sm_load_session_id = {payload_buf[0], payload_buf[1],
                              payload_buf[2], payload_buf[3]};
        sm_load_direction = payload_buf[4];
        sm_load_total_len = {payload_buf[5], payload_buf[6]};
        sm_load_offset = chunk_base_q + (chunk_index_q - 8'd2);
        sm_load_data = payload_buf[chunk_index_q];
        sm_commit_session_id = {payload_buf[0], payload_buf[1],
                                payload_buf[2], payload_buf[3]};
        sm_commit_policy = {payload_buf[4], payload_buf[5],
                            payload_buf[6], payload_buf[7]};
        sm_activate_session_id = {payload_buf[0], payload_buf[1],
                                  payload_buf[2], payload_buf[3]};
        sm_tx_commit_sequence = {
            payload_buf[0], payload_buf[1], payload_buf[2], payload_buf[3],
            payload_buf[4], payload_buf[5], payload_buf[6], payload_buf[7]
        };
        sm_rx_expected_sequence = sm_tx_commit_sequence;

        if (state_q == E_SM_BEGIN_FIRE) sm_load_begin = 1'b1;
        if (state_q == E_KEY_STREAM) sm_load_byte = 1'b1;
        if (state_q == E_SM_COMMIT_FIRE) sm_load_commit = 1'b1;
        if (state_q == E_SM_ABORT_FIRE) sm_load_abort = 1'b1;
        if (state_q == E_SM_ACTIVATE_FIRE) sm_activate = 1'b1;
        if (state_q == E_SM_TX_COMMIT_FIRE) sm_tx_commit = 1'b1;
        if (state_q == E_SM_RECONCILE_FIRE) sm_reconcile = 1'b1;
    end

    always_comb begin
        tx_telemetry = '0;
        for (i = 0; i < 24; i = i + 1)
            tx_telemetry[8*i +: 8] = payload_buf[i];
        tx_start = (state_q == E_TX_START);
        tx_release = (state_q == E_TX_RELEASE);
        kat_start = (state_q == E_KAT_START);
        local_zeroize = (state_q == E_LOCAL_ZEROIZE);
    end

    /* Opcode-specific response bytes. */
    always_comb begin
        response_app_rdata = 8'h00;
        tx_packet_raddr = 7'd0;

        if (app_kind_q == APP_STATIC) begin
            if (response_app_raddr < 32)
                response_app_rdata = app_static[response_app_raddr];
        end else if (app_kind_q == APP_TELEMETRY) begin
            case (response_app_raddr)
                10'd0: response_app_rdata = tx_retained_sequence[63:56];
                10'd1: response_app_rdata = tx_retained_sequence[55:48];
                10'd2: response_app_rdata = tx_retained_sequence[47:40];
                10'd3: response_app_rdata = tx_retained_sequence[39:32];
                10'd4: response_app_rdata = tx_retained_sequence[31:24];
                10'd5: response_app_rdata = tx_retained_sequence[23:16];
                10'd6: response_app_rdata = tx_retained_sequence[15:8];
                10'd7: response_app_rdata = tx_retained_sequence[7:0];
                10'd8: response_app_rdata = 8'h00;
                10'd9: response_app_rdata = {1'b0, tx_packet_len[6:0]};
                default: begin
                    if ((response_app_raddr >= 10) &&
                        (response_app_raddr < 10 + tx_packet_len)) begin
                        tx_packet_raddr = response_app_raddr - 10;
                        response_app_rdata = tx_packet_rdata;
                    end
                end
            endcase
        end
    end

    task automatic queue_response(
        input logic [15:0] status,
        input logic [15:0] detail,
        input logic [31:0] meta,
        input app_kind_t app_kind,
        input logic [9:0] app_len
    );
        begin
            response_status_q  <= status;
            response_detail_q  <= detail;
            response_meta_q    <= meta;
            app_kind_q         <= app_kind;
            response_app_len_q <= app_len;
            if (status != ERR_OK)
                last_error_q <= status;
            state_q <= E_RESPONSE_START;
        end
    endtask

    always_ff @(posedge clk_i) begin
        if (!rst_ni || external_zeroize_i) begin
            state_q              <= E_IDLE;
            pending_action_q     <= ACTION_NONE;
            app_kind_q           <= APP_NONE;
            payload_index_q      <= '0;
            chunk_index_q        <= '0;
            chunk_base_q         <= '0;
            opcode_q             <= '0;
            request_flags_q      <= '0;
            transaction_id_q     <= '0;
            payload_len_q        <= '0;
            response_status_q    <= '0;
            response_detail_q    <= '0;
            response_meta_q      <= '0;
            response_app_len_q   <= '0;
            last_error_q         <= '0;
            req_take_o           <= 1'b0;
            rsp_rearm_o          <= 1'b0;
            for (i = 0; i < 128; i = i + 1)
                payload_buf[i] <= 8'h00;
            for (i = 0; i < 32; i = i + 1)
                app_static[i] <= 8'h00;
        end else begin
            req_take_o  <= 1'b0;
            rsp_rearm_o <= 1'b0;

            if (sm_event_valid && sm_event_code != ERR_OK)
                last_error_q <= sm_event_code;
            if (tx_error_valid && tx_error_code != ERR_OK)
                last_error_q <= tx_error_code;

            case (state_q)
                E_IDLE: begin
                    if (req_valid_i)
                        state_q <= E_VALIDATE_START;
                end

                E_VALIDATE_START: state_q <= E_VALIDATE_WAIT;

                E_VALIDATE_WAIT: begin
                    if (validator_done) begin
                        opcode_q         <= validator_opcode;
                        request_flags_q  <= validator_flags;
                        transaction_id_q <= validator_txid;
                        payload_len_q    <= validator_payload_len;
                        if (!validator_valid) begin
                            queue_response(validator_error, 16'h0000,
                                           32'h0000_0000, APP_NONE, 10'd0);
                        end else if (validator_flags != 8'h00) begin
                            queue_response(ERR_RESERVED_FIELD, 16'h0000,
                                           32'h0000_0000, APP_NONE, 10'd0);
                        end else begin
                            state_q <= E_DUP_START;
                        end
                    end
                end

                E_DUP_START: state_q <= E_DUP_WAIT;

                E_DUP_WAIT: begin
                    if (duplicate_decision_valid) begin
                        if (duplicate_hit) begin
                            rsp_rearm_o <= 1'b1;
                            req_take_o  <= 1'b1;
                            state_q     <= E_IDLE;
                        end else if (duplicate_collision) begin
                            queue_response(ERR_TRANSACTION_COLLISION, 16'h0000,
                                           32'h0000_0000, APP_NONE, 10'd0);
                        end else if (duplicate_new) begin
                            if (payload_len_q > 16'd128) begin
                                queue_response(ERR_BTP_LENGTH, 16'h0000,
                                               32'h0000_0000, APP_NONE, 10'd0);
                            end else if (payload_len_q == 16'd0) begin
                                state_q <= E_EXECUTE;
                            end else begin
                                payload_index_q <= 8'd0;
                                state_q <= E_PAYLOAD_LOAD;
                            end
                        end
                    end
                end

                E_PAYLOAD_LOAD: begin
                    payload_buf[payload_index_q] <= req_rdata_i;
                    if (payload_index_q == payload_len_q - 16'd1)
                        state_q <= E_EXECUTE;
                    else
                        payload_index_q <= payload_index_q + 8'd1;
                end

                E_EXECUTE: begin
                    pending_action_q <= ACTION_NONE;
                    case (opcode_q)
                        OP_GET_DEVICE_ID: begin
                            if (payload_len_q != 0) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else begin
                                app_static[0] <= "P"; app_static[1] <= "R";
                                app_static[2] <= "I"; app_static[3] <= "M";
                                app_static[4] <= "E"; app_static[5] <= "R";
                                app_static[6] <= "1"; app_static[7] <= 8'h00;
                                queue_response(ERR_OK, 0, 32'h0001_0001,
                                               APP_STATIC, 10'd8);
                            end
                        end

                        OP_GET_STATUS: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else
                                queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                        end

                        OP_GET_ERROR: begin
                            if (payload_len_q != 0) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else begin
                                app_static[0] <= last_error_q[15:8];
                                app_static[1] <= last_error_q[7:0];
                                queue_response(ERR_OK, 0, 2, APP_STATIC, 10'd2);
                            end
                        end

                        OP_CLEAR_ERROR: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else begin
                                last_error_q <= 16'h0000;
                                queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                            end
                        end

                        OP_SOFT_RESET: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else
                                state_q <= E_LOCAL_ZEROIZE;
                        end

                        OP_SELF_TEST, OP_ASCON_KAT: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (safe_locked_i)
                                queue_response(ERR_SAFE_LOCKED, 0, 0, APP_NONE, 0);
                            else
                                state_q <= E_KAT_START;
                        end

                        OP_KEY_LOAD_BEGIN: begin
                            if (payload_len_q != 16'd7)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (safe_locked_i)
                                queue_response(ERR_SAFE_LOCKED, 0, 0, APP_NONE, 0);
                            else begin
                                pending_action_q <= ACTION_KEY;
                                state_q <= E_SM_BEGIN_FIRE;
                            end
                        end

                        OP_KEY_LOAD_CHUNK: begin
                            if ((payload_len_q < 16'd3) ||
                                (payload_len_q > 16'd26)) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else begin
                                chunk_base_q <= {payload_buf[0], payload_buf[1]};
                                chunk_index_q <= 8'd2;
                                if (({payload_buf[0], payload_buf[1]} +
                                     payload_len_q - 16'd2) > 16'd24)
                                    queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                                else begin
                                    pending_action_q <= ACTION_KEY;
                                    state_q <= E_KEY_STREAM;
                                end
                            end
                        end

                        OP_KEY_LOAD_COMMIT: begin
                            if (payload_len_q != 16'd8)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (safe_locked_i)
                                queue_response(ERR_SAFE_LOCKED, 0, 0, APP_NONE, 0);
                            else begin
                                pending_action_q <= ACTION_KEY;
                                state_q <= E_SM_COMMIT_FIRE;
                            end
                        end

                        OP_KEY_LOAD_ABORT: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else begin
                                pending_action_q <= ACTION_KEY;
                                state_q <= E_SM_ABORT_FIRE;
                            end
                        end

                        OP_KEY_STATUS: begin
                            if (payload_len_q != 0) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else begin
                                app_static[0] <= {7'd0, sm_key_valid};
                                app_static[1] <= {7'd0, sm_session_active};
                                app_static[2] <= sm_session_id[31:24];
                                app_static[3] <= sm_session_id[23:16];
                                app_static[4] <= sm_session_id[15:8];
                                app_static[5] <= sm_session_id[7:0];
                                app_static[6] <= sm_tx_sequence[63:56];
                                app_static[7] <= sm_tx_sequence[55:48];
                                app_static[8] <= sm_tx_sequence[47:40];
                                app_static[9] <= sm_tx_sequence[39:32];
                                app_static[10] <= sm_tx_sequence[31:24];
                                app_static[11] <= sm_tx_sequence[23:16];
                                app_static[12] <= sm_tx_sequence[15:8];
                                app_static[13] <= sm_tx_sequence[7:0];
                                queue_response(ERR_OK, 0, 14, APP_STATIC, 10'd14);
                            end
                        end

                        OP_ZEROIZE: begin
                            if (payload_len_q != 16'd2)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else
                                state_q <= E_LOCAL_ZEROIZE;
                        end

                        OP_SESSION_ACTIVATE: begin
                            if (payload_len_q != 16'd4)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (safe_locked_i)
                                queue_response(ERR_SAFE_LOCKED, 0, 0, APP_NONE, 0);
                            else begin
                                pending_action_q <= ACTION_KEY;
                                state_q <= E_SM_ACTIVATE_FIRE;
                            end
                        end

                        OP_TELEMETRY_TX_SAMPLE: begin
                            if (payload_len_q != 16'd24)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (safe_locked_i)
                                queue_response(ERR_SAFE_LOCKED, 0, 0, APP_NONE, 0);
                            else
                                state_q <= E_TX_START;
                        end

                        OP_STP_GET_COUNTERS: begin
                            if (payload_len_q != 0) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else begin
                                app_static[0] <= {7'd0, tx_retained_valid};
                                app_static[1] <= sm_tx_sequence[63:56];
                                app_static[2] <= sm_tx_sequence[55:48];
                                app_static[3] <= sm_tx_sequence[47:40];
                                app_static[4] <= sm_tx_sequence[39:32];
                                app_static[5] <= sm_tx_sequence[31:24];
                                app_static[6] <= sm_tx_sequence[23:16];
                                app_static[7] <= sm_tx_sequence[15:8];
                                app_static[8] <= sm_tx_sequence[7:0];
                                queue_response(ERR_OK, 0, 9, APP_STATIC, 10'd9);
                            end
                        end

                        OP_STP_CLEAR_COUNTERS: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (sm_session_active || tx_retained_valid)
                                queue_response(ERR_INVALID_STATE, 0, 0, APP_NONE, 0);
                            else
                                queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                        end

                        OP_STP_TX_COMMIT: begin
                            if (payload_len_q != 16'd8)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else if (!tx_retained_valid)
                                queue_response(ERR_INVALID_STATE, 0, 0, APP_NONE, 0);
                            else if ({payload_buf[0], payload_buf[1], payload_buf[2],
                                      payload_buf[3], payload_buf[4], payload_buf[5],
                                      payload_buf[6], payload_buf[7]} !=
                                     tx_retained_sequence)
                                queue_response(ERR_INVALID_STATE, 0, 0, APP_NONE, 0);
                            else begin
                                pending_action_q <= ACTION_TX_COMMIT;
                                state_q <= E_SM_TX_COMMIT_FIRE;
                            end
                        end

                        OP_STP_TX_RECONCILE: begin
                            if (payload_len_q != 16'd8) begin
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            end else if (!tx_retained_valid) begin
                                queue_response(ERR_INVALID_STATE, 0, 0, APP_NONE, 0);
                            end else begin
                                if ({payload_buf[0], payload_buf[1], payload_buf[2],
                                     payload_buf[3], payload_buf[4], payload_buf[5],
                                     payload_buf[6], payload_buf[7]} == sm_tx_sequence)
                                    pending_action_q <= ACTION_TX_RECONCILE_KEEP;
                                else
                                    pending_action_q <= ACTION_TX_RECONCILE_ADVANCE;
                                state_q <= E_SM_RECONCILE_FIRE;
                            end
                        end

                        OP_PING: begin
                            if (payload_len_q != 0)
                                queue_response(ERR_ARGUMENT, 0, 0, APP_NONE, 0);
                            else begin
                                app_static[0] <= "F"; app_static[1] <= "P";
                                app_static[2] <= "S"; app_static[3] <= "T";
                                queue_response(ERR_OK, 0, 4, APP_STATIC, 10'd4);
                            end
                        end

                        default:
                            queue_response(ERR_UNSUPPORTED_OPCODE, 0,
                                           opcode_q, APP_NONE, 0);
                    endcase
                end

                E_KEY_STREAM: begin
                    if (chunk_index_q == payload_len_q - 16'd1)
                        state_q <= E_SM_RESULT;
                    else
                        chunk_index_q <= chunk_index_q + 8'd1;
                end

                E_SM_BEGIN_FIRE,
                E_SM_COMMIT_FIRE,
                E_SM_ABORT_FIRE,
                E_SM_ACTIVATE_FIRE,
                E_SM_TX_COMMIT_FIRE,
                E_SM_RECONCILE_FIRE:
                    state_q <= E_SM_RESULT;

                E_SM_RESULT: begin
                    if (sm_event_valid) begin
                        queue_response(sm_event_code, 0, 0, APP_NONE, 0);
                    end else begin
                        case (pending_action_q)
                            ACTION_TX_COMMIT,
                            ACTION_TX_RECONCILE_ADVANCE:
                                state_q <= E_TX_RELEASE;
                            ACTION_TX_RECONCILE_KEEP:
                                queue_response(ERR_OK, 0, 32'd1,
                                               APP_NONE, 0);
                            default:
                                queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                        endcase
                    end
                end

                E_TX_START: state_q <= E_TX_WAIT;

                E_TX_WAIT: begin
                    if (tx_error_valid)
                        queue_response(tx_error_code, 0, 0, APP_NONE, 0);
                    else if (tx_done) begin
                        if (!tx_retained_valid)
                            queue_response(ERR_INVALID_STATE, 0, 0, APP_NONE, 0);
                        else
                            queue_response(ERR_OK, 0, tx_packet_len,
                                           APP_TELEMETRY,
                                           10'd10 + tx_packet_len);
                    end
                end

                E_TX_RELEASE: begin
                    queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                end

                E_KAT_START: state_q <= E_KAT_WAIT;

                E_KAT_WAIT: begin
                    if (kat_done) begin
                        if (kat_pass && !kat_fail && kat_error_code == 16'h0000)
                            queue_response(ERR_OK, 0, 32'd1, APP_NONE, 0);
                        else
                            queue_response(ERR_SELF_TEST,
                                           {10'd0, kat_mismatch_index},
                                           {16'h0000,
                                            kat_mismatch_observed,
                                            kat_mismatch_expected},
                                           APP_NONE, 0);
                    end
                end

                E_LOCAL_ZEROIZE: begin
                    last_error_q <= 16'h0000;
                    queue_response(ERR_OK, 0, 0, APP_NONE, 0);
                end

                E_RESPONSE_START: begin
                    state_q <= E_RESPONSE_WAIT;
                end

                E_RESPONSE_WAIT: begin
                    if (response_builder_argument_error) begin
                        /* Internal construction failure is never reported as success. */
                        last_error_q <= ERR_BTP_LENGTH;
                    end
                    if (response_builder_done) begin
                        req_take_o <= 1'b1;
                        state_q <= E_IDLE;
                    end
                end

                default: state_q <= E_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && !external_zeroize_i) begin
            assert (!(req_take_o && rsp_rearm_o && !duplicate_hit))
                else $error("primer1_endpoint_core: invalid request/rearm combination");
            assert (!tx_retained_valid || sm_key_valid)
                else $error("primer1_endpoint_core: retained packet without key context");
        end
    end
`endif

    /* Keep review-visible signals used for debug/evidence. */
    logic unused_debug;
    always_comb begin
        unused_debug = duplicate_cache_valid ^ response_builder_busy ^
                       rsp_consumed_i ^ sm_staging_valid ^ (^sm_staging_mask) ^
                       (^sm_policy) ^ kat_complete ^ kat_core_busy;
    end
endmodule
