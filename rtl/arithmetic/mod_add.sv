module mod_add #(
    parameter int unsigned WIDTH = 16,
    parameter int unsigned MODULUS = 3329
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    output logic [WIDTH-1:0] y_o
);
    logic [WIDTH:0] sum_ext;
    logic [WIDTH:0] reduced_ext;
    localparam logic [WIDTH:0] MODULUS_EXT = {1'b0, MODULUS[WIDTH-1:0]};

    always_comb begin
        sum_ext = {1'b0, a_i} + {1'b0, b_i};

        if (sum_ext >= MODULUS_EXT)
            reduced_ext = sum_ext - MODULUS_EXT;
        else
            reduced_ext = sum_ext;

        y_o = reduced_ext[WIDTH-1:0];
    end
endmodule