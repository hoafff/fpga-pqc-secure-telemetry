module forward_ntt_core (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_i,
    output logic        busy_o,
    output logic        done_o,

    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_ready_o,
    output logic [15:0] host_rdata_o,

    output logic [2:0]  stage_o,
    output logic        stage_barrier_o
);
    // Correctness-first 256-coefficient ML-KEM forward NTT integration.
    //
    // Dataflow:
    //   scheduler -> coefficient reads + twiddle ROM -> pipelined butterfly
    //             -> metadata FIFO -> in-place coefficient writeback
    //
    // The scheduler is stalled after every stage's final transaction until that
    // transaction reaches writeback. Because butterfly results preserve order,
    // observing the stage-last writeback also proves that all earlier writes in
    // that stage have completed. The next stage therefore cannot read stale data.

    localparam int unsigned META_DEPTH = 16;
    localparam int unsigned META_PTR_W = 4;
    localparam int unsigned META_COUNT_W = 5;
    localparam int unsigned META_STOP_LEVEL = META_DEPTH - 4;

    logic running_q;
    logic barrier_q;
    logic start_accept;

    logic scheduler_busy;
    logic scheduler_valid;
    logic scheduler_ready;
    logic scheduler_done;
    logic [2:0] scheduler_stage;
    logic [7:0] scheduler_length;
    logic [7:0] scheduler_left_addr;
    logic [7:0] scheduler_right_addr;
    logic [6:0] scheduler_zeta_addr;
    logic scheduler_group_first;
    logic scheduler_group_last;
    logic scheduler_stage_first;
    logic scheduler_stage_last;
    logic scheduler_transform_first;
    logic scheduler_transform_last;
    logic scheduler_fire;

    logic [15:0] memory_left_data;
    logic [15:0] memory_right_data;

    logic twiddle_valid;
    logic [15:0] twiddle_data;

    logic req_valid_s1;
    logic req_valid_s2;
    logic [15:0] req_left_data_s1;
    logic [15:0] req_right_data_s1;
    logic [7:0] req_left_addr_s1;
    logic [7:0] req_right_addr_s1;
    logic req_stage_last_s1;
    logic req_transform_last_s1;
    logic [15:0] req_left_data_s2;
    logic [15:0] req_right_data_s2;
    logic [7:0] req_left_addr_s2;
    logic [7:0] req_right_addr_s2;
    logic req_stage_last_s2;
    logic req_transform_last_s2;

    logic butterfly_input_valid;
    logic butterfly_output_valid;
    logic [15:0] butterfly_left_data;
    logic [15:0] butterfly_right_data;

    logic [7:0] meta_left_addr [0:META_DEPTH-1];
    logic [7:0] meta_right_addr [0:META_DEPTH-1];
    logic meta_stage_last [0:META_DEPTH-1];
    logic meta_transform_last [0:META_DEPTH-1];
    logic [META_PTR_W-1:0] meta_write_ptr_q;
    logic [META_PTR_W-1:0] meta_read_ptr_q;
    logic [META_COUNT_W-1:0] meta_count_q;
    logic meta_push;
    logic meta_pop;
    logic meta_near_full;

    assign start_accept = start_i && !running_q;
    assign busy_o = running_q;
    assign host_ready_o = !running_q;
    assign stage_o = scheduler_stage;
    assign stage_barrier_o = barrier_q;

    assign meta_near_full = meta_count_q >= META_STOP_LEVEL;
    assign scheduler_ready = running_q && !barrier_q && !meta_near_full;
    assign scheduler_fire = scheduler_valid && scheduler_ready;

    assign butterfly_input_valid = twiddle_valid && req_valid_s2;
    assign meta_push = butterfly_input_valid;
    assign meta_pop = butterfly_output_valid;

    forward_ntt_scheduler u_scheduler (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .start_i           (start_accept),
        .ready_i           (scheduler_ready),
        .busy_o            (scheduler_busy),
        .valid_o           (scheduler_valid),
        .done_o            (scheduler_done),
        .stage_o           (scheduler_stage),
        .length_o          (scheduler_length),
        .left_addr_o       (scheduler_left_addr),
        .right_addr_o      (scheduler_right_addr),
        .zeta_addr_o       (scheduler_zeta_addr),
        .group_first_o     (scheduler_group_first),
        .group_last_o      (scheduler_group_last),
        .stage_first_o     (scheduler_stage_first),
        .stage_last_o      (scheduler_stage_last),
        .transform_first_o (scheduler_transform_first),
        .transform_last_o  (scheduler_transform_last)
    );

    coefficient_memory_256x16 u_coefficient_memory (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .host_we_i      (host_we_i && host_ready_o),
        .host_addr_i    (host_addr_i),
        .host_wdata_i   (host_wdata_i),
        .host_rdata_o   (host_rdata_o),
        .left_raddr_i   (scheduler_left_addr),
        .right_raddr_i  (scheduler_right_addr),
        .left_rdata_o   (memory_left_data),
        .right_rdata_o  (memory_right_data),
        .core_we_i      (meta_pop),
        .left_waddr_i   (meta_left_addr[meta_read_ptr_q]),
        .right_waddr_i  (meta_right_addr[meta_read_ptr_q]),
        .left_wdata_i   (butterfly_left_data),
        .right_wdata_i  (butterfly_right_data)
    );

    twiddle_rom_3329 u_twiddle_rom (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (scheduler_fire),
        .addr_i  (scheduler_zeta_addr),
        .valid_o (twiddle_valid),
        .zeta_o  (twiddle_data)
    );

    ntt_butterfly_pipe u_butterfly (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (butterfly_input_valid),
        .a_i     (req_left_data_s2),
        .b_i     (req_right_data_s2),
        .zeta_i  (twiddle_data),
        .valid_o (butterfly_output_valid),
        .a_o     (butterfly_left_data),
        .b_o     (butterfly_right_data)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            req_valid_s1          <= 1'b0;
            req_valid_s2          <= 1'b0;
            req_left_data_s1      <= '0;
            req_right_data_s1     <= '0;
            req_left_addr_s1      <= '0;
            req_right_addr_s1     <= '0;
            req_stage_last_s1     <= 1'b0;
            req_transform_last_s1 <= 1'b0;
            req_left_data_s2      <= '0;
            req_right_data_s2     <= '0;
            req_left_addr_s2      <= '0;
            req_right_addr_s2     <= '0;
            req_stage_last_s2     <= 1'b0;
            req_transform_last_s2 <= 1'b0;
        end else begin
            req_valid_s1 <= scheduler_fire;
            req_valid_s2 <= req_valid_s1;

            if (scheduler_fire) begin
                req_left_data_s1      <= memory_left_data;
                req_right_data_s1     <= memory_right_data;
                req_left_addr_s1      <= scheduler_left_addr;
                req_right_addr_s1     <= scheduler_right_addr;
                req_stage_last_s1     <= scheduler_stage_last;
                req_transform_last_s1 <= scheduler_transform_last;
            end

            if (req_valid_s1) begin
                req_left_data_s2      <= req_left_data_s1;
                req_right_data_s2     <= req_right_data_s1;
                req_left_addr_s2      <= req_left_addr_s1;
                req_right_addr_s2     <= req_right_addr_s1;
                req_stage_last_s2     <= req_stage_last_s1;
                req_transform_last_s2 <= req_transform_last_s1;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            running_q        <= 1'b0;
            barrier_q        <= 1'b0;
            done_o           <= 1'b0;
            meta_write_ptr_q <= '0;
            meta_read_ptr_q  <= '0;
            meta_count_q     <= '0;
        end else begin
            done_o <= 1'b0;

            if (start_accept) begin
                running_q <= 1'b1;
                barrier_q <= 1'b0;
            end

            if (scheduler_fire && scheduler_stage_last)
                barrier_q <= 1'b1;

            if (meta_push) begin
                meta_left_addr[meta_write_ptr_q]      <= req_left_addr_s2;
                meta_right_addr[meta_write_ptr_q]     <= req_right_addr_s2;
                meta_stage_last[meta_write_ptr_q]     <= req_stage_last_s2;
                meta_transform_last[meta_write_ptr_q] <= req_transform_last_s2;
                meta_write_ptr_q <= meta_write_ptr_q + 1'b1;
            end

            if (meta_pop) begin
                meta_read_ptr_q <= meta_read_ptr_q + 1'b1;

                if (meta_stage_last[meta_read_ptr_q])
                    barrier_q <= 1'b0;

                if (meta_transform_last[meta_read_ptr_q]) begin
                    running_q <= 1'b0;
                    done_o    <= 1'b1;
                end
            end

            case ({meta_push, meta_pop})
                2'b10: meta_count_q <= meta_count_q + 1'b1;
                2'b01: meta_count_q <= meta_count_q - 1'b1;
                default: meta_count_q <= meta_count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (twiddle_valid == req_valid_s2)
                else $error(
                    "forward_ntt_core: twiddle/request pipeline misalignment");

            assert (!(meta_push && (meta_count_q == META_DEPTH)))
                else $error("forward_ntt_core: metadata FIFO overflow");

            assert (!(meta_pop && (meta_count_q == 0)))
                else $error("forward_ntt_core: metadata FIFO underflow");

            if (start_i && running_q) begin
                assert (!start_accept)
                    else $error(
                        "forward_ntt_core: start accepted while already busy");
            end

            if (scheduler_fire) begin
                assert (scheduler_busy)
                    else $error(
                        "forward_ntt_core: scheduler transaction while idle");
                assert (scheduler_left_addr < scheduler_right_addr)
                    else $error(
                        "forward_ntt_core: invalid scheduler address pair");
            end

            if (meta_pop) begin
                assert (butterfly_left_data < 3329)
                    else $error(
                        "forward_ntt_core: non-canonical left result %0d",
                        butterfly_left_data);
                assert (butterfly_right_data < 3329)
                    else $error(
                        "forward_ntt_core: non-canonical right result %0d",
                        butterfly_right_data);
            end
        end
    end
`endif
endmodule
