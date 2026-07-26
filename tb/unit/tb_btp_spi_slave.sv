`timescale 1ns/1ps

module tb_btp_spi_slave;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic zeroize = 1'b0;
    always #18.5 clk = ~clk; /* ~27.027 MHz; deliberately asynchronous to SPI */

    logic spi_sclk = 1'b0;
    logic spi_mosi = 1'b0;
    logic spi_cs_n = 1'b1;
    logic spi_miso;
    logic spi_miso_oe;

    logic req_valid;
    logic req_take;
    logic [10:0] req_len;
    logic [10:0] req_raddr;
    logic [7:0] req_rdata;

    logic rsp_we;
    logic [10:0] rsp_waddr;
    logic [7:0] rsp_wdata;
    logic [10:0] rsp_len;
    logic rsp_commit;
    logic rsp_rearm;
    logic rsp_pending;
    logic rsp_consumed;
    logic irq_n;
    logic overflow;

    logic [7:0] r0, r1, r2, r3;

    btp_spi_slave #(.MAX_FRAME_BYTES(64)) dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .spi_sclk_i(spi_sclk), .spi_mosi_i(spi_mosi),
        .spi_cs_ni(spi_cs_n), .spi_miso_o(spi_miso),
        .spi_miso_oe_o(spi_miso_oe),
        .req_valid_o(req_valid), .req_take_i(req_take),
        .req_len_o(req_len), .req_raddr_i(req_raddr),
        .req_rdata_o(req_rdata),
        .rsp_we_i(rsp_we), .rsp_waddr_i(rsp_waddr),
        .rsp_wdata_i(rsp_wdata), .rsp_len_i(rsp_len),
        .rsp_commit_i(rsp_commit), .rsp_rearm_i(rsp_rearm),
        .rsp_pending_o(rsp_pending), .rsp_consumed_o(rsp_consumed),
        .irq_no(irq_n), .overflow_o(overflow)
    );

    task spi_write_byte(input [7:0] value);
        integer bitn;
        begin
            for (bitn = 7; bitn >= 0; bitn = bitn - 1) begin
                spi_mosi = value[bitn];
                #500;
                spi_sclk = 1'b1;
                #500;
                spi_sclk = 1'b0;
            end
        end
    endtask

    task spi_read_byte(output [7:0] value);
        integer bitn;
        begin
            value = 8'h00;
            for (bitn = 7; bitn >= 0; bitn = bitn - 1) begin
                #500;
                spi_sclk = 1'b1;
                #100;
                value[bitn] = spi_miso;
                #400;
                spi_sclk = 1'b0;
            end
        end
    endtask

    task write_response_byte(input [10:0] addr, input [7:0] value);
        begin
            @(negedge clk);
            rsp_waddr = addr;
            rsp_wdata = value;
            rsp_we = 1'b1;
            @(negedge clk);
            rsp_we = 1'b0;
        end
    endtask

    initial begin
        req_take = 0;
        req_raddr = 0;
        rsp_we = 0;
        rsp_waddr = 0;
        rsp_wdata = 0;
        rsp_len = 0;
        rsp_commit = 0;
        rsp_rearm = 0;
        r0 = 0; r1 = 0; r2 = 0; r3 = 0;

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        if (!irq_n || rsp_pending || spi_miso_oe)
            $fatal(1, "bad idle state");

        /* Request transaction: 3 bytes under one CS assertion. */
        spi_cs_n = 1'b0;
        #300;
        if (!spi_miso_oe) $fatal(1, "MISO output-enable did not follow CS");
        spi_write_byte(8'hA5);
        spi_write_byte(8'h5A);
        spi_write_byte(8'h01);
        #300;
        spi_cs_n = 1'b1;
        #300;

        if (!req_valid || req_len != 11'd3 || overflow)
            $fatal(1, "request not latched: valid=%0d len=%0d ovf=%0d",
                   req_valid, req_len, overflow);

        req_raddr = 0; #1; if (req_rdata !== 8'hA5) $fatal(1, "req[0]");
        req_raddr = 1; #1; if (req_rdata !== 8'h5A) $fatal(1, "req[1]");
        req_raddr = 2; #1; if (req_rdata !== 8'h01) $fatal(1, "req[2]");

        /* Endpoint consumes request and commits a response while CS is high. */
        @(negedge clk); req_take = 1'b1;
        @(negedge clk); req_take = 1'b0;
        if (req_valid) $fatal(1, "request take failed");

        write_response_byte(0, 8'hDE);
        write_response_byte(1, 8'hAD);
        write_response_byte(2, 8'hBE);
        write_response_byte(3, 8'hEF);
        @(negedge clk);
        rsp_len = 11'd4;
        rsp_commit = 1'b1;
        @(negedge clk);
        rsp_commit = 1'b0;
        #100;
        if (!rsp_pending || irq_n)
            $fatal(1, "response commit did not assert active-low IRQ");

        /* Response is a separate SPI transaction. */
        spi_cs_n = 1'b0;
        #300;
        spi_read_byte(r0);
        spi_read_byte(r1);
        spi_read_byte(r2);
        spi_read_byte(r3);
        #300;
        spi_cs_n = 1'b1;
        #400;

        if ({r0,r1,r2,r3} !== 32'hDEAD_BEEF)
            $fatal(1, "response mismatch %02x %02x %02x %02x", r0,r1,r2,r3);
        if (rsp_pending || !irq_n)
            $fatal(1, "response was not consumed");
        if (spi_miso_oe)
            $fatal(1, "MISO remained driven with CS high");

        /* Cached response can be re-armed byte-identically. */
        @(negedge clk); rsp_rearm = 1'b1;
        @(negedge clk); rsp_rearm = 1'b0;
        #100;
        if (!rsp_pending || irq_n) $fatal(1, "response rearm failed");

        /* Zeroize invalidates pending transport state immediately. */
        @(negedge clk); zeroize = 1'b1;
        @(negedge clk); zeroize = 1'b0;
        #100;
        if (req_valid || rsp_pending || !irq_n)
            $fatal(1, "zeroize did not clear transport state");

        $display("PASS: tb_btp_spi_slave");
        $finish;
    end
endmodule
