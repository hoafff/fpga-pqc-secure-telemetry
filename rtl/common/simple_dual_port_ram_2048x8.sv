// Generic BRAM-oriented byte memory used by the deployment BTP endpoint.
// The memory array is intentionally not reset; validity/length metadata owns
// initialization. This preserves block-RAM inference on Gowin devices.
module simple_dual_port_ram_2048x8 (
    input  logic        clk_i,

    input  logic        we_i,
    input  logic [10:0] waddr_i,
    input  logic [7:0]  wdata_i,

    input  logic        re_i,
    input  logic [10:0] raddr_i,
    output logic        rvalid_o,
    output logic [7:0]  rdata_o
);
    logic [7:0] mem [0:2047];

    always_ff @(posedge clk_i) begin
        if (we_i)
            mem[waddr_i] <= wdata_i;

        rvalid_o <= re_i;
        if (re_i)
            rdata_o <= mem[raddr_i];
    end
endmodule
