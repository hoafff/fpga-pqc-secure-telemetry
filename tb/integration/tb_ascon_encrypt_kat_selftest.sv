`timescale 1ns/1ps

module tb_ascon_encrypt_kat_selftest;
    logic clk;
    logic rst_n;
    logic start;
    logic running;
    logic complete;
    logic done;
    logic pass;
    logic fail;
    logic core_busy;
    logic [5:0] mismatch_index;
    logic [7:0] mismatch_observed;
    logic [7:0] mismatch_expected;
    logic [15:0] core_error_code;

    ascon_encrypt_kat_selftest dut (
        .clk_i                 (clk),
        .rst_ni                (rst_n),
        .start_i               (start),
        .running_o             (running),
        .complete_o            (complete),
        .done_o                (done),
        .pass_o                (pass),
        .fail_o                (fail),
        .core_busy_o           (core_busy),
        .mismatch_index_o      (mismatch_index),
        .mismatch_observed_o   (mismatch_observed),
        .mismatch_expected_o   (mismatch_expected),
        .core_error_code_o     (core_error_code)
    );

    always #5 clk = ~clk;

    task automatic run_once;
        integer timeout_cycles;
        begin
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;

            timeout_cycles = 0;
            while (!done && timeout_cycles < 10000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end

            if (!done || !complete || !pass || fail) begin
                $display("FAIL: board KAT self-test pass=%b fail=%b complete=%b mismatch=%0d got=%02h expected=%02h error=%04h state=%0d",
                         pass, fail, complete, mismatch_index,
                         mismatch_observed, mismatch_expected, core_error_code,
                         dut.state_q);
                $fatal(1);
            end
            @(posedge clk);
        end
    endtask

    initial begin : watchdog
        #2_000_000;
        $display("FAIL: board self-test global timeout state=%0d running=%b busy=%b",
                 dut.state_q, running, core_busy);
        $fatal(1);
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_once();
        repeat (3) @(posedge clk);
        run_once();

        $display("PASS: Primer 20K Ascon KAT self-test runs repeatedly");
        $finish;
    end
endmodule
