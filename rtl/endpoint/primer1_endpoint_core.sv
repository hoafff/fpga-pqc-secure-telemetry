module primer1_endpoint_core (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic [7:0]   cmd_opcode_i,
    input  logic [7:0]   cmd_flags_i,
    input  logic [15:0]  cmd_transaction_id_i,
    input  logic [15:0]  cmd_payload_len_i,
    output logic [9:0]   cmd_payload_addr_o,
    input  logic [7:0]   cmd_payload_data_i,

    output logic         rsp_payload_we_o,
    output logic [9:0]   rsp_payload_addr_o,
    output logic [7:0]   rsp_payload_data_o,
    output logic         rsp_valid_o,
    input  logic         rsp_ready_i,
    output logic [7:0]   rsp_opcode_o,
    output logic [7:0]   rsp_flags_o,
    output logic [15:0]  rsp_transaction_id_o,
    output logic [15:0]  rsp_payload_len_o,

    /* Receiver commit evidence is a logical integration input. FPST v1.1
     * Appendix B already assigns 0x61 to STP_RX_PACKET, therefore Primer #1
     * SHALL NOT invent a private BTP opcode for this signal. */
    input  logic         tx_commit_valid_i,
    input  logic [63:0]  tx_commit_sequence_i,

    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [63:0]  tx_sequence_o,
    output logic         tx_packet_retained_o,
    output logic         endpoint_busy_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    /* Frozen FPST-SYS-SPEC-001 v1.1 Appendix-B opcodes. */
    localparam logic [7:0] OP_GET_DEVICE_ID        = 8'h01;
    localparam logic [7:0] OP_GET_STATUS           = 8'h02;
    localparam logic [7:0] OP_GET_ERROR            = 8'h03;
    localparam logic [7:0] OP_CLEAR_ERROR          = 8'h04;
    localparam logic [7:0] OP_SOFT_RESET           = 8'h05;
    localparam logic [7:0] OP_SELF_TEST            = 8'h06;
    localparam logic [7:0] OP_READ_REG             = 8'h10;
    localparam logic [7:0] OP_WRITE_REG            = 8'h11;
    localparam logic [7:0] OP_PQC_WRITE_COEFF      = 8'h20;
    localparam logic [7:0] OP_PQC_READ_COEFF       = 8'h21;
    localparam logic [7:0] OP_PQC_LOAD_POLY        = 8'h22;
    localparam logic [7:0] OP_PQC_READ_POLY        = 8'h23;
    localparam logic [7:0] OP_PQC_START_NTT        = 8'h24;
    localparam logic [7:0] OP_PQC_START_INTT       = 8'h25;
    localparam logic [7:0] OP_PQC_POINTWISE_MUL    = 8'h26;
    localparam logic [7:0] OP_PQC_POLY_ADD_SUB     = 8'h27;
    localparam logic [7:0] OP_PQC_GET_RESULT       = 8'h28;
    localparam logic [7:0] OP_KEY_LOAD_BEGIN       = 8'h40;
    localparam logic [7:0] OP_KEY_LOAD_CHUNK       = 8'h41;
    localparam logic [7:0] OP_KEY_LOAD_COMMIT      = 8'h42;
    localparam logic [7:0] OP_KEY_LOAD_ABORT       = 8'h43;
    localparam logic [7:0] OP_KEY_STATUS           = 8'h44;
    localparam logic [7:0] OP_ZEROIZE              = 8'h45;
    localparam logic [7:0] OP_SESSION_ACTIVATE     = 8'h46;
    localparam logic [7:0] OP_ASCON_KAT            = 8'h50;
    localparam logic [7:0] OP_TELEMETRY_TX_SAMPLE  = 8'h60;
    localparam logic [7:0] OP_STP_RX_PACKET        = 8'h61;
    localparam logic [7:0] OP_STP_GET_COUNTERS     = 8'h62;
    localparam logic [7:0] OP_STP_CLEAR_COUNTERS   = 8'h63;
    localparam logic [7:0] OP_TEST_INJECT_CONFIG   = 8'h70;
    localparam logic [7:0] OP_TEST_TRIGGER_TIMEOUT = 8'h71;
    localparam logic [7:0] OP_TEST_GET_HOOKS       = 8'h72;
    localparam logic [7:0] OP_PING                 = 8'h7F;

    localparam logic [15:0] ERR_UNSUPPORTED_OPCODE  = 16'h0201;
    localparam logic [15:0] ERR_STP_LENGTH          = 16'h0206;
    localparam logic [15:0] ERR_BUSY                = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE       = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY              = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED     = 16'h0304;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT          = 16'h0505;
    localparam logic [15:0] ERR_SEQUENCE_DESYNC     = 16'h0610;

    /* Stable repository device identifier for Primer #1 TX endpoint. */
    localparam logic [31:0] DEVICE_ID_PRIMER1_TX = 32'h0000_0001;

    localparam logic [31:0] CAP_FORWARD_NTT = 32'h0000_0001;
    localparam logic [31:0] CAP_ASCON_TX    = 32'h0000_0002;
    localparam logic [31:0] CAP_STP_TX      = 32'h0000_0004;
    localparam logic [31:0] CAP_BTP_CRC32   = 32'h0000_0008;
    localparam logic [31:0] CAPABILITIES =
        CAP_FORWARD_NTT | CAP_ASCON_TX | CAP_STP_TX | CAP_BTP_CRC32;

    localparam logic [2:0] RSP_NONE      = 3'd0;
    localparam logic [2:0] RSP_DEVICE_ID = 3'd1;
    localparam logic [2:0] RSP_STATUS    = 3'd2;
    localparam logic [2:0] RSP_ERROR     = 3'd3;
    localparam logic [2:0] RSP_NTT_READ  = 3'd4;
    localparam logic [2:0] RSP_TX_PACKET = 3'd5;

    typedef enum logic [5:0] {
        S_IDLE,
        S_COPY_CMD,
        S_EXEC,
        S_KEY_CHUNK_CHECK,
        S_KEY_CHUNK_APPLY,
        S_KEY_STAGE_PULSE,
        S_KEY_STAGE_WAIT,
        S_KEY_COMMIT_WAIT,
        S_ACTIVATE_WAIT,
        S_ZEROIZE_WAIT,
        S_NTT_LOAD_CHECK,
        S_NTT_LOAD_WRITE,
        S_NTT_READ_REQ,
        S_NTT_READ_WAIT,
        S_NTT_READ_WRITE_LO,
        S_NTT_WAIT,
        S_TX_WAIT,
        S_BUILD_STATUS_HI,
        S_BUILD_STATUS_LO,
        S_BUILD_EXTRA,
        S_BUILD_TX_PACKET,
        S_FINISH_CMD,
        S_SUBMIT_RSP
    } state_t;

    state_t state_q;

    logic [7:0] cmd_buf [0:1023];
    logic [9:0] copy_index_q;
    logic [7:0] opcode_q;
    logic [15:0] transaction_id_q;
    logic [15:0] payload_len_q;

    logic [15:0] response_status_q;
    logic [15:0] response_len_q;
    logic [9:0] response_index_q;
    logic [2:0] response_kind_q;
    logic [15:0] last_error_q;

    logic key_loading_q;
    logic [31:0] key_load_session_id_q;
    logic [23:0] key_coverage_q;
    logic [7:0] key_material_q [0:23];
    logic [5:0] key_chunk_offset_q;
    logic [5:0] key_chunk_len_q;
    logic [5:0] key_chunk_index_q;
    logic key_chunk_conflict_q;

    logic session_stage_valid_q;
    logic session_stage_ready;
    logic [31:0] session_stage_id_q;
    logic [127:0] session_stage_key;
    logic [63:0] session_stage_np;
    logic [63:0] session_stage_sequence_q;
    logic [31:0] session_stage_policy_q;
    logic session_commit_valid_q;
    logic session_commit_ready;
    logic session_activate_valid_q;
    logic session_activate_ready;
    logic crypto_zeroize_q;
    logic session_error_valid;
    logic [15:0] session_error_code;
    logic [31:0] active_session_id;
    logic [127:0] active_key;
    logic [63:0] active_np;
    logic [31:0] active_policy;

    logic tx_commit_accept;

    logic ntt_start_q;
    logic ntt_busy;
    logic ntt_done;
    logic ntt_host_re_q;
    logic ntt_host_we_q;
    logic [7:0] ntt_host_addr_q;
    logic [15:0] ntt_host_wdata_q;
    logic ntt_host_ready;
    logic ntt_host_rvalid;
    logic [15:0] ntt_host_rdata;
    logic [8:0] ntt_count_q;
    logic [8:0] ntt_index_q;
    logic [7:0] ntt_read_base_q;
    logic [15:0] ntt_read_data_q;

    logic tx_start_q;
    logic tx_ready;
    logic [191:0] tx_sample;
    logic tx_busy;
    logic tx_done;
    logic tx_packet_valid;
    logic [15:0] tx_packet_len;
    logic [63:0] tx_packet_sequence;
    logic [6:0] tx_packet_addr_q;
    logic [7:0] tx_packet_data;
    logic tx_error_valid;
    logic [15:0] tx_error_code;

    logic [15:0] cmd_u16_0;
    logic [15:0] cmd_u16_2;
    logic [31:0] cmd_u32_0;
    logic [63:0] cmd_u64_0;

    integer i;

    assign cmd_u16_0 = {cmd_buf[0], cmd_buf[1]};
    assign cmd_u16_2 = {cmd_buf[2], cmd_buf[3]};
    assign cmd_u32_0 = {cmd_buf[0], cmd_buf[1], cmd_buf[2], cmd_buf[3]};
    assign cmd_u64_0 = {cmd_buf[0], cmd_buf[1], cmd_buf[2], cmd_buf[3],
                        cmd_buf[4], cmd_buf[5], cmd_buf[6], cmd_buf[7]};

    always_comb begin
        session_stage_key = '0;
        session_stage_np = '0;
        for (i = 0; i < 16; i = i + 1)
            session_stage_key[8*i +: 8] = key_material_q[i];
        for (i = 0; i < 8; i = i + 1)
            session_stage_np[8*i +: 8] = key_material_q[16+i];

        tx_sample = '0;
        for (i = 0; i < 24; i = i + 1)
            tx_sample[8*i +: 8] = cmd_buf[i];
    end

    assign cmd_payload_addr_o = copy_index_q;
    assign endpoint_busy_o = (state_q != S_IDLE) || ntt_busy || tx_busy;
    assign tx_packet_retained_o = tx_packet_valid;

    /* Commit is accepted exactly once and only for the currently retained
     * packet/current TX sequence. A mismatched logical commit never reaches the
     * session counter nor the retained-packet release input. */
    assign tx_commit_accept = tx_commit_valid_i && tx_packet_valid &&
                              (tx_commit_sequence_i == tx_packet_sequence) &&
                              (tx_commit_sequence_i == tx_sequence_o);

    fpst_tx_session u_session (
        .clk_i                    (clk_i),
        .rst_ni                   (rst_ni),
        .zeroize_i                (zeroize_i || crypto_zeroize_q),
        .secure_enable_i          (secure_enable_i),
        .stage_valid_i            (session_stage_valid_q),
        .stage_ready_o            (session_stage_ready),
        .stage_session_id_i       (session_stage_id_q),
        .stage_key_i              (session_stage_key),
        .stage_nonce_prefix_i     (session_stage_np),
        .stage_initial_sequence_i (session_stage_sequence_q),
        .stage_policy_flags_i     (session_stage_policy_q),
        .commit_valid_i           (session_commit_valid_q),
        .commit_ready_o           (session_commit_ready),
        .commit_session_id_i      (session_stage_id_q),
        .activate_valid_i         (session_activate_valid_q),
        .activate_ready_o         (session_activate_ready),
        .activate_session_id_i    (cmd_u32_0),
        .tx_commit_valid_i        (tx_commit_accept),
        .tx_commit_sequence_i     (tx_commit_sequence_i),
        .key_valid_o              (key_valid_o),
        .session_active_o         (session_active_o),
        .session_id_o             (active_session_id),
        .key_o                    (active_key),
        .nonce_prefix_o           (active_np),
        .sequence_o               (tx_sequence_o),
        .policy_flags_o           (active_policy),
        .error_valid_o            (session_error_valid),
        .error_code_o             (session_error_code)
    );

    forward_ntt_core u_ntt (
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
        .stage_o         (),
        .stage_barrier_o (),
        .active_bank_o   ()
    );

    fpst_telemetry_tx u_tx (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .zeroize_i          (zeroize_i || crypto_zeroize_q),
        .secure_enable_i    (secure_enable_i),
        .start_i            (tx_start_q),
        .ready_o            (tx_ready),
        .telemetry_record_i (tx_sample),
        .session_active_i   (session_active_o),
        .session_id_i       (active_session_id),
        .key_i              (active_key),
        .nonce_prefix_i     (active_np),
        .sequence_i         (tx_sequence_o),
        .busy_o             (tx_busy),
        .done_o             (tx_done),
        .packet_valid_o     (tx_packet_valid),
        .packet_len_o       (tx_packet_len),
        .packet_sequence_o  (tx_packet_sequence),
        .packet_addr_i      (tx_packet_addr_q),
        .packet_data_o      (tx_packet_data),
        .packet_release_i   (tx_commit_accept),
        .error_valid_o      (tx_error_valid),
        .error_code_o       (tx_error_code)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= S_IDLE;
            copy_index_q <= '0;
            opcode_q <= '0;
            transaction_id_q <= '0;
            payload_len_q <= '0;
            response_status_q <= '0;
            response_len_q <= 16'd2;
            response_index_q <= '0;
            response_kind_q <= RSP_NONE;
            last_error_q <= 16'h0000;

            key_loading_q <= 1'b0;
            key_load_session_id_q <= '0;
            key_coverage_q <= '0;
            key_chunk_offset_q <= '0;
            key_chunk_len_q <= '0;
            key_chunk_index_q <= '0;
            key_chunk_conflict_q <= 1'b0;
            session_stage_valid_q <= 1'b0;
            session_stage_id_q <= '0;
            session_stage_sequence_q <= '0;
            session_stage_policy_q <= '0;
            session_commit_valid_q <= 1'b0;
            session_activate_valid_q <= 1'b0;
            crypto_zeroize_q <= 1'b0;

            ntt_start_q <= 1'b0;
            ntt_host_re_q <= 1'b0;
            ntt_host_we_q <= 1'b0;
            ntt_host_addr_q <= '0;
            ntt_host_wdata_q <= '0;
            ntt_count_q <= '0;
            ntt_index_q <= '0;
            ntt_read_base_q <= '0;
            ntt_read_data_q <= '0;

            tx_start_q <= 1'b0;
            tx_packet_addr_q <= '0;

            cmd_ready_o <= 1'b0;
            rsp_payload_we_o <= 1'b0;
            rsp_payload_addr_o <= '0;
            rsp_payload_data_o <= '0;
            rsp_valid_o <= 1'b0;
            rsp_opcode_o <= '0;
            rsp_flags_o <= '0;
            rsp_transaction_id_o <= '0;
            rsp_payload_len_o <= '0;
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;

            for (i = 0; i < 24; i = i + 1)
                key_material_q[i] <= 8'h00;
        end else begin
            cmd_ready_o <= 1'b0;
            rsp_payload_we_o <= 1'b0;
            rsp_valid_o <= 1'b0;
            session_stage_valid_q <= 1'b0;
            session_commit_valid_q <= 1'b0;
            session_activate_valid_q <= 1'b0;
            crypto_zeroize_q <= 1'b0;
            ntt_start_q <= 1'b0;
            ntt_host_re_q <= 1'b0;
            ntt_host_we_q <= 1'b0;
            tx_start_q <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;

            if (zeroize_i) begin
                state_q <= S_IDLE;
                last_error_q <= 16'h0000;
                key_loading_q <= 1'b0;
                key_load_session_id_q <= '0;
                key_coverage_q <= '0;
                for (i = 0; i < 24; i = i + 1)
                    key_material_q[i] <= 8'h00;
            end else begin
                /* Logical receiver-commit mismatch is a local integration
                 * error; it never increments sequence or releases the packet. */
                if (tx_commit_valid_i && !tx_commit_accept) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_SEQUENCE_DESYNC;
                    last_error_q <= ERR_SEQUENCE_DESYNC;
                end else if (session_error_valid) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= session_error_code;
                    last_error_q <= session_error_code;
                end else if (tx_error_valid) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= tx_error_code;
                    last_error_q <= tx_error_code;
                end

                case (state_q)
                    S_IDLE: begin
                        if (cmd_valid_i) begin
                            opcode_q <= cmd_opcode_i;
                            transaction_id_q <= cmd_transaction_id_i;
                            payload_len_q <= cmd_payload_len_i;
                            copy_index_q <= '0;
                            if (cmd_payload_len_i == 0)
                                state_q <= S_EXEC;
                            else
                                state_q <= S_COPY_CMD;
                        end
                    end

                    S_COPY_CMD: begin
                        cmd_buf[copy_index_q] <= cmd_payload_data_i;
                        if (copy_index_q + 1'b1 == payload_len_q)
                            state_q <= S_EXEC;
                        else
                            copy_index_q <= copy_index_q + 1'b1;
                    end

                    S_EXEC: begin
                        response_status_q <= 16'h0000;
                        response_len_q <= 16'd2;
                        response_kind_q <= RSP_NONE;
                        response_index_q <= '0;

                        case (opcode_q)
                            OP_PING: begin
                                if (payload_len_q != 0)
                                    response_status_q <= ERR_INVALID_STATE;
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_GET_DEVICE_ID: begin
                                if (payload_len_q != 0) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                end else begin
                                    response_kind_q <= RSP_DEVICE_ID;
                                    response_len_q <= 16'd6;
                                end
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_GET_STATUS, OP_KEY_STATUS: begin
                                if (payload_len_q != 0) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                end else begin
                                    response_kind_q <= RSP_STATUS;
                                    /* status + capability + session + seq + retained */
                                    response_len_q <= 16'd20;
                                end
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_GET_ERROR: begin
                                if (payload_len_q != 0) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                end else begin
                                    response_kind_q <= RSP_ERROR;
                                    response_len_q <= 16'd4;
                                end
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_CLEAR_ERROR: begin
                                if (payload_len_q != 0)
                                    response_status_q <= ERR_INVALID_STATE;
                                else
                                    last_error_q <= 16'h0000;
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_SOFT_RESET: begin
                                if (payload_len_q != 0) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    crypto_zeroize_q <= 1'b1;
                                    key_loading_q <= 1'b0;
                                    key_coverage_q <= '0;
                                    for (i = 0; i < 24; i = i + 1)
                                        key_material_q[i] <= 8'h00;
                                    state_q <= S_ZEROIZE_WAIT;
                                end
                            end

                            OP_SELF_TEST, OP_READ_REG, OP_WRITE_REG,
                            OP_ASCON_KAT, OP_STP_RX_PACKET,
                            OP_STP_GET_COUNTERS, OP_STP_CLEAR_COUNTERS,
                            OP_TEST_INJECT_CONFIG, OP_TEST_TRIGGER_TIMEOUT,
                            OP_TEST_GET_HOOKS: begin
                                response_status_q <= ERR_UNSUPPORTED_OPCODE;
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_KEY_LOAD_BEGIN: begin
                                if (payload_len_q != 7 || cmd_buf[4] != 8'h01 ||
                                    cmd_u16_0 == 16'h0000 ||
                                    {cmd_buf[5],cmd_buf[6]} != 16'd24) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                end else begin
                                    key_loading_q <= 1'b1;
                                    key_load_session_id_q <= cmd_u32_0;
                                    key_coverage_q <= '0;
                                    for (i = 0; i < 24; i = i + 1)
                                        key_material_q[i] <= 8'h00;
                                end
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_KEY_LOAD_CHUNK: begin
                                if (!key_loading_q || payload_len_q < 3 ||
                                    cmd_u16_0 > 23 ||
                                    (cmd_u16_0 + payload_len_q - 2) > 24) begin
                                    response_status_q <= ERR_KEY_LOAD_INCOMPLETE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    key_chunk_offset_q <= cmd_u16_0[5:0];
                                    key_chunk_len_q <= payload_len_q - 2;
                                    key_chunk_index_q <= '0;
                                    key_chunk_conflict_q <= 1'b0;
                                    state_q <= S_KEY_CHUNK_CHECK;
                                end
                            end

                            OP_KEY_LOAD_COMMIT: begin
                                if (!key_loading_q || payload_len_q != 16 ||
                                    cmd_u32_0 != key_load_session_id_q ||
                                    key_coverage_q != 24'hFFFFFF) begin
                                    response_status_q <= ERR_KEY_LOAD_INCOMPLETE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (cmd_u64_0 != {cmd_buf[0],cmd_buf[1],cmd_buf[2],cmd_buf[3],
                                                          cmd_buf[4],cmd_buf[5],cmd_buf[6],cmd_buf[7]}) begin
                                    response_status_q <= ERR_KEY_COMMIT;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if ({cmd_buf[4],cmd_buf[5],cmd_buf[6],cmd_buf[7],
                                             cmd_buf[8],cmd_buf[9],cmd_buf[10],cmd_buf[11]} != 64'd0) begin
                                    /* FPST v1.1: first sequence of a new session is zero. */
                                    response_status_q <= ERR_KEY_COMMIT;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    session_stage_id_q <= cmd_u32_0;
                                    session_stage_sequence_q <= 64'd0;
                                    session_stage_policy_q <= {cmd_buf[12],cmd_buf[13],cmd_buf[14],cmd_buf[15]};
                                    state_q <= S_KEY_STAGE_PULSE;
                                end
                            end

                            OP_KEY_LOAD_ABORT: begin
                                if (payload_len_q != 0)
                                    response_status_q <= ERR_INVALID_STATE;
                                key_loading_q <= 1'b0;
                                key_load_session_id_q <= '0;
                                key_coverage_q <= '0;
                                for (i = 0; i < 24; i = i + 1)
                                    key_material_q[i] <= 8'h00;
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_SESSION_ACTIVATE: begin
                                if (payload_len_q != 4 || !key_valid_o) begin
                                    response_status_q <= ERR_NO_KEY;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (cmd_u32_0 != active_session_id) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (!secure_enable_i) begin
                                    response_status_q <= ERR_SECURE_DISABLED;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (!session_activate_ready) begin
                                    response_status_q <= ERR_BUSY;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    session_activate_valid_q <= 1'b1;
                                    state_q <= S_ACTIVATE_WAIT;
                                end
                            end

                            OP_ZEROIZE: begin
                                if (payload_len_q != 0) begin
                                    response_status_q <= ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    crypto_zeroize_q <= 1'b1;
                                    key_loading_q <= 1'b0;
                                    key_coverage_q <= '0;
                                    for (i = 0; i < 24; i = i + 1)
                                        key_material_q[i] <= 8'h00;
                                    state_q <= S_ZEROIZE_WAIT;
                                end
                            end

                            OP_PQC_WRITE_COEFF: begin
                                if (payload_len_q != 4 || cmd_u16_0 > 255 ||
                                    cmd_u16_2 >= 3329 || !ntt_host_ready) begin
                                    response_status_q <= !ntt_host_ready ?
                                                         ERR_BUSY : ERR_INVALID_STATE;
                                end else begin
                                    ntt_host_addr_q <= cmd_buf[1];
                                    ntt_host_wdata_q <= cmd_u16_2;
                                    ntt_host_we_q <= 1'b1;
                                end
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_PQC_READ_COEFF: begin
                                if (payload_len_q != 2 || cmd_u16_0 > 255 ||
                                    !ntt_host_ready) begin
                                    response_status_q <= !ntt_host_ready ?
                                                         ERR_BUSY : ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    ntt_read_base_q <= cmd_buf[1];
                                    ntt_count_q <= 9'd1;
                                    ntt_index_q <= '0;
                                    response_kind_q <= RSP_NTT_READ;
                                    response_len_q <= 16'd4;
                                    state_q <= S_BUILD_STATUS_HI;
                                end
                            end

                            OP_PQC_LOAD_POLY: begin
                                if (payload_len_q < 2 || cmd_u16_0 > 256 ||
                                    payload_len_q != 2 + 2*cmd_u16_0 ||
                                    !ntt_host_ready) begin
                                    response_status_q <= !ntt_host_ready ?
                                                         ERR_BUSY : ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    ntt_count_q <= cmd_u16_0[8:0];
                                    ntt_index_q <= '0;
                                    state_q <= S_NTT_LOAD_CHECK;
                                end
                            end

                            OP_PQC_READ_POLY: begin
                                if (payload_len_q != 2 || cmd_u16_0 > 256 ||
                                    !ntt_host_ready) begin
                                    response_status_q <= !ntt_host_ready ?
                                                         ERR_BUSY : ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    ntt_read_base_q <= 8'd0;
                                    ntt_count_q <= cmd_u16_0[8:0];
                                    ntt_index_q <= '0;
                                    response_kind_q <= RSP_NTT_READ;
                                    response_len_q <= 16'd2 + 2*cmd_u16_0;
                                    state_q <= S_BUILD_STATUS_HI;
                                end
                            end

                            OP_PQC_START_NTT: begin
                                if (payload_len_q != 4 || ntt_busy) begin
                                    response_status_q <= ntt_busy ?
                                                         ERR_BUSY : ERR_INVALID_STATE;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    ntt_start_q <= 1'b1;
                                    state_q <= S_NTT_WAIT;
                                end
                            end

                            OP_PQC_START_INTT, OP_PQC_POINTWISE_MUL,
                            OP_PQC_POLY_ADD_SUB, OP_PQC_GET_RESULT: begin
                                response_status_q <= ERR_UNSUPPORTED_OPCODE;
                                state_q <= S_BUILD_STATUS_HI;
                            end

                            OP_TELEMETRY_TX_SAMPLE: begin
                                if (payload_len_q != 24) begin
                                    response_status_q <= ERR_STP_LENGTH;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (!session_active_o) begin
                                    response_status_q <= ERR_NO_KEY;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (!secure_enable_i) begin
                                    response_status_q <= ERR_SECURE_DISABLED;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else if (!tx_ready) begin
                                    response_status_q <= ERR_BUSY;
                                    state_q <= S_BUILD_STATUS_HI;
                                end else begin
                                    tx_start_q <= 1'b1;
                                    state_q <= S_TX_WAIT;
                                end
                            end

                            default: begin
                                response_status_q <= ERR_UNSUPPORTED_OPCODE;
                                state_q <= S_BUILD_STATUS_HI;
                            end
                        endcase
                    end

                    S_KEY_CHUNK_CHECK: begin
                        if (key_chunk_index_q == key_chunk_len_q) begin
                            if (key_chunk_conflict_q) begin
                                response_status_q <= ERR_KEY_COMMIT;
                                state_q <= S_BUILD_STATUS_HI;
                            end else begin
                                key_chunk_index_q <= '0;
                                state_q <= S_KEY_CHUNK_APPLY;
                            end
                        end else begin
                            if (key_coverage_q[key_chunk_offset_q + key_chunk_index_q] &&
                                key_material_q[key_chunk_offset_q + key_chunk_index_q] !=
                                cmd_buf[2 + key_chunk_index_q])
                                key_chunk_conflict_q <= 1'b1;
                            key_chunk_index_q <= key_chunk_index_q + 1'b1;
                        end
                    end

                    S_KEY_CHUNK_APPLY: begin
                        if (key_chunk_index_q == key_chunk_len_q) begin
                            state_q <= S_BUILD_STATUS_HI;
                        end else begin
                            key_material_q[key_chunk_offset_q + key_chunk_index_q] <=
                                cmd_buf[2 + key_chunk_index_q];
                            key_coverage_q[key_chunk_offset_q + key_chunk_index_q] <= 1'b1;
                            key_chunk_index_q <= key_chunk_index_q + 1'b1;
                        end
                    end

                    S_KEY_STAGE_PULSE: begin
                        if (!session_stage_ready) begin
                            response_status_q <= ERR_BUSY;
                            state_q <= S_BUILD_STATUS_HI;
                        end else begin
                            session_stage_valid_q <= 1'b1;
                            state_q <= S_KEY_STAGE_WAIT;
                        end
                    end

                    S_KEY_STAGE_WAIT: begin
                        if (session_error_valid) begin
                            response_status_q <= session_error_code;
                            state_q <= S_BUILD_STATUS_HI;
                        end else if (session_commit_ready) begin
                            session_commit_valid_q <= 1'b1;
                            state_q <= S_KEY_COMMIT_WAIT;
                        end
                    end

                    S_KEY_COMMIT_WAIT: begin
                        if (session_error_valid) begin
                            response_status_q <= session_error_code;
                            state_q <= S_BUILD_STATUS_HI;
                        end else if (key_valid_o) begin
                            key_loading_q <= 1'b0;
                            key_load_session_id_q <= '0;
                            key_coverage_q <= '0;
                            for (i = 0; i < 24; i = i + 1)
                                key_material_q[i] <= 8'h00;
                            state_q <= S_BUILD_STATUS_HI;
                        end
                    end

                    S_ACTIVATE_WAIT: begin
                        if (session_error_valid) begin
                            response_status_q <= session_error_code;
                            state_q <= S_BUILD_STATUS_HI;
                        end else if (session_active_o) begin
                            state_q <= S_BUILD_STATUS_HI;
                        end
                    end

                    S_ZEROIZE_WAIT: begin
                        if (!key_valid_o && !session_active_o && !tx_packet_valid)
                            state_q <= S_BUILD_STATUS_HI;
                    end

                    S_NTT_LOAD_CHECK: begin
                        if (ntt_index_q == ntt_count_q) begin
                            ntt_index_q <= '0;
                            state_q <= S_NTT_LOAD_WRITE;
                        end else if ({cmd_buf[2+2*ntt_index_q],
                                     cmd_buf[3+2*ntt_index_q]} >= 16'd3329) begin
                            response_status_q <= ERR_INVALID_STATE;
                            state_q <= S_BUILD_STATUS_HI;
                        end else begin
                            ntt_index_q <= ntt_index_q + 1'b1;
                        end
                    end

                    S_NTT_LOAD_WRITE: begin
                        if (ntt_index_q == ntt_count_q) begin
                            state_q <= S_BUILD_STATUS_HI;
                        end else if (ntt_host_ready) begin
                            ntt_host_addr_q <= ntt_index_q[7:0];
                            ntt_host_wdata_q <= {cmd_buf[2+2*ntt_index_q],
                                                 cmd_buf[3+2*ntt_index_q]};
                            ntt_host_we_q <= 1'b1;
                            ntt_index_q <= ntt_index_q + 1'b1;
                        end
                    end

                    S_NTT_READ_REQ: begin
                        if (ntt_index_q == ntt_count_q) begin
                            state_q <= S_FINISH_CMD;
                        end else if (ntt_host_ready) begin
                            ntt_host_addr_q <= ntt_read_base_q + ntt_index_q[7:0];
                            ntt_host_re_q <= 1'b1;
                            state_q <= S_NTT_READ_WAIT;
                        end
                    end

                    S_NTT_READ_WAIT: begin
                        if (ntt_host_rvalid) begin
                            ntt_read_data_q <= ntt_host_rdata;
                            rsp_payload_we_o <= 1'b1;
                            rsp_payload_addr_o <= 2 + 2*ntt_index_q;
                            rsp_payload_data_o <= ntt_host_rdata[15:8];
                            state_q <= S_NTT_READ_WRITE_LO;
                        end
                    end

                    S_NTT_READ_WRITE_LO: begin
                        rsp_payload_we_o <= 1'b1;
                        rsp_payload_addr_o <= 3 + 2*ntt_index_q;
                        rsp_payload_data_o <= ntt_read_data_q[7:0];
                        ntt_index_q <= ntt_index_q + 1'b1;
                        state_q <= S_NTT_READ_REQ;
                    end

                    S_NTT_WAIT: begin
                        if (ntt_done)
                            state_q <= S_BUILD_STATUS_HI;
                    end

                    S_TX_WAIT: begin
                        if (tx_error_valid) begin
                            response_status_q <= tx_error_code;
                            state_q <= S_BUILD_STATUS_HI;
                        end else if (tx_done && tx_packet_valid) begin
                            response_kind_q <= RSP_TX_PACKET;
                            response_len_q <= 16'd12 + tx_packet_len;
                            response_index_q <= '0;
                            tx_packet_addr_q <= '0;
                            state_q <= S_BUILD_STATUS_HI;
                        end
                    end

                    S_BUILD_STATUS_HI: begin
                        if (response_status_q != 0)
                            last_error_q <= response_status_q;
                        rsp_payload_we_o <= 1'b1;
                        rsp_payload_addr_o <= 0;
                        rsp_payload_data_o <= response_status_q[15:8];
                        state_q <= S_BUILD_STATUS_LO;
                    end

                    S_BUILD_STATUS_LO: begin
                        rsp_payload_we_o <= 1'b1;
                        rsp_payload_addr_o <= 1;
                        rsp_payload_data_o <= response_status_q[7:0];
                        response_index_q <= 2;

                        if (response_status_q != 0 || response_len_q == 2) begin
                            state_q <= S_FINISH_CMD;
                        end else if (response_kind_q == RSP_NTT_READ) begin
                            ntt_index_q <= '0;
                            state_q <= S_NTT_READ_REQ;
                        end else if (response_kind_q == RSP_TX_PACKET) begin
                            state_q <= S_BUILD_TX_PACKET;
                        end else begin
                            state_q <= S_BUILD_EXTRA;
                        end
                    end

                    S_BUILD_EXTRA: begin
                        rsp_payload_we_o <= 1'b1;
                        rsp_payload_addr_o <= response_index_q;

                        case (response_kind_q)
                            RSP_DEVICE_ID: begin
                                case (response_index_q)
                                    2: rsp_payload_data_o <= DEVICE_ID_PRIMER1_TX[31:24];
                                    3: rsp_payload_data_o <= DEVICE_ID_PRIMER1_TX[23:16];
                                    4: rsp_payload_data_o <= DEVICE_ID_PRIMER1_TX[15:8];
                                    default: rsp_payload_data_o <= DEVICE_ID_PRIMER1_TX[7:0];
                                endcase
                            end

                            RSP_STATUS: begin
                                case (response_index_q)
                                    2: rsp_payload_data_o <= {6'b0,session_active_o,key_valid_o};
                                    3: rsp_payload_data_o <= {7'b0,tx_packet_valid};
                                    4: rsp_payload_data_o <= CAPABILITIES[31:24];
                                    5: rsp_payload_data_o <= CAPABILITIES[23:16];
                                    6: rsp_payload_data_o <= CAPABILITIES[15:8];
                                    7: rsp_payload_data_o <= CAPABILITIES[7:0];
                                    8: rsp_payload_data_o <= active_session_id[31:24];
                                    9: rsp_payload_data_o <= active_session_id[23:16];
                                    10: rsp_payload_data_o <= active_session_id[15:8];
                                    11: rsp_payload_data_o <= active_session_id[7:0];
                                    12: rsp_payload_data_o <= tx_sequence_o[63:56];
                                    13: rsp_payload_data_o <= tx_sequence_o[55:48];
                                    14: rsp_payload_data_o <= tx_sequence_o[47:40];
                                    15: rsp_payload_data_o <= tx_sequence_o[39:32];
                                    16: rsp_payload_data_o <= tx_sequence_o[31:24];
                                    17: rsp_payload_data_o <= tx_sequence_o[23:16];
                                    18: rsp_payload_data_o <= tx_sequence_o[15:8];
                                    default: rsp_payload_data_o <= tx_sequence_o[7:0];
                                endcase
                            end

                            RSP_ERROR: begin
                                if (response_index_q == 2)
                                    rsp_payload_data_o <= last_error_q[15:8];
                                else
                                    rsp_payload_data_o <= last_error_q[7:0];
                            end

                            default: rsp_payload_data_o <= 8'h00;
                        endcase

                        if (response_index_q + 1'b1 == response_len_q)
                            state_q <= S_FINISH_CMD;
                        else
                            response_index_q <= response_index_q + 1'b1;
                    end

                    S_BUILD_TX_PACKET: begin
                        rsp_payload_we_o <= 1'b1;
                        rsp_payload_addr_o <= response_index_q;

                        if (response_index_q == 2)
                            rsp_payload_data_o <= tx_packet_sequence[63:56];
                        else if (response_index_q == 3)
                            rsp_payload_data_o <= tx_packet_sequence[55:48];
                        else if (response_index_q == 4)
                            rsp_payload_data_o <= tx_packet_sequence[47:40];
                        else if (response_index_q == 5)
                            rsp_payload_data_o <= tx_packet_sequence[39:32];
                        else if (response_index_q == 6)
                            rsp_payload_data_o <= tx_packet_sequence[31:24];
                        else if (response_index_q == 7)
                            rsp_payload_data_o <= tx_packet_sequence[23:16];
                        else if (response_index_q == 8)
                            rsp_payload_data_o <= tx_packet_sequence[15:8];
                        else if (response_index_q == 9)
                            rsp_payload_data_o <= tx_packet_sequence[7:0];
                        else if (response_index_q == 10)
                            rsp_payload_data_o <= tx_packet_len[15:8];
                        else if (response_index_q == 11)
                            rsp_payload_data_o <= tx_packet_len[7:0];
                        else begin
                            rsp_payload_data_o <= tx_packet_data;
                            tx_packet_addr_q <= tx_packet_addr_q + 1'b1;
                        end

                        if (response_index_q + 1'b1 == response_len_q)
                            state_q <= S_FINISH_CMD;
                        else
                            response_index_q <= response_index_q + 1'b1;
                    end

                    S_FINISH_CMD: begin
                        cmd_ready_o <= 1'b1;
                        rsp_opcode_o <= opcode_q;
                        rsp_flags_o <= (response_status_q == 0) ? 8'h00 : 8'h02;
                        rsp_transaction_id_o <= transaction_id_q;
                        rsp_payload_len_o <= (response_status_q == 0) ?
                                             response_len_q : 16'd2;
                        state_q <= S_SUBMIT_RSP;
                    end

                    S_SUBMIT_RSP: begin
                        rsp_valid_o <= 1'b1;
                        if (rsp_ready_i)
                            state_q <= S_IDLE;
                    end

                    default: begin
                        response_status_q <= ERR_INVALID_STATE;
                        state_q <= S_BUILD_STATUS_HI;
                    end
                endcase
            end
        end
    end

    logic unused_cmd_flags;
    assign unused_cmd_flags = ^cmd_flags_i;
endmodule
