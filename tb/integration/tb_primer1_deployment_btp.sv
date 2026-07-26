`timescale 1ns/1ps

module tb_primer1_deployment_btp;
    logic sys_clk_i = 1'b0;
    logic rst_ni = 1'b0;
    logic spi_sclk_i = 1'b0;
    logic spi_mosi_i = 1'b0;
    logic spi_miso_o;
    logic spi_cs_ni = 1'b1;
    logic irq_no;
    logic busy_o;
    logic fault_o;
    logic link_reset_ni = 1'b1;
    logic secure_enable_i = 1'b0;
    logic zeroize_ni = 1'b1;
    logic heartbeat_o;
    logic led1_no, led2_no, led3_no, led4_no, led5_no, led6_no, led7_no;

    logic [7:0] request [0:17];
    logic [7:0] response [0:29];
    logic [31:0] crc;
    integer i;

    always #18.5185 sys_clk_i = ~sys_clk_i; // 27 MHz

    kiwi_primer20k_fpst_tx_top dut (
        .sys_clk_i(sys_clk_i),
        .rst_ni(rst_ni),
        .spi_sclk_i(spi_sclk_i),
        .spi_mosi_i(spi_mosi_i),
        .spi_miso_o(spi_miso_o),
        .spi_cs_ni(spi_cs_ni),
        .irq_no(irq_no),
        .busy_o(busy_o),
        .fault_o(fault_o),
        .link_reset_ni(link_reset_ni),
        .secure_enable_i(secure_enable_i),
        .zeroize_ni(zeroize_ni),
        .heartbeat_o(heartbeat_o),
        .led1_no(led1_no), .led2_no(led2_no), .led3_no(led3_no),
        .led4_no(led4_no), .led5_no(led5_no), .led6_no(led6_no),
        .led7_no(led7_no)
    );

    function automatic [31:0] crc32_byte(
        input [31:0] crc_in,
        input [7:0] data_in
    );
        reg [31:0] c;
        reg [7:0] d;
        integer k;
        begin
            c = crc_in;
            d = data_in;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0] ^ d[0]) c = (c >> 1) ^ 32'hedb8_8320;
                else c = c >> 1;
                d = d >> 1;
            end
            crc32_byte = c;
        end
    endfunction

    task automatic spi_byte(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            rx = 8'h00;
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi_i = tx[b];
                // Mode 0: the master samples MISO at the rising edge. Sample
                // the stable pre-edge value before allowing the synchronized
                // FPGA slave to advance to the next bit.
                #500;
                rx[b] = spi_miso_o;
                spi_sclk_i = 1'b1;
                #500;
                spi_sclk_i = 1'b0;
            end
        end
    endtask

    task automatic send_ping_request;
        reg [7:0] dummy;
        begin
            request[0] = 8'ha5;
            request[1] = 8'h5a;
            request[2] = 8'h01;
            request[3] = 8'h7f;
            request[4] = 8'h00;
            request[5] = 8'h00;
            request[6] = 8'h12;
            request[7] = 8'h34;
            request[8] = 8'h00;
            request[9] = 8'h04;
            request[10] = 8'hde;
            request[11] = 8'had;
            request[12] = 8'hbe;
            request[13] = 8'hef;

            crc = 32'hffff_ffff;
            for (i = 2; i <= 13; i = i + 1)
                crc = crc32_byte(crc, request[i]);
            crc = crc ^ 32'hffff_ffff;
            request[14] = crc[31:24];
            request[15] = crc[23:16];
            request[16] = crc[15:8];
            request[17] = crc[7:0];

            spi_cs_ni = 1'b0;
            #1000;
            for (i = 0; i < 18; i = i + 1)
                spi_byte(request[i], dummy);
            #1000;
            spi_cs_ni = 1'b1;
            #2000;
        end
    endtask

    task automatic read_ping_response;
        reg [7:0] rx;
        integer timeout_count;
        begin
            timeout_count = 0;
            while (irq_no && timeout_count < 200000) begin
                #100;
                timeout_count = timeout_count + 1;
            end
            if (irq_no) $fatal(1, "timeout waiting for Primer #1 BTP IRQ");

            spi_cs_ni = 1'b0;
            #1000;
            for (i = 0; i < 30; i = i + 1) begin
                spi_byte(8'h00, rx);
                response[i] = rx;
            end
            #1000;
            spi_cs_ni = 1'b1;
            #3000;

            if (response[0] != 8'ha5 || response[1] != 8'h5a)
                $fatal(1, "bad response SOF: %02x %02x", response[0], response[1]);
            if (response[2] != 8'h01 || response[3] != 8'h7f)
                $fatal(1, "bad response version/opcode");
            if ((response[4] & 8'h01) == 0)
                $fatal(1, "response flag not set");
            if (response[6] != 8'h12 || response[7] != 8'h34)
                $fatal(1, "transaction id mismatch");
            if (response[8] != 8'h00 || response[9] != 8'h10)
                $fatal(1, "unexpected response payload length");
            if (response[10] != 8'h00 || response[11] != 8'h00)
                $fatal(1, "PING returned nonzero status");
            if (response[22] != 8'hde || response[23] != 8'had ||
                response[24] != 8'hbe || response[25] != 8'hef)
                $fatal(1, "PING token echo mismatch");

            crc = 32'hffff_ffff;
            for (i = 2; i <= 25; i = i + 1)
                crc = crc32_byte(crc, response[i]);
            crc = crc ^ 32'hffff_ffff;
            if ({response[26],response[27],response[28],response[29]} != crc)
                $fatal(1, "response CRC32 mismatch");

            timeout_count = 0;
            while (!irq_no && timeout_count < 2000) begin
                #100;
                timeout_count = timeout_count + 1;
            end
            if (!irq_no) $fatal(1, "IRQ did not clear after full response read");
        end
    endtask

    initial begin
        repeat (8) @(posedge sys_clk_i);
        rst_ni = 1'b1;
        repeat (8) @(posedge sys_clk_i);

        // First execution.
        send_ping_request();
        read_ping_response();

        // Exact duplicate transaction_id/opcode/payload must be served from
        // the response cache without creating a second side effect.
        send_ping_request();
        read_ping_response();

        if (fault_o) $fatal(1, "unexpected fatal fault");
        $display("PASS: Primer #1 deployment BTP PING + duplicate cache");
        $finish;
    end
endmodule
