`timescale 1ns/1ps

module tb_fpst_spi_mem_slave;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #18.518 clk = ~clk; // 27 MHz

    logic spi_sclk = 1'b0;
    logic spi_cs_n = 1'b1;
    logic spi_mosi = 1'b0;
    wire  spi_miso;

    logic endpoint_busy = 1'b0;
    logic endpoint_fatal = 1'b0;
    logic response_valid = 1'b0;
    logic [15:0] response_len = 16'd0;
    logic [15:0] response_id = 16'd0;
    logic [15:0] error_code = 16'd0;

    logic request_doorbell;
    logic response_ack;
    logic link_reset;
    logic [15:0] request_len;
    logic [15:0] request_id;
    logic [8:0] request_rd_addr = 9'd0;
    logic [7:0] request_rd_data;

    logic response_we = 1'b0;
    logic [8:0] response_waddr = 9'd0;
    logic [7:0] response_wdata = 8'd0;

    fpst_spi_mem_slave dut (
        .clk_i(clk), .rst_ni(rst_n),
        .spi_sclk_i(spi_sclk), .spi_cs_ni(spi_cs_n),
        .spi_mosi_i(spi_mosi), .spi_miso_o(spi_miso),
        .endpoint_busy_i(endpoint_busy), .endpoint_fatal_i(endpoint_fatal),
        .response_valid_i(response_valid), .response_len_i(response_len),
        .response_id_i(response_id), .error_code_i(error_code),
        .request_doorbell_o(request_doorbell), .response_ack_o(response_ack),
        .link_reset_o(link_reset), .request_len_o(request_len),
        .request_id_o(request_id), .request_rd_addr_i(request_rd_addr),
        .request_rd_data_o(request_rd_data), .response_we_i(response_we),
        .response_waddr_i(response_waddr), .response_wdata_i(response_wdata)
    );

    function automatic [15:0] crc16_byte(input [15:0] crc_in, input [7:0] data);
        reg [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
            crc16_byte = crc;
        end
    endfunction

    function automatic [15:0] crc16_2(input [7:0] a, input [7:0] b);
        reg [15:0] crc;
        begin
            crc = crc16_byte(16'hffff, a);
            crc16_2 = crc16_byte(crc, b);
        end
    endfunction

    task automatic spi_byte(input [7:0] tx, output [7:0] rx);
        integer bitn;
        begin
            rx = 8'h00;
            for (bitn = 7; bitn >= 0; bitn = bitn - 1) begin
                spi_mosi = tx[bitn];
                #167;
                spi_sclk = 1'b1;
                #80;
                rx[bitn] = spi_miso;
                #87;
                spi_sclk = 1'b0;
            end
        end
    endtask

    task automatic begin_cs;
        begin
            spi_sclk = 1'b0;
            spi_mosi = 1'b0;
            spi_cs_n = 1'b0;
            #250;
        end
    endtask

    task automatic end_cs;
        begin
            #200;
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;
            #250;
        end
    endtask

    task automatic send_header(
        input [7:0] cmd,
        input [15:0] addr,
        input [15:0] len,
        input bit corrupt_crc
    );
        reg [7:0] h [0:6];
        reg [15:0] crc;
        reg [7:0] dummy;
        integer i;
        begin
            h[0] = cmd;
            h[1] = addr[15:8]; h[2] = addr[7:0];
            h[3] = len[15:8];  h[4] = len[7:0];
            crc = 16'hffff;
            for (i = 0; i < 5; i = i + 1)
                crc = crc16_byte(crc, h[i]);
            if (corrupt_crc) crc = crc ^ 16'h0001;
            h[5] = crc[15:8]; h[6] = crc[7:0];
            for (i = 0; i < 7; i = i + 1)
                spi_byte(h[i], dummy);
        end
    endtask

    task automatic write2(
        input [15:0] addr,
        input [7:0] d0,
        input [7:0] d1,
        input bit bad_header,
        input bit bad_payload,
        output [7:0] status
    );
        reg [15:0] crc;
        reg [7:0] dummy;
        begin
            begin_cs();
            send_header(8'ha1, addr, 16'd2, bad_header);
            spi_byte(d0, dummy);
            spi_byte(d1, dummy);
            crc = crc16_2(d0, d1);
            if (bad_payload) crc = crc ^ 16'h0001;
            spi_byte(crc[15:8], dummy);
            spi_byte(crc[7:0], dummy);
            spi_byte(8'h00, status);
            end_cs();
        end
    endtask

    task automatic read4_status(
        output [7:0] status,
        output [7:0] d0, output [7:0] d1,
        output [7:0] d2, output [7:0] d3,
        output [15:0] observed_crc
    );
        reg [7:0] c0, c1;
        begin
            begin_cs();
            send_header(8'ha2, 16'h0004, 16'd4, 1'b0);
            spi_byte(8'h00, status);
            spi_byte(8'h00, d0);
            spi_byte(8'h00, d1);
            spi_byte(8'h00, d2);
            spi_byte(8'h00, d3);
            spi_byte(8'h00, c0);
            spi_byte(8'h00, c1);
            observed_crc = {c0,c1};
            end_cs();
        end
    endtask

    initial begin
        reg [7:0] status;
        reg [7:0] d0, d1, d2, d3;
        reg [15:0] crc;
        reg [15:0] expected_crc;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Architected 16-bit register write passes CRC and commits atomically.
        write2(16'h0008, 8'h01, 8'h05, 1'b0, 1'b0, status);
        if (status !== 8'h00 || request_len !== 16'h0105)
            $fatal(1, "valid MEM_WRITE failed: status=%02x len=%04x", status, request_len);

        // A bad payload CRC must not modify REQUEST_LEN.
        write2(16'h0008, 8'h00, 8'h20, 1'b0, 1'b1, status);
        if (status !== 8'he1 || request_len !== 16'h0105)
            $fatal(1, "payload CRC rejection failed: status=%02x len=%04x", status, request_len);

        // A bad header CRC is reported in the final write status byte, after the
        // master has sent the advertised payload and its CRC.
        write2(16'h0008, 8'h00, 8'h10, 1'b1, 1'b0, status);
        if (status !== 8'he1 || request_len !== 16'h0105)
            $fatal(1, "header CRC rejection failed: status=%02x len=%04x", status, request_len);

        // STATUS read while idle: 0x00000001 and data CRC must match.
        read4_status(status, d0, d1, d2, d3, crc);
        expected_crc = 16'hffff;
        expected_crc = crc16_byte(expected_crc, d0);
        expected_crc = crc16_byte(expected_crc, d1);
        expected_crc = crc16_byte(expected_crc, d2);
        expected_crc = crc16_byte(expected_crc, d3);
        if (status !== 8'h00 || {d0,d1,d2,d3} !== 32'h00000001 ||
            crc !== expected_crc)
            $fatal(1, "MEM_READ failed st=%02x data=%02x%02x%02x%02x crc=%04x/%04x",
                   status, d0,d1,d2,d3, crc, expected_crc);

        if (spi_miso !== 1'bz)
            $fatal(1, "MISO is not high-Z while CS is deasserted");

        $display("PASS: fpst_spi_mem_slave Mode-0 A1/A2 burst checks");
        $finish;
    end
endmodule
