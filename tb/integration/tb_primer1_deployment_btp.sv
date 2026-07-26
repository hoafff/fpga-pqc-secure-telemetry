`timescale 1ns/1ps

module tb_primer1_deployment_btp;
    import fpst_btp_pkg::*;

    localparam time SYS_HALF = 18.518ns;   // approximately 27 MHz
    localparam time SPI_HALF = 500ns;      // 1 MHz bring-up SPI

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
    logic [7:0] response [0:29];
    logic [31:0] crc;
    integer i;

    kiwi_primer20k_fpst_tx_top #(
        .HEARTBEAT_BIT(8)
    ) dut (
        .sys_clk_i        (sys_clk),
        .rst_ni           (rst_n),
        .spi_sck_i        (spi_sck),
        .spi_cs_ni        (spi_cs_n),
        .spi_mosi_i       (spi_mosi),
        .spi_miso_o       (spi_miso),
        .irq_no           (irq_n),
        .busy_o           (busy),
        .fault_o          (fault),
        .secure_enable_i  (secure_enable),
        .zeroize_ni       (zeroize_n),
        .fatal_latched_i  (fatal_latched),
        .heartbeat_o      (heartbeat),
        .led1_no          (led1_n),
        .led2_no          (led2_n),
        .led3_no          (led3_n),
        .led4_no          (led4_n),
        .led5_no          (led5_n),
        .led6_no          (led6_n),
        .led7_no          (led7_n)
    );

    always begin
        #SYS_HALF sys_clk = ~sys_clk;
    end

    function automatic logic [31:0] crc32_bytes(
        input integer first_index,
        input integer last_index,
        input logic select_response
    );
        logic [31:0] c;
        integer k;
        begin
            c = 32'hFFFF_FFFF;
            for (k = first_index; k <= last_index; k = k + 1) begin
                if (select_response)
                    c = crc32_update_byte(c, response[k]);
                else
                    c = crc32_update_byte(c, request[k]);
            end
            crc32_bytes = crc32_finalize(c);
        end
    endfunction

    task automatic spi_send_byte(input logic [7:0] value);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = value[b];
                #SPI_HALF;
                spi_sck = 1'b1;
                #SPI_HALF;
                spi_sck = 1'b0;
            end
        end
    endtask

    task automatic spi_recv_byte(output logic [7:0] value);
        integer b;
        begin
            value = 8'h00;
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = 1'b0;
                #SPI_HALF;
                spi_sck = 1'b1;
                value[b] = spi_miso;
                #SPI_HALF;
                spi_sck = 1'b0;
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

        /* PING request, txid=0x1234, token DE AD BE EF. */
        request[0]  = 8'hA5;
        request[1]  = 8'h5A;
        request[2]  = 8'h01;
        request[3]  = OP_PING;
        request[4]  = 8'h00;
        request[5]  = 8'h00;
        request[6]  = 8'h12;
        request[7]  = 8'h34;
        request[8]  = 8'h00;
        request[9]  = 8'h04;
        request[10] = 8'hDE;
        request[11] = 8'hAD;
        request[12] = 8'hBE;
        request[13] = 8'hEF;

        crc = 32'hFFFF_FFFF;
        for (i = 2; i <= 13; i = i + 1)
            crc = crc32_update_byte(crc, request[i]);
        crc = crc32_finalize(crc);
        request[14] = crc[31:24];
        request[15] = crc[23:16];
        request[16] = crc[15:8];
        request[17] = crc[7:0];

        /* Transaction 1: request only. */
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 18; i = i + 1)
            spi_send_byte(request[i]);
        #100ns;
        spi_cs_n = 1'b1;
        spi_mosi = 1'b0;

        wait_irq_low();

        /* Transaction 2: clock out the complete cached response. */
        spi_cs_n = 1'b0;
        #100ns;
        for (i = 0; i < 30; i = i + 1)
            spi_recv_byte(response[i]);
        #100ns;
        spi_cs_n = 1'b1;

        repeat (8) @(posedge sys_clk);

        if ({response[0],response[1]} !== BTP_SOF)
            $fatal(1, "Bad response SOF %02x%02x", response[0], response[1]);
        if (response[2] !== BTP_VERSION)
            $fatal(1, "Bad response version %02x", response[2]);
        if (response[3] !== OP_PING)
            $fatal(1, "Bad response opcode %02x", response[3]);
        if ((response[4] & BTP_FLAG_RESPONSE) == 0)
            $fatal(1, "Response flag not set");
        if ((response[4] & BTP_FLAG_ERROR) != 0)
            $fatal(1, "Unexpected error response flag");
        if ({response[6],response[7]} !== 16'h1234)
            $fatal(1, "Transaction ID mismatch");
        if ({response[8],response[9]} !== 16'd16)
            $fatal(1, "Response payload length mismatch: %0d",
                   {response[8],response[9]});

        /* Generic response prefix: status/detail/device-state/data_len. */
        if ({response[10],response[11]} !== ERR_OK)
            $fatal(1, "PING returned status %04x", {response[10],response[11]});
        if ({response[12],response[13]} !== 16'h0000)
            $fatal(1, "PING detail_code nonzero");
        if ({response[18],response[19],response[20],response[21]} !== 32'd4)
            $fatal(1, "PING data_len mismatch");
        if ({response[22],response[23],response[24],response[25]} !== 32'hDEAD_BEEF)
            $fatal(1, "PING token echo mismatch");

        crc = 32'hFFFF_FFFF;
        for (i = 2; i <= 25; i = i + 1)
            crc = crc32_update_byte(crc, response[i]);
        crc = crc32_finalize(crc);
        if ({response[26],response[27],response[28],response[29]} !== crc)
            $fatal(1, "Response CRC mismatch observed=%08x expected=%08x",
                   {response[26],response[27],response[28],response[29]}, crc);

        if (irq_n !== 1'b1)
            $fatal(1, "IRQ did not release after complete response read");
        if (fault !== 1'b0)
            $fatal(1, "Unexpected fault output");

        $display("PASS: Primer #1 deployment BTP PING wire-level smoke test");
        $finish;
    end
endmodule
