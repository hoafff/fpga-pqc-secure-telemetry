module mod_sub #(
    parameter int unsigned WIDTH = 16,
    parameter int unsigned MODULUS = 3329
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    output logic [WIDTH-1:0] y_o
);
    logic [WIDTH:0] diff_ext;
    localparam logic [WIDTH:0] MODULUS_EXT = {1'b0, MODULUS[WIDTH-1:0]};

    always_comb begin
        if (a_i >= b_i)
            diff_ext = {1'b0, a_i} - {1'b0, b_i};
        else
            diff_ext = {1'b0, a_i} + MODULUS_EXT - {1'b0, b_i};

        y_o = diff_ext[WIDTH-1:0];
    end
endmodule
