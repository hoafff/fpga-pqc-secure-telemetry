`timescale 1ns/1ps

module tb_primer1_deployment_btp_retry;
    import fpst_btp_pkg::*;

    localparam time SYS_HALF = 18.518ns;
    localparam time SPI_HALF = 500ns;

    logic sys_clk;
    logic rst_n;
    logic spi_sck;
    logic spi_cs_n;
    logic spi_mosi;
    logic spi_miso;
    logic irq_n;
    logic busy;
    logic fault;
    logic secure_enable;
    logic zeroize_n;
    logic fatal_latched;
    logic heartbeat;
    logic led1_n, led2_n, led3_n, led4_n, led5_n, led6_n, led7_n;

    logic [7:0] request [0:17];
    logic [7:0] response_a [0:29];
    logic [7:0] response_b [0:29];
    logic [7:0] collision_response [0:25];
    logic [7:0] partial [0:4];
    logic [31:0] crc;
    integer i;

    kiwi_primer20k_fpst_tx_top #(.HEARTBEAT_BIT(8)) dut (
        .sys_clk_i(sys_clk), .rst_ni(rst_n),
        .spi_sck_i(spi_sck), .spi_cs_ni(spi_cs_n),
        .spi_mosi_i(spi_mosi), .spi_miso_o(spi_miso),
        .irq_no(irq_n), .busy_o(busy), .fault_o(fault),
        .secure_enable_i(secure_enable), .zeroize_ni(zeroize_n),
        .fatal_latched_i(fatal_latched), .heartbeat_o(heartbeat),
        .led1_no(led1_n), .led2_no(led2_n), .led3_no(led3_n),
        .led4_no(led4_n), .led5_no(led5_n), .led6_no(led6_n),
        .led7_no(led7_n)
    );

    always #SYS_HALF sys_clk = ~sys_clk;

    task automatic spi_send_byte(input logic [7:0] value);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = value[b];
                #SPI_HALF; spi_sck = 1'b1;
                #SPI_HALF; spi_sck = 1'b0;
            end
        end
    endtask

    task automatic spi_recv_byte(output logic [7:0] value);
        integer b;
        begin
            value = 8'h00;
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = 1'b0;
                #SPI_HALF; spi_sck = 1'b1;
                value[b] = spi_miso;
                #SPI_HALF; spi_sck = 1'b0;
            end
        end
    endtask

    task automatic wait_irq_low;
        integer cycles;
        begin
            cycles = 0;
            while (irq_n !== 1'b0 && cycles < 200000) begin
                @(posedge sys_clk);
                cycles = cycles + 1;
            end
            if (irq_n !== 1'b0)
                $fatal(1, "Timeout waiting for BTP response IRQ");
        end
    endtask

    task automatic build_ping(input logic [31:0] token);
        begin
            request[0] = 8'hA5;
            request[1] = 8'h5A;
            request[2] = BTP_VERSION;
            request[3] = OP_PING;
            request[4] = 8'h00;
            request[5] = 8'h00;
            request[6] = 8'h42;
            request[7] = 8'h10;
            request[8] = 8'h00;
            request[9] = 8'h04;
            request[10] = token[31:24];
            request[11] = token[23:16];
            request[12] = token[15:8];
            request[13] = token[7:0];
            crc = 32'hFFFF_FFFF;
            for (i = 2; i <= 13; i = i + 1)
                crc = crc32_update_byte(crc, request[i]);
            crc = crc32_finalize(crc);
            request[14] = crc[31:24];
            request[15] = crc[23:16];
            request[16] = crc[15:8];
            request[17] = crc[7:0];
        end
    endtask

    task automatic send_request;
        begin
            spi_cs_n = 1'b0;
            #100ns;
            for (i = 0; i < 18; i = i + 1)
                spi_send_byte(request[i]);
            #100ns;
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;
        end
    endtask

    initial begin
        sys_clk = 1'b0;
        rst_n = 1'b0;
        spi_sck = 1'b0;
        spi_cs_n = 1'b1;
        spi_mosi = 1'b0;
        secure_enable = 1'b1;
        zeroize_n = 1'b1;
        fatal_latched = 1'b0;

        repeat (8) @(posedge sys_clk);
        rst_n = 1'b1;
        repeat (8) @(posedge sys_clk);

        build_ping(32'hCAFE_BABE);
        send_request();
        wait_irq_low();

        /* Read only five bytes. A truncated second transaction must NOT consume response. */
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 5; i = i + 1)
            spi_recv_byte(partial[i]);
        #100ns;
        spi_cs_n = 1'b1;
        repeat (8) @(posedge sys_clk);
        if (irq_n !== 1'b0)
            $fatal(1, "Truncated response incorrectly consumed cached frame");

        /* Retry response transaction without re-sending the request. */
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 30; i = i + 1)
            spi_recv_byte(response_a[i]);
        #100ns;
        spi_cs_n = 1'b1;
        repeat (8) @(posedge sys_clk);
        if (irq_n !== 1'b1)
            $fatal(1, "IRQ remained asserted after complete retry read");
        if ({response_a[22],response_a[23],response_a[24],response_a[25]} !== 32'hCAFE_BABE)
            $fatal(1, "Recovered response token mismatch");

        /* Re-send exact same request/transaction ID: restore byte-identical cached response. */
        send_request();
        wait_irq_low();
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 30; i = i + 1)
            spi_recv_byte(response_b[i]);
        #100ns;
        spi_cs_n = 1'b1;
        repeat (8) @(posedge sys_clk);
        for (i = 0; i < 30; i = i + 1) begin
            if (response_b[i] !== response_a[i])
                $fatal(1, "Duplicate response changed at byte %0d: %02x != %02x",
                       i, response_b[i], response_a[i]);
        end

        /* Same transaction ID with different request contents must be rejected. */
        build_ping(32'hDEAD_BEEF);
        send_request();
        wait_irq_low();
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 26; i = i + 1)
            spi_recv_byte(collision_response[i]);
        #100ns;
        spi_cs_n = 1'b1;
        repeat (8) @(posedge sys_clk);

        if ((collision_response[4] & BTP_FLAG_ERROR) == 0)
            $fatal(1, "Transaction collision did not set ERROR flag");
        if ({collision_response[10],collision_response[11]} !== ERR_BTP_TRANSACTION)
            $fatal(1, "Transaction collision status mismatch: %04x",
                   {collision_response[10],collision_response[11]});
        if ({collision_response[12],collision_response[13]} !== 16'h0001)
            $fatal(1, "Transaction collision detail mismatch");

        crc = 32'hFFFF_FFFF;
        for (i = 2; i <= 21; i = i + 1)
            crc = crc32_update_byte(crc, collision_response[i]);
        crc = crc32_finalize(crc);
        if ({collision_response[22],collision_response[23],
             collision_response[24],collision_response[25]} !== crc)
            $fatal(1, "Collision response CRC mismatch");

        $display("PASS: Primer #1 BTP truncation, retry, duplicate-cache and collision test");
        $finish;
    end
endmodule
