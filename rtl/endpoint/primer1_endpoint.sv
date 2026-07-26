module primer1_endpoint #(
    parameter integer MAX_FRAME_BYTES = 269,
    parameter integer MAX_APP_BYTES   = 254
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,

    input  logic        request_doorbell_i,
    input  logic        response_ack_i,
    input  logic        link_reset_i,
    input  logic [15:0] request_len_i,
    input  logic [15:0] request_id_i,

    output logic [8:0]  request_rd_addr_o,
    input  logic [7:0]  request_rd_data_i,

    output logic        response_we_o,
    output logic [8:0]  response_waddr_o,
    output logic [7:0]  response_wdata_o,
    output logic        response_valid_o,
    output logic [15:0] response_len_o,
    output logic [15:0] response_id_o,
    output logic [15:0] error_code_o,

    output logic        busy_o,
    output logic        fatal_o,
    output logic        key_valid_o,
    output logic        retained_packet_o
);
    localparam logic [7:0] FRAME_SOF0    = 8'hA5;
    localparam logic [7:0] FRAME_SOF1    = 8'h5A;
    localparam logic [7:0] FRAME_VERSION = 8'h10;
    localparam logic [7:0] FRAME_RESPONSE = 8'h01;

    localparam logic [7:0] OP_PING          = 8'h01;
    localparam logic [7:0] OP_GET_CAPS      = 8'h02;
    localparam logic [7:0] OP_GET_STATUS    = 8'h03;
    localparam logic [7:0] OP_STAGE_CONTEXT = 8'h10;
    localparam logic [7:0] OP_COMMIT_CONTEXT = 8'h11;
    localparam logic [7:0] OP_ZEROIZE       = 8'h12;
    localparam logic [7:0] OP_ASCON_ENCRYPT = 8'h20;
    localparam logic [7:0] OP_STP_RETRY     = 8'h21;
    localparam logic [7:0] OP_STP_COMMIT    = 8'h22;
    localparam logic [7:0] OP_NTT_LOAD      = 8'h30;
    localparam logic [7:0] OP_NTT_START     = 8'h31;
    localparam logic [7:0] OP_NTT_READ      = 8'h32;
    localparam logic [7:0] OP_LINK_RESET    = 8'h7F;

    localparam logic [15:0] STATUS_OK               = 16'h0000;
    localparam logic [15:0] ERR_LINK_FORMAT         = 16'h0201;
    localparam logic [15:0] ERR_LINK_CRC            = 16'h0202;
    localparam logic [15:0] ERR_TRANSACTION_COLLISION = 16'h0207;
    localparam logic [15:0] ERR_BUSY                 = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE        = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY               = 16'h0303;
    localparam logic [15:0] ERR_ASCON_LENGTH         = 16'h0501;
    localparam logic [15:0] ERR_SEQUENCE_DESYNC      = 16'h0610;

    localparam logic [15:0] MLKEM_N = 16'd256;
    localparam logic [15:0] MLKEM_Q = 16'd3329;

    typedef enum logic [5:0] {
        EP_IDLE,
        EP_COPY_REQUEST,
        EP_VALIDATE_REQUEST,
        EP_PAYLOAD_CRC,
        EP_DISPATCH,
        EP_DUPLICATE_COPY,
        EP_STAGE_CONTEXT,
        EP_COMMIT_CONTEXT,
        EP_ZEROIZE_COMMAND,
        EP_NTT_LOAD_VALIDATE,
        EP_NTT_LOAD_WRITE,
        EP_NTT_START_PULSE,
        EP_NTT_START_WAIT,
        EP_NTT_READ_ISSUE,
        EP_NTT_READ_WAIT,
        EP_ASCON_PREP,
        EP_ASCON_START,
        EP_ASCON_FEED,
        EP_ASCON_WAIT,
        EP_ASCON_COPY_RESPONSE,
        EP_STP_RETRY_COPY,
        EP_STP_COMMIT,
        EP_RESPONSE_HEADER,
        EP_RESPONSE_APP,
        EP_RESPONSE_TRAILER,
        EP_RESPONSE_COMMIT
    } endpoint_state_t;

    endpoint_state_t state_q;

    logic [7:0] request_frame_q  [0:MAX_FRAME_BYTES-1];
    logic [7:0] response_frame_q [0:MAX_FRAME_BYTES-1];
    logic [7:0] cached_response_q[0:MAX_FRAME_BYTES-1];
    logic [7:0] app_data_q       [0:MAX_APP_BYTES-1];
    logic [7:0] stp_packet_q     [0:63];

    logic [8:0]  copy_index_q;
    logic [31:0] request_hash_work_q;
    logic [31:0] request_hash_q;
    logic [15:0] payload_crc_q;
    logic [15:0] payload_index_q;
    logic [15:0] payload_len_q;
    logic [7:0]  opcode_q;
    logic [15:0] transaction_id_q;

    logic        cache_valid_q;
    logic [15:0] cache_request_id_q;
    logic [15:0] cache_request_len_q;
    logic [7:0]  cache_opcode_q;
    logic [31:0] cache_request_hash_q;
    logic [15:0] cache_response_len_q;
    logic [15:0] cache_error_code_q;
    logic        cache_update_q;

    logic [15:0] response_status_work_q;
    logic [15:0] app_len_q;
    logic [15:0] response_frame_len_q;
    logic [15:0] response_payload_crc_q;
    logic [8:0]  response_app_index_q;
    logic [8:0]  response_commit_index_q;

    logic        staged_valid_q;
    logic [31:0] staged_session_id_q;
    logic [127:0] staged_key_q;
    logic [63:0]  staged_nonce_prefix_q;
    logic [63:0]  staged_sequence_q;
    logic [31:0]  staged_policy_q;

    logic [31:0]  active_session_id_q;
    logic [127:0] active_key_q;
    logic [63:0]  active_nonce_prefix_q;
    logic [63:0]  active_sequence_q;
    logic [31:0]  active_policy_q;
    logic         key_valid_q;

    logic         retained_valid_q;
    logic [15:0]  retained_len_q;

    logic         fatal_q;
    logic [15:0]  last_error_q;
    logic         core_zeroize_pulse_q;

    logic [7:0] ntt_load_offset_q;
    logic [7:0] ntt_load_count_q;
    logic [7:0] ntt_index_q;

    logic       ntt_start;
    logic       ntt_busy;
    logic       ntt_done;
    logic       ntt_host_re;
    logic       ntt_host_we;
    logic [7:0] ntt_host_addr;
    logic [15:0] ntt_host_wdata;
    logic       ntt_host_ready;
    logic       ntt_host_rvalid;
    logic [15:0] ntt_host_rdata;
    logic [2:0] ntt_stage;
    logic       ntt_stage_barrier;
    logic       ntt_active_bank;

    logic         ascon_start;
    logic         ascon_ready;
    logic [127:0] ascon_nonce_q;
    logic         ascon_in_valid;
    logic         ascon_in_ready;
    logic [7:0]   ascon_in_data;
    logic         ascon_in_last;
    logic         ascon_out_valid;
    logic [7:0]   ascon_out_data;
    logic         ascon_out_last;
    logic         ascon_tag_valid;
    logic [127:0] ascon_tag;
    logic         ascon_done;
    logic         ascon_error_valid;
    logic [15:0]  ascon_error_code;
    logic [5:0]   ascon_feed_index_q;
    logic [5:0]   ascon_cipher_index_q;
    logic         ascon_tag_seen_q;

    function automatic logic [15:0] crc16_byte(
        input logic [15:0] crc_in,
        input logic [7:0] data
    );
        logic [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_byte = crc;
        end
    endfunction

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data
    );
        logic [31:0] crc;
        integer i;
        begin
            crc = crc_in ^ data;
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[0])
                    crc = (crc >> 1) ^ 32'hEDB8_8320;
                else
                    crc = crc >> 1;
            end
            crc32_byte = crc;
        end
    endfunction

    function automatic logic [15:0] response_header_crc(
        input logic [7:0] opcode,
        input logic [15:0] txid,
        input logic [15:0] response_payload_len
    );
        logic [15:0] crc;
        begin
            crc = 16'hFFFF;
            crc = crc16_byte(crc, FRAME_VERSION);
            crc = crc16_byte(crc, opcode);
            crc = crc16_byte(crc, FRAME_RESPONSE);
            crc = crc16_byte(crc, txid[15:8]);
            crc = crc16_byte(crc, txid[7:0]);
            crc = crc16_byte(crc, response_payload_len[15:8]);
            crc = crc16_byte(crc, response_payload_len[7:0]);
            response_header_crc = crc;
        end
    endfunction

    function automatic logic [63:0] load_be64_request(input integer base);
        logic [63:0] value;
        integer i;
        begin
            value = 64'h0;
            for (i = 0; i < 8; i = i + 1)
                value = {value[55:0], request_frame_q[base+i]};
            load_be64_request = value;
        end
    endfunction

    function automatic logic [31:0] load_be32_request(input integer base);
        begin
            load_be32_request = {
                request_frame_q[base+0], request_frame_q[base+1],
                request_frame_q[base+2], request_frame_q[base+3]
            };
        end
    endfunction

    function automatic logic [15:0] load_be16_request(input integer base);
        begin
            load_be16_request = {request_frame_q[base], request_frame_q[base+1]};
        end
    endfunction

    assign busy_o            = (state_q != EP_IDLE);
    assign fatal_o           = fatal_q;
    assign key_valid_o       = key_valid_q;
    assign retained_packet_o = retained_valid_q;

    always_comb begin
        request_rd_addr_o = copy_index_q;

        response_we_o    = 1'b0;
        response_waddr_o = response_commit_index_q;
        response_wdata_o = 8'h00;

        if (state_q == EP_RESPONSE_COMMIT) begin
            response_we_o    = 1'b1;
            response_waddr_o = response_commit_index_q;
            response_wdata_o = response_frame_q[response_commit_index_q];
        end else if (state_q == EP_DUPLICATE_COPY) begin
            response_we_o    = 1'b1;
            response_waddr_o = response_commit_index_q;
            response_wdata_o = cached_response_q[response_commit_index_q];
        end
    end

    always_comb begin
        ntt_start      = 1'b0;
        ntt_host_re    = 1'b0;
        ntt_host_we    = 1'b0;
        ntt_host_addr  = ntt_load_offset_q + ntt_index_q;
        ntt_host_wdata = {
            request_frame_q[13 + (2*ntt_index_q)],
            request_frame_q[14 + (2*ntt_index_q)]
        };

        if (state_q == EP_NTT_LOAD_WRITE)
            ntt_host_we = 1'b1;
        if (state_q == EP_NTT_START_PULSE)
            ntt_start = 1'b1;
        if (state_q == EP_NTT_READ_ISSUE)
            ntt_host_re = 1'b1;
    end

    always_comb begin
        ascon_start    = (state_q == EP_ASCON_START);
        ascon_in_valid = (state_q == EP_ASCON_FEED);
        ascon_in_last  = (ascon_feed_index_q == 6'd47);

        if (ascon_feed_index_q < 6'd24)
            ascon_in_data = stp_packet_q[ascon_feed_index_q];
        else
            ascon_in_data = request_frame_q[13 + (ascon_feed_index_q - 6'd24)];
    end

    forward_ntt_core u_forward_ntt (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .start_i           (ntt_start),
        .busy_o            (ntt_busy),
        .done_o            (ntt_done),
        .host_re_i         (ntt_host_re),
        .host_we_i         (ntt_host_we),
        .host_addr_i       (ntt_host_addr),
        .host_wdata_i      (ntt_host_wdata),
        .host_ready_o      (ntt_host_ready),
        .host_rvalid_o     (ntt_host_rvalid),
        .host_rdata_o      (ntt_host_rdata),
        .stage_o           (ntt_stage),
        .stage_barrier_o   (ntt_stage_barrier),
        .active_bank_o     (ntt_active_bank)
    );

    ascon_aead_encrypt #(
        .MAX_DATA_BYTES(128)
    ) u_ascon_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i || core_zeroize_pulse_q),
        .start_i        (ascon_start),
        .ready_o        (ascon_ready),
        .key_i          (active_key_q),
        .nonce_i        (ascon_nonce_q),
        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),
        .in_valid_i     (ascon_in_valid),
        .in_ready_o     (ascon_in_ready),
        .in_data_i      (ascon_in_data),
        .in_last_i      (ascon_in_last),
        .out_valid_o    (ascon_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (ascon_out_data),
        .out_last_o     (ascon_out_last),
        .tag_valid_o    (ascon_tag_valid),
        .tag_ready_i    (1'b1),
        .tag_o          (ascon_tag),
        .done_o         (ascon_done),
        .error_valid_o  (ascon_error_valid),
        .error_code_o   (ascon_error_code)
    );

    always_ff @(posedge clk_i) begin
        integer i;
        logic [15:0] header_crc_calc;
        logic [15:0] payload_crc_next;
        logic [15:0] observed_payload_crc;
        logic [15:0] response_payload_len;
        logic [15:0] header_crc_response;
        logic [15:0] coeff_value;
        logic [15:0] flags_value;
        logic [63:0] commit_sequence;

        if (!rst_ni) begin
            state_q                 <= EP_IDLE;
            copy_index_q            <= 9'd0;
            request_hash_work_q     <= 32'hFFFF_FFFF;
            request_hash_q          <= 32'h0000_0000;
            payload_crc_q           <= 16'hFFFF;
            payload_index_q         <= 16'd0;
            payload_len_q           <= 16'd0;
            opcode_q                <= 8'h00;
            transaction_id_q        <= 16'd0;
            cache_valid_q           <= 1'b0;
            cache_request_id_q      <= 16'd0;
            cache_request_len_q     <= 16'd0;
            cache_opcode_q          <= 8'h00;
            cache_request_hash_q    <= 32'h0000_0000;
            cache_response_len_q    <= 16'd0;
            cache_error_code_q      <= 16'd0;
            cache_update_q          <= 1'b0;
            response_status_work_q  <= STATUS_OK;
            app_len_q               <= 16'd0;
            response_frame_len_q    <= 16'd0;
            response_payload_crc_q  <= 16'hFFFF;
            response_app_index_q    <= 9'd0;
            response_commit_index_q <= 9'd0;
            response_valid_o        <= 1'b0;
            response_len_o          <= 16'd0;
            response_id_o           <= 16'd0;
            error_code_o            <= 16'd0;
            staged_valid_q          <= 1'b0;
            staged_session_id_q     <= 32'd0;
            staged_key_q            <= 128'd0;
            staged_nonce_prefix_q   <= 64'd0;
            staged_sequence_q       <= 64'd0;
            staged_policy_q         <= 32'd0;
            active_session_id_q     <= 32'd0;
            active_key_q            <= 128'd0;
            active_nonce_prefix_q   <= 64'd0;
            active_sequence_q       <= 64'd0;
            active_policy_q         <= 32'd0;
            key_valid_q             <= 1'b0;
            retained_valid_q        <= 1'b0;
            retained_len_q          <= 16'd0;
            fatal_q                 <= 1'b0;
            last_error_q            <= 16'd0;
            core_zeroize_pulse_q    <= 1'b0;
            ntt_load_offset_q       <= 8'd0;
            ntt_load_count_q        <= 8'd0;
            ntt_index_q             <= 8'd0;
            ascon_nonce_q           <= 128'd0;
            ascon_feed_index_q      <= 6'd0;
            ascon_cipher_index_q    <= 6'd0;
            ascon_tag_seen_q        <= 1'b0;
        end else if (zeroize_i) begin
            state_q                 <= EP_IDLE;
            response_valid_o        <= 1'b0;
            response_len_o          <= 16'd0;
            response_id_o           <= 16'd0;
            error_code_o            <= 16'd0;
            cache_valid_q           <= 1'b0;
            staged_valid_q          <= 1'b0;
            staged_session_id_q     <= 32'd0;
            staged_key_q            <= 128'd0;
            staged_nonce_prefix_q   <= 64'd0;
            staged_sequence_q       <= 64'd0;
            staged_policy_q         <= 32'd0;
            active_session_id_q     <= 32'd0;
            active_key_q            <= 128'd0;
            active_nonce_prefix_q   <= 64'd0;
            active_sequence_q       <= 64'd0;
            active_policy_q         <= 32'd0;
            key_valid_q             <= 1'b0;
            retained_valid_q        <= 1'b0;
            retained_len_q          <= 16'd0;
            last_error_q            <= 16'd0;
            core_zeroize_pulse_q    <= 1'b0;
        end else begin
            core_zeroize_pulse_q <= 1'b0;

            if (response_ack_i)
                response_valid_o <= 1'b0;

            if (link_reset_i && state_q == EP_IDLE) begin
                response_valid_o <= 1'b0;
                response_len_o   <= 16'd0;
                response_id_o    <= 16'd0;
                error_code_o     <= 16'd0;
            end

            if (ascon_out_valid && ascon_cipher_index_q < 6'd24) begin
                stp_packet_q[24 + ascon_cipher_index_q] <= ascon_out_data;
                ascon_cipher_index_q <= ascon_cipher_index_q + 6'd1;
            end

            if (ascon_tag_valid) begin
                for (i = 0; i < 16; i = i + 1)
                    stp_packet_q[48+i] <= ascon_tag[8*i +: 8];
                ascon_tag_seen_q <= 1'b1;
            end

            case (state_q)
                EP_IDLE: begin
                    if (request_doorbell_i && !response_valid_o) begin
                        if (request_len_i < 16'd13 || request_len_i > MAX_FRAME_BYTES) begin
                            opcode_q               <= 8'h00;
                            transaction_id_q       <= request_id_i;
                            response_status_work_q <= ERR_LINK_FORMAT;
                            app_len_q              <= 16'd0;
                            cache_update_q         <= 1'b0;
                            state_q                <= EP_RESPONSE_HEADER;
                        end else begin
                            copy_index_q        <= 9'd0;
                            request_hash_work_q <= 32'hFFFF_FFFF;
                            state_q             <= EP_COPY_REQUEST;
                        end
                    end
                end

                EP_COPY_REQUEST: begin
                    request_frame_q[copy_index_q] <= request_rd_data_i;
                    request_hash_work_q <= crc32_byte(request_hash_work_q,
                                                      request_rd_data_i);
                    if (copy_index_q + 9'd1 == request_len_i) begin
                        request_hash_q <= ~crc32_byte(request_hash_work_q,
                                                     request_rd_data_i);
                        state_q <= EP_VALIDATE_REQUEST;
                    end else begin
                        copy_index_q <= copy_index_q + 9'd1;
                    end
                end

                EP_VALIDATE_REQUEST: begin
                    header_crc_calc = 16'hFFFF;
                    for (i = 2; i <= 8; i = i + 1)
                        header_crc_calc = crc16_byte(header_crc_calc, request_frame_q[i]);

                    opcode_q         <= request_frame_q[3];
                    transaction_id_q <= {request_frame_q[5], request_frame_q[6]};
                    payload_len_q    <= {request_frame_q[7], request_frame_q[8]};

                    if (request_frame_q[0] != FRAME_SOF0 ||
                        request_frame_q[1] != FRAME_SOF1 ||
                        request_frame_q[2] != FRAME_VERSION ||
                        request_frame_q[4] != 8'h00 ||
                        {request_frame_q[5], request_frame_q[6]} != request_id_i ||
                        ({1'b0, request_frame_q[7], request_frame_q[8]} + 17'd13) != request_len_i) begin
                        response_status_work_q <= ERR_LINK_FORMAT;
                        app_len_q      <= 16'd0;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end else if ({request_frame_q[9], request_frame_q[10]} != header_crc_calc) begin
                        response_status_work_q <= ERR_LINK_CRC;
                        app_len_q      <= 16'd0;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end else begin
                        payload_crc_q   <= 16'hFFFF;
                        payload_index_q <= 16'd0;
                        if ({request_frame_q[7], request_frame_q[8]} == 16'd0) begin
                            if ({request_frame_q[11], request_frame_q[12]} != 16'hFFFF) begin
                                response_status_work_q <= ERR_LINK_CRC;
                                app_len_q      <= 16'd0;
                                cache_update_q <= 1'b1;
                                state_q        <= EP_RESPONSE_HEADER;
                            end else begin
                                state_q <= EP_DISPATCH;
                            end
                        end else begin
                            state_q <= EP_PAYLOAD_CRC;
                        end
                    end
                end

                EP_PAYLOAD_CRC: begin
                    payload_crc_next = crc16_byte(
                        payload_crc_q,
                        request_frame_q[11 + payload_index_q]
                    );
                    payload_crc_q <= payload_crc_next;
                    if (payload_index_q + 16'd1 == payload_len_q) begin
                        observed_payload_crc = {
                            request_frame_q[11 + payload_len_q],
                            request_frame_q[12 + payload_len_q]
                        };
                        if (observed_payload_crc != payload_crc_next) begin
                            response_status_work_q <= ERR_LINK_CRC;
                            app_len_q      <= 16'd0;
                            cache_update_q <= 1'b1;
                            state_q        <= EP_RESPONSE_HEADER;
                        end else begin
                            state_q <= EP_DISPATCH;
                        end
                    end else begin
                        payload_index_q <= payload_index_q + 16'd1;
                    end
                end

                EP_DISPATCH: begin
                    if (cache_valid_q && transaction_id_q == cache_request_id_q) begin
                        if (opcode_q == cache_opcode_q &&
                            request_len_i == cache_request_len_q &&
                            request_hash_q == cache_request_hash_q) begin
                            response_commit_index_q <= 9'd0;
                            state_q <= EP_DUPLICATE_COPY;
                        end else begin
                            response_status_work_q <= ERR_TRANSACTION_COLLISION;
                            app_len_q      <= 16'd0;
                            cache_update_q <= 1'b0;
                            state_q        <= EP_RESPONSE_HEADER;
                        end
                    end else begin
                        case (opcode_q)
                            OP_PING: begin
                                if (payload_len_q != 16'd0) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q <= 16'd0;
                                end else begin
                                    app_data_q[0] <= 8'h50;
                                    app_data_q[1] <= 8'h4F;
                                    app_data_q[2] <= 8'h4E;
                                    app_data_q[3] <= 8'h47;
                                    response_status_work_q <= STATUS_OK;
                                    app_len_q <= 16'd4;
                                end
                                cache_update_q <= 1'b1;
                                state_q <= EP_RESPONSE_HEADER;
                            end

                            OP_GET_CAPS: begin
                                if (payload_len_q != 16'd0) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q <= 16'd0;
                                end else begin
                                    app_data_q[0]  <= 8'h01; // Primer #1 endpoint ID
                                    app_data_q[1]  <= FRAME_VERSION;
                                    app_data_q[2]  <= MLKEM_N[15:8];
                                    app_data_q[3]  <= MLKEM_N[7:0];
                                    app_data_q[4]  <= MLKEM_Q[15:8];
                                    app_data_q[5]  <= MLKEM_Q[7:0];
                                    app_data_q[6]  <= 8'd128; // STP plaintext maximum
                                    app_data_q[7]  <= 8'b0000_1111; // NTT/session/Ascon/STP retention
                                    app_data_q[8]  <= 8'h01; // link burst profile version
                                    app_data_q[9]  <= 8'h00;
                                    app_data_q[10] <= 8'h00;
                                    app_data_q[11] <= 8'h00;
                                    response_status_work_q <= STATUS_OK;
                                    app_len_q <= 16'd12;
                                end
                                cache_update_q <= 1'b1;
                                state_q <= EP_RESPONSE_HEADER;
                            end

                            OP_GET_STATUS: begin
                                if (payload_len_q != 16'd0) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q <= 16'd0;
                                end else begin
                                    app_data_q[0] <= {4'b0000, retained_valid_q,
                                                      staged_valid_q, ntt_busy, key_valid_q};
                                    app_data_q[1] <= {5'b00000, ntt_stage};
                                    app_data_q[2] <= {6'b000000, ntt_stage_barrier, ntt_active_bank};
                                    app_data_q[3] <= 8'h00;
                                    app_data_q[4] <= active_session_id_q[31:24];
                                    app_data_q[5] <= active_session_id_q[23:16];
                                    app_data_q[6] <= active_session_id_q[15:8];
                                    app_data_q[7] <= active_session_id_q[7:0];
                                    for (i = 0; i < 8; i = i + 1)
                                        app_data_q[8+i] <= active_sequence_q[8*(7-i) +: 8];
                                    app_data_q[16] <= last_error_q[15:8];
                                    app_data_q[17] <= last_error_q[7:0];
                                    response_status_work_q <= STATUS_OK;
                                    app_len_q <= 16'd18;
                                end
                                cache_update_q <= 1'b1;
                                state_q <= EP_RESPONSE_HEADER;
                            end

                            OP_STAGE_CONTEXT: begin
                                if (payload_len_q != 16'd40) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    state_q <= EP_STAGE_CONTEXT;
                                end
                            end

                            OP_COMMIT_CONTEXT: begin
                                state_q <= EP_COMMIT_CONTEXT;
                            end

                            OP_ZEROIZE: begin
                                state_q <= EP_ZEROIZE_COMMAND;
                            end

                            OP_ASCON_ENCRYPT: begin
                                flags_value = {request_frame_q[11], request_frame_q[12]};
                                if (payload_len_q != 16'd26 || (flags_value & 16'hFFF8) != 16'h0000) begin
                                    response_status_work_q <= ERR_ASCON_LENGTH;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else if (!key_valid_q) begin
                                    response_status_work_q <= ERR_NO_KEY;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else if (retained_valid_q || !ascon_ready) begin
                                    response_status_work_q <= ERR_INVALID_STATE;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    state_q <= EP_ASCON_PREP;
                                end
                            end

                            OP_STP_RETRY: begin
                                if (payload_len_q != 16'd0 || !retained_valid_q) begin
                                    response_status_work_q <= ERR_INVALID_STATE;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    response_app_index_q <= 9'd0;
                                    state_q <= EP_STP_RETRY_COPY;
                                end
                            end

                            OP_STP_COMMIT: begin
                                state_q <= EP_STP_COMMIT;
                            end

                            OP_NTT_LOAD: begin
                                if (payload_len_q < 16'd4 ||
                                    request_frame_q[12] == 8'd0 ||
                                    request_frame_q[12] > 8'd127 ||
                                    payload_len_q != (16'd2 + {7'd0, request_frame_q[12], 1'b0}) ||
                                    ({1'b0, request_frame_q[11]} + {1'b0, request_frame_q[12]}) > 9'd256 ||
                                    ntt_busy) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    ntt_load_offset_q <= request_frame_q[11];
                                    ntt_load_count_q  <= request_frame_q[12];
                                    ntt_index_q       <= 8'd0;
                                    state_q           <= EP_NTT_LOAD_VALIDATE;
                                end
                            end

                            OP_NTT_START: begin
                                if (payload_len_q != 16'd0 || ntt_busy || !ntt_host_ready) begin
                                    response_status_work_q <= ERR_BUSY;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    state_q <= EP_NTT_START_PULSE;
                                end
                            end

                            OP_NTT_READ: begin
                                if (payload_len_q != 16'd2 ||
                                    request_frame_q[12] == 8'd0 ||
                                    request_frame_q[12] > 8'd127 ||
                                    ({1'b0, request_frame_q[11]} + {1'b0, request_frame_q[12]}) > 9'd256 ||
                                    ntt_busy || !ntt_host_ready) begin
                                    response_status_work_q <= ERR_LINK_FORMAT;
                                    app_len_q      <= 16'd0;
                                    cache_update_q <= 1'b1;
                                    state_q        <= EP_RESPONSE_HEADER;
                                end else begin
                                    ntt_load_offset_q <= request_frame_q[11];
                                    ntt_load_count_q  <= request_frame_q[12];
                                    ntt_index_q       <= 8'd0;
                                    state_q           <= EP_NTT_READ_ISSUE;
                                end
                            end

                            OP_LINK_RESET: begin
                                response_status_work_q <= STATUS_OK;
                                app_len_q      <= 16'd0;
                                cache_update_q <= 1'b1;
                                state_q        <= EP_RESPONSE_HEADER;
                            end

                            default: begin
                                response_status_work_q <= ERR_INVALID_STATE;
                                app_len_q      <= 16'd0;
                                cache_update_q <= 1'b1;
                                state_q        <= EP_RESPONSE_HEADER;
                            end
                        endcase
                    end
                end

                EP_DUPLICATE_COPY: begin
                    if (response_commit_index_q + 9'd1 == cache_response_len_q) begin
                        response_len_o   <= cache_response_len_q;
                        response_id_o    <= cache_request_id_q;
                        error_code_o     <= cache_error_code_q;
                        response_valid_o <= 1'b1;
                        response_commit_index_q <= 9'd0;
                        state_q <= EP_IDLE;
                    end else begin
                        response_commit_index_q <= response_commit_index_q + 9'd1;
                    end
                end

                EP_STAGE_CONTEXT: begin
                    staged_session_id_q <= load_be32_request(11);
                    for (i = 0; i < 16; i = i + 1)
                        staged_key_q[8*i +: 8] <= request_frame_q[15+i];
                    for (i = 0; i < 8; i = i + 1)
                        staged_nonce_prefix_q[8*i +: 8] <= request_frame_q[31+i];
                    staged_sequence_q <= load_be64_request(39);
                    staged_policy_q   <= load_be32_request(47);
                    staged_valid_q    <= (load_be32_request(11) != 32'd0);
                    response_status_work_q <= (load_be32_request(11) != 32'd0)
                        ? STATUS_OK : ERR_LINK_FORMAT;
                    app_len_q      <= 16'd0;
                    cache_update_q <= 1'b1;
                    state_q        <= EP_RESPONSE_HEADER;
                end

                EP_COMMIT_CONTEXT: begin
                    if (payload_len_q != 16'd4 || !staged_valid_q ||
                        load_be32_request(11) != staged_session_id_q || retained_valid_q) begin
                        response_status_work_q <= ERR_INVALID_STATE;
                    end else begin
                        active_session_id_q   <= staged_session_id_q;
                        active_key_q          <= staged_key_q;
                        active_nonce_prefix_q <= staged_nonce_prefix_q;
                        active_sequence_q     <= staged_sequence_q;
                        active_policy_q       <= staged_policy_q;
                        key_valid_q           <= 1'b1;
                        staged_valid_q        <= 1'b0;
                        staged_key_q          <= 128'd0;
                        staged_nonce_prefix_q <= 64'd0;
                        response_status_work_q <= STATUS_OK;
                    end
                    app_len_q      <= 16'd0;
                    cache_update_q <= 1'b1;
                    state_q        <= EP_RESPONSE_HEADER;
                end

                EP_ZEROIZE_COMMAND: begin
                    if (payload_len_q != 16'd0) begin
                        response_status_work_q <= ERR_LINK_FORMAT;
                    end else begin
                        staged_valid_q          <= 1'b0;
                        staged_session_id_q     <= 32'd0;
                        staged_key_q            <= 128'd0;
                        staged_nonce_prefix_q   <= 64'd0;
                        staged_sequence_q       <= 64'd0;
                        staged_policy_q         <= 32'd0;
                        active_session_id_q     <= 32'd0;
                        active_key_q            <= 128'd0;
                        active_nonce_prefix_q   <= 64'd0;
                        active_sequence_q       <= 64'd0;
                        active_policy_q         <= 32'd0;
                        key_valid_q             <= 1'b0;
                        retained_valid_q        <= 1'b0;
                        retained_len_q          <= 16'd0;
                        core_zeroize_pulse_q    <= 1'b1;
                        response_status_work_q  <= STATUS_OK;
                    end
                    app_len_q      <= 16'd0;
                    cache_update_q <= 1'b1;
                    state_q        <= EP_RESPONSE_HEADER;
                end

                EP_NTT_LOAD_VALIDATE: begin
                    coeff_value = {
                        request_frame_q[13 + (2*ntt_index_q)],
                        request_frame_q[14 + (2*ntt_index_q)]
                    };
                    if (coeff_value >= MLKEM_Q) begin
                        response_status_work_q <= ERR_LINK_FORMAT;
                        app_len_q      <= 16'd0;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end else if (ntt_index_q + 8'd1 == ntt_load_count_q) begin
                        ntt_index_q <= 8'd0;
                        state_q <= EP_NTT_LOAD_WRITE;
                    end else begin
                        ntt_index_q <= ntt_index_q + 8'd1;
                    end
                end

                EP_NTT_LOAD_WRITE: begin
                    if (ntt_host_ready) begin
                        if (ntt_index_q + 8'd1 == ntt_load_count_q) begin
                            response_status_work_q <= STATUS_OK;
                            app_len_q      <= 16'd0;
                            cache_update_q <= 1'b1;
                            ntt_index_q    <= 8'd0;
                            state_q        <= EP_RESPONSE_HEADER;
                        end else begin
                            ntt_index_q <= ntt_index_q + 8'd1;
                        end
                    end
                end

                EP_NTT_START_PULSE: begin
                    state_q <= EP_NTT_START_WAIT;
                end

                EP_NTT_START_WAIT: begin
                    if (ntt_done) begin
                        app_data_q[0] <= 8'h00;
                        app_data_q[1] <= {5'b00000, ntt_stage};
                        response_status_work_q <= STATUS_OK;
                        app_len_q      <= 16'd2;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end
                end

                EP_NTT_READ_ISSUE: begin
                    if (ntt_host_ready)
                        state_q <= EP_NTT_READ_WAIT;
                end

                EP_NTT_READ_WAIT: begin
                    if (ntt_host_rvalid) begin
                        app_data_q[2*ntt_index_q]     <= ntt_host_rdata[15:8];
                        app_data_q[2*ntt_index_q + 1] <= ntt_host_rdata[7:0];
                        if (ntt_index_q + 8'd1 == ntt_load_count_q) begin
                            response_status_work_q <= STATUS_OK;
                            app_len_q      <= {7'd0, ntt_load_count_q, 1'b0};
                            cache_update_q <= 1'b1;
                            ntt_index_q    <= 8'd0;
                            state_q        <= EP_RESPONSE_HEADER;
                        end else begin
                            ntt_index_q <= ntt_index_q + 8'd1;
                            state_q <= EP_NTT_READ_ISSUE;
                        end
                    end
                end

                EP_ASCON_PREP: begin
                    flags_value = {request_frame_q[11], request_frame_q[12]};
                    stp_packet_q[0] <= 8'h50;
                    stp_packet_q[1] <= 8'h51;
                    stp_packet_q[2] <= 8'h01;
                    stp_packet_q[3] <= 8'h03;
                    stp_packet_q[4] <= flags_value[15:8];
                    stp_packet_q[5] <= flags_value[7:0];
                    stp_packet_q[6] <= 8'h00;
                    stp_packet_q[7] <= 8'h18;
                    stp_packet_q[8] <= active_session_id_q[31:24];
                    stp_packet_q[9] <= active_session_id_q[23:16];
                    stp_packet_q[10] <= active_session_id_q[15:8];
                    stp_packet_q[11] <= active_session_id_q[7:0];
                    for (i = 0; i < 8; i = i + 1)
                        stp_packet_q[12+i] <= active_sequence_q[8*(7-i) +: 8];
                    stp_packet_q[20] <= 8'h00;
                    stp_packet_q[21] <= 8'h18;
                    stp_packet_q[22] <= 8'h01;
                    stp_packet_q[23] <= 8'h00;

                    for (i = 0; i < 8; i = i + 1) begin
                        ascon_nonce_q[8*i +: 8] <= active_nonce_prefix_q[8*i +: 8];
                        ascon_nonce_q[8*(8+i) +: 8] <= active_sequence_q[8*(7-i) +: 8];
                    end

                    ascon_feed_index_q   <= 6'd0;
                    ascon_cipher_index_q <= 6'd0;
                    ascon_tag_seen_q     <= 1'b0;
                    state_q <= EP_ASCON_START;
                end

                EP_ASCON_START: begin
                    state_q <= EP_ASCON_FEED;
                end

                EP_ASCON_FEED: begin
                    if (ascon_error_valid) begin
                        last_error_q <= ascon_error_code;
                        response_status_work_q <= ascon_error_code;
                        app_len_q      <= 16'd0;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end else if (ascon_in_valid && ascon_in_ready) begin
                        if (ascon_feed_index_q == 6'd47)
                            state_q <= EP_ASCON_WAIT;
                        else
                            ascon_feed_index_q <= ascon_feed_index_q + 6'd1;
                    end
                end

                EP_ASCON_WAIT: begin
                    if (ascon_error_valid) begin
                        last_error_q <= ascon_error_code;
                        response_status_work_q <= ascon_error_code;
                        app_len_q      <= 16'd0;
                        cache_update_q <= 1'b1;
                        state_q        <= EP_RESPONSE_HEADER;
                    end else if (ascon_done) begin
                        if (ascon_cipher_index_q != 6'd24 || !ascon_tag_seen_q) begin
                            response_status_work_q <= ERR_INVALID_STATE;
                            app_len_q      <= 16'd0;
                            cache_update_q <= 1'b1;
                            state_q        <= EP_RESPONSE_HEADER;
                        end else begin
                            retained_valid_q <= 1'b1;
                            retained_len_q   <= 16'd64;
                            response_app_index_q <= 9'd0;
                            state_q <= EP_ASCON_COPY_RESPONSE;
                        end
                    end
                end

                EP_ASCON_COPY_RESPONSE: begin
                    app_data_q[response_app_index_q] <= stp_packet_q[response_app_index_q];
                    if (response_app_index_q == 9'd63) begin
                        response_status_work_q <= STATUS_OK;
                        app_len_q      <= 16'd64;
                        cache_update_q <= 1'b1;
                        response_app_index_q <= 9'd0;
                        state_q <= EP_RESPONSE_HEADER;
                    end else begin
                        response_app_index_q <= response_app_index_q + 9'd1;
                    end
                end

                EP_STP_RETRY_COPY: begin
                    app_data_q[response_app_index_q] <= stp_packet_q[response_app_index_q];
                    if (response_app_index_q + 9'd1 == retained_len_q) begin
                        response_status_work_q <= STATUS_OK;
                        app_len_q      <= retained_len_q;
                        cache_update_q <= 1'b1;
                        response_app_index_q <= 9'd0;
                        state_q <= EP_RESPONSE_HEADER;
                    end else begin
                        response_app_index_q <= response_app_index_q + 9'd1;
                    end
                end

                EP_STP_COMMIT: begin
                    commit_sequence = load_be64_request(11);
                    if (payload_len_q != 16'd8 || !retained_valid_q ||
                        commit_sequence != active_sequence_q) begin
                        response_status_work_q <= ERR_SEQUENCE_DESYNC;
                        app_len_q <= 16'd0;
                    end else if (active_sequence_q == 64'hFFFF_FFFF_FFFF_FFFF) begin
                        fatal_q <= 1'b1;
                        response_status_work_q <= ERR_SEQUENCE_DESYNC;
                        app_len_q <= 16'd0;
                    end else begin
                        retained_valid_q  <= 1'b0;
                        retained_len_q    <= 16'd0;
                        active_sequence_q <= active_sequence_q + 64'd1;
                        for (i = 0; i < 8; i = i + 1)
                            app_data_q[i] <= (active_sequence_q + 64'd1)[8*(7-i) +: 8];
                        response_status_work_q <= STATUS_OK;
                        app_len_q <= 16'd8;
                    end
                    cache_update_q <= 1'b1;
                    state_q <= EP_RESPONSE_HEADER;
                end

                EP_RESPONSE_HEADER: begin
                    response_payload_len = app_len_q + 16'd2;
                    header_crc_response = response_header_crc(
                        opcode_q, transaction_id_q, response_payload_len
                    );

                    response_frame_q[0]  <= FRAME_SOF0;
                    response_frame_q[1]  <= FRAME_SOF1;
                    response_frame_q[2]  <= FRAME_VERSION;
                    response_frame_q[3]  <= opcode_q;
                    response_frame_q[4]  <= FRAME_RESPONSE;
                    response_frame_q[5]  <= transaction_id_q[15:8];
                    response_frame_q[6]  <= transaction_id_q[7:0];
                    response_frame_q[7]  <= response_payload_len[15:8];
                    response_frame_q[8]  <= response_payload_len[7:0];
                    response_frame_q[9]  <= header_crc_response[15:8];
                    response_frame_q[10] <= header_crc_response[7:0];
                    response_frame_q[11] <= response_status_work_q[15:8];
                    response_frame_q[12] <= response_status_work_q[7:0];

                    response_payload_crc_q <= crc16_byte(
                        crc16_byte(16'hFFFF, response_status_work_q[15:8]),
                        response_status_work_q[7:0]
                    );
                    response_frame_len_q <= app_len_q + 16'd15;
                    response_app_index_q <= 9'd0;
                    if (app_len_q == 16'd0)
                        state_q <= EP_RESPONSE_TRAILER;
                    else
                        state_q <= EP_RESPONSE_APP;
                end

                EP_RESPONSE_APP: begin
                    response_frame_q[13 + response_app_index_q] <=
                        app_data_q[response_app_index_q];
                    response_payload_crc_q <= crc16_byte(
                        response_payload_crc_q,
                        app_data_q[response_app_index_q]
                    );
                    if (response_app_index_q + 9'd1 == app_len_q) begin
                        state_q <= EP_RESPONSE_TRAILER;
                    end else begin
                        response_app_index_q <= response_app_index_q + 9'd1;
                    end
                end

                EP_RESPONSE_TRAILER: begin
                    response_frame_q[13 + app_len_q] <= response_payload_crc_q[15:8];
                    response_frame_q[14 + app_len_q] <= response_payload_crc_q[7:0];
                    response_commit_index_q <= 9'd0;
                    state_q <= EP_RESPONSE_COMMIT;
                end

                EP_RESPONSE_COMMIT: begin
                    if (cache_update_q)
                        cached_response_q[response_commit_index_q] <=
                            response_frame_q[response_commit_index_q];

                    if (response_commit_index_q + 9'd1 == response_frame_len_q) begin
                        response_len_o   <= response_frame_len_q;
                        response_id_o    <= transaction_id_q;
                        error_code_o     <= response_status_work_q;
                        last_error_q     <= response_status_work_q;
                        response_valid_o <= 1'b1;

                        if (cache_update_q) begin
                            cache_valid_q        <= 1'b1;
                            cache_request_id_q   <= transaction_id_q;
                            cache_request_len_q  <= request_len_i;
                            cache_opcode_q       <= opcode_q;
                            cache_request_hash_q <= request_hash_q;
                            cache_response_len_q <= response_frame_len_q;
                            cache_error_code_q   <= response_status_work_q;
                        end

                        response_commit_index_q <= 9'd0;
                        state_q <= EP_IDLE;
                    end else begin
                        response_commit_index_q <= response_commit_index_q + 9'd1;
                    end
                end

                default: state_q <= EP_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(key_valid_q && active_session_id_q == 32'd0))
                else $error("primer1_endpoint: key valid with zero session id");
            assert (!(retained_valid_q && !key_valid_q))
                else $error("primer1_endpoint: retained packet without active key");
        end
    end
`endif
endmodule
