module ascon_round (
    input  logic [319:0] state_i,
    input  logic [7:0]   round_constant_i,
    output logic [319:0] state_o
);
    logic [63:0] x0;
    logic [63:0] x1;
    logic [63:0] x2;
    logic [63:0] x3;
    logic [63:0] x4;

    logic [63:0] y0;
    logic [63:0] y1;
    logic [63:0] y2;
    logic [63:0] y3;
    logic [63:0] y4;

    function automatic logic [63:0] rotr64 (
        input logic [63:0] value,
        input integer      amount
    );
        rotr64 = (value >> amount) | (value << (64 - amount));
    endfunction

    always_comb begin
        x0 = state_i[63:0];
        x1 = state_i[127:64];
        x2 = state_i[191:128];
        x3 = state_i[255:192];
        x4 = state_i[319:256];

        // pC: the NIST round constant is XORed into the least-significant
        // byte of S2 in the SP 800-232 little-endian representation.
        x2[7:0] = x2[7:0] ^ round_constant_i;

        // pS: 64 parallel copies of the 5-bit Ascon S-box, expressed in
        // bit-sliced Boolean form.
        y0 = (x4 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^
             (x1 & x0) ^ x1 ^ x0;
        y1 = x4 ^ (x3 & x2) ^ (x3 & x1) ^ x3 ^
             (x2 & x1) ^ x2 ^ x1 ^ x0;
        y2 = (x4 & x3) ^ x4 ^ x2 ^ x1 ^ 64'hffff_ffff_ffff_ffff;
        y3 = (x4 & x0) ^ x4 ^ (x3 & x0) ^ x3 ^ x2 ^ x1 ^ x0;
        y4 = (x4 & x1) ^ x4 ^ x3 ^ (x1 & x0) ^ x1;

        // pL: word-wise linear diffusion.
        state_o[63:0]    = y0 ^ rotr64(y0, 19) ^ rotr64(y0, 28);
        state_o[127:64]  = y1 ^ rotr64(y1, 61) ^ rotr64(y1, 39);
        state_o[191:128] = y2 ^ rotr64(y2, 1)  ^ rotr64(y2, 6);
        state_o[255:192] = y3 ^ rotr64(y3, 10) ^ rotr64(y3, 17);
        state_o[319:256] = y4 ^ rotr64(y4, 7)  ^ rotr64(y4, 41);
    end
endmodule
