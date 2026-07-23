module coefficient_pingpong_memory_256x16 (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        host_re_i,
    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_rvalid_o,
    output logic [15:0] host_rdata_o,

    input  logic        core_re_i,
    input  logic [7:0]  left_raddr_i,
    input  logic [7:0]  right_raddr_i,
    output logic        core_rvalid_o,
    output logic [15:0] left_rdata_o,
    output logic [15:0] right_rdata_o,

    input  logic        core_we_i,
    input  logic [7:0]  left_waddr_i,
    input  logic [7:0]  right_waddr_i,
    input  logic [15:0] left_wdata_i,
    input  logic [15:0] right_wdata_i,

    input  logic        swap_i,
    output logic        active_bank_o
);
    // The active bank is the current stage's read source and the host-visible
    // coefficient image. The inactive bank is the current stage's write
    // destination. swap_i is asserted with the final write of each NTT stage.
    logic active_bank_q;

    logic        bank0_a_en;
    logic        bank0_a_we;
    logic [7:0]  bank0_a_addr;
    logic [15:0] bank0_a_wdata;
    logic [15:0] bank0_a_rdata;
    logic        bank0_b_en;
    logic        bank0_b_we;
    logic [7:0]  bank0_b_addr;
    logic [15:0] bank0_b_wdata;
    logic [15:0] bank0_b_rdata;

    logic        bank1_a_en;
    logic        bank1_a_we;
    logic [7:0]  bank1_a_addr;
    logic [15:0] bank1_a_wdata;
    logic [15:0] bank1_a_rdata;
    logic        bank1_b_en;
    logic        bank1_b_we;
    logic [7:0]  bank1_b_addr;
    logic [15:0] bank1_b_wdata;
    logic [15:0] bank1_b_rdata;

    assign active_bank_o = active_bank_q;
    assign left_rdata_o = active_bank_q ? bank1_a_rdata : bank0_a_rdata;
    assign right_rdata_o = active_bank_q ? bank1_b_rdata : bank0_b_rdata;
    assign host_rdata_o = active_bank_q ? bank1_a_rdata : bank0_a_rdata;

    always_comb begin
        bank0_a_en    = 1'b0;
        bank0_a_we    = 1'b0;
        bank0_a_addr  = '0;
        bank0_a_wdata = '0;
        bank0_b_en    = 1'b0;
        bank0_b_we    = 1'b0;
        bank0_b_addr  = '0;
        bank0_b_wdata = '0;

        bank1_a_en    = 1'b0;
        bank1_a_we    = 1'b0;
        bank1_a_addr  = '0;
        bank1_a_wdata = '0;
        bank1_b_en    = 1'b0;
        bank1_b_we    = 1'b0;
        bank1_b_addr  = '0;
        bank1_b_wdata = '0;

        if (core_re_i) begin
            if (!active_bank_q) begin
                bank0_a_en   = 1'b1;
                bank0_a_addr = left_raddr_i;
                bank0_b_en   = 1'b1;
                bank0_b_addr = right_raddr_i;
            end else begin
                bank1_a_en   = 1'b1;
                bank1_a_addr = left_raddr_i;
                bank1_b_en   = 1'b1;
                bank1_b_addr = right_raddr_i;
            end
        end

        if (core_we_i) begin
            if (!active_bank_q) begin
                bank1_a_en    = 1'b1;
                bank1_a_we    = 1'b1;
                bank1_a_addr  = left_waddr_i;
                bank1_a_wdata = left_wdata_i;
                bank1_b_en    = 1'b1;
                bank1_b_we    = 1'b1;
                bank1_b_addr  = right_waddr_i;
                bank1_b_wdata = right_wdata_i;
            end else begin
                bank0_a_en    = 1'b1;
                bank0_a_we    = 1'b1;
                bank0_a_addr  = left_waddr_i;
                bank0_a_wdata = left_wdata_i;
                bank0_b_en    = 1'b1;
                bank0_b_we    = 1'b1;
                bank0_b_addr  = right_waddr_i;
                bank0_b_wdata = right_wdata_i;
            end
        end

        // Host access is permitted only while the core is idle. Port A is used
        // for either a synchronous read or a write to the active bank.
        if (host_re_i || host_we_i) begin
            if (!active_bank_q) begin
                bank0_a_en    = 1'b1;
                bank0_a_we    = host_we_i;
                bank0_a_addr  = host_addr_i;
                bank0_a_wdata = host_wdata_i;
            end else begin
                bank1_a_en    = 1'b1;
                bank1_a_we    = host_we_i;
                bank1_a_addr  = host_addr_i;
                bank1_a_wdata = host_wdata_i;
            end
        end
    end

    true_dual_port_ram_256x16 u_bank0 (
        .clk_i     (clk_i),
        .a_en_i    (bank0_a_en),
        .a_we_i    (bank0_a_we),
        .a_addr_i  (bank0_a_addr),
        .a_wdata_i (bank0_a_wdata),
        .a_rdata_o (bank0_a_rdata),
        .b_en_i    (bank0_b_en),
        .b_we_i    (bank0_b_we),
        .b_addr_i  (bank0_b_addr),
        .b_wdata_i (bank0_b_wdata),
        .b_rdata_o (bank0_b_rdata)
    );

    true_dual_port_ram_256x16 u_bank1 (
        .clk_i     (clk_i),
        .a_en_i    (bank1_a_en),
        .a_we_i    (bank1_a_we),
        .a_addr_i  (bank1_a_addr),
        .a_wdata_i (bank1_a_wdata),
        .a_rdata_o (bank1_a_rdata),
        .b_en_i    (bank1_b_en),
        .b_we_i    (bank1_b_we),
        .b_addr_i  (bank1_b_addr),
        .b_wdata_i (bank1_b_wdata),
        .b_rdata_o (bank1_b_rdata)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            active_bank_q <= 1'b0;
            core_rvalid_o <= 1'b0;
            host_rvalid_o <= 1'b0;
        end else begin
            core_rvalid_o <= core_re_i;
            host_rvalid_o <= host_re_i && !host_we_i;

            if (swap_i)
                active_bank_q <= ~active_bank_q;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(core_re_i && (host_re_i || host_we_i)))
                else $error(
                    "coefficient_pingpong_memory_256x16: host/core read conflict");
            assert (!(core_we_i && (host_re_i || host_we_i)))
                else $error(
                    "coefficient_pingpong_memory_256x16: host/core write conflict");
            assert (!(host_re_i && host_we_i))
                else $error(
                    "coefficient_pingpong_memory_256x16: simultaneous host read/write");
            if (core_we_i) begin
                assert (left_waddr_i != right_waddr_i)
                    else $error(
                        "coefficient_pingpong_memory_256x16: duplicate write address");
            end
            if (swap_i)
                assert (core_we_i)
                    else $error(
                        "coefficient_pingpong_memory_256x16: swap without final write");
        end
    end
`endif
endmodule
