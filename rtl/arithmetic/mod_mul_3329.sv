module mod_mul_3329 (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    output logic [15:0] y_o
);
    // ML-KEM modulus q = 3329.
    // Correctness-first combinational Barrett reducer for canonical inputs
    // 0 <= a_i, b_i < 3329.
    //
    // mu = floor(2^24 / 3329) = 5039
    // q_hat = floor((x * mu) / 2^24)
    // r = x - q_hat*q; for x <= (q-1)^2, one correction is enough.

    localparam logic [11:0] Q            = 12'd3329;
    localparam logic [12:0] BARRETT_MU   = 13'd5039;
    localparam int unsigned BARRETT_SHIFT = 24;

    logic [31:0] product;
    logic [44:0] scaled_product;
    logic [20:0] quotient_estimate;
    logic [32:0] quotient_times_q;
    logic [32:0] remainder;

    always_comb begin
        product           = a_i * b_i;
        scaled_product    = product * BARRETT_MU;
        quotient_estimate = scaled_product >> BARRETT_SHIFT;
        quotient_times_q  = quotient_estimate * Q;
        remainder         = {1'b0, product} - quotient_times_q;

        if (remainder >= Q)
            y_o = remainder - Q;
        else
            y_o = remainder[15:0];
    end
endmodule
