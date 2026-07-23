`timescale 1ns/1ps

module tb_mod_arithmetic;
    localparam int WIDTH   = 16;
    localparam int MODULUS = 3329;

    logic [WIDTH-1:0] a;
    logic [WIDTH-1:0] b;
    logic [WIDTH-1:0] add_y;
    logic [WIDTH-1:0] sub_y;

    mod_add #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) dut_add (
        .a_i(a),
        .b_i(b),
        .y_o(add_y)
    );

    mod_sub #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) dut_sub (
        .a_i(a),
        .b_i(b),
        .y_o(sub_y)
    );

    task automatic check_case(
        input int unsigned a_val,
        input int unsigned b_val
    );
        int unsigned expected_add;
        int unsigned expected_sub;
    begin
        a = a_val;
        b = b_val;
        #1;

        expected_add = (a_val + b_val) % MODULUS;
        expected_sub = (a_val + MODULUS - b_val) % MODULUS;

        assert (add_y == expected_add)
            else $fatal(1, "mod_add failed: a=%0d b=%0d got=%0d expected=%0d",
                        a_val, b_val, add_y, expected_add);

        assert (sub_y == expected_sub)
            else $fatal(1, "mod_sub failed: a=%0d b=%0d got=%0d expected=%0d",
                        a_val, b_val, sub_y, expected_sub);
    end
    endtask

    initial begin
        a = '0;
        b = '0;

        check_case(0, 0);
        check_case(1, 1);
        check_case(3328, 0);
        check_case(3328, 1);
        check_case(2000, 2000);
        check_case(100, 200);
        check_case(200, 100);
        check_case(3328, 3328);

        $display("PASS: modular arithmetic unit tests completed");
        $finish;
    end
endmodule
