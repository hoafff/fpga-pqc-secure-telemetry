`timescale 1ns/1ps

module tb_mod_mul_3329;
    localparam int unsigned Q = 3329;

    logic [15:0] a;
    logic [15:0] b;
    logic [15:0] y;

    integer unsigned ai;
    integer unsigned bi;
    integer unsigned a_rand;
    integer unsigned b_rand;
    integer unsigned test_count;
    logic [31:0] prng;

    mod_mul_3329 dut (
        .a_i(a),
        .b_i(b),
        .y_o(y)
    );

    task automatic check_case(
        input integer unsigned a_val,
        input integer unsigned b_val
    );
        integer unsigned expected;
    begin
        a = a_val;
        b = b_val;
        #1;

        expected = (a_val * b_val) % Q;
        test_count = test_count + 1;

        if (y !== expected[15:0])
            $fatal(1,
                "mod_mul_3329 failed: a=%0d b=%0d got=%0d expected=%0d",
                a_val, b_val, y, expected);
    end
    endtask

    task automatic prng_next;
    begin
        prng = prng ^ (prng << 13);
        prng = prng ^ (prng >> 17);
        prng = prng ^ (prng << 5);
    end
    endtask

    initial begin
        a          = '0;
        b          = '0;
        test_count = 0;
        prng       = 32'h6d2b79f5;

        // Boundary and representative values.
        check_case(0, 0);
        check_case(0, Q - 1);
        check_case(1, 1);
        check_case(1, Q - 1);
        check_case(Q - 1, Q - 1);
        check_case(1664, 1664);
        check_case(1234, 2345);

        // Deterministic coverage grid across the complete canonical range.
        for (ai = 0; ai < Q; ai = ai + 17)
            for (bi = 0; bi < Q; bi = bi + 31)
                check_case(ai, bi);

        // Reproducible pseudo-random cases.
        repeat (10000) begin
            prng_next();
            a_rand = prng % Q;
            prng_next();
            b_rand = prng % Q;
            check_case(a_rand, b_rand);
        end

        $display("PASS: mod_mul_3329 completed %0d checks", test_count);
        $finish;
    end
endmodule
