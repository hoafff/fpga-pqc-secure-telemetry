module coefficient_memory_256x16 (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic [15:0] host_rdata_o,

    input  logic [7:0]  left_raddr_i,
    input  logic [7:0]  right_raddr_i,
    output logic [15:0] left_rdata_o,
    output logic [15:0] right_rdata_o,

    input  logic        core_we_i,
    input  logic [7:0]  left_waddr_i,
    input  logic [7:0]  right_waddr_i,
    input  logic [15:0] left_wdata_i,
    input  logic [15:0] right_wdata_i
);
    // Correctness-first generic storage for 256 canonical q=3329 coefficients.
    //
    // The two asynchronous read ports and two synchronous write ports make the
    // NTT integration straightforward and deterministic in simulation. This
    // structure will normally map to registers or distributed RAM rather than a
    // vendor block RAM. A board-specific BRAM/ping-pong implementation is a
    // later optimization and can replace this module without changing the core
    // control contract.

    localparam int unsigned DEPTH   = 256;
    localparam int unsigned MODULUS = 3329;

    logic [15:0] memory [0:DEPTH-1];
    integer index;

    always_comb begin
        host_rdata_o  = memory[host_addr_i];
        left_rdata_o  = memory[left_raddr_i];
        right_rdata_o = memory[right_raddr_i];
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (index = 0; index < DEPTH; index = index + 1)
                memory[index] <= '0;
        end else if (core_we_i) begin
            memory[left_waddr_i]  <= left_wdata_i;
            memory[right_waddr_i] <= right_wdata_i;
        end else if (host_we_i) begin
            memory[host_addr_i] <= host_wdata_i;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && host_we_i) begin
            assert (host_wdata_i < MODULUS)
                else $error(
                    "coefficient_memory_256x16: non-canonical host write %0d",
                    host_wdata_i);
        end

        if (rst_ni && core_we_i) begin
            assert (left_waddr_i != right_waddr_i)
                else $error(
                    "coefficient_memory_256x16: duplicate core write address %0d",
                    left_waddr_i);
            assert (left_wdata_i < MODULUS)
                else $error(
                    "coefficient_memory_256x16: non-canonical left write %0d",
                    left_wdata_i);
            assert (right_wdata_i < MODULUS)
                else $error(
                    "coefficient_memory_256x16: non-canonical right write %0d",
                    right_wdata_i);
        end
    end
`endif
endmodule
