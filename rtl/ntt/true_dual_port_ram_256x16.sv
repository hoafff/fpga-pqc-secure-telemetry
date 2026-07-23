module true_dual_port_ram_256x16 (
    input  logic        clk_i,

    input  logic        a_en_i,
    input  logic        a_we_i,
    input  logic [7:0]  a_addr_i,
    input  logic [15:0] a_wdata_i,
    output logic [15:0] a_rdata_o,

    input  logic        b_en_i,
    input  logic        b_we_i,
    input  logic [7:0]  b_addr_i,
    input  logic [15:0] b_wdata_i,
    output logic [15:0] b_rdata_o
);
    // Generic synchronous true-dual-port storage. There is intentionally no
    // array reset because resetting every word prevents block-RAM inference on
    // common FPGA toolchains. The caller must load all live coefficients before
    // starting a transform.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [15:0] memory [0:255];

    always_ff @(posedge clk_i) begin
        if (a_en_i) begin
            if (a_we_i)
                memory[a_addr_i] <= a_wdata_i;
            else
                a_rdata_o <= memory[a_addr_i];
        end

        if (b_en_i) begin
            if (b_we_i)
                memory[b_addr_i] <= b_wdata_i;
            else
                b_rdata_o <= memory[b_addr_i];
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (a_en_i && a_we_i && b_en_i && b_we_i) begin
            assert (a_addr_i != b_addr_i)
                else $error(
                    "true_dual_port_ram_256x16: simultaneous writes to address %0d",
                    a_addr_i);
        end
    end
`endif
endmodule
