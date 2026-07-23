module mod_sub #(
    parameter int unsigned WIDTH = 16,
    parameter int unsigned MODULUS = 3329
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    output logic [WIDTH-1:0] y_o
);
    always_comb begin
        if (a_i >= b_i)
            y_o = a_i - b_i;
        else
            y_o = a_i + MODULUS - b_i;
    end
endmodule
