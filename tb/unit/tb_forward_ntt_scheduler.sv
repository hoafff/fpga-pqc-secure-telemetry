`timescale 1ns/1ps

module tb_forward_ntt_scheduler;
    localparam integer ENTRY_COUNT = 896;

    logic clk;
    logic rst_n;
    logic start_i;
    logic ready_i;

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
    logic [39:0] held_transaction;
    logic        stall_active;
    logic        random_stall_enable;
    logic [31:0] lfsr;

    integer expected_index;
    integer accepted_count;
    integer done_count;
    integer stall_cycle_count;
    integer run_number;

    forward_ntt_scheduler dut (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .start_i           (start_i),
        .ready_i           (ready_i),
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

    // ready_i is updated immediately after each rising edge and is therefore
    // stable for the complete cycle before the next scheduler handshake.
    always @(posedge clk) begin
        if (!rst_n) begin
            ready_i <= 1'b1;
            lfsr    <= 32'h6d2b79f5;
        end else if (random_stall_enable) begin
            ready_i <= lfsr[0] | lfsr[5];
            lfsr <= {
                lfsr[30:0],
                lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]
            };
        end else begin
            ready_i <= 1'b1;
        end
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
                "run %0d: expected %0d transactions, accepted %0d",
                run_number, ENTRY_COUNT, expected_index);
        if (accepted_count != ENTRY_COUNT)
            $fatal(1,
                "run %0d: accepted count mismatch %0d",
                run_number, accepted_count);
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
            expected_index    = 0;
            accepted_count    = 0;
            done_count        = 0;
            stall_cycle_count = 0;
            stall_active      = 1'b0;
            held_transaction  = '0;
        end else begin
            if (busy_o !== valid_o)
                $fatal(1,
                    "busy/valid mismatch: busy=%0b valid=%0b",
                    busy_o, valid_o);

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

            if (valid_o && !ready_i) begin
                if (stall_active && (actual !== held_transaction))
                    $fatal(1,
                        "scheduler transaction changed while stalled: got=%010h held=%010h",
                        actual, held_transaction);

                held_transaction  = actual;
                stall_active      = 1'b1;
                stall_cycle_count = stall_cycle_count + 1;
            end else begin
                stall_active = 1'b0;
            end

            if (valid_o && ready_i) begin
                if (expected_index >= ENTRY_COUNT)
                    $fatal(1, "scheduler accepted more than 896 transactions");

                if (actual !== expected[expected_index])
                    $fatal(1,
                        "schedule mismatch at index=%0d got=%010h expected=%010h",
                        expected_index, actual, expected[expected_index]);

                expected_index = expected_index + 1;
                accepted_count = accepted_count + 1;
            end else if (!valid_o) begin
                if (actual !== '0)
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

        rst_n               = 1'b0;
        start_i             = 1'b0;
        random_stall_enable = 1'b0;
        expected_index      = 0;
        accepted_count      = 0;
        done_count          = 0;
        stall_cycle_count   = 0;
        stall_active        = 1'b0;
        held_transaction    = '0;
        run_number          = 0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Full-rate run. Extra start pulses while busy must be ignored.
        run_number = 1;
        pulse_start();
        repeat (137) @(negedge clk);
        start_i = 1'b1;
        @(negedge clk);
        start_i = 1'b0;
        wait_for_completed_run();
        if (stall_cycle_count != 0)
            $fatal(1, "full-rate run unexpectedly stalled");

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

        // Complete a second run with deterministic random backpressure.
        release_reset();
        random_stall_enable = 1'b1;
        run_number = 3;
        pulse_start();
        wait_for_completed_run();
        random_stall_enable = 1'b0;
        if (stall_cycle_count == 0)
            $fatal(1, "backpressure run did not exercise any stalls");

        $display(
            "PASS: forward_ntt_scheduler verified full-rate, stalled, ignored-start, and reset-abort behavior");
        $finish;
    end
endmodule
