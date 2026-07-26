module mlkem_basemul_sequential (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [15:0] a0_i,
    input  logic [15:0] a1_i,
    input  logic [15:0] b0_i,
    input  logic [15:0] b1_i,
    input  logic [15:0] gamma_i,
    output logic        busy_o,
    output logic        done_o,
    output logic [15:0] c0_o,
    output logic [15:0] c1_o
);
    // FIPS 203 Algorithm 12 BaseCaseMultiply:
    //   c0 = a0*b0 + a1*b1*gamma mod q
    //   c1 = a0*b1 + a1*b0       mod q
    // One modular multiplier is reused for all five products.

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_MUL_A0B0, ST_WAIT_A0B0,
        ST_MUL_A1B1, ST_WAIT_A1B1,
        ST_MUL_GAMMA, ST_WAIT_GAMMA,
        ST_MUL_A0B1, ST_WAIT_A0B1,
        ST_MUL_A1B0, ST_WAIT_A1B0,
        ST_FINISH
    } state_t;

    state_t state_q;
    logic [15:0] a0_q, a1_q, b0_q, b1_q, gamma_q;
    logic [15:0] p00_q, p11_q, p11g_q, p01_q, p10_q;
    logic mul_valid_i, mul_valid_o;
    logic [15:0] mul_a, mul_b, mul_y;
    logic [15:0] c0_comb, c1_comb;

    assign busy_o = state_q != ST_IDLE;
    assign mul_valid_i = (state_q == ST_MUL_A0B0) ||
                         (state_q == ST_MUL_A1B1) ||
                         (state_q == ST_MUL_GAMMA) ||
                         (state_q == ST_MUL_A0B1) ||
                         (state_q == ST_MUL_A1B0);

    always_comb begin
        mul_a = 16'd0;
        mul_b = 16'd0;
        case (state_q)
            ST_MUL_A0B0: begin mul_a = a0_q; mul_b = b0_q; end
            ST_MUL_A1B1: begin mul_a = a1_q; mul_b = b1_q; end
            ST_MUL_GAMMA: begin mul_a = p11_q; mul_b = gamma_q; end
            ST_MUL_A0B1: begin mul_a = a0_q; mul_b = b1_q; end
            ST_MUL_A1B0: begin mul_a = a1_q; mul_b = b0_q; end
            default: begin end
        endcase
    end

    mod_mul_3329_pipe u_mul (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .valid_i(mul_valid_i), .a_i(mul_a), .b_i(mul_b),
        .valid_o(mul_valid_o), .y_o(mul_y)
    );

    mod_add #(.WIDTH(16), .MODULUS(3329)) u_c0_add (
        .a_i(p00_q), .b_i(p11g_q), .y_o(c0_comb)
    );
    mod_add #(.WIDTH(16), .MODULUS(3329)) u_c1_add (
        .a_i(p01_q), .b_i(p10_q), .y_o(c1_comb)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            a0_q <= '0; a1_q <= '0; b0_q <= '0; b1_q <= '0; gamma_q <= '0;
            p00_q <= '0; p11_q <= '0; p11g_q <= '0; p01_q <= '0; p10_q <= '0;
            c0_o <= '0; c1_o <= '0;
            done_o <= 1'b0;
        end else begin
            done_o <= 1'b0;
            case (state_q)
                ST_IDLE: begin
                    if (start_i) begin
                        a0_q <= a0_i; a1_q <= a1_i;
                        b0_q <= b0_i; b1_q <= b1_i; gamma_q <= gamma_i;
                        state_q <= ST_MUL_A0B0;
                    end
                end
                ST_MUL_A0B0: state_q <= ST_WAIT_A0B0;
                ST_WAIT_A0B0: if (mul_valid_o) begin p00_q <= mul_y; state_q <= ST_MUL_A1B1; end
                ST_MUL_A1B1: state_q <= ST_WAIT_A1B1;
                ST_WAIT_A1B1: if (mul_valid_o) begin p11_q <= mul_y; state_q <= ST_MUL_GAMMA; end
                ST_MUL_GAMMA: state_q <= ST_WAIT_GAMMA;
                ST_WAIT_GAMMA: if (mul_valid_o) begin p11g_q <= mul_y; state_q <= ST_MUL_A0B1; end
                ST_MUL_A0B1: state_q <= ST_WAIT_A0B1;
                ST_WAIT_A0B1: if (mul_valid_o) begin p01_q <= mul_y; state_q <= ST_MUL_A1B0; end
                ST_MUL_A1B0: state_q <= ST_WAIT_A1B0;
                ST_WAIT_A1B0: if (mul_valid_o) begin p10_q <= mul_y; state_q <= ST_FINISH; end
                ST_FINISH: begin
                    c0_o <= c0_comb;
                    c1_o <= c1_comb;
                    done_o <= 1'b1;
                    state_q <= ST_IDLE;
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && start_i && state_q == ST_IDLE) begin
            assert (a0_i < 3329 && a1_i < 3329 && b0_i < 3329 && b1_i < 3329 && gamma_i < 3329)
                else $error("mlkem_basemul_sequential: non-canonical input");
        end
    end
`endif
endmodule
