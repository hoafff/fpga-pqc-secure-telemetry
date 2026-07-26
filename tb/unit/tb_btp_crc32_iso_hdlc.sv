`timescale 1ns/1ps

module tb_btp_crc32_iso_hdlc;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear;
    logic valid;
    logic [7:0] data;
    logic [31:0] crc;

    always #5 clk = ~clk;

    btp_crc32_iso_hdlc dut (
        .clk_i(clk), .rst_ni(rst_n),
        .clear_i(clear), .valid_i(valid), .data_i(data), .crc_o(crc)
    );

    task feed(input [7:0] b);
        begin
            @(negedge clk);
            data = b;
            valid = 1'b1;
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    initial begin
        clear = 0;
        valid = 0;
        data = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;

        feed("1"); feed("2"); feed("3"); feed("4"); feed("5");
        feed("6"); feed("7"); feed("8"); feed("9");
        @(posedge clk); #1;
        if (crc !== 32'hCBF4_3926)
            $fatal(1, "CRC32 KAT mismatch: %08x", crc);

        @(negedge clk);
        clear = 1;
        @(negedge clk);
        clear = 0;
        @(posedge clk); #1;
        if (crc !== 32'h0000_0000)
            $fatal(1, "CRC32 clear state mismatch: %08x", crc);

        $display("PASS: tb_btp_crc32_iso_hdlc");
        $finish;
    end
endmodule
