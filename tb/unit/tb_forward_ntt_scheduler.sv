`timescale 1ns/1ps

module tb_forward_ntt_scheduler;
    localparam integer ENTRY_COUNT = 896;

    logic clk;
    logic rst_n;
    logic start_i;

    logic       busy_o;
    logic       valid_o;
    logic       done_o;
    logic [2:0] stage_o;
    logic [7:0] length_o;
    logic [7:0] left_addr_o;
    logic [7:0] right_addr_o;
    logic [6:0] zeta_addr_o;
    logic       group_first_o;
    logic       group_last_o;
    logic       stage_first_o;
    logic       stage_last_o;
    logic       transform_first_o;
    logic       transform_last_o;

    logic [39:0] expected [0:ENTRY_COUNT-1];

    integer expected_index;
    integer valid_count;
    integer done_count;
    integer run_number;

    forward_ntt_scheduler dut (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .start_i           (start_i),
        .busy_o            (busy_o),
        .valid_o           (valid_o),
        .done_o            (done_o),
        .stage_o           (stage_o),
        .length_o          (length_o),
        .left_addr_o       (left_addr_o),
        .right_addr_o      (right_addr_o),
        .zeta_addr_o       (zeta_addr_o),
        .group_first_o     (group_first_o),
        .group_last_o      (group_last_o),
        .stage_first_o     (stage_first_o),
        .stage_last_o      (stage_last_o),
        .transform_first_o (transform_first_o),
        .transform_last_o  (transform_last_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic assert_reset;
    begin
        @(negedge clk);
        rst_n   = 1'b0;
        start_i = 1'b0;
        repeat (2) @(negedge clk);
    end
    endtask

    task automatic release_reset;
    begin
        @(negedge clk);
        rst_n = 1'b1;
    end
    endtask

    task automatic pulse_start;
    begin
        @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
    end
    endtask

    task automatic wait_for_completed_run;
    begin
        wait (done_o === 1'b1);
        repeat (2) @(negedge clk);
        #1;

        if (expected_index != ENTRY_COUNT)
            $fatal(1,
                "run %0d: expected %0d transactions, observed %0d",
                run_number, ENTRY_COUNT, expected_index);
        if (valid_count != ENTRY_COUNT)
            $fatal(1,
                "run %0d: valid count mismatch %0d",
                run_number, valid_count);
        if (done_count != 1)
            $fatal(1,
                "run %0d: done pulse count mismatch %0d",
                run_number, done_count);
    end
    endtask

    always @(negedge clk) begin
        logic [39:0] actual;

        #1;
        if (!rst_n) begin
            expected_index = 0;
            valid_count    = 0;
            done_count     = 0;
        end else begin
            if (busy_o !== valid_o)
                $fatal(1,
                    "busy/valid mismatch: busy=%0b valid=%0b",
                    busy_o, valid_o);

            if (valid_o) begin
                if (expected_index >= ENTRY_COUNT)
                    $fatal(1, "scheduler emitted more than 896 transactions");

                actual = {
                    stage_o,
                    length_o,
                    left_addr_o,
                    right_addr_o,
                    zeta_addr_o,
                    group_first_o,
                    group_last_o,
                    stage_first_o,
                    stage_last_o,
                    transform_first_o,
                    transform_last_o
                };

                if (actual !== expected[expected_index])
                    $fatal(1,
                        "schedule mismatch at index=%0d got=%010h expected=%010h",
                        expected_index, actual, expected[expected_index]);

                expected_index = expected_index + 1;
                valid_count    = valid_count + 1;
            end else begin
                if ({stage_o, length_o, left_addr_o, right_addr_o,
                     zeta_addr_o, group_first_o, group_last_o,
                     stage_first_o, stage_last_o,
                     transform_first_o, transform_last_o} !== '0)
                    $fatal(1, "scheduler outputs must be zero while invalid");
            end

            if (done_o) begin
                done_count = done_count + 1;
                if (valid_o)
                    $fatal(1, "done_o must not overlap valid_o");
                if (expected_index != ENTRY_COUNT)
                    $fatal(1,
                        "done_o asserted early at transaction %0d",
                        expected_index);
            end
        end
    end

    initial begin
        $readmemh("build/sim/forward_ntt_schedule.hex", expected);

        rst_n          = 1'b0;
        start_i        = 1'b0;
        expected_index = 0;
        valid_count    = 0;
        done_count     = 0;
        run_number     = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Full run. Extra start pulses while busy must be ignored.
        run_number = 1;
        pulse_start();
        repeat (137) @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
        wait_for_completed_run();

        // Abort a run with synchronous reset and verify clean restart.
        assert_reset();
        release_reset();
        run_number = 2;
        pulse_start();
        repeat (211) @(negedge clk);
        assert_reset();
        @(posedge clk);
        #1;
        if (busy_o || valid_o || done_o)
            $fatal(1, "reset did not abort the in-flight schedule");

        release_reset();
        run_number = 3;
        pulse_start();
        wait_for_completed_run();

        $display(
            "PASS: forward_ntt_scheduler completed two full 896-entry runs and one reset-aborted run");
        $finish;
    end
endmodule
