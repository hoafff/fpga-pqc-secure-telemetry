`timescale 1ns/1ps

module tb_primer1_deployment_session_tx;
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
    logic secure_enable_i = 1'b1;
    logic zeroize_ni = 1'b1;
    logic heartbeat_o;
    logic led1_no, led2_no, led3_no, led4_no, led5_no, led6_no, led7_no;

    logic [7:0] payload [0:1023];
    logic [7:0] request [0:1037];
    logic [7:0] response [0:1037];
    logic [7:0] first_tx_response [0:127];
    logic [31:0] crc;
    integer response_total_len;
    integer i;

    always #18.5185 sys_clk_i = ~sys_clk_i;

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
                #500;
                rx[b] = spi_miso_o;
                spi_sclk_i = 1'b1;
                #500;
                spi_sclk_i = 1'b0;
            end
        end
    endtask

    task automatic send_request(
        input [7:0] opcode,
        input [15:0] txid,
        input integer payload_len
    );
        reg [7:0] dummy;
        integer total_len;
        begin
            request[0] = 8'ha5;
            request[1] = 8'h5a;
            request[2] = 8'h01;
            request[3] = opcode;
            request[4] = 8'h00;
            request[5] = 8'h00;
            request[6] = txid[15:8];
            request[7] = txid[7:0];
            request[8] = payload_len[15:8];
            request[9] = payload_len[7:0];
            for (i = 0; i < payload_len; i = i + 1)
                request[10+i] = payload[i];

            crc = 32'hffff_ffff;
            for (i = 2; i < 10+payload_len; i = i + 1)
                crc = crc32_byte(crc, request[i]);
            crc = crc ^ 32'hffff_ffff;
            request[10+payload_len] = crc[31:24];
            request[11+payload_len] = crc[23:16];
            request[12+payload_len] = crc[15:8];
            request[13+payload_len] = crc[7:0];
            total_len = 14 + payload_len;

            spi_cs_ni = 1'b0;
            #1000;
            for (i = 0; i < total_len; i = i + 1)
                spi_byte(request[i], dummy);
            #1000;
            spi_cs_ni = 1'b1;
            #2000;
        end
    endtask

    task automatic read_response;
        reg [7:0] rx;
        integer timeout_count;
        integer payload_len;
        begin
            timeout_count = 0;
            while (irq_no && timeout_count < 800000) begin
                #100;
                timeout_count = timeout_count + 1;
            end
            if (irq_no) $fatal(1, "timeout waiting for BTP response");

            spi_cs_ni = 1'b0;
            #1000;
            for (i = 0; i < 10; i = i + 1) begin
                spi_byte(8'h00, rx);
                response[i] = rx;
            end
            payload_len = {response[8],response[9]};
            response_total_len = 14 + payload_len;
            if (response_total_len > 1038)
                $fatal(1, "response length overflow");
            for (i = 10; i < response_total_len; i = i + 1) begin
                spi_byte(8'h00, rx);
                response[i] = rx;
            end
            #1000;
            spi_cs_ni = 1'b1;
            #3000;

            if (response[0] != 8'ha5 || response[1] != 8'h5a ||
                response[2] != 8'h01 || (response[4] & 8'h01) == 0)
                $fatal(1, "malformed BTP response header");

            crc = 32'hffff_ffff;
            for (i = 2; i < response_total_len-4; i = i + 1)
                crc = crc32_byte(crc, response[i]);
            crc = crc ^ 32'hffff_ffff;
            if ({response[response_total_len-4],response[response_total_len-3],
                 response[response_total_len-2],response[response_total_len-1]} != crc)
                $fatal(1, "response CRC32 mismatch");
        end
    endtask

    task automatic expect_ok(input [7:0] opcode, input [15:0] txid);
        begin
            if (response[3] != opcode ||
                {response[6],response[7]} != txid ||
                {response[10],response[11]} != 16'h0000)
                $fatal(1, "command %02x txid %04x returned error %02x%02x",
                       opcode, txid, response[10], response[11]);
        end
    endtask

    initial begin
        repeat (8) @(posedge sys_clk_i);
        rst_ni = 1'b1;
        repeat (12) @(posedge sys_clk_i);

        // KEY_LOAD_BEGIN: session 1, TX direction, 24-byte K_TX||NP_TX.
        payload[0]=8'h00; payload[1]=8'h00; payload[2]=8'h00; payload[3]=8'h01;
        payload[4]=8'h00; payload[5]=8'h00; payload[6]=8'h18;
        send_request(8'h40,16'h0100,7); read_response(); expect_ok(8'h40,16'h0100);

        // One complete key-load chunk: K_TX=00..0f, NP_TX=10..17.
        payload[0]=8'h00; payload[1]=8'h00;
        for (i=0;i<24;i=i+1) payload[2+i]=i[7:0];
        send_request(8'h41,16'h0101,26); read_response(); expect_ok(8'h41,16'h0101);

        payload[0]=8'h00; payload[1]=8'h00; payload[2]=8'h00; payload[3]=8'h01;
        send_request(8'h42,16'h0102,4); read_response(); expect_ok(8'h42,16'h0102);

        // KEY_STATUS must expose key_valid=1 and key_loading=0.
        send_request(8'h44,16'h0103,0); read_response(); expect_ok(8'h44,16'h0103);
        if ((response[26] & 8'h02) == 0)
            $fatal(1, "key_valid was not asserted after atomic commit");

        // Activate the committed session; sequence starts at zero.
        payload[0]=8'h00; payload[1]=8'h00; payload[2]=8'h00; payload[3]=8'h01;
        send_request(8'h46,16'h0104,4); read_response(); expect_ok(8'h46,16'h0104);

        // First telemetry record: 20..37. Primer #1 must build the STP packet.
        for (i=0;i<24;i=i+1) payload[i]=(8'h20+i[7:0]);
        send_request(8'h60,16'h0200,24); read_response(); expect_ok(8'h60,16'h0200);
        if ({response[8],response[9]} != 16'd86)
            $fatal(1, "unexpected telemetry response payload length");
        // Generic response prefix is frame bytes 10..21. Extra starts at 22:
        // sequence[8], packet_len[2], then the complete 64-byte STP packet.
        for (i=22;i<30;i=i+1)
            if (response[i] != 8'h00) $fatal(1,"first TX sequence is not zero");
        if (response[30] != 8'h00 || response[31] != 8'h40)
            $fatal(1, "STP packet length is not 64 bytes");
        if (response[32] != 8'h50 || response[33] != 8'h51 ||
            response[34] != 8'h01 || response[35] != 8'h03)
            $fatal(1, "bad STP header prefix");
        if ({response[40],response[41],response[42],response[43]} != 32'h0000_0001)
            $fatal(1, "bad STP session_id");
        for (i=44;i<52;i=i+1)
            if (response[i] != 8'h00) $fatal(1,"bad first STP sequence");
        if (response[52] != 8'h00 || response[53] != 8'h18 ||
            response[54] != 8'h01 || response[55] != 8'h00)
            $fatal(1, "bad STP payload descriptor");
        for (i=0;i<response_total_len;i=i+1)
            first_tx_response[i]=response[i];

        // Exact duplicate transaction: byte-identical cache replay, no re-encrypt.
        for (i=0;i<24;i=i+1) payload[i]=(8'h20+i[7:0]);
        send_request(8'h60,16'h0200,24); read_response(); expect_ok(8'h60,16'h0200);
        for (i=0;i<response_total_len;i=i+1)
            if (response[i] !== first_tx_response[i])
                $fatal(1, "duplicate TX response changed at byte %0d", i);

        // A new unique telemetry command is issued only after the receiver
        // commit acknowledgement; this commits sequence 0 and encrypts seq 1.
        for (i=0;i<24;i=i+1) payload[i]=(8'h40+i[7:0]);
        send_request(8'h60,16'h0201,24); read_response(); expect_ok(8'h60,16'h0201);
        for (i=22;i<29;i=i+1)
            if (response[i] != 8'h00) $fatal(1,"second TX sequence high bytes wrong");
        if (response[29] != 8'h01)
            $fatal(1, "second TX did not advance to sequence 1");
        for (i=44;i<51;i=i+1)
            if (response[i] != 8'h00) $fatal(1,"second STP sequence high bytes wrong");
        if (response[51] != 8'h01)
            $fatal(1, "second STP packet did not use sequence 1");

        // In-band zeroize clears key/session state.
        payload[0]=8'h00; payload[1]=8'h01;
        send_request(8'h45,16'h0300,2); read_response(); expect_ok(8'h45,16'h0300);
        repeat (8) @(posedge sys_clk_i);
        if (led3_no !== 1'b1 || led4_no !== 1'b1)
            $fatal(1, "zeroize did not clear key/session indicators");

        if (fault_o) $fatal(1, "unexpected fatal fault");
        $display("PASS: Primer #1 session, STP retention/sequence and zeroize");
        $finish;
    end
endmodule
