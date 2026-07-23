`timescale 1ns/1ps

module tb_forward_ntt_board_selftest;
    localparam integer TIMEOUT_CYCLES = 10000;

    logic clk;
    logic rst_n;
    logic start_i;

    logic running_o;
    logic complete_o;
    logic done_o;
    logic pass_o;
    logic fail_o;
    logic core_busy_o;
    logic [2:0] core_stage_o;
    logic core_stage_barrier_o;
    logic core_active_bank_o;
    logic [7:0] mismatch_addr_o;
    logic [15:0] mismatch_observed_o;
    logic [15:0] mismatch_expected_o;

    integer done_count;
    integer barrier_count;
    logic previous_barrier;

    forward_ntt_board_selftest dut (
        .clk_i                   (clk),
        .rst_ni                  (rst_n),
        .start_i                 (start_i),
        .running_o               (running_o),
        .complete_o              (complete_o),
        .done_o                  (done_o),
        .pass_o                  (pass_o),
        .fail_o                  (fail_o),
        .core_busy_o             (core_busy_o),
        .core_stage_o            (core_stage_o),
        .core_stage_barrier_o    (core_stage_barrier_o),
        .core_active_bank_o      (core_active_bank_o),
        .mismatch_addr_o         (mismatch_addr_o),
        .mismatch_observed_o     (mismatch_observed_o),
        .mismatch_expected_o     (mismatch_expected_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            done_count       = 0;
            barrier_count    = 0;
            previous_barrier = 1'b0;
        end else begin
            if (done_o)
                done_count = done_count + 1;
            if (core_stage_barrier_o && !previous_barrier)
                barrier_count = barrier_count + 1;
            previous_barrier = core_stage_barrier_o;
        end
    end

    task automatic pulse_start;
    begin
        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
    end
    endtask

    task automatic wait_and_check(
        input integer expected_done_count,
        input integer expected_barrier_count,
        input logic expected_bank
    );
        integer cycles;
    begin
        cycles = 0;
        while (!complete_o && cycles < TIMEOUT_CYCLES) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end

        if (!complete_o)
            $fatal(1, "board self-test timed out after %0d cycles", cycles);
        if (!pass_o || fail_o)
            $fatal(1,
                "board self-test failed addr=%0d observed=%0d expected=%0d",
                mismatch_addr_o, mismatch_observed_o, mismatch_expected_o);
        if (running_o || core_busy_o)
            $fatal(1, "board self-test remained busy after completion");
        if (barrier_count != expected_barrier_count)
            $fatal(1,
                "expected barrier_count=%0d observed=%0d",
                expected_barrier_count, barrier_count);
        if (core_active_bank_o !== expected_bank)
            $fatal(1,
                "expected active bank=%0d observed=%0d",
                expected_bank, core_active_bank_o);

        // The monitor observes the registered done pulse on the following edge.
        @(posedge clk);
        #1;
        if (done_o)
            $fatal(1, "self-test done_o must be a one-cycle pulse");
        if (done_count != expected_done_count)
            $fatal(1,
                "expected done_count=%0d observed=%0d",
                expected_done_count, done_count);
    end
    endtask

    initial begin
        rst_n   = 1'b0;
        start_i = 1'b0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        if (running_o || complete_o || pass_o || fail_o)
            $fatal(1, "self-test did not reset to idle");
        if (core_active_bank_o !== 1'b0)
            $fatal(1, "coefficient bank did not reset to bank 0");

        pulse_start();
        wait_and_check(1, 7, 1'b1);
        $display("PASS: first ramp self-test completed from bank 0 to bank 1");

        pulse_start();
        wait_and_check(2, 14, 1'b0);
        $display("PASS: repeated ramp self-test completed from bank 1 to bank 0");

        $display(
            "PASS: board self-test verified two complete NTT runs and 512 output checks");
        $finish;
    end
endmodule
