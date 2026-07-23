module ntt_butterfly_pipe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] zeta_i,
    output logic        valid_o,
    output logic [15:0] a_o,
    output logic [15:0] b_o
);
    // Pipelined forward Cooley-Tukey butterfly over Z_q, q = 3329:
    //   t   = b_i * zeta_i mod q
    //   a_o = a_i + t mod q
    //   b_o = a_i - t mod q
    //
    // The multiplier has three registered stages. The final modular
    // add/sub results are registered in this module. The interface accepts
    // one transaction per cycle and preserves input order.

    localparam int unsigned WIDTH   = 16;
    localparam int unsigned MODULUS = 3329;

    logic [15:0] a_s1;
    logic [15:0] a_s2;
    logic [15:0] a_s3;

    logic        mul_valid;
    logic [15:0] t_mul;
    logic [15:0] add_comb;
    logic [15:0] sub_comb;

    mod_mul_3329_pipe u_mod_mul_pipe (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (valid_i),
        .a_i     (b_i),
        .b_i     (zeta_i),
        .valid_o (mul_valid),
        .y_o     (t_mul)
    );

    mod_add #(
        .WIDTH   (WIDTH),
        .MODULUS (MODULUS)
    ) u_mod_add (
        .a_i (a_s3),
        .b_i (t_mul),
        .y_o (add_comb)
    );

    mod_sub #(
        .WIDTH   (WIDTH),
        .MODULUS (MODULUS)
    ) u_mod_sub (
        .a_i (a_s3),
        .b_i (t_mul),
        .y_o (sub_comb)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            a_s1    <= '0;
            a_s2    <= '0;
            a_s3    <= '0;
            valid_o <= 1'b0;
            a_o     <= '0;
            b_o     <= '0;
        end else begin
            // Delay a_i by the same three register stages as the multiplier.
            // Data shifts every cycle; valid_o marks which cycles are meaningful.
            a_s1 <= a_i;
            a_s2 <= a_s1;
            a_s3 <= a_s2;

            valid_o <= mul_valid;

            if (mul_valid) begin
                a_o <= add_comb;
                b_o <= sub_comb;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && valid_i) begin
            assert (a_i < MODULUS)
                else $error("ntt_butterfly_pipe: a_i is not canonical: %0d", a_i);
            assert (b_i < MODULUS)
                else $error("ntt_butterfly_pipe: b_i is not canonical: %0d", b_i);
            assert (zeta_i < MODULUS)
                else $error("ntt_butterfly_pipe: zeta_i is not canonical: %0d", zeta_i);
        end
    end
`endif
endmodule
