`timescale 1ns/1ps

module tb_primer1_deployment_pqc;
    import fpst_btp_pkg::*;

    localparam time SYS_HALF = 18.518ns;
    localparam time SPI_HALF = 100ns; // 5 MHz simulation-only transport rate
    localparam integer MAX_BYTES = 600;

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

    logic [7:0] request [0:MAX_BYTES-1];
    logic [7:0] response [0:MAX_BYTES-1];
    logic [7:0] first_add_response [0:25];
    logic [15:0] original_poly [0:255];
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
            for (b=7; b>=0; b=b-1) begin
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
            for (b=7; b>=0; b=b-1) begin
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
            while (irq_n !== 1'b0 && cycles < 1000000) begin
                @(posedge sys_clk);
                cycles = cycles + 1;
            end
            if (irq_n !== 1'b0)
                $fatal(1, "timeout waiting for PQC BTP response");
        end
    endtask

    task automatic wait_busy_clear;
        integer cycles;
        begin
            cycles = 0;
            while (busy && cycles < 1000000) begin
                @(posedge sys_clk);
                cycles = cycles + 1;
            end
            if (busy)
                $fatal(1, "timeout waiting for Primer PQC operation to finish");
        end
    endtask

    task automatic transact(
        input logic [7:0] opcode,
        input logic [15:0] txid,
        input integer payload_len,
        output integer response_total
    );
        integer k;
        integer request_total;
        integer response_payload_len;
        begin
            request[0] = BTP_SOF[15:8];
            request[1] = BTP_SOF[7:0];
            request[2] = BTP_VERSION;
            request[3] = opcode;
            request[4] = 8'h00;
            request[5] = 8'h00;
            request[6] = txid[15:8];
            request[7] = txid[7:0];
            request[8] = payload_len[15:8];
            request[9] = payload_len[7:0];

            crc = 32'hFFFF_FFFF;
            for (k=2; k<10+payload_len; k=k+1)
                crc = crc32_update_byte(crc,request[k]);
            crc = crc32_finalize(crc);
            request[10+payload_len] = crc[31:24];
            request[11+payload_len] = crc[23:16];
            request[12+payload_len] = crc[15:8];
            request[13+payload_len] = crc[7:0];
            request_total = 14 + payload_len;

            spi_cs_n = 1'b0;
            #40ns;
            for (k=0; k<request_total; k=k+1)
                spi_send_byte(request[k]);
            #40ns;
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;

            wait_irq_low();

            spi_cs_n = 1'b0;
            #40ns;
            for (k=0; k<10; k=k+1)
                spi_recv_byte(response[k]);
            response_payload_len = {response[8],response[9]};
            response_total = 14 + response_payload_len;
            if (response_total > MAX_BYTES)
                $fatal(1,"response exceeds test buffer: %0d",response_total);
            for (k=10; k<response_total; k=k+1)
                spi_recv_byte(response[k]);
            #40ns;
            spi_cs_n = 1'b1;
            repeat (8) @(posedge sys_clk);

            if ({response[0],response[1]} !== BTP_SOF ||
                response[2] !== BTP_VERSION || response[3] !== opcode)
                $fatal(1,"bad response header for opcode %02x",opcode);
            if ({response[6],response[7]} !== txid)
                $fatal(1,"transaction ID mismatch for opcode %02x",opcode);

            crc = 32'hFFFF_FFFF;
            for (k=2; k<response_total-4; k=k+1)
                crc = crc32_update_byte(crc,response[k]);
            crc = crc32_finalize(crc);
            if ({response[response_total-4],response[response_total-3],
                 response[response_total-2],response[response_total-1]} !== crc)
                $fatal(1,"response CRC mismatch for opcode %02x",opcode);
        end
    endtask

    task automatic expect_ok(input logic [7:0] opcode);
        begin
            if ((response[4] & BTP_FLAG_ERROR) != 0)
                $fatal(1,"opcode %02x returned error flag",opcode);
            if ({response[10],response[11]} !== ERR_OK)
                $fatal(1,"opcode %02x returned status %04x",opcode,
                       {response[10],response[11]});
        end
    endtask

    integer response_total;
    integer txid;
    integer add_txid;
    integer data_offset;

    initial begin
        sys_clk = 1'b0;
        rst_n = 1'b0;
        spi_sck = 1'b0;
        spi_cs_n = 1'b1;
        spi_mosi = 1'b0;
        secure_enable = 1'b1;
        zeroize_n = 1'b1;
        fatal_latched = 1'b0;
        txid = 16'h2000;

        for (i=0; i<256; i=i+1)
            original_poly[i] = (17*i + 3) % 3329;

        repeat (8) @(posedge sys_clk);
        rst_n = 1'b1;
        repeat (8) @(posedge sys_clk);

        // Single coefficient path first: address 0x0000, value 0x0005.
        request[10]=8'h00; request[11]=8'h00;
        request[12]=8'h00; request[13]=8'h05;
        transact(OP_PQC_WRITE_COEFF,txid[15:0],4,response_total); txid=txid+1;
        expect_ok(OP_PQC_WRITE_COEFF);

        request[10]=8'h00; request[11]=8'h00;
        transact(OP_PQC_READ_COEFF,txid[15:0],2,response_total); txid=txid+1;
        expect_ok(OP_PQC_READ_COEFF);
        if ({response[22],response[23]} !== 16'd5)
            $fatal(1,"PQC_READ_COEFF did not return written value");

        // Atomic full polynomial load, count = 256.
        request[10]=8'h01; request[11]=8'h00;
        for (i=0; i<256; i=i+1) begin
            request[12+2*i] = original_poly[i][15:8];
            request[13+2*i] = original_poly[i][7:0];
        end
        transact(OP_PQC_LOAD_POLY,txid[15:0],514,response_total); txid=txid+1;
        expect_ok(OP_PQC_LOAD_POLY);

        // Non-idempotent duplicate test: add one to every coefficient, then
        // resend the exact same transaction ID and request. The second request
        // must be served from cache and MUST NOT execute the addition again.
        request[10] = 8'h00; // add
        for (i=0; i<256; i=i+1) begin
            request[11+2*i] = 8'h00;
            request[12+2*i] = 8'h01;
        end
        add_txid = txid;
        transact(OP_PQC_POLY_ADD_SUB,add_txid[15:0],513,response_total);
        expect_ok(OP_PQC_POLY_ADD_SUB);
        if (response_total != 26)
            $fatal(1,"unexpected add response size %0d",response_total);
        for (i=0; i<26; i=i+1)
            first_add_response[i] = response[i];

        transact(OP_PQC_POLY_ADD_SUB,add_txid[15:0],513,response_total);
        expect_ok(OP_PQC_POLY_ADD_SUB);
        for (i=0; i<26; i=i+1) begin
            if (response[i] !== first_add_response[i])
                $fatal(1,"duplicate PQC response changed at byte %0d",i);
        end
        txid = txid + 1;

        request[10]=8'h00; request[11]=8'h00;
        transact(OP_PQC_READ_COEFF,txid[15:0],2,response_total); txid=txid+1;
        expect_ok(OP_PQC_READ_COEFF);
        if ({response[22],response[23]} !== ((original_poly[0] + 1) % 3329))
            $fatal(1,"duplicate POLY_ADD executed side effect more than once");

        // Subtract one once to restore the original polynomial before the
        // NTT/INTT round trip.
        request[10] = 8'h01; // subtract
        for (i=0; i<256; i=i+1) begin
            request[11+2*i] = 8'h00;
            request[12+2*i] = 8'h01;
        end
        transact(OP_PQC_POLY_ADD_SUB,txid[15:0],513,response_total); txid=txid+1;
        expect_ok(OP_PQC_POLY_ADD_SUB);

        // Forward NTT; the 4-byte command payload is reserved/profile-owned.
        request[10]=0; request[11]=0; request[12]=0; request[13]=0;
        transact(OP_PQC_START_NTT,txid[15:0],4,response_total); txid=txid+1;
        expect_ok(OP_PQC_START_NTT);
        wait_busy_clear();

        // Multiply by the identity in each NTT base case: (b0,b1)=(1,0).
        for (i=0; i<128; i=i+1) begin
            request[10+4*i] = 8'h00;
            request[11+4*i] = 8'h01;
            request[12+4*i] = 8'h00;
            request[13+4*i] = 8'h00;
        end
        transact(OP_PQC_POINTWISE_MUL,txid[15:0],512,response_total); txid=txid+1;
        expect_ok(OP_PQC_POINTWISE_MUL);

        // Confirm GET_RESULT sees a complete NTT-domain polynomial.
        transact(OP_PQC_GET_RESULT,txid[15:0],0,response_total); txid=txid+1;
        expect_ok(OP_PQC_GET_RESULT);
        if (response[24] !== 8'd2) // data byte 2: domain
            $fatal(1,"GET_RESULT did not report NTT domain: %0d",response[24]);

        // Inverse NTT back to standard coefficients.
        request[10]=0; request[11]=0; request[12]=0; request[13]=0;
        transact(OP_PQC_START_INTT,txid[15:0],4,response_total); txid=txid+1;
        expect_ok(OP_PQC_START_INTT);
        wait_busy_clear();

        // Bulk read all 256 coefficients and compare byte-for-byte.
        request[10]=8'h01; request[11]=8'h00;
        transact(OP_PQC_READ_POLY,txid[15:0],2,response_total); txid=txid+1;
        expect_ok(OP_PQC_READ_POLY);
        if ({response[18],response[19],response[20],response[21]} !== 32'd512)
            $fatal(1,"PQC_READ_POLY data length mismatch");
        data_offset = 22;
        for (i=0; i<256; i=i+1) begin
            if ({response[data_offset+2*i],response[data_offset+2*i+1]} !== original_poly[i])
                $fatal(1,"round-trip coefficient %0d got=%0d expected=%0d",i,
                       {response[data_offset+2*i],response[data_offset+2*i+1]},
                       original_poly[i]);
        end

        if (irq_n !== 1'b1 || fault !== 1'b0)
            $fatal(1,"Primer deployment did not return to clean idle state");

        $display("PASS: Primer #1 complete PQC path + non-idempotent retry works over SPI/BTP");
        $finish;
    end
endmodule
