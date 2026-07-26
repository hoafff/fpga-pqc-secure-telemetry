module mlkem_ntt_intt_core (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_ntt_i,
    input  logic        start_intt_i,
    output logic        busy_o,
    output logic        done_o,
    output logic        inverse_active_o,

    input  logic        host_re_i,
    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_ready_o,
    output logic        host_rvalid_o,
    output logic [15:0] host_rdata_o,

    output logic [2:0]  stage_o,
    output logic        stage_barrier_o,
    output logic        active_bank_o
);
    // Shared BRAM-backed transform engine for FIPS 203 Algorithms 9 and 10.
    // The datapath deliberately keeps at most one butterfly in flight. This is
    // slower than forward_ntt_core but greatly simplifies cross-direction reuse
    // of the same ping-pong coefficient image and is still far below the FPST
    // 500 ms PQC command timeout at 27 MHz.

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_ISSUE,
        ST_WAIT_DATA,
        ST_WAIT_TWIDDLE,
        ST_WAIT_BFLY,
        ST_WRITE,
        ST_SCALE_ISSUE,
        ST_SCALE_WAIT_READ,
        ST_SCALE_MUL_LEFT,
        ST_SCALE_WAIT_LEFT,
        ST_SCALE_MUL_RIGHT,
        ST_SCALE_WAIT_RIGHT,
        ST_SCALE_WRITE
    } state_t;

    state_t state_q;
    logic inverse_q;

    logic forward_start, inverse_start;
    logic forward_busy, forward_valid, forward_done;
    logic inverse_busy, inverse_valid, inverse_done;
    logic [2:0] forward_stage, inverse_stage;
    logic [7:0] forward_length, inverse_length;
    logic [7:0] forward_left, forward_right;
    logic [7:0] inverse_left, inverse_right;
    logic [6:0] forward_zeta, inverse_zeta;
    logic forward_stage_last, inverse_stage_last;
    logic forward_transform_last, inverse_transform_last;
    logic scheduler_valid, scheduler_ready;
    logic [2:0] scheduler_stage;
    logic [7:0] scheduler_left, scheduler_right;
    logic [6:0] scheduler_zeta;
    logic scheduler_stage_last, scheduler_transform_last;

    logic memory_core_re, memory_core_we, memory_swap;
    logic [7:0] memory_left_raddr, memory_right_raddr;
    logic [7:0] memory_left_waddr, memory_right_waddr;
    logic [15:0] memory_left_wdata, memory_right_wdata;
    logic memory_rvalid;
    logic [15:0] memory_left_rdata, memory_right_rdata;

    logic twiddle_valid;
    logic [15:0] twiddle_data;

    logic butterfly_valid_i, butterfly_valid_o;
    logic [15:0] butterfly_a_o, butterfly_b_o;

    logic [7:0] pair_left_q, pair_right_q;
    logic [2:0] pair_stage_q;
    logic pair_stage_last_q, pair_transform_last_q;
    logic [15:0] pair_left_data_q, pair_right_data_q;
    logic [15:0] result_left_q, result_right_q;

    logic [7:0] scale_pair_q;
    logic [15:0] scale_left_q, scale_right_q;
    logic [15:0] scale_left_result_q, scale_right_result_q;
    logic scale_mul_valid_i, scale_mul_valid_o;
    logic [15:0] scale_mul_a, scale_mul_result;

    assign forward_start = (state_q == ST_IDLE) && start_ntt_i && !start_intt_i;
    assign inverse_start = (state_q == ST_IDLE) && start_intt_i && !start_ntt_i;

    forward_ntt_scheduler u_forward_scheduler (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_i(forward_start), .ready_i(scheduler_ready && !inverse_q),
        .busy_o(forward_busy), .valid_o(forward_valid), .done_o(forward_done),
        .stage_o(forward_stage), .length_o(forward_length),
        .left_addr_o(forward_left), .right_addr_o(forward_right),
        .zeta_addr_o(forward_zeta),
        .group_first_o(), .group_last_o(), .stage_first_o(),
        .stage_last_o(forward_stage_last), .transform_first_o(),
        .transform_last_o(forward_transform_last)
    );

    inverse_ntt_scheduler u_inverse_scheduler (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_i(inverse_start), .ready_i(scheduler_ready && inverse_q),
        .busy_o(inverse_busy), .valid_o(inverse_valid), .done_o(inverse_done),
        .stage_o(inverse_stage), .length_o(inverse_length),
        .left_addr_o(inverse_left), .right_addr_o(inverse_right),
        .zeta_addr_o(inverse_zeta),
        .group_first_o(), .group_last_o(), .stage_first_o(),
        .stage_last_o(inverse_stage_last), .transform_first_o(),
        .transform_last_o(inverse_transform_last)
    );

    always_comb begin
        if (inverse_q) begin
            scheduler_valid = inverse_valid;
            scheduler_stage = inverse_stage;
            scheduler_left = inverse_left;
            scheduler_right = inverse_right;
            scheduler_zeta = inverse_zeta;
            scheduler_stage_last = inverse_stage_last;
            scheduler_transform_last = inverse_transform_last;
        end else begin
            scheduler_valid = forward_valid;
            scheduler_stage = forward_stage;
            scheduler_left = forward_left;
            scheduler_right = forward_right;
            scheduler_zeta = forward_zeta;
            scheduler_stage_last = forward_stage_last;
            scheduler_transform_last = forward_transform_last;
        end
    end

    assign scheduler_ready = (state_q == ST_ISSUE) && scheduler_valid;

    twiddle_rom_3329 u_twiddle_rom (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(scheduler_ready), .addr_i(scheduler_zeta),
        .valid_o(twiddle_valid), .zeta_o(twiddle_data)
    );

    assign butterfly_valid_i = (state_q == ST_WAIT_TWIDDLE) && twiddle_valid;

    ntt_intt_butterfly_pipe u_butterfly (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(butterfly_valid_i), .inverse_i(inverse_q),
        .a_i(pair_left_data_q), .b_i(pair_right_data_q), .zeta_i(twiddle_data),
        .valid_o(butterfly_valid_o), .a_o(butterfly_a_o), .b_o(butterfly_b_o)
    );

    assign scale_mul_valid_i = (state_q == ST_SCALE_MUL_LEFT) ||
                               (state_q == ST_SCALE_MUL_RIGHT);
    assign scale_mul_a = (state_q == ST_SCALE_MUL_LEFT) ? scale_left_q : scale_right_q;

    mod_mul_3329_pipe u_scale_mul (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(scale_mul_valid_i), .a_i(scale_mul_a), .b_i(16'd3303),
        .valid_o(scale_mul_valid_o), .y_o(scale_mul_result)
    );

    always_comb begin
        memory_core_re = 1'b0;
        memory_core_we = 1'b0;
        memory_swap = 1'b0;
        memory_left_raddr = '0;
        memory_right_raddr = '0;
        memory_left_waddr = '0;
        memory_right_waddr = '0;
        memory_left_wdata = '0;
        memory_right_wdata = '0;

        if ((state_q == ST_ISSUE) && scheduler_valid) begin
            memory_core_re = 1'b1;
            memory_left_raddr = scheduler_left;
            memory_right_raddr = scheduler_right;
        end else if (state_q == ST_WRITE) begin
            memory_core_we = 1'b1;
            memory_left_waddr = pair_left_q;
            memory_right_waddr = pair_right_q;
            memory_left_wdata = result_left_q;
            memory_right_wdata = result_right_q;
            memory_swap = pair_stage_last_q;
        end else if (state_q == ST_SCALE_ISSUE) begin
            memory_core_re = 1'b1;
            memory_left_raddr = {scale_pair_q[6:0],1'b0};
            memory_right_raddr = {scale_pair_q[6:0],1'b1};
        end else if (state_q == ST_SCALE_WRITE) begin
            memory_core_we = 1'b1;
            memory_left_waddr = {scale_pair_q[6:0],1'b0};
            memory_right_waddr = {scale_pair_q[6:0],1'b1};
            memory_left_wdata = scale_left_result_q;
            memory_right_wdata = scale_right_result_q;
            memory_swap = (scale_pair_q == 8'd127);
        end
    end

    coefficient_pingpong_memory_256x16 u_memory (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .host_re_i(host_re_i && host_ready_o),
        .host_we_i(host_we_i && host_ready_o),
        .host_addr_i(host_addr_i), .host_wdata_i(host_wdata_i),
        .host_rvalid_o(host_rvalid_o), .host_rdata_o(host_rdata_o),
        .core_re_i(memory_core_re),
        .left_raddr_i(memory_left_raddr), .right_raddr_i(memory_right_raddr),
        .core_rvalid_o(memory_rvalid),
        .left_rdata_o(memory_left_rdata), .right_rdata_o(memory_right_rdata),
        .core_we_i(memory_core_we),
        .left_waddr_i(memory_left_waddr), .right_waddr_i(memory_right_waddr),
        .left_wdata_i(memory_left_wdata), .right_wdata_i(memory_right_wdata),
        .swap_i(memory_swap), .active_bank_o(active_bank_o)
    );

    assign busy_o = (state_q != ST_IDLE);
    assign host_ready_o = (state_q == ST_IDLE);
    assign inverse_active_o = busy_o && inverse_q;
    assign stage_barrier_o = (state_q == ST_WRITE) && pair_stage_last_q;
    assign stage_o = (state_q == ST_ISSUE) ? scheduler_stage : pair_stage_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            inverse_q <= 1'b0;
            done_o <= 1'b0;
            pair_left_q <= '0;
            pair_right_q <= '0;
            pair_stage_q <= '0;
            pair_stage_last_q <= 1'b0;
            pair_transform_last_q <= 1'b0;
            pair_left_data_q <= '0;
            pair_right_data_q <= '0;
            result_left_q <= '0;
            result_right_q <= '0;
            scale_pair_q <= '0;
            scale_left_q <= '0;
            scale_right_q <= '0;
            scale_left_result_q <= '0;
            scale_right_result_q <= '0;
        end else begin
            done_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_ntt_i && !start_intt_i) begin
                        inverse_q <= 1'b0;
                        state_q <= ST_ISSUE;
                    end else if (start_intt_i && !start_ntt_i) begin
                        inverse_q <= 1'b1;
                        state_q <= ST_ISSUE;
                    end
                end

                ST_ISSUE: begin
                    if (scheduler_valid) begin
                        pair_left_q <= scheduler_left;
                        pair_right_q <= scheduler_right;
                        pair_stage_q <= scheduler_stage;
                        pair_stage_last_q <= scheduler_stage_last;
                        pair_transform_last_q <= scheduler_transform_last;
                        state_q <= ST_WAIT_DATA;
                    end
                end

                ST_WAIT_DATA: begin
                    if (memory_rvalid) begin
                        pair_left_data_q <= memory_left_rdata;
                        pair_right_data_q <= memory_right_rdata;
                        state_q <= ST_WAIT_TWIDDLE;
                    end
                end

                ST_WAIT_TWIDDLE: begin
                    if (twiddle_valid)
                        state_q <= ST_WAIT_BFLY;
                end

                ST_WAIT_BFLY: begin
                    if (butterfly_valid_o) begin
                        result_left_q <= butterfly_a_o;
                        result_right_q <= butterfly_b_o;
                        state_q <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    if (pair_transform_last_q) begin
                        if (inverse_q) begin
                            scale_pair_q <= 8'd0;
                            state_q <= ST_SCALE_ISSUE;
                        end else begin
                            state_q <= ST_IDLE;
                            done_o <= 1'b1;
                        end
                    end else begin
                        state_q <= ST_ISSUE;
                    end
                end

                ST_SCALE_ISSUE:
                    state_q <= ST_SCALE_WAIT_READ;

                ST_SCALE_WAIT_READ: begin
                    if (memory_rvalid) begin
                        scale_left_q <= memory_left_rdata;
                        scale_right_q <= memory_right_rdata;
                        state_q <= ST_SCALE_MUL_LEFT;
                    end
                end

                ST_SCALE_MUL_LEFT:
                    state_q <= ST_SCALE_WAIT_LEFT;

                ST_SCALE_WAIT_LEFT: begin
                    if (scale_mul_valid_o) begin
                        scale_left_result_q <= scale_mul_result;
                        state_q <= ST_SCALE_MUL_RIGHT;
                    end
                end

                ST_SCALE_MUL_RIGHT:
                    state_q <= ST_SCALE_WAIT_RIGHT;

                ST_SCALE_WAIT_RIGHT: begin
                    if (scale_mul_valid_o) begin
                        scale_right_result_q <= scale_mul_result;
                        state_q <= ST_SCALE_WRITE;
                    end
                end

                ST_SCALE_WRITE: begin
                    if (scale_pair_q == 8'd127) begin
                        state_q <= ST_IDLE;
                        done_o <= 1'b1;
                    end else begin
                        scale_pair_q <= scale_pair_q + 1'b1;
                        state_q <= ST_SCALE_ISSUE;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(start_ntt_i && start_intt_i))
                else $error("mlkem_ntt_intt_core: simultaneous NTT and INTT start");
            if (memory_core_we) begin
                assert (memory_left_wdata < 3329 && memory_right_wdata < 3329)
                    else $error("mlkem_ntt_intt_core: non-canonical writeback");
            end
            if (state_q == ST_SCALE_WRITE && scale_pair_q == 8'd127)
                assert (memory_swap)
                    else $error("mlkem_ntt_intt_core: final inverse scale did not swap bank");
        end
    end
`endif

    logic unused_scheduler_status;
    always_comb unused_scheduler_status = ^{forward_busy,forward_done,inverse_busy,inverse_done,
                                            forward_length,inverse_length};
endmodule
