module fpst_sync_rise_pulse (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic async_i,
    output logic pulse_o
);
    logic sync_w;
    logic sync_d_q;

    fpst_sync_bit #(
        .RESET_VALUE(1'b0)
    ) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .async_i(async_i),
        .sync_o (sync_w)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            sync_d_q <= 1'b0;
        end else begin
            sync_d_q <= sync_w;
        end
    end

    assign pulse_o = sync_w & ~sync_d_q;
endmodule
