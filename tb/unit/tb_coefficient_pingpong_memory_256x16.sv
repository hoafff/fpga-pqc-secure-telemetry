`timescale 1ns/1ps

module tb_coefficient_pingpong_memory_256x16;
    logic clk;
    logic rst_n;

    logic host_re;
    logic host_we;
    logic [7:0] host_addr;
    logic [15:0] host_wdata;
    logic host_rvalid;
    logic [15:0] host_rdata;

    logic core_re;
    logic [7:0] left_raddr;
    logic [7:0] right_raddr;
    logic core_rvalid;
    logic [15:0] left_rdata;
    logic [15:0] right_rdata;

    logic core_we;
    logic [7:0] left_waddr;
    logic [7:0] right_waddr;
    logic [15:0] left_wdata;
    logic [15:0] right_wdata;
    logic swap;
    logic active_bank;

    coefficient_pingpong_memory_256x16 dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .host_re_i      (host_re),
        .host_we_i      (host_we),
        .host_addr_i    (host_addr),
        .host_wdata_i   (host_wdata),
        .host_rvalid_o  (host_rvalid),
        .host_rdata_o   (host_rdata),
        .core_re_i      (core_re),
        .left_raddr_i   (left_raddr),
        .right_raddr_i  (right_raddr),
        .core_rvalid_o  (core_rvalid),
        .left_rdata_o   (left_rdata),
        .right_rdata_o  (right_rdata),
        .core_we_i      (core_we),
        .left_waddr_i   (left_waddr),
        .right_waddr_i  (right_waddr),
        .left_wdata_i   (left_wdata),
        .right_wdata_i  (right_wdata),
        .swap_i         (swap),
        .active_bank_o  (active_bank)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic host_write(
        input logic [7:0] addr,
        input logic [15:0] value
    );
    begin
        @(negedge clk);
        host_we    = 1'b1;
        host_addr  = addr;
        host_wdata = value;
        @(negedge clk);
        host_we = 1'b0;
    end
    endtask

    task automatic host_read_check(
        input logic [7:0] addr,
        input logic [15:0] expected
    );
    begin
        @(negedge clk);
        host_re   = 1'b1;
        host_addr = addr;
        @(posedge clk);
        #1;
        if (!host_rvalid)
            $fatal(1, "host read response was not valid");
        if (host_rdata !== expected)
            $fatal(1,
                "host read addr=%0d got=%0d expected=%0d",
                addr, host_rdata, expected);
        @(negedge clk);
        host_re = 1'b0;
        @(posedge clk);
        #1;
        if (host_rvalid)
            $fatal(1, "host_rvalid_o must clear after the request");
    end
    endtask

    task automatic core_read_check(
        input logic [7:0] left_addr,
        input logic [7:0] right_addr,
        input logic [15:0] expected_left,
        input logic [15:0] expected_right
    );
    begin
        @(negedge clk);
        core_re    = 1'b1;
        left_raddr = left_addr;
        right_raddr = right_addr;
        @(posedge clk);
        #1;
        if (!core_rvalid)
            $fatal(1, "core read response was not valid");
        if (left_rdata !== expected_left || right_rdata !== expected_right)
            $fatal(1,
                "core read got=(%0d,%0d) expected=(%0d,%0d)",
                left_rdata, right_rdata, expected_left, expected_right);
        @(negedge clk);
        core_re = 1'b0;
        @(posedge clk);
        #1;
        if (core_rvalid)
            $fatal(1, "core_rvalid_o must clear after the request");
    end
    endtask

    task automatic core_write_and_swap(
        input logic [7:0] left_addr,
        input logic [7:0] right_addr,
        input logic [15:0] left_value,
        input logic [15:0] right_value,
        input logic expected_active_bank
    );
    begin
        @(negedge clk);
        core_we     = 1'b1;
        left_waddr  = left_addr;
        right_waddr = right_addr;
        left_wdata  = left_value;
        right_wdata = right_value;
        swap        = 1'b1;
        @(posedge clk);
        #1;
        if (active_bank !== expected_active_bank)
            $fatal(1,
                "bank swap got=%0d expected=%0d",
                active_bank, expected_active_bank);
        @(negedge clk);
        core_we = 1'b0;
        swap    = 1'b0;
    end
    endtask

    initial begin
        rst_n       = 1'b0;
        host_re     = 1'b0;
        host_we     = 1'b0;
        host_addr   = '0;
        host_wdata  = '0;
        core_re     = 1'b0;
        left_raddr  = '0;
        right_raddr = '0;
        core_we     = 1'b0;
        left_waddr  = '0;
        right_waddr = '0;
        left_wdata  = '0;
        right_wdata = '0;
        swap        = 1'b0;

        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (active_bank !== 1'b0)
            $fatal(1, "reset did not select bank 0");

        host_write(8'd10, 16'd111);
        host_write(8'd20, 16'd222);
        host_read_check(8'd10, 16'd111);
        core_read_check(8'd10, 8'd20, 16'd111, 16'd222);

        core_write_and_swap(
            8'd10, 8'd20, 16'd333, 16'd444, 1'b1);
        host_read_check(8'd10, 16'd333);
        core_read_check(8'd10, 8'd20, 16'd333, 16'd444);

        core_write_and_swap(
            8'd10, 8'd20, 16'd555, 16'd666, 1'b0);
        host_read_check(8'd20, 16'd666);

        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (active_bank !== 1'b0)
            $fatal(1, "reset did not restore bank 0 selection");

        // RAM contents are deliberately not reset; bank 0 still contains the
        // last completed image. Production software must nevertheless reload all
        // coefficients after reset because an aborted transform may be partial.
        host_read_check(8'd10, 16'd555);

        $display(
            "PASS: coefficient ping-pong memory preserved synchronous reads, "
            "dual writes and bank swaps");
        $finish;
    end
endmodule
