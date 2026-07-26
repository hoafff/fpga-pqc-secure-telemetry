`timescale 1ns/1ps

module tb_inverse_ntt_core;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic start;
    logic busy;
    logic done;
    logic host_re;
    logic host_we;
    logic [7:0] host_addr;
    logic [15:0] host_wdata;
    logic host_ready;
    logic host_rvalid;
    logic [15:0] host_rdata;
    logic [2:0] stage;

    logic [15:0] forward_ramp [0:255];

    inverse_ntt_core dut (
        .clk_i(clk), .rst_ni(rst_n),
        .start_i(start), .busy_o(busy), .done_o(done),
        .host_re_i(host_re), .host_we_i(host_we),
        .host_addr_i(host_addr), .host_wdata_i(host_wdata),
        .host_ready_o(host_ready), .host_rvalid_o(host_rvalid),
        .host_rdata_o(host_rdata), .stage_o(stage)
    );

    task write_coeff(input [7:0] addr, input [15:0] value);
        begin
            while (!host_ready) @(negedge clk);
            host_addr = addr;
            host_wdata = value;
            host_we = 1'b1;
            @(negedge clk);
            host_we = 1'b0;
        end
    endtask

    task read_coeff(input [7:0] addr, output [15:0] value);
        begin
            while (!host_ready) @(negedge clk);
            host_addr = addr;
            host_re = 1'b1;
            @(negedge clk);
            host_re = 1'b0;
            while (!host_rvalid) @(negedge clk);
            value = host_rdata;
        end
    endtask

    initial begin
        $readmemh("rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected.hex",
                  forward_ramp);

        start = 0;
        host_re = 0;
        host_we = 0;
        host_addr = 0;
        host_wdata = 0;

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        for (integer i = 0; i < 256; i = i + 1)
            write_coeff(i[7:0], forward_ramp[i]);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (busy);
        wait (done);
        @(negedge clk);

        for (integer i = 0; i < 256; i = i + 1) begin
            logic [15:0] got;
            read_coeff(i[7:0], got);
            if (got !== i[15:0]) begin
                $fatal(1, "inverse mismatch at %0d: got=%0d expected=%0d stage=%0d",
                       i, got, i, stage);
            end
        end

        $display("PASS: tb_inverse_ntt_core");
        $finish;
    end
endmodule
