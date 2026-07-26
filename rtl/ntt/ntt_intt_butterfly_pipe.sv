module ntt_intt_butterfly_pipe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic        inverse_i,
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] zeta_i,
    output logic        valid_o,
    output logic [15:0] a_o,
    output logic [15:0] b_o
);
    // Shared butterfly for FIPS 203 Algorithms 9 and 10 over q = 3329.
    //
    // Forward NTT:
    //   t   = zeta * b
    //   a'  = a + t
    //   b'  = a - t
    //
    // Inverse NTT:
    //   s   = a + b
    //   d   = b - a
    //   a'  = s
    //   b'  = zeta * d
    //
    // All values are canonical representatives in [0, 3328]. One modular
    // multiplier is shared by both directions; the non-multiplied wing is
    // delayed to match the three registered multiplier stages.

    localparam int unsigned WIDTH   = 16;
    localparam int unsigned MODULUS = 3329;

    logic [15:0] add_ab;
    logic [15:0] sub_ba;
    logic [15:0] mul_operand;

    logic [15:0] base_s1, base_s2, base_s3;
    logic        inverse_s1, inverse_s2, inverse_s3;

    logic        mul_valid;
    logic [15:0] mul_result;
    logic [15:0] forward_add;
    logic [15:0] forward_sub;

    mod_add #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) u_inverse_sum (
        .a_i(a_i),
        .b_i(b_i),
        .y_o(add_ab)
    );

    mod_sub #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) u_inverse_difference (
        .a_i(b_i),
        .b_i(a_i),
        .y_o(sub_ba)
    );

    assign mul_operand = inverse_i ? sub_ba : b_i;

    mod_mul_3329_pipe u_mod_mul (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .valid_i(valid_i),
        .a_i(mul_operand),
        .b_i(zeta_i),
        .valid_o(mul_valid),
        .y_o(mul_result)
    );

    mod_add #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) u_forward_add (
        .a_i(base_s3),
        .b_i(mul_result),
        .y_o(forward_add)
    );

    mod_sub #(
        .WIDTH(WIDTH),
        .MODULUS(MODULUS)
    ) u_forward_sub (
        .a_i(base_s3),
        .b_i(mul_result),
        .y_o(forward_sub)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            base_s1 <= '0;
            base_s2 <= '0;
            base_s3 <= '0;
            inverse_s1 <= 1'b0;
            inverse_s2 <= 1'b0;
            inverse_s3 <= 1'b0;
            valid_o <= 1'b0;
            a_o <= '0;
            b_o <= '0;
        end else begin
            // For inverse mode the delayed wing is the precomputed sum. For
            // forward mode it is the original a input.
            base_s1 <= inverse_i ? add_ab : a_i;
            base_s2 <= base_s1;
            base_s3 <= base_s2;
            inverse_s1 <= inverse_i;
            inverse_s2 <= inverse_s1;
            inverse_s3 <= inverse_s2;

            valid_o <= mul_valid;
            if (mul_valid) begin
                if (inverse_s3) begin
                    a_o <= base_s3;
                    b_o <= mul_result;
                end else begin
                    a_o <= forward_add;
                    b_o <= forward_sub;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && valid_i) begin
            assert (a_i < MODULUS)
                else $error("ntt_intt_butterfly_pipe: a_i out of range: %0d", a_i);
            assert (b_i < MODULUS)
                else $error("ntt_intt_butterfly_pipe: b_i out of range: %0d", b_i);
            assert (zeta_i < MODULUS)
                else $error("ntt_intt_butterfly_pipe: zeta_i out of range: %0d", zeta_i);
        end
    end
`endif
endmodule
