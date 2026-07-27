module fpst_ms_tick #(
    parameter integer CLK_HZ = 27_000_000
) (
    input  logic clk_i,
    input  logic rst_ni,
    output logic tick_ms_o
);
    localparam integer CYCLES_PER_MS = CLK_HZ / 1000;
    localparam integer COUNT_W = (CYCLES_PER_MS <= 1) ? 1 : $clog2(CYCLES_PER_MS);

    logic [COUNT_W-1:0] count_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count_q   <= '0;
            tick_ms_o <= 1'b0;
        end else begin
            tick_ms_o <= 1'b0;
            if (CYCLES_PER_MS <= 1) begin
                count_q   <= '0;
                tick_ms_o <= 1'b1;
            end else if (count_q == CYCLES_PER_MS - 1) begin
                count_q   <= '0;
                tick_ms_o <= 1'b1;
            end else begin
                count_q <= count_q + 1'b1;
            end
        end
    end
endmodule
