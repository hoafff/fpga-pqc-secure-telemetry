module primer1_pqc_btp_endpoint #(
    parameter integer CLOCK_HZ = 27_000_000,
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic zeroize_i,

    input  logic request_valid_i,
    output logic request_accept_o,
    input  logic [7:0] request_opcode_i,
    input  logic [15:0] request_transaction_id_i,
    input  logic [15:0] request_payload_len_i,
    input  logic [31:0] request_crc32_i,
    input  logic request_error_i,
    input  logic [15:0] request_error_code_i,
    output logic [9:0] request_payload_rd_addr_o,
    input  logic [7:0] request_payload_rd_data_i,

    input  logic tx_frame_ready_i,
    output logic tx_frame_commit_o,
    output logic [COUNT_W-1:0] tx_frame_len_o,
    output logic tx_wr_en_o,
    output logic [COUNT_W-1:0] tx_wr_addr_o,
    output logic [7:0] tx_wr_data_o,

    output logic busy_o,
    output logic accelerator_busy_o,
    output logic [1:0] polynomial_domain_o,
    output logic polynomial_complete_o,
    output logic [15:0] last_error_code_o
);
    import fpst_btp_pkg::*;

    localparam integer CACHE_CYCLES = CLOCK_HZ;
    localparam integer CACHE_COUNT_W = $clog2(CACHE_CYCLES + 1);

    localparam logic [1:0] DOMAIN_PARTIAL  = 2'd0;
    localparam logic [1:0] DOMAIN_STANDARD = 2'd1;
    localparam logic [1:0] DOMAIN_NTT      = 2'd2;

    localparam logic [3:0] OPK_NONE      = 4'd0;
    localparam logic [3:0] OPK_NTT       = 4'd1;
    localparam logic [3:0] OPK_INTT      = 4'd2;
    localparam logic [3:0] OPK_POINTWISE = 4'd3;
    localparam logic [3:0] OPK_ADD       = 4'd4;
    localparam logic [3:0] OPK_SUB       = 4'd5;

    typedef enum logic [5:0] {
        ST_IDLE,
        ST_ARG_READ,
        ST_EXEC_ARG,
        ST_WRITE_COEFF,
        ST_READ_COEFF_REQ,
        ST_READ_COEFF_WAIT,
        ST_LOAD_COUNT_HI,
        ST_LOAD_COUNT_LO,
        ST_LOAD_VALIDATE_HI,
        ST_LOAD_VALIDATE_LO,
        ST_LOAD_WRITE_HI,
        ST_LOAD_WRITE_LO,
        ST_READPOLY_COUNT_HI,
        ST_READPOLY_COUNT_LO,
        ST_READPOLY_REQ,
        ST_READPOLY_WAIT,
        ST_START_NTT,
        ST_START_INTT,
        ST_ADDSUB_MODE,
        ST_BINARY_START,
        ST_BINARY_WAIT,
        ST_RESP_FILL,
        ST_RESP_START,
        ST_RESP_WAIT,
        ST_RESP_COMMIT,
        ST_CACHE_RESTORE,
        ST_CACHE_RECOMMIT
    } state_t;

    typedef enum logic [1:0] {
        ARG_NONE,
        ARG_WRITE_COEFF,
        ARG_READ_COEFF
    } arg_kind_t;

    typedef enum logic [1:0] {
        RESP_GENERIC,
        RESP_INLINE,
        RESP_BULK
    } response_kind_t;

    state_t state_q;
    arg_kind_t arg_kind_q;
    response_kind_t response_kind_q;

    logic [7:0] current_opcode_q;
    logic [15:0] current_transaction_id_q;
    logic [15:0] current_payload_len_q;
    logic [31:0] current_request_crc32_q;

    logic [7:0] arg_q [0:3];
    logic [2:0] arg_index_q;
    logic [2:0] arg_expected_q;
    logic [15:0] arg_address_word;
    logic [7:0] arg_address_index;
    logic [15:0] arg_coeff_word;

    logic [255:0] coverage_q;
    logic [255:0] write_coverage_next;
    logic write_completes_coverage;
    logic [1:0] domain_q;
    logic done_latched_q;
    logic [3:0] last_operation_q;
    logic [3:0] transform_pending_q;

    logic [8:0] poly_count_q;
    logic [8:0] poly_index_q;
    logic [7:0] poly_hi_q;
    logic [15:0] read_poly_count_q;
    logic [7:0] bulk_mem [0:511];

    logic binary_sub_q;
    logic [9:0] accelerator_operand_addr;
    logic accelerator_start_ntt;
    logic accelerator_start_intt;
    logic accelerator_start_pointwise;
    logic accelerator_start_addsub;
    logic accelerator_busy_internal;
    logic accelerator_done;
    logic accelerator_operand_error;
    logic [7:0] accelerator_operand_error_index;
    logic accelerator_inverse_active;
    logic [2:0] accelerator_stage;
    logic accelerator_stage_barrier;
    logic accelerator_active_bank;

    logic accelerator_host_re;
    logic accelerator_host_we;
    logic [7:0] accelerator_host_addr;
    logic [15:0] accelerator_host_wdata;
    logic accelerator_host_ready;
    logic accelerator_host_rvalid;
    logic [15:0] accelerator_host_rdata;

    logic [15:0] response_status_q;
    logic [15:0] response_detail_q;
    logic [31:0] response_device_state_q;
    logic [31:0] response_data_len_q;
    logic [15:0] response_payload_len_q;
    logic response_error_q;
    logic response_cache_capture_q;
    logic [127:0] response_inline_data_q;
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

    logic [31:0] pqc_device_state;
    logic [15:0] last_error_code_q;
    integer i;

    assign arg_address_word = {arg_q[0],arg_q[1]};
    assign arg_address_index = arg_q[1];
    assign arg_coeff_word = {arg_q[2],arg_q[3]};

    assign polynomial_domain_o = domain_q;
    assign polynomial_complete_o = &coverage_q;
    assign last_error_code_o = last_error_code_q;
    assign accelerator_busy_o = accelerator_busy_internal;
    assign busy_o = (state_q != ST_IDLE) || builder_busy || accelerator_busy_internal;

    always_comb begin
        pqc_device_state = 32'h0;
        pqc_device_state[0] = &coverage_q;
        pqc_device_state[2:1] = domain_q;
        pqc_device_state[3] = accelerator_busy_internal;
        pqc_device_state[4] = done_latched_q;
        pqc_device_state[5] = accelerator_inverse_active;
        pqc_device_state[6] = accelerator_active_bank;
    end

    always_comb begin
        write_coverage_next = coverage_q;
        write_coverage_next[arg_address_index] = 1'b1;
        write_completes_coverage = &write_coverage_next;
    end

    assign accelerator_start_ntt = (state_q == ST_START_NTT);
    assign accelerator_start_intt = (state_q == ST_START_INTT);
    assign accelerator_start_pointwise = (state_q == ST_BINARY_START) &&
                                         (current_opcode_q == OP_PQC_POINTWISE_MUL);
    assign accelerator_start_addsub = (state_q == ST_BINARY_START) &&
                                      (current_opcode_q == OP_PQC_POLY_ADD_SUB);

    always_comb begin
        accelerator_host_re = 1'b0;
        accelerator_host_we = 1'b0;
        accelerator_host_addr = 8'h00;
        accelerator_host_wdata = 16'h0000;
        case (state_q)
            ST_WRITE_COEFF: begin
                accelerator_host_we = 1'b1;
                accelerator_host_addr = arg_address_index;
                accelerator_host_wdata = arg_coeff_word;
            end
            ST_READ_COEFF_REQ: begin
                accelerator_host_re = 1'b1;
                accelerator_host_addr = arg_address_index;
            end
            ST_LOAD_WRITE_LO: begin
                accelerator_host_we = 1'b1;
                accelerator_host_addr = poly_index_q[7:0];
                accelerator_host_wdata = {poly_hi_q,request_payload_rd_data_i};
            end
            ST_READPOLY_REQ: begin
                accelerator_host_re = 1'b1;
                accelerator_host_addr = poly_index_q[7:0];
            end
            default: begin end
        endcase
    end

    mlkem_pqc_accelerator u_pqc_accelerator (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_ntt_i(accelerator_start_ntt),
        .start_intt_i(accelerator_start_intt),
        .start_pointwise_i(accelerator_start_pointwise),
        .start_addsub_i(accelerator_start_addsub),
        .addsub_sub_i(binary_sub_q),
        .operand_base_i(current_opcode_q == OP_PQC_POLY_ADD_SUB ? 10'd1 : 10'd0),
        .operand_byte_addr_o(accelerator_operand_addr),
        .operand_byte_data_i(request_payload_rd_data_i),
        .host_re_i(accelerator_host_re),
        .host_we_i(accelerator_host_we),
        .host_addr_i(accelerator_host_addr),
        .host_wdata_i(accelerator_host_wdata),
        .host_ready_o(accelerator_host_ready),
        .host_rvalid_o(accelerator_host_rvalid),
        .host_rdata_o(accelerator_host_rdata),
        .busy_o(accelerator_busy_internal),
        .done_o(accelerator_done),
        .operand_error_o(accelerator_operand_error),
        .operand_error_index_o(accelerator_operand_error_index),
        .inverse_active_o(accelerator_inverse_active),
        .stage_o(accelerator_stage),
        .stage_barrier_o(accelerator_stage_barrier),
        .active_bank_o(accelerator_active_bank)
    );

    always_comb begin
        request_payload_rd_addr_o = 10'd0;
        case (state_q)
            ST_ARG_READ:
                request_payload_rd_addr_o = arg_index_q;
            ST_LOAD_COUNT_HI,
            ST_READPOLY_COUNT_HI:
                request_payload_rd_addr_o = 10'd0;
            ST_LOAD_COUNT_LO,
            ST_READPOLY_COUNT_LO:
                request_payload_rd_addr_o = 10'd1;
            ST_LOAD_VALIDATE_HI,
            ST_LOAD_WRITE_HI:
                request_payload_rd_addr_o = 10'd2 + (poly_index_q << 1);
            ST_LOAD_VALIDATE_LO,
            ST_LOAD_WRITE_LO:
                request_payload_rd_addr_o = 10'd3 + (poly_index_q << 1);
            ST_ADDSUB_MODE:
                request_payload_rd_addr_o = 10'd0;
            ST_BINARY_START,
            ST_BINARY_WAIT:
                request_payload_rd_addr_o = accelerator_operand_addr;
            default: begin end
        endcase
    end

    // Portable byte selection: explicit cases avoid dynamic indexed part-selects
    // that are interpreted differently by Icarus, Yosys and vendor frontends.
    always_comb begin
        response_fill_byte = 8'h00;
        case (response_fill_index_q)
            10'd0:  response_fill_byte = response_status_q[15:8];
            10'd1:  response_fill_byte = response_status_q[7:0];
            10'd2:  response_fill_byte = response_detail_q[15:8];
            10'd3:  response_fill_byte = response_detail_q[7:0];
            10'd4:  response_fill_byte = response_device_state_q[31:24];
            10'd5:  response_fill_byte = response_device_state_q[23:16];
            10'd6:  response_fill_byte = response_device_state_q[15:8];
            10'd7:  response_fill_byte = response_device_state_q[7:0];
            10'd8:  response_fill_byte = response_data_len_q[31:24];
            10'd9:  response_fill_byte = response_data_len_q[23:16];
            10'd10: response_fill_byte = response_data_len_q[15:8];
            10'd11: response_fill_byte = response_data_len_q[7:0];
            10'd12: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[7:0] : bulk_mem[0];
            10'd13: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[15:8] : bulk_mem[1];
            10'd14: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[23:16] : bulk_mem[2];
            10'd15: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[31:24] : bulk_mem[3];
            10'd16: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[39:32] : bulk_mem[4];
            10'd17: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[47:40] : bulk_mem[5];
            10'd18: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[55:48] : bulk_mem[6];
            10'd19: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[63:56] : bulk_mem[7];
            10'd20: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[71:64] : bulk_mem[8];
            10'd21: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[79:72] : bulk_mem[9];
            10'd22: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[87:80] : bulk_mem[10];
            10'd23: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[95:88] : bulk_mem[11];
            10'd24: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[103:96] : bulk_mem[12];
            10'd25: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[111:104] : bulk_mem[13];
            10'd26: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[119:112] : bulk_mem[14];
            10'd27: response_fill_byte = response_kind_q == RESP_INLINE ? response_inline_data_q[127:120] : bulk_mem[15];
            default: begin
                if (response_kind_q == RESP_BULK)
                    response_fill_byte = bulk_mem[response_fill_index_q-10'd12];
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
        .clk_i(clk_i), .rst_ni(rst_ni), .zeroize_i(zeroize_i),
        .payload_wr_en_i(builder_payload_wr_en),
        .payload_wr_addr_i(builder_payload_wr_addr),
        .payload_wr_data_i(builder_payload_wr_data),
        .start_i(builder_start), .opcode_i(current_opcode_q),
        .transaction_id_i(current_transaction_id_q),
        .payload_len_i(response_payload_len_q), .error_i(response_error_q),
        .busy_o(builder_busy), .done_o(builder_done), .frame_len_o(builder_frame_len),
        .tx_wr_en_o(builder_tx_wr_en), .tx_wr_addr_o(builder_tx_wr_addr),
        .tx_wr_data_o(builder_tx_wr_data)
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

    task automatic queue_response(
        input logic [15:0] status,
        input logic [15:0] detail,
        input response_kind_t kind,
        input logic [15:0] data_len,
        input logic cache_capture
    );
        begin
            response_status_q <= status;
            response_detail_q <= detail;
            response_device_state_q <= pqc_device_state;
            response_data_len_q <= {16'h0,data_len};
            response_payload_len_q <= 16'd12 + data_len;
            response_error_q <= status != ERR_OK;
            response_kind_q <= kind;
            response_cache_capture_q <= cache_capture;
            response_fill_index_q <= '0;
            if (status != ERR_OK)
                last_error_code_q <= status;
            state_q <= ST_RESP_FILL;
        end
    endtask

    task automatic start_arg_read(
        input arg_kind_t kind,
        input logic [2:0] byte_count
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
            coverage_q <= '0;
            domain_q <= DOMAIN_PARTIAL;
            done_latched_q <= 1'b0;
            last_operation_q <= OPK_NONE;
            transform_pending_q <= OPK_NONE;
            poly_count_q <= '0;
            poly_index_q <= '0;
            poly_hi_q <= '0;
            read_poly_count_q <= '0;
            binary_sub_q <= 1'b0;
            response_status_q <= ERR_OK;
            response_detail_q <= '0;
            response_device_state_q <= '0;
            response_data_len_q <= '0;
            response_payload_len_q <= '0;
            response_error_q <= 1'b0;
            response_kind_q <= RESP_GENERIC;
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
            last_error_code_q <= ERR_OK;
            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;
            tx_frame_len_o <= '0;
            for (i=0; i<4; i=i+1)
                arg_q[i] <= 8'h00;
            for (i=0; i<512; i=i+1)
                bulk_mem[i] <= 8'h00;
        end else begin
            request_accept_o <= 1'b0;
            tx_frame_commit_o <= 1'b0;

            if (accelerator_done && transform_pending_q != OPK_NONE) begin
                done_latched_q <= 1'b1;
                last_operation_q <= transform_pending_q;
                if (transform_pending_q == OPK_NTT)
                    domain_q <= DOMAIN_NTT;
                else if (transform_pending_q == OPK_INTT)
                    domain_q <= DOMAIN_STANDARD;
                transform_pending_q <= OPK_NONE;
            end

            if (cache_valid_q) begin
                if (cache_age_q >= CACHE_CYCLES-1) begin
                    cache_valid_q <= 1'b0;
                    cache_age_q <= '0;
                end else
                    cache_age_q <= cache_age_q + 1'b1;
            end else
                cache_age_q <= '0;

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
                            queue_response(request_error_code_i,16'h0,RESP_GENERIC,16'd0,1'b0);
                        end else if (cache_valid_q &&
                                     request_transaction_id_i == cache_transaction_id_q) begin
                            if (request_opcode_i == cache_opcode_q &&
                                request_payload_len_i == cache_payload_len_q &&
                                request_crc32_i == cache_request_crc32_q) begin
                                request_accept_o <= 1'b1;
                                cache_restore_index_q <= '0;
                                cache_age_q <= '0;
                                state_q <= ST_CACHE_RESTORE;
                            end else begin
                                request_accept_o <= 1'b1;
                                queue_response(ERR_BTP_TRANSACTION,16'h0001,RESP_GENERIC,16'd0,1'b0);
                            end
                        end else begin
                            case (request_opcode_i)
                                OP_PQC_WRITE_COEFF: begin
                                    if (request_payload_len_i == 16'd4)
                                        start_arg_read(ARG_WRITE_COEFF,3'd4);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end
                                end
                                OP_PQC_READ_COEFF: begin
                                    if (request_payload_len_i == 16'd2)
                                        start_arg_read(ARG_READ_COEFF,3'd2);
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end
                                end
                                OP_PQC_LOAD_POLY: begin
                                    if (request_payload_len_i >= 16'd4 && request_payload_len_i <= 16'd514)
                                        state_q <= ST_LOAD_COUNT_HI;
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end
                                end
                                OP_PQC_READ_POLY: begin
                                    if (request_payload_len_i == 16'd2)
                                        state_q <= ST_READPOLY_COUNT_HI;
                                    else begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end
                                end
                                OP_PQC_START_NTT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i != 16'd4)
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else if ((&coverage_q) == 1'b0 || domain_q != DOMAIN_STANDARD)
                                        queue_response(ERR_PQC_DOMAIN,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else if (!accelerator_host_ready || accelerator_busy_internal)
                                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else begin
                                        done_latched_q <= 1'b0;
                                        transform_pending_q <= OPK_NTT;
                                        state_q <= ST_START_NTT;
                                    end
                                end
                                OP_PQC_START_INTT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i != 16'd4)
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else if ((&coverage_q) == 1'b0 || domain_q != DOMAIN_NTT)
                                        queue_response(ERR_PQC_DOMAIN,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else if (!accelerator_host_ready || accelerator_busy_internal)
                                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    else begin
                                        done_latched_q <= 1'b0;
                                        transform_pending_q <= OPK_INTT;
                                        state_q <= ST_START_INTT;
                                    end
                                end
                                OP_PQC_POINTWISE_MUL: begin
                                    if (request_payload_len_i != 16'd512) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else if ((&coverage_q) == 1'b0 || domain_q != DOMAIN_NTT) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_DOMAIN,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else if (!accelerator_host_ready || accelerator_busy_internal) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else begin
                                        binary_sub_q <= 1'b0;
                                        done_latched_q <= 1'b0;
                                        state_q <= ST_BINARY_START;
                                    end
                                end
                                OP_PQC_POLY_ADD_SUB: begin
                                    if (request_payload_len_i != 16'd513) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else if ((&coverage_q) == 1'b0) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_PQC_DOMAIN,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else if (!accelerator_host_ready || accelerator_busy_internal) begin
                                        request_accept_o <= 1'b1;
                                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                                    end else
                                        state_q <= ST_ADDSUB_MODE;
                                end
                                OP_PQC_GET_RESULT: begin
                                    request_accept_o <= 1'b1;
                                    if (request_payload_len_i == 0) begin
                                        response_inline_data_q[7:0] <= {7'h0,accelerator_busy_internal};
                                        response_inline_data_q[15:8] <= {7'h0,done_latched_q};
                                        response_inline_data_q[23:16] <= {6'h0,domain_q};
                                        response_inline_data_q[31:24] <= {7'h0,accelerator_active_bank};
                                        response_inline_data_q[39:32] <= {5'h0,accelerator_stage};
                                        response_inline_data_q[47:40] <= {7'h0,accelerator_inverse_active};
                                        response_inline_data_q[55:48] <= {7'h0,(&coverage_q)};
                                        response_inline_data_q[63:56] <= {4'h0,last_operation_q};
                                        queue_response(ERR_OK,16'h0,RESP_INLINE,16'd8,1'b1);
                                    end else
                                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                                end
                                default: begin
                                    request_accept_o <= 1'b1;
                                    queue_response(ERR_UNSUPPORTED_OPCODE,16'h0,RESP_GENERIC,16'd0,1'b1);
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
                    end else
                        arg_index_q <= arg_index_q + 1'b1;
                end

                ST_EXEC_ARG: begin
                    case (arg_kind_q)
                        ARG_WRITE_COEFF: begin
                            if (arg_address_word >= 16'd256)
                                queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else if (arg_coeff_word >= 16'd3329)
                                queue_response(ERR_COEFF_RANGE,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else if (!accelerator_host_ready)
                                queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else
                                state_q <= ST_WRITE_COEFF;
                        end
                        ARG_READ_COEFF: begin
                            if (arg_address_word >= 16'd256)
                                queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else if (coverage_q[arg_address_index] == 1'b0)
                                queue_response(ERR_INVALID_STATE,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else if (!accelerator_host_ready)
                                queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                            else
                                state_q <= ST_READ_COEFF_REQ;
                        end
                        default:
                            queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                    endcase
                end

                ST_WRITE_COEFF: begin
                    coverage_q <= write_coverage_next;
                    domain_q <= write_completes_coverage ? DOMAIN_STANDARD : DOMAIN_PARTIAL;
                    done_latched_q <= 1'b0;
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b1);
                end

                ST_READ_COEFF_REQ:
                    state_q <= ST_READ_COEFF_WAIT;

                ST_READ_COEFF_WAIT: begin
                    if (accelerator_host_rvalid) begin
                        response_inline_data_q[7:0] <= accelerator_host_rdata[15:8];
                        response_inline_data_q[15:8] <= accelerator_host_rdata[7:0];
                        queue_response(ERR_OK,16'h0,RESP_INLINE,16'd2,1'b1);
                    end
                end

                ST_LOAD_COUNT_HI: begin
                    poly_count_q[8] <= request_payload_rd_data_i[0];
                    poly_count_q[7:0] <= '0;
                    if (request_payload_rd_data_i[7:1] != 0) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                    end else
                        state_q <= ST_LOAD_COUNT_LO;
                end

                ST_LOAD_COUNT_LO: begin
                    poly_count_q[7:0] <= request_payload_rd_data_i;
                    poly_index_q <= '0;
                    if ({7'h0,poly_count_q[8],request_payload_rd_data_i} == 16'd0 ||
                        {7'h0,poly_count_q[8],request_payload_rd_data_i} > 16'd256 ||
                        current_payload_len_q !=
                            (16'd2 + ({7'h0,poly_count_q[8],request_payload_rd_data_i} << 1))) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                    end else if (!accelerator_host_ready) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                    end else
                        state_q <= ST_LOAD_VALIDATE_HI;
                end

                ST_LOAD_VALIDATE_HI: begin
                    poly_hi_q <= request_payload_rd_data_i;
                    state_q <= ST_LOAD_VALIDATE_LO;
                end

                ST_LOAD_VALIDATE_LO: begin
                    if ({poly_hi_q,request_payload_rd_data_i} >= 16'd3329) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_COEFF_RANGE,{7'h0,poly_index_q},RESP_GENERIC,16'd0,1'b1);
                    end else if (poly_index_q + 1'b1 >= poly_count_q) begin
                        coverage_q <= '0;
                        domain_q <= DOMAIN_PARTIAL;
                        poly_index_q <= '0;
                        state_q <= ST_LOAD_WRITE_HI;
                    end else begin
                        poly_index_q <= poly_index_q + 1'b1;
                        state_q <= ST_LOAD_VALIDATE_HI;
                    end
                end

                ST_LOAD_WRITE_HI: begin
                    poly_hi_q <= request_payload_rd_data_i;
                    state_q <= ST_LOAD_WRITE_LO;
                end

                ST_LOAD_WRITE_LO: begin
                    coverage_q[poly_index_q[7:0]] <= 1'b1;
                    if (poly_index_q + 1'b1 >= poly_count_q) begin
                        request_accept_o <= 1'b1;
                        domain_q <= (poly_count_q == 9'd256) ? DOMAIN_STANDARD : DOMAIN_PARTIAL;
                        done_latched_q <= 1'b0;
                        poly_index_q <= '0;
                        queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b1);
                    end else begin
                        poly_index_q <= poly_index_q + 1'b1;
                        state_q <= ST_LOAD_WRITE_HI;
                    end
                end

                ST_READPOLY_COUNT_HI: begin
                    read_poly_count_q[15:8] <= request_payload_rd_data_i;
                    state_q <= ST_READPOLY_COUNT_LO;
                end

                ST_READPOLY_COUNT_LO: begin
                    read_poly_count_q[7:0] <= request_payload_rd_data_i;
                    poly_index_q <= '0;
                    request_accept_o <= 1'b1;
                    if ({read_poly_count_q[15:8],request_payload_rd_data_i} == 0 ||
                        {read_poly_count_q[15:8],request_payload_rd_data_i} > 16'd256)
                        queue_response(ERR_PQC_LENGTH,16'h0,RESP_GENERIC,16'd0,1'b1);
                    else if ((&coverage_q) == 1'b0)
                        queue_response(ERR_INVALID_STATE,16'h0,RESP_GENERIC,16'd0,1'b1);
                    else if (!accelerator_host_ready)
                        queue_response(ERR_BUSY,16'h0,RESP_GENERIC,16'd0,1'b1);
                    else
                        state_q <= ST_READPOLY_REQ;
                end

                ST_READPOLY_REQ:
                    state_q <= ST_READPOLY_WAIT;

                ST_READPOLY_WAIT: begin
                    if (accelerator_host_rvalid) begin
                        bulk_mem[2*poly_index_q] <= accelerator_host_rdata[15:8];
                        bulk_mem[2*poly_index_q+1] <= accelerator_host_rdata[7:0];
                        if (poly_index_q + 1'b1 >= read_poly_count_q) begin
                            poly_index_q <= '0;
                            queue_response(ERR_OK,16'h0,RESP_BULK,read_poly_count_q << 1,1'b1);
                        end else begin
                            poly_index_q <= poly_index_q + 1'b1;
                            state_q <= ST_READPOLY_REQ;
                        end
                    end
                end

                ST_START_NTT:
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b1);

                ST_START_INTT:
                    queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b1);

                ST_ADDSUB_MODE: begin
                    if (request_payload_rd_data_i > 8'd1) begin
                        request_accept_o <= 1'b1;
                        queue_response(ERR_ARGUMENT,16'h0,RESP_GENERIC,16'd0,1'b1);
                    end else begin
                        binary_sub_q <= request_payload_rd_data_i[0];
                        done_latched_q <= 1'b0;
                        state_q <= ST_BINARY_START;
                    end
                end

                ST_BINARY_START:
                    state_q <= ST_BINARY_WAIT;

                ST_BINARY_WAIT: begin
                    if (accelerator_done) begin
                        request_accept_o <= 1'b1;
                        if (accelerator_operand_error)
                            queue_response(ERR_COEFF_RANGE,
                                {8'h00,accelerator_operand_error_index},RESP_GENERIC,16'd0,1'b1);
                        else begin
                            done_latched_q <= 1'b1;
                            if (current_opcode_q == OP_PQC_POINTWISE_MUL) begin
                                last_operation_q <= OPK_POINTWISE;
                                domain_q <= DOMAIN_NTT;
                            end else begin
                                last_operation_q <= binary_sub_q ? OPK_SUB : OPK_ADD;
                            end
                            queue_response(ERR_OK,16'h0,RESP_GENERIC,16'd0,1'b1);
                        end
                    end
                end

                ST_RESP_FILL: begin
                    if (response_fill_index_q + 1'b1 >= response_payload_len_q) begin
                        response_fill_index_q <= '0;
                        state_q <= ST_RESP_START;
                    end else
                        response_fill_index_q <= response_fill_index_q + 1'b1;
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
                    end else
                        cache_restore_index_q <= cache_restore_index_q + 1'b1;
                end

                ST_CACHE_RECOMMIT: begin
                    tx_frame_len_o <= cache_frame_len_q;
                    tx_frame_commit_o <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default:
                    state_q <= ST_IDLE;
            endcase

            if (zeroize_i) begin
                state_q <= ST_IDLE;
                request_accept_o <= 1'b0;
                tx_frame_commit_o <= 1'b0;
                coverage_q <= '0;
                domain_q <= DOMAIN_PARTIAL;
                done_latched_q <= 1'b0;
                last_operation_q <= OPK_NONE;
                transform_pending_q <= OPK_NONE;
                cache_valid_q <= 1'b0;
                cache_age_q <= '0;
                response_cache_capture_q <= 1'b0;
                last_error_code_q <= ERR_OK;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if (tx_frame_commit_o)
                assert (tx_frame_len_o != 0)
                    else $error("primer1_pqc_btp_endpoint: zero response frame");
            if (state_q == ST_LOAD_WRITE_LO)
                assert (accelerator_host_ready)
                    else $error("primer1_pqc_btp_endpoint: accelerator lost host ownership during load");
            if ((state_q == ST_BINARY_START) || (state_q == ST_BINARY_WAIT))
                assert (request_valid_i)
                    else $error("primer1_pqc_btp_endpoint: binary operand request released early");
        end
    end
`endif

    logic unused_stage_barrier;
    always_comb unused_stage_barrier = accelerator_stage_barrier;
endmodule
