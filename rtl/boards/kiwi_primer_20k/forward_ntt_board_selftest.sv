module forward_ntt_board_selftest #(
    parameter integer CORE_TIMEOUT_CYCLES = 4096,
    parameter integer READ_TIMEOUT_CYCLES = 16
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,

    output logic        running_o,
    output logic        complete_o,
    output logic        done_o,
    output logic        pass_o,
    output logic        fail_o,

    output logic        core_busy_o,
    output logic [2:0]  core_stage_o,
    output logic        core_stage_barrier_o,
    output logic        core_active_bank_o,

    output logic [7:0]  mismatch_addr_o,
    output logic [15:0] mismatch_observed_o,
    output logic [15:0] mismatch_expected_o
);
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOAD,
        ST_START,
        ST_WAIT_CORE,
        ST_READ_REQUEST,
        ST_READ_WAIT,
        ST_COMPLETE
    } state_t;

    localparam integer CORE_TIMEOUT_WIDTH =
        (CORE_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(CORE_TIMEOUT_CYCLES + 1);
    localparam integer READ_TIMEOUT_WIDTH =
        (READ_TIMEOUT_CYCLES <= 1) ? 1 : $clog2(READ_TIMEOUT_CYCLES + 1);

    state_t state_q;

    logic core_start;
    logic core_done;
    logic core_host_re;
    logic core_host_we;
    logic [7:0] core_host_addr;
    logic [15:0] core_host_wdata;
    logic core_host_ready;
    logic core_host_rvalid;
    logic [15:0] core_host_rdata;

    logic [7:0] load_addr_q;
    logic [7:0] check_addr_q;
    logic [15:0] expected_value;
    logic mismatch_now;

    logic [CORE_TIMEOUT_WIDTH-1:0] core_timeout_q;
    logic [READ_TIMEOUT_WIDTH-1:0] read_timeout_q;

    assign running_o = (state_q != ST_IDLE) && (state_q != ST_COMPLETE);
    assign mismatch_now =
        core_host_rvalid && (core_host_rdata != expected_value);

    always_comb begin
        core_start      = 1'b0;
        core_host_re    = 1'b0;
        core_host_we    = 1'b0;
        core_host_addr  = check_addr_q;
        core_host_wdata = 16'd0;

        case (state_q)
            ST_LOAD: begin
                core_host_we    = core_host_ready;
                core_host_addr  = load_addr_q;
                core_host_wdata = {8'd0, load_addr_q};
            end

            ST_START: begin
                core_start = 1'b1;
            end

            ST_READ_REQUEST: begin
                core_host_re   = core_host_ready;
                core_host_addr = check_addr_q;
            end

            default: begin
                core_start      = 1'b0;
                core_host_re    = 1'b0;
                core_host_we    = 1'b0;
                core_host_addr  = check_addr_q;
                core_host_wdata = 16'd0;
            end
        endcase
    end

    forward_ntt_ramp_expected_rom u_expected_rom (
        .addr_i     (check_addr_q),
        .expected_o (expected_value)
    );

    forward_ntt_core u_forward_ntt_core (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .start_i         (core_start),
        .busy_o          (core_busy_o),
        .done_o          (core_done),
        .host_re_i       (core_host_re),
        .host_we_i       (core_host_we),
        .host_addr_i     (core_host_addr),
        .host_wdata_i    (core_host_wdata),
        .host_ready_o    (core_host_ready),
        .host_rvalid_o   (core_host_rvalid),
        .host_rdata_o    (core_host_rdata),
        .stage_o         (core_stage_o),
        .stage_barrier_o (core_stage_barrier_o),
        .active_bank_o   (core_active_bank_o)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q               <= ST_IDLE;
            load_addr_q           <= 8'd0;
            check_addr_q          <= 8'd0;
            core_timeout_q        <= '0;
            read_timeout_q        <= '0;
            complete_o            <= 1'b0;
            done_o                <= 1'b0;
            pass_o                <= 1'b0;
            fail_o                <= 1'b0;
            mismatch_addr_o       <= 8'd0;
            mismatch_observed_o   <= 16'd0;
            mismatch_expected_o   <= 16'd0;
        end else begin
            done_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_i) begin
                        load_addr_q         <= 8'd0;
                        check_addr_q        <= 8'd0;
                        core_timeout_q      <= '0;
                        read_timeout_q      <= '0;
                        complete_o          <= 1'b0;
                        pass_o              <= 1'b0;
                        fail_o              <= 1'b0;
                        mismatch_addr_o     <= 8'd0;
                        mismatch_observed_o <= 16'd0;
                        mismatch_expected_o <= 16'd0;
                        state_q             <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    if (core_host_ready) begin
                        if (load_addr_q == 8'hff) begin
                            state_q <= ST_START;
                        end else begin
                            load_addr_q <= load_addr_q + 1'b1;
                        end
                    end
                end

                ST_START: begin
                    core_timeout_q <= '0;
                    state_q        <= ST_WAIT_CORE;
                end

                ST_WAIT_CORE: begin
                    if (core_done) begin
                        check_addr_q   <= 8'd0;
                        read_timeout_q <= '0;
                        state_q        <= ST_READ_REQUEST;
                    end else if (core_timeout_q == CORE_TIMEOUT_CYCLES - 1) begin
                        fail_o              <= 1'b1;
                        complete_o          <= 1'b1;
                        done_o              <= 1'b1;
                        mismatch_addr_o     <= 8'hff;
                        mismatch_observed_o <= 16'hffff;
                        mismatch_expected_o <= 16'h0000;
                        state_q             <= ST_COMPLETE;
                    end else begin
                        core_timeout_q <= core_timeout_q + 1'b1;
                    end
                end

                ST_READ_REQUEST: begin
                    if (core_host_ready) begin
                        read_timeout_q <= '0;
                        state_q        <= ST_READ_WAIT;
                    end
                end

                ST_READ_WAIT: begin
                    if (core_host_rvalid) begin
                        if (mismatch_now) begin
                            fail_o <= 1'b1;
                            if (!fail_o) begin
                                mismatch_addr_o     <= check_addr_q;
                                mismatch_observed_o <= core_host_rdata;
                                mismatch_expected_o <= expected_value;
                            end
                        end

                        if (check_addr_q == 8'hff) begin
                            complete_o <= 1'b1;
                            pass_o     <= !(fail_o || mismatch_now);
                            done_o     <= 1'b1;
                            state_q    <= ST_COMPLETE;
                        end else begin
                            check_addr_q   <= check_addr_q + 1'b1;
                            read_timeout_q <= '0;
                            state_q        <= ST_READ_REQUEST;
                        end
                    end else if (read_timeout_q == READ_TIMEOUT_CYCLES - 1) begin
                        fail_o              <= 1'b1;
                        complete_o          <= 1'b1;
                        done_o              <= 1'b1;
                        mismatch_addr_o     <= check_addr_q;
                        mismatch_observed_o <= 16'hffff;
                        mismatch_expected_o <= expected_value;
                        state_q             <= ST_COMPLETE;
                    end else begin
                        read_timeout_q <= read_timeout_q + 1'b1;
                    end
                end

                ST_COMPLETE: begin
                    if (start_i) begin
                        load_addr_q         <= 8'd0;
                        check_addr_q        <= 8'd0;
                        core_timeout_q      <= '0;
                        read_timeout_q      <= '0;
                        complete_o          <= 1'b0;
                        pass_o              <= 1'b0;
                        fail_o              <= 1'b0;
                        mismatch_addr_o     <= 8'd0;
                        mismatch_observed_o <= 16'd0;
                        mismatch_expected_o <= 16'd0;
                        state_q             <= ST_LOAD;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(pass_o && fail_o))
                else $error("forward_ntt_board_selftest: pass and fail both set");

            if (core_host_we) begin
                assert (state_q == ST_LOAD)
                    else $error("forward_ntt_board_selftest: write outside load state");
                assert (core_host_wdata < 3329)
                    else $error("forward_ntt_board_selftest: non-canonical input");
            end

            if (core_host_re) begin
                assert (state_q == ST_READ_REQUEST)
                    else $error("forward_ntt_board_selftest: read outside check state");
            end
        end
    end
`endif
endmodule
