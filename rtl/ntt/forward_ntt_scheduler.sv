module forward_ntt_scheduler (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       start_i,

    output logic       busy_o,
    output logic       valid_o,
    output logic       done_o,

    output logic [2:0] stage_o,
    output logic [7:0] length_o,
    output logic [7:0] left_addr_o,
    output logic [7:0] right_addr_o,
    output logic [6:0] zeta_addr_o,

    output logic       group_first_o,
    output logic       group_last_o,
    output logic       stage_first_o,
    output logic       stage_last_o,
    output logic       transform_first_o,
    output logic       transform_last_o
);
    // Schedule equivalent to the ML-KEM reference forward NTT:
    //
    //   k = 1
    //   for (len = 128; len >= 2; len >>= 1)
    //     for (start = 0; start < 256; start = j + len) {
    //       zeta = zetas[k++];
    //       for (j = start; j < start + len; j++)
    //         butterfly(j, j + len, zeta);
    //     }
    //
    // A start pulse launches exactly 896 consecutive valid transactions.
    // start_i is ignored while busy_o is asserted. The final transaction is
    // consumed on a rising edge with transform_last_o == 1; done_o pulses in
    // the immediately following cycle.

    localparam logic [8:0] N = 9'd256;

    logic       busy_q;
    logic [2:0] stage_q;
    logic [7:0] length_q;
    logic [7:0] start_q;
    logic [7:0] left_q;
    logic [6:0] zeta_q;

    logic [8:0] group_end_exclusive;
    logic [8:0] next_group_start;
    logic [8:0] right_addr_ext;
    logic       current_group_last;
    logic       current_stage_last;

    always_comb begin
        group_end_exclusive = {1'b0, start_q} + {1'b0, length_q};
        next_group_start =
            {1'b0, start_q} + ({1'b0, length_q} << 1);
        right_addr_ext = {1'b0, left_q} + {1'b0, length_q};

        current_group_last =
            ({1'b0, left_q} + 9'd1) == group_end_exclusive;
        current_stage_last = current_group_last && (next_group_start == N);
    end

    always_comb begin
        busy_o            = busy_q;
        valid_o           = busy_q;
        stage_o           = '0;
        length_o          = '0;
        left_addr_o       = '0;
        right_addr_o      = '0;
        zeta_addr_o       = '0;
        group_first_o     = 1'b0;
        group_last_o      = 1'b0;
        stage_first_o     = 1'b0;
        stage_last_o      = 1'b0;
        transform_first_o = 1'b0;
        transform_last_o  = 1'b0;

        if (busy_q) begin
            stage_o      = stage_q;
            length_o     = length_q;
            left_addr_o  = left_q;
            right_addr_o = right_addr_ext[7:0];
            zeta_addr_o  = zeta_q;

            group_first_o = left_q == start_q;
            group_last_o  = current_group_last;
            stage_first_o = (start_q == 8'd0) && (left_q == 8'd0);
            stage_last_o  = current_stage_last;

            transform_first_o =
                (stage_q == 3'd0) && stage_first_o;
            transform_last_o =
                (stage_q == 3'd6) && current_stage_last;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            busy_q   <= 1'b0;
            done_o   <= 1'b0;
            stage_q  <= '0;
            length_q <= '0;
            start_q  <= '0;
            left_q   <= '0;
            zeta_q   <= '0;
        end else begin
            done_o <= 1'b0;

            if (!busy_q) begin
                if (start_i) begin
                    busy_q   <= 1'b1;
                    stage_q  <= 3'd0;
                    length_q <= 8'd128;
                    start_q  <= 8'd0;
                    left_q   <= 8'd0;
                    zeta_q   <= 7'd1;
                end
            end else if (current_group_last) begin
                if (next_group_start < N) begin
                    start_q <= next_group_start[7:0];
                    left_q  <= next_group_start[7:0];
                    zeta_q  <= zeta_q + 7'd1;
                end else if (length_q != 8'd2) begin
                    stage_q  <= stage_q + 3'd1;
                    length_q <= length_q >> 1;
                    start_q  <= 8'd0;
                    left_q   <= 8'd0;
                    zeta_q   <= zeta_q + 7'd1;
                end else begin
                    busy_q <= 1'b0;
                    done_o <= 1'b1;
                end
            end else begin
                left_q <= left_q + 8'd1;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && busy_q) begin
            assert (stage_q <= 3'd6)
                else $error("forward_ntt_scheduler: invalid stage %0d", stage_q);
            assert ((length_q == 8'd128) || (length_q == 8'd64) ||
                    (length_q == 8'd32)  || (length_q == 8'd16) ||
                    (length_q == 8'd8)   || (length_q == 8'd4)  ||
                    (length_q == 8'd2))
                else $error(
                    "forward_ntt_scheduler: invalid length %0d", length_q);
            assert (right_addr_ext < N)
                else $error(
                    "forward_ntt_scheduler: right address out of range %0d",
                    right_addr_ext);
            assert (left_q < right_addr_ext[7:0])
                else $error(
                    "forward_ntt_scheduler: invalid pair %0d,%0d",
                    left_q, right_addr_ext);
            assert ((zeta_q >= 7'd1) && (zeta_q <= 7'd127))
                else $error(
                    "forward_ntt_scheduler: invalid zeta address %0d", zeta_q);
        end
    end
`endif
endmodule
