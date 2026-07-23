`timescale 1ns/1ps

module tb_forward_ntt_core;
    localparam integer Q = 3329;
    localparam integer N = 256;
    localparam integer CASE_COUNT = 5;
    localparam integer TOTAL_VALUES = N * CASE_COUNT;
    localparam integer TIMEOUT_CYCLES = 5000;

    logic clk;
    logic rst_n;
    logic start_i;
    logic busy_o;
    logic done_o;
    logic host_re_i;
    logic host_we_i;
    logic [7:0] host_addr_i;
    logic [15:0] host_wdata_i;
    logic host_ready_o;
    logic host_rvalid_o;
    logic [15:0] host_rdata_o;
    logic [2:0] stage_o;
    logic stage_barrier_o;
    logic active_bank_o;

    logic [15:0] input_vectors [0:TOTAL_VALUES-1];
    logic [15:0] expected_vectors [0:TOTAL_VALUES-1];

    integer barrier_entry_count;
    integer bank_swap_count;
    integer done_count;
    logic previous_barrier;
    logic previous_active_bank;
    logic run_start_bank;

    forward_ntt_core dut (
        .clk_i(clk), .rst_ni(rst_n),
        .start_i(start_i), .busy_o(busy_o), .done_o(done_o),
        .host_re_i(host_re_i), .host_we_i(host_we_i),
        .host_addr_i(host_addr_i), .host_wdata_i(host_wdata_i),
        .host_ready_o(host_ready_o), .host_rvalid_o(host_rvalid_o),
        .host_rdata_o(host_rdata_o), .stage_o(stage_o),
        .stage_barrier_o(stage_barrier_o), .active_bank_o(active_bank_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Sample settled registered outputs on the falling edge. This avoids races
    // with the DUT's nonblocking assignments on the rising edge.
    always @(negedge clk) begin
        if (!rst_n) begin
            barrier_entry_count = 0;
            bank_swap_count = 0;
            done_count = 0;
            previous_barrier = 1'b0;
            previous_active_bank = 1'b0;
        end else begin
            if (stage_barrier_o && !previous_barrier)
                barrier_entry_count = barrier_entry_count + 1;
            previous_barrier = stage_barrier_o;

            if (active_bank_o != previous_active_bank)
                bank_swap_count = bank_swap_count + 1;
            previous_active_bank = active_bank_o;

            if (done_o)
                done_count = done_count + 1;
        end
    end

    task automatic assert_reset;
    begin
        @(negedge clk);
        rst_n = 1'b0;
        start_i = 1'b0;
        host_re_i = 1'b0;
        host_we_i = 1'b0;
        repeat (2) @(negedge clk);
    end
    endtask

    task automatic release_reset;
    begin
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (busy_o || done_o || !host_ready_o || host_rvalid_o)
            $fatal(1, "forward_ntt_core did not return to idle after reset");
        if (active_bank_o !== 1'b0)
            $fatal(1, "reset did not select coefficient bank 0");
    end
    endtask

    task automatic load_case(input integer case_index);
        integer coefficient;
        integer vector_index;
    begin
        if (!host_ready_o)
            $fatal(1, "host interface not ready before load");

        for (coefficient = 0; coefficient < N; coefficient = coefficient + 1) begin
            vector_index = (case_index * N) + coefficient;
            @(negedge clk);
            if (!host_ready_o)
                $fatal(1, "host interface became busy during load");
            host_we_i = 1'b1;
            host_addr_i = coefficient[7:0];
            host_wdata_i = input_vectors[vector_index];
        end

        @(negedge clk);
        host_we_i = 1'b0;
    end
    endtask

    task automatic pulse_start;
    begin
        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
        wait (busy_o == 1'b1);
        if (host_ready_o)
            $fatal(1, "host interface remained writable while core was busy");
    end
    endtask

    task automatic attempt_illegal_host_access;
    begin
        repeat (20) @(negedge clk);
        if (!busy_o || host_ready_o)
            $fatal(1, "core unexpectedly idle during illegal-access test");

        host_we_i = 1'b1;
        host_addr_i = 8'd0;
        host_wdata_i = 16'd123;
        repeat (2) @(negedge clk);
        host_we_i = 1'b0;

        host_re_i = 1'b1;
        host_addr_i = 8'd1;
        repeat (2) @(negedge clk);
        host_re_i = 1'b0;
        if (host_rvalid_o)
            $fatal(1, "host read was accepted while core was busy");
    end
    endtask

    task automatic wait_for_done;
        integer cycles;
    begin
        cycles = 0;
        while (!done_o && cycles < TIMEOUT_CYCLES) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!done_o)
            $fatal(1, "forward_ntt_core timeout after %0d cycles", cycles);
        if (busy_o)
            $fatal(1, "busy_o remained asserted with done_o");
        if (!host_ready_o)
            $fatal(1, "host interface not released at completion");

        // Allow the falling-edge monitor to count the final bank swap and done.
        @(negedge clk);
        #1;
        if (barrier_entry_count != 7)
            $fatal(1, "expected 7 stage barriers, observed %0d",
                barrier_entry_count);
        if (bank_swap_count != 7)
            $fatal(1, "expected 7 coefficient-bank swaps, observed %0d",
                bank_swap_count);
        if (active_bank_o === run_start_bank)
            $fatal(1, "seven stages must leave the opposite bank active");

        @(posedge clk);
        #1;
        if (done_o)
            $fatal(1, "done_o must be a one-cycle pulse");
    end
    endtask

    task automatic read_coefficient(
        input logic [7:0] address,
        output logic [15:0] value
    );
    begin
        @(negedge clk);
        host_re_i = 1'b1;
        host_addr_i = address;
        @(posedge clk);
        #1;
        if (!host_rvalid_o)
            $fatal(1, "missing synchronous host read response");
        value = host_rdata_o;
        @(negedge clk);
        host_re_i = 1'b0;
        @(posedge clk);
        #1;
        if (host_rvalid_o)
            $fatal(1, "host_rvalid_o must clear after the request");
    end
    endtask

    task automatic check_case(input integer case_index);
        integer coefficient;
        integer vector_index;
        integer mismatch_count;
        logic [15:0] observed;
    begin
        mismatch_count = 0;
        for (coefficient = 0; coefficient < N; coefficient = coefficient + 1) begin
            vector_index = (case_index * N) + coefficient;
            read_coefficient(coefficient[7:0], observed);

            if (observed >= Q)
                $fatal(1,
                    "case=%0d coefficient=%0d produced non-canonical value %0d",
                    case_index, coefficient, observed);

            if (observed !== expected_vectors[vector_index]) begin
                mismatch_count = mismatch_count + 1;
                if (mismatch_count <= 8)
                    $display(
                        "MISMATCH case=%0d coefficient=%0d got=%0d expected=%0d",
                        case_index, coefficient, observed,
                        expected_vectors[vector_index]);
            end
        end

        if (mismatch_count != 0)
            $fatal(1, "case=%0d failed with %0d coefficient mismatches",
                case_index, mismatch_count);
    end
    endtask

    task automatic run_case(
        input integer case_index,
        input logic inject_illegal_access
    );
    begin
        load_case(case_index);
        @(negedge clk);
        barrier_entry_count = 0;
        bank_swap_count = 0;
        previous_barrier = 1'b0;
        previous_active_bank = active_bank_o;
        run_start_bank = active_bank_o;

        pulse_start();
        if (inject_illegal_access)
            attempt_illegal_host_access();
        wait_for_done();
        check_case(case_index);

        $display("PASS: forward_ntt_core case=%0d completed with 7 drained ping-pong stages",
            case_index);
    end
    endtask

    integer case_index;

    initial begin
        rst_n = 1'b0;
        start_i = 1'b0;
        host_re_i = 1'b0;
        host_we_i = 1'b0;
        host_addr_i = '0;
        host_wdata_i = '0;

        $readmemh("build/sim/forward_ntt_core_inputs.hex", input_vectors);
        $readmemh("build/sim/forward_ntt_core_expected.hex", expected_vectors);

        assert_reset();
        release_reset();

        // Reset aborts an in-flight transform and restores bank 0 selection.
        // RAM words are not cleared, so the next operation reloads all 256 words.
        load_case(2);
        pulse_start();
        repeat (180) @(negedge clk);
        assert_reset();
        release_reset();

        for (case_index = 0; case_index < CASE_COUNT; case_index = case_index + 1)
            run_case(case_index, case_index == 4);

        if (done_count != CASE_COUNT)
            $fatal(1, "expected %0d completed transforms, observed %0d",
                CASE_COUNT, done_count);

        $display("PASS: forward_ntt_core matched %0d vectors (%0d coefficients) using inferred ping-pong storage",
            CASE_COUNT, TOTAL_VALUES);
        $finish;
    end
endmodule
