module mod_add #(
    parameter int unsigned WIDTH = 16,
    parameter int unsigned MODULUS = 3329
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    output logic [WIDTH-1:0] y_o
);
    logic [WIDTH:0] sum_ext;

    always_comb begin
        sum_ext = {1'b0, a_i} + {1'b0, b_i};

        if (sum_ext >= MODULUS)
            y_o = sum_ext - MODULUS;
        else
            y_o = sum_ext[WIDTH-1:0];
    end
endmodule
