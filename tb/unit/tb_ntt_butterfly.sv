`timescale 1ns/1ps

module tb_ntt_butterfly;
    localparam int unsigned Q = 3329;

    logic [15:0] a;
    logic [15:0] b;
    logic [15:0] zeta;
    logic [15:0] a_out;
    logic [15:0] b_out;

    integer unsigned a_rand;
    integer unsigned b_rand;
    integer unsigned zeta_rand;
    integer unsigned test_count;
    logic [31:0] prng;

    ntt_butterfly dut (
        .a_i(a),
        .b_i(b),
        .zeta_i(zeta),
        .a_o(a_out),
        .b_o(b_out)
    );

    task automatic check_case(
        input integer unsigned a_val,
        input integer unsigned b_val,
        input integer unsigned zeta_val
    );
        integer unsigned t_expected;
        integer unsigned a_expected;
        integer unsigned b_expected;
    begin
        a    = a_val;
        b    = b_val;
        zeta = zeta_val;
        #1;

        t_expected = (b_val * zeta_val) % Q;
        a_expected = (a_val + t_expected) % Q;
        b_expected = (a_val + Q - t_expected) % Q;
        test_count = test_count + 1;

        if (a_out !== a_expected[15:0])
            $fatal(1,
                "ntt_butterfly a_o failed: a=%0d b=%0d zeta=%0d got=%0d expected=%0d",
                a_val, b_val, zeta_val, a_out, a_expected);

        if (b_out !== b_expected[15:0])
            $fatal(1,
                "ntt_butterfly b_o failed: a=%0d b=%0d zeta=%0d got=%0d expected=%0d",
                a_val, b_val, zeta_val, b_out, b_expected);
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
        zeta       = '0;
        test_count = 0;
        prng       = 32'h13579bdf;

        check_case(0, 0, 0);
        check_case(0, Q - 1, Q - 1);
        check_case(Q - 1, Q - 1, Q - 1);
        check_case(1, 1, 1);
        check_case(100, 200, 300);
        check_case(1664, 1664, 1664);

        repeat (20000) begin
            prng_next();
            a_rand = prng % Q;
            prng_next();
            b_rand = prng % Q;
            prng_next();
            zeta_rand = prng % Q;
            check_case(a_rand, b_rand, zeta_rand);
        end

        $display("PASS: ntt_butterfly completed %0d checks", test_count);
        $finish;
    end
endmodule
