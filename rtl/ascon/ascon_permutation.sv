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

    always_comb begin
        round_constant = round_constant_at(5'd16 - {1'b0, rounds_q} +
                                           {1'b0, round_index_q});
    end

    ascon_round u_round (
        .state_i          (state_q),
        .round_constant_i (round_constant),
        .state_o          (round_state)
    );

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
