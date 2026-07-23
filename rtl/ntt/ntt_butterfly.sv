module ntt_butterfly (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] zeta_i,
    output logic [15:0] a_o,
    output logic [15:0] b_o
);
    // Forward Cooley-Tukey butterfly over Z_q, q = 3329:
    //   t   = b * zeta mod q
    //   a_o = a + t mod q
    //   b_o = a - t mod q
    // Inputs and outputs use canonical representatives in [0, 3328].

    logic [15:0] t;

    mod_mul_3329 u_mod_mul (
        .a_i(b_i),
        .b_i(zeta_i),
        .y_o(t)
    );

    mod_add #(
        .WIDTH(16),
        .MODULUS(3329)
    ) u_mod_add (
        .a_i(a_i),
        .b_i(t),
        .y_o(a_o)
    );

    mod_sub #(
        .WIDTH(16),
        .MODULUS(3329)
    ) u_mod_sub (
        .a_i(a_i),
        .b_i(t),
        .y_o(b_o)
    );
endmodule
