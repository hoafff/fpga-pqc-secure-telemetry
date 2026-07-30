module ascon_permutation (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         start_i,
    input  logic [3:0]   rounds_i,
    input  logic [319:0] state_i,

    output logic         busy_o,
    output logic         done_o,
    output logic [319:0] state_o
);
    logic [319:0] state_q;
    logic [3:0]   rounds_q;
    logic [3:0]   round_index_q;
    logic [7:0]   round_constant;
    logic [319:0] round_state;

    function automatic logic [7:0] round_constant_at (
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0:  round_constant_at = 8'h3c;
                5'd1:  round_constant_at = 8'h2d;
                5'd2:  round_constant_at = 8'h1e;
                5'd3:  round_constant_at = 8'h0f;
                5'd4:  round_constant_at = 8'hf0;
                5'd5:  round_constant_at = 8'he1;
                5'd6:  round_constant_at = 8'hd2;
                5'd7:  round_constant_at = 8'hc3;
                5'd8:  round_constant_at = 8'hb4;
                5'd9:  round_constant_at = 8'ha5;
                5'd10: round_constant_at = 8'h96;
                5'd11: round_constant_at = 8'h87;
                5'd12: round_constant_at = 8'h78;
                5'd13: round_constant_at = 8'h69;
                5'd14: round_constant_at = 8'h5a;
                5'd15: round_constant_at = 8'h4b;
                default: round_constant_at = 8'h00;
            endcase
        end
    endfunction

    /*
     * Logic-equivalent to rtl/ascon/ascon_round.sv.
     * Keeping the round combinational logic local removes the u_round hierarchy
     * that Gowin reports as NL0002 "swept in optimizing".
     */
    function automatic logic [319:0] round_comb (
        input logic [319:0] s,
        input logic [7:0]   rc
    );
        logic [63:0] x0, x1, x2, x3, x4;
        logic [63:0] y0, y1, y2, y3, y4;
        begin
            x0 = s[63:0];
            x1 = s[127:64];
            x2 = s[191:128];
            x3 = s[255:192];
            x4 = s[319:256];

            x2[7:0] = x2[7:0] ^ rc;

            y0 = (x4 & x1) ^ x3 ^ (x2 & x1) ^ x2 ^
                 (x1 & x0) ^ x1 ^ x0;
            y1 = x4 ^ (x3 & x2) ^ (x3 & x1) ^ x3 ^
                 (x2 & x1) ^ x2 ^ x1 ^ x0;
            y2 = (x4 & x3) ^ x4 ^ x2 ^ x1 ^
                 64'hffff_ffff_ffff_ffff;
            y3 = (x4 & x0) ^ x4 ^ (x3 & x0) ^ x3 ^
                 x2 ^ x1 ^ x0;
            y4 = (x4 & x1) ^ x4 ^ x3 ^ (x1 & x0) ^ x1;

            round_comb[63:0] =
                y0 ^ ((y0 >> 19) | (y0 << 45)) ^
                     ((y0 >> 28) | (y0 << 36));
            round_comb[127:64] =
                y1 ^ ((y1 >> 61) | (y1 << 3)) ^
                     ((y1 >> 39) | (y1 << 25));
            round_comb[191:128] =
                y2 ^ ((y2 >> 1) | (y2 << 63)) ^
                     ((y2 >> 6) | (y2 << 58));
            round_comb[255:192] =
                y3 ^ ((y3 >> 10) | (y3 << 54)) ^
                     ((y3 >> 17) | (y3 << 47));
            round_comb[319:256] =
                y4 ^ ((y4 >> 7) | (y4 << 57)) ^
                     ((y4 >> 41) | (y4 << 23));
        end
    endfunction

    always_comb begin
        round_constant = round_constant_at(5'd16 - {1'b0, rounds_q} +
                                           {1'b0, round_index_q});
    end

    assign round_state = round_comb(state_q, round_constant);
    assign state_o = state_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q       <= '0;
            rounds_q      <= '0;
            round_index_q <= '0;
            busy_o        <= 1'b0;
            done_o        <= 1'b0;
        end else if (zeroize_i) begin
            state_q       <= '0;
            rounds_q      <= '0;
            round_index_q <= '0;
            busy_o        <= 1'b0;
            done_o        <= 1'b0;
        end else begin
            done_o <= 1'b0;

            if (start_i && !busy_o) begin
                state_q       <= state_i;
                rounds_q      <= rounds_i;
                round_index_q <= 4'd0;
                busy_o        <= 1'b1;
            end else if (busy_o) begin
                state_q <= round_state;

                if (round_index_q == rounds_q - 1'b1) begin
                    busy_o <= 1'b0;
                    done_o <= 1'b1;
                end else begin
                    round_index_q <= round_index_q + 1'b1;
                end
            end
        end
    end
endmodule
