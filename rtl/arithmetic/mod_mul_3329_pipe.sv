module mod_mul_3329_pipe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    output logic        valid_o,
    output logic [15:0] y_o
);
    // Three registered stages, one result per cycle after the pipeline fills.
    // Contract: valid inputs are canonical ML-KEM coefficients in [0, 3328].
    // Arithmetic:
    //   product = a_i * b_i
    //   q_hat   = floor(product * floor(2^24 / 3329) / 2^24)
    //   y_o     = product - q_hat*3329, followed by one correction.

    localparam logic [11:0] Q             = 12'd3329;
    localparam logic [12:0] BARRETT_MU    = 13'd5039;
    localparam int unsigned BARRETT_SHIFT = 24;

    logic        valid_s1;
    logic        valid_s2;
    logic [31:0] product_s1;
    logic [31:0] product_s2;
    logic [44:0] scaled_s2;

    logic [20:0] quotient_comb;
    logic [32:0] quotient_times_q_comb;
    logic [32:0] remainder_comb;
    logic [15:0] reduced_comb;

    always_comb begin
        quotient_comb         = scaled_s2 >> BARRETT_SHIFT;
        quotient_times_q_comb = quotient_comb * Q;
        remainder_comb        = {1'b0, product_s2} - quotient_times_q_comb;

        if (remainder_comb >= Q)
            reduced_comb = remainder_comb - Q;
        else
            reduced_comb = remainder_comb[15:0];
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            valid_s1  <= 1'b0;
            valid_s2  <= 1'b0;
            valid_o   <= 1'b0;
            product_s1 <= '0;
            product_s2 <= '0;
            scaled_s2  <= '0;
            y_o         <= '0;
        end else begin
            valid_s1 <= valid_i;
            valid_s2 <= valid_s1;
            valid_o  <= valid_s2;

            if (valid_i)
                product_s1 <= a_i * b_i;

            if (valid_s1) begin
                product_s2 <= product_s1;
                scaled_s2  <= product_s1 * BARRETT_MU;
            end

            if (valid_s2)
                y_o <= reduced_comb;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && valid_i) begin
            assert (a_i < Q)
                else $error("mod_mul_3329_pipe: a_i is not canonical: %0d", a_i);
            assert (b_i < Q)
                else $error("mod_mul_3329_pipe: b_i is not canonical: %0d", b_i);
        end
    end
`endif
endmodule
