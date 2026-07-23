`timescale 1ns/1ps

module tb_ntt_butterfly_pipe;
    localparam int unsigned Q = 3329;
    localparam int unsigned MAX_EXPECTED = 4096;

    logic        clk;
    logic        rst_n;
    logic        valid_i;
    logic [15:0] a_i;
    logic [15:0] b_i;
    logic [15:0] zeta_i;
    logic        valid_o;
    logic [15:0] a_o;
    logic [15:0] b_o;

    logic expected_valid_s1;
    logic expected_valid_s2;
    logic expected_valid_s3;
    logic expected_valid_now;

    logic [15:0] expected_a [0:MAX_EXPECTED-1];
    logic [15:0] expected_b [0:MAX_EXPECTED-1];

    integer unsigned head;
    integer unsigned tail;
    integer unsigned sent_count;
    integer unsigned recv_count;
    integer unsigned i;
    logic [31:0] prng;

    ntt_butterfly_pipe dut (
        .clk_i   (clk),
        .rst_ni  (rst_n),
        .valid_i (valid_i),
        .a_i     (a_i),
        .b_i     (b_i),
        .zeta_i  (zeta_i),
        .valid_o (valid_o),
        .a_o     (a_o),
        .b_o     (b_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic drive_case(
        input logic drive_valid,
        input integer unsigned a_val,
        input integer unsigned b_val,
        input integer unsigned zeta_val
    );
        integer unsigned t_expected;
    begin
        @(negedge clk);
        valid_i = drive_valid;
        a_i     = a_val[15:0];
        b_i     = b_val[15:0];
        zeta_i  = zeta_val[15:0];

        if (drive_valid) begin
            if (tail >= MAX_EXPECTED)
                $fatal(1, "tb_ntt_butterfly_pipe: expected queue overflow");

            t_expected       = (b_val * zeta_val) % Q;
            expected_a[tail] = (a_val + t_expected) % Q;
            expected_b[tail] = (a_val + Q - t_expected) % Q;
            tail             = tail + 1;
            sent_count       = sent_count + 1;
        end
    end
    endtask

    task automatic prng_next;
    begin
        prng = prng ^ (prng << 13);
        prng = prng ^ (prng >> 17);
        prng = prng ^ (prng << 5);
    end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            expected_valid_s1  = 1'b0;
            expected_valid_s2  = 1'b0;
            expected_valid_s3  = 1'b0;
            expected_valid_now = 1'b0;
            head = 0;
            tail = 0;
            sent_count = 0;
            recv_count = 0;
        end else begin
            // valid_o corresponds to valid_i from three earlier rising edges.
            expected_valid_now = expected_valid_s3;
            expected_valid_s3  = expected_valid_s2;
            expected_valid_s2  = expected_valid_s1;
            expected_valid_s1  = valid_i;

            #1;

            if (valid_o !== expected_valid_now)
                $fatal(1,
                    "ntt_butterfly_pipe valid mismatch: got=%0b expected=%0b",
                    valid_o, expected_valid_now);

            if (expected_valid_now) begin
                if (head >= tail)
                    $fatal(1, "ntt_butterfly_pipe produced an unexpected output");

                if (a_o !== expected_a[head])
                    $fatal(1,
                        "ntt_butterfly_pipe a_o mismatch: index=%0d got=%0d expected=%0d",
                        head, a_o, expected_a[head]);

                if (b_o !== expected_b[head])
                    $fatal(1,
                        "ntt_butterfly_pipe b_o mismatch: index=%0d got=%0d expected=%0d",
                        head, b_o, expected_b[head]);

                head = head + 1;
                recv_count = recv_count + 1;
            end
        end
    end

    initial begin
        rst_n   = 1'b0;
        valid_i = 1'b0;
        a_i     = '0;
        b_i     = '0;
        zeta_i  = '0;
        prng    = 32'h13579bdf;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Boundary and representative cases.
        drive_case(1'b1, 0, 0, 0);
        drive_case(1'b1, 1, 1, 1);
        drive_case(1'b1, Q - 1, Q - 1, Q - 1);
        drive_case(1'b0, 0, 0, 0);
        drive_case(1'b1, 100, 200, 300);
        drive_case(1'b1, 1664, 1664, 1664);

        // Continuous stream verifies one butterfly per cycle throughput.
        for (i = 0; i < 128; i = i + 1)
            drive_case(
                1'b1,
                (i * 13 + 1) % Q,
                (i * 17 + 2) % Q,
                (i * 31 + 3) % Q
            );

        // Reproducible pseudo-random traffic with bubbles.
        for (i = 0; i < 1000; i = i + 1) begin
            integer unsigned a_rand;
            integer unsigned b_rand;
            integer unsigned zeta_rand;

            prng_next();
            a_rand = prng % Q;
            prng_next();
            b_rand = prng % Q;
            prng_next();
            zeta_rand = prng % Q;

            if (prng[3:0] == 4'h0)
                drive_case(1'b0, 0, 0, 0);
            else
                drive_case(1'b1, a_rand, b_rand, zeta_rand);
        end

        // Drain the pipeline.
        repeat (8)
            drive_case(1'b0, 0, 0, 0);

        @(negedge clk);
        if (head != tail)
            $fatal(1,
                "tb_ntt_butterfly_pipe did not drain: head=%0d tail=%0d",
                head, tail);

        $display(
            "PASS: ntt_butterfly_pipe sent=%0d received=%0d",
            sent_count, recv_count);
        $finish;
    end
endmodule
