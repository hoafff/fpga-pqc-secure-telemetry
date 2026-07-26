module fpst_sync_bit #(
    parameter logic RESET_VALUE = 1'b0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic async_i,
    output logic sync_o
);
    (* syn_preserve = 1 *) logic sync_ff1_q;
    (* syn_preserve = 1 *) logic sync_ff2_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            sync_ff1_q <= RESET_VALUE;
            sync_ff2_q <= RESET_VALUE;
        end else begin
            sync_ff1_q <= async_i;
            sync_ff2_q <= sync_ff1_q;
        end
    end

    assign sync_o = sync_ff2_q;
endmodule
