module mlkem_pqc_accelerator (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_ntt_i,
    input  logic        start_intt_i,
    input  logic        start_pointwise_i,
    input  logic        start_addsub_i,
    input  logic        addsub_sub_i,

    // The second polynomial remains in the immutable BTP request buffer while
    // a binary operation runs. operand_base_i is 0 for pointwise and 1 when an
    // add/sub mode byte precedes the 256 BE16 coefficients.
    input  logic [9:0]  operand_base_i,
    output logic [9:0]  operand_byte_addr_o,
    input  logic [7:0]  operand_byte_data_i,

    input  logic        host_re_i,
    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_ready_o,
    output logic        host_rvalid_o,
    output logic [15:0] host_rdata_o,

    output logic        busy_o,
    output logic        done_o,
    output logic        operand_error_o,
    output logic [7:0]  operand_error_index_o,
    output logic        inverse_active_o,
    output logic [2:0]  stage_o,
    output logic        stage_barrier_o,
    output logic        active_bank_o
);
    // One polynomial image lives in the transform core's ping-pong BRAM.
    // Binary commands use the current image as operand A and stream operand B
    // from the held BTP request. A complete validation pass precedes every
    // writeback, so a malformed B polynomial cannot partially modify A.

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_VALIDATE_HI,
        ST_VALIDATE_LO,
        ST_ADD_B_HI,
        ST_ADD_B_LO,
        ST_ADD_READ_A,
        ST_ADD_WAIT_A,
        ST_ADD_WRITE,
        ST_PW_GAMMA_REQ,
        ST_PW_GAMMA_WAIT,
        ST_PW_B0_HI,
        ST_PW_B0_LO,
        ST_PW_B1_HI,
        ST_PW_B1_LO,
        ST_PW_READ_A0,
        ST_PW_WAIT_A0,
        ST_PW_READ_A1,
        ST_PW_WAIT_A1,
        ST_PW_BASE_START,
        ST_PW_BASE_WAIT,
        ST_PW_WRITE0,
        ST_PW_WRITE1
    } state_t;

    state_t state_q;
    logic binary_pointwise_q;
    logic addsub_sub_q;
    logic [9:0] operand_base_q;
    logic [7:0] coeff_index_q;
    logic [6:0] pair_index_q;
    logic [7:0] operand_hi_q;
    logic [15:0] b0_q, b1_q, a0_q, a1_q;
    logic [15:0] c0_q, c1_q;
    logic [15:0] gamma_q;
    logic binary_done_q;

    logic core_start_ntt, core_start_intt;
    logic transform_busy, transform_done;
    logic transform_host_re, transform_host_we;
    logic [7:0] transform_host_addr;
    logic [15:0] transform_host_wdata;
    logic transform_host_ready, transform_host_rvalid;
    logic [15:0] transform_host_rdata;

    logic gamma_req, gamma_valid;
    logic [6:0] gamma_addr;
    logic [15:0] gamma_zeta;

    logic basemul_start, basemul_busy, basemul_done;
    logic [15:0] basemul_c0, basemul_c1;

    logic [15:0] add_result, sub_result;

    assign core_start_ntt = (state_q == ST_IDLE) && start_ntt_i &&
                            !start_intt_i && !start_pointwise_i && !start_addsub_i;
    assign core_start_intt = (state_q == ST_IDLE) && start_intt_i &&
                             !start_ntt_i && !start_pointwise_i && !start_addsub_i;

    mlkem_ntt_intt_core u_transform (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_ntt_i(core_start_ntt), .start_intt_i(core_start_intt),
        .busy_o(transform_busy), .done_o(transform_done),
        .inverse_active_o(inverse_active_o),
        .host_re_i(transform_host_re), .host_we_i(transform_host_we),
        .host_addr_i(transform_host_addr), .host_wdata_i(transform_host_wdata),
        .host_ready_o(transform_host_ready), .host_rvalid_o(transform_host_rvalid),
        .host_rdata_o(transform_host_rdata),
        .stage_o(stage_o), .stage_barrier_o(stage_barrier_o),
        .active_bank_o(active_bank_o)
    );

    assign gamma_req = state_q == ST_PW_GAMMA_REQ;
    assign gamma_addr = 7'd64 + {1'b0,pair_index_q[6:1]};

    twiddle_rom_3329 u_gamma_rom (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(gamma_req), .addr_i(gamma_addr),
        .valid_o(gamma_valid), .zeta_o(gamma_zeta)
    );

    assign basemul_start = state_q == ST_PW_BASE_START;
    mlkem_basemul_sequential u_basemul (
        .clk_i(clk_i), .rst_ni(rst_ni), .start_i(basemul_start),
        .a0_i(a0_q), .a1_i(a1_q), .b0_i(b0_q), .b1_i(b1_q),
        .gamma_i(gamma_q), .busy_o(basemul_busy), .done_o(basemul_done),
        .c0_o(basemul_c0), .c1_o(basemul_c1)
    );

    mod_add #(.WIDTH(16), .MODULUS(3329)) u_poly_add (
        .a_i(a0_q), .b_i(b0_q), .y_o(add_result)
    );
    mod_sub #(.WIDTH(16), .MODULUS(3329)) u_poly_sub (
        .a_i(a0_q), .b_i(b0_q), .y_o(sub_result)
    );

    always_comb begin
        operand_byte_addr_o = operand_base_q;
        case (state_q)
            ST_VALIDATE_HI:
                operand_byte_addr_o = operand_base_q + ({2'b00,coeff_index_q} << 1);
            ST_VALIDATE_LO:
                operand_byte_addr_o = operand_base_q + ({2'b00,coeff_index_q} << 1) + 10'd1;
            ST_ADD_B_HI:
                operand_byte_addr_o = operand_base_q + ({2'b00,coeff_index_q} << 1);
            ST_ADD_B_LO:
                operand_byte_addr_o = operand_base_q + ({2'b00,coeff_index_q} << 1) + 10'd1;
            ST_PW_B0_HI:
                operand_byte_addr_o = operand_base_q + ({2'b00,pair_index_q,1'b0} << 1);
            ST_PW_B0_LO:
                operand_byte_addr_o = operand_base_q + ({2'b00,pair_index_q,1'b0} << 1) + 10'd1;
            ST_PW_B1_HI:
                operand_byte_addr_o = operand_base_q + ({2'b00,pair_index_q,1'b1} << 1);
            ST_PW_B1_LO:
                operand_byte_addr_o = operand_base_q + ({2'b00,pair_index_q,1'b1} << 1) + 10'd1;
            default: begin end
        endcase
    end

    always_comb begin
        transform_host_re = 1'b0;
        transform_host_we = 1'b0;
        transform_host_addr = host_addr_i;
        transform_host_wdata = host_wdata_i;

        if (state_q == ST_IDLE) begin
            transform_host_re = host_re_i;
            transform_host_we = host_we_i;
        end else begin
            case (state_q)
                ST_ADD_READ_A: begin
                    transform_host_re = 1'b1;
                    transform_host_addr = coeff_index_q;
                end
                ST_ADD_WRITE: begin
                    transform_host_we = 1'b1;
                    transform_host_addr = coeff_index_q;
                    transform_host_wdata = addsub_sub_q ? sub_result : add_result;
                end
                ST_PW_READ_A0: begin
                    transform_host_re = 1'b1;
                    transform_host_addr = {pair_index_q,1'b0};
                end
                ST_PW_READ_A1: begin
                    transform_host_re = 1'b1;
                    transform_host_addr = {pair_index_q,1'b1};
                end
                ST_PW_WRITE0: begin
                    transform_host_we = 1'b1;
                    transform_host_addr = {pair_index_q,1'b0};
                    transform_host_wdata = c0_q;
                end
                ST_PW_WRITE1: begin
                    transform_host_we = 1'b1;
                    transform_host_addr = {pair_index_q,1'b1};
                    transform_host_wdata = c1_q;
                end
                default: begin end
            endcase
        end
    end

    assign host_ready_o = (state_q == ST_IDLE) && transform_host_ready && !transform_busy;
    assign host_rvalid_o = (state_q == ST_IDLE) ? transform_host_rvalid : 1'b0;
    assign host_rdata_o = transform_host_rdata;
    assign busy_o = transform_busy || (state_q != ST_IDLE);
    assign done_o = transform_done || binary_done_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            binary_pointwise_q <= 1'b0;
            addsub_sub_q <= 1'b0;
            operand_base_q <= '0;
            coeff_index_q <= '0;
            pair_index_q <= '0;
            operand_hi_q <= '0;
            b0_q <= '0; b1_q <= '0; a0_q <= '0; a1_q <= '0;
            c0_q <= '0; c1_q <= '0; gamma_q <= '0;
            binary_done_q <= 1'b0;
            operand_error_o <= 1'b0;
            operand_error_index_o <= '0;
        end else begin
            binary_done_q <= 1'b0;
            operand_error_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (!transform_busy && transform_host_ready && start_pointwise_i) begin
                        binary_pointwise_q <= 1'b1;
                        operand_base_q <= operand_base_i;
                        coeff_index_q <= 8'd0;
                        state_q <= ST_VALIDATE_HI;
                    end else if (!transform_busy && transform_host_ready && start_addsub_i) begin
                        binary_pointwise_q <= 1'b0;
                        addsub_sub_q <= addsub_sub_i;
                        operand_base_q <= operand_base_i;
                        coeff_index_q <= 8'd0;
                        state_q <= ST_VALIDATE_HI;
                    end
                end

                ST_VALIDATE_HI: begin
                    operand_hi_q <= operand_byte_data_i;
                    state_q <= ST_VALIDATE_LO;
                end

                ST_VALIDATE_LO: begin
                    if ({operand_hi_q,operand_byte_data_i} >= 16'd3329) begin
                        operand_error_o <= 1'b1;
                        operand_error_index_o <= coeff_index_q;
                        binary_done_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end else if (coeff_index_q == 8'd255) begin
                        coeff_index_q <= 8'd0;
                        pair_index_q <= 7'd0;
                        state_q <= binary_pointwise_q ? ST_PW_GAMMA_REQ : ST_ADD_B_HI;
                    end else begin
                        coeff_index_q <= coeff_index_q + 1'b1;
                        state_q <= ST_VALIDATE_HI;
                    end
                end

                ST_ADD_B_HI: begin
                    operand_hi_q <= operand_byte_data_i;
                    state_q <= ST_ADD_B_LO;
                end
                ST_ADD_B_LO: begin
                    b0_q <= {operand_hi_q,operand_byte_data_i};
                    state_q <= ST_ADD_READ_A;
                end
                ST_ADD_READ_A:
                    state_q <= ST_ADD_WAIT_A;
                ST_ADD_WAIT_A: begin
                    if (transform_host_rvalid) begin
                        a0_q <= transform_host_rdata;
                        state_q <= ST_ADD_WRITE;
                    end
                end
                ST_ADD_WRITE: begin
                    if (coeff_index_q == 8'd255) begin
                        binary_done_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end else begin
                        coeff_index_q <= coeff_index_q + 1'b1;
                        state_q <= ST_ADD_B_HI;
                    end
                end

                ST_PW_GAMMA_REQ:
                    state_q <= ST_PW_GAMMA_WAIT;
                ST_PW_GAMMA_WAIT: begin
                    if (gamma_valid) begin
                        gamma_q <= pair_index_q[0] ? (16'd3329 - gamma_zeta) : gamma_zeta;
                        state_q <= ST_PW_B0_HI;
                    end
                end
                ST_PW_B0_HI: begin
                    operand_hi_q <= operand_byte_data_i;
                    state_q <= ST_PW_B0_LO;
                end
                ST_PW_B0_LO: begin
                    b0_q <= {operand_hi_q,operand_byte_data_i};
                    state_q <= ST_PW_B1_HI;
                end
                ST_PW_B1_HI: begin
                    operand_hi_q <= operand_byte_data_i;
                    state_q <= ST_PW_B1_LO;
                end
                ST_PW_B1_LO: begin
                    b1_q <= {operand_hi_q,operand_byte_data_i};
                    state_q <= ST_PW_READ_A0;
                end
                ST_PW_READ_A0:
                    state_q <= ST_PW_WAIT_A0;
                ST_PW_WAIT_A0: begin
                    if (transform_host_rvalid) begin
                        a0_q <= transform_host_rdata;
                        state_q <= ST_PW_READ_A1;
                    end
                end
                ST_PW_READ_A1:
                    state_q <= ST_PW_WAIT_A1;
                ST_PW_WAIT_A1: begin
                    if (transform_host_rvalid) begin
                        a1_q <= transform_host_rdata;
                        state_q <= ST_PW_BASE_START;
                    end
                end
                ST_PW_BASE_START:
                    state_q <= ST_PW_BASE_WAIT;
                ST_PW_BASE_WAIT: begin
                    if (basemul_done) begin
                        c0_q <= basemul_c0;
                        c1_q <= basemul_c1;
                        state_q <= ST_PW_WRITE0;
                    end
                end
                ST_PW_WRITE0:
                    state_q <= ST_PW_WRITE1;
                ST_PW_WRITE1: begin
                    if (pair_index_q == 7'd127) begin
                        binary_done_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end else begin
                        pair_index_q <= pair_index_q + 1'b1;
                        state_q <= ST_PW_GAMMA_REQ;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if ((state_q != ST_IDLE) && transform_busy)
                assert (1'b0)
                    else $error("mlkem_pqc_accelerator: binary engine overlapped transform");
            if (transform_host_we && state_q != ST_IDLE)
                assert (transform_host_wdata < 3329)
                    else $error("mlkem_pqc_accelerator: non-canonical binary writeback");
        end
    end
`endif

    logic unused_basemul_busy;
    always_comb unused_basemul_busy = basemul_busy;
endmodule
