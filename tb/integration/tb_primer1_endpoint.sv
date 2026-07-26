`timescale 1ns/1ps

module tb_primer1_endpoint;
    localparam integer MAX_FRAME_BYTES = 269;
    localparam integer NTT_VECTOR_VALUES = 5 * 256;

    localparam logic [15:0] STATUS_OK                 = 16'h0000;
    localparam logic [15:0] ERR_TRANSACTION_COLLISION = 16'h0207;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #18.518 clk = ~clk; // 27 MHz

    logic zeroize = 1'b0;
    logic request_doorbell = 1'b0;
    logic response_ack = 1'b0;
    logic link_reset = 1'b0;
    logic [15:0] request_len = 16'd0;
    logic [15:0] request_id = 16'd0;

    logic [8:0] request_rd_addr;
    logic [7:0] request_rd_data;
    logic response_we;
    logic [8:0] response_waddr;
    logic [7:0] response_wdata;
    logic response_valid;
    logic [15:0] response_len;
    logic [15:0] response_id;
    logic [15:0] error_code;
    logic busy;
    logic fatal;
    logic key_valid;
    logic retained_packet;

    logic [7:0] request_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] response_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] saved_response [0:MAX_FRAME_BYTES-1];
    logic [7:0] expected_packet [0:63];
    logic [15:0] ntt_inputs [0:NTT_VECTOR_VALUES-1];
    logic [15:0] ntt_expected [0:NTT_VECTOR_VALUES-1];

    assign request_rd_data = request_mem[request_rd_addr];

    always_ff @(posedge clk) begin
        if (response_we)
            response_mem[response_waddr] <= response_wdata;
    end

    primer1_endpoint dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .zeroize_i(zeroize),
        .request_doorbell_i(request_doorbell),
        .response_ack_i(response_ack),
        .link_reset_i(link_reset),
        .request_len_i(request_len),
        .request_id_i(request_id),
        .request_rd_addr_o(request_rd_addr),
        .request_rd_data_i(request_rd_data),
        .response_we_o(response_we),
        .response_waddr_o(response_waddr),
        .response_wdata_o(response_wdata),
        .response_valid_o(response_valid),
        .response_len_o(response_len),
        .response_id_o(response_id),
        .error_code_o(error_code),
        .busy_o(busy),
        .fatal_o(fatal),
        .key_valid_o(key_valid),
        .retained_packet_o(retained_packet)
    );

    function automatic [15:0] crc16_byte(input [15:0] crc_in, input [7:0] data);
        reg [15:0] crc;
        integer bit_index;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
            crc16_byte = crc;
        end
    endfunction

    task automatic clear_request;
        integer i;
        begin
            for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                request_mem[i] = 8'h00;
        end
    endtask

    task automatic finalize_request(
        input [7:0] opcode,
        input [15:0] txid,
        input integer payload_length
    );
        reg [15:0] crc;
        integer i;
        begin
            request_mem[0] = 8'hA5;
            request_mem[1] = 8'h5A;
            request_mem[2] = 8'h10;
            request_mem[3] = opcode;
            request_mem[4] = 8'h00;
            request_mem[5] = txid[15:8];
            request_mem[6] = txid[7:0];
            request_mem[7] = payload_length[15:8];
            request_mem[8] = payload_length[7:0];

            crc = 16'hFFFF;
            for (i = 2; i <= 8; i = i + 1)
                crc = crc16_byte(crc, request_mem[i]);
            request_mem[9] = crc[15:8];
            request_mem[10] = crc[7:0];

            crc = 16'hFFFF;
            for (i = 0; i < payload_length; i = i + 1)
                crc = crc16_byte(crc, request_mem[11+i]);
            request_mem[11+payload_length] = crc[15:8];
            request_mem[12+payload_length] = crc[7:0];

            request_len = payload_length + 13;
            request_id = txid;
        end
    endtask

    task automatic launch_and_wait(input integer timeout_cycles);
        integer cycles;
        begin
            while (busy || response_valid)
                @(posedge clk);

            @(negedge clk);
            request_doorbell = 1'b1;
            @(negedge clk);
            request_doorbell = 1'b0;

            cycles = 0;
            while (!response_valid && cycles < timeout_cycles) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (!response_valid)
                $fatal(1, "Primer1 endpoint response timeout after %0d cycles", cycles);
            @(negedge clk);
        end
    endtask

    task automatic check_response(
        input [7:0] expected_opcode,
        input [15:0] expected_txid,
        input [15:0] expected_status,
        input integer expected_app_len
    );
        reg [15:0] crc;
        reg [15:0] observed_crc;
        integer payload_length;
        integer expected_total;
        integer i;
        begin
            payload_length = expected_app_len + 2;
            expected_total = payload_length + 13;

            if (response_len !== expected_total[15:0])
                $fatal(1, "response length got=%0d expected=%0d", response_len, expected_total);
            if (response_id !== expected_txid)
                $fatal(1, "response id got=%04x expected=%04x", response_id, expected_txid);
            if (error_code !== expected_status)
                $fatal(1, "error_code got=%04x expected=%04x", error_code, expected_status);
            if (response_mem[0] !== 8'hA5 || response_mem[1] !== 8'h5A ||
                response_mem[2] !== 8'h10 || response_mem[3] !== expected_opcode ||
                response_mem[4] !== 8'h01 ||
                {response_mem[5],response_mem[6]} !== expected_txid ||
                {response_mem[7],response_mem[8]} !== payload_length[15:0])
                $fatal(1, "response header fields malformed");

            crc = 16'hFFFF;
            for (i = 2; i <= 8; i = i + 1)
                crc = crc16_byte(crc, response_mem[i]);
            if ({response_mem[9],response_mem[10]} !== crc)
                $fatal(1, "response header CRC got=%02x%02x expected=%04x",
                       response_mem[9], response_mem[10], crc);

            if ({response_mem[11],response_mem[12]} !== expected_status)
                $fatal(1, "remote status got=%02x%02x expected=%04x",
                       response_mem[11], response_mem[12], expected_status);

            crc = 16'hFFFF;
            for (i = 0; i < payload_length; i = i + 1)
                crc = crc16_byte(crc, response_mem[11+i]);
            observed_crc = {response_mem[11+payload_length],
                            response_mem[12+payload_length]};
            if (observed_crc !== crc)
                $fatal(1, "response payload CRC got=%04x expected=%04x", observed_crc, crc);
        end
    endtask

    task automatic ack_current_response;
        integer cycles;
        begin
            @(negedge clk);
            response_ack = 1'b1;
            @(negedge clk);
            response_ack = 1'b0;
            cycles = 0;
            while (response_valid && cycles < 20) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (response_valid)
                $fatal(1, "response ACK did not clear response_valid");
        end
    endtask

    task automatic send_empty_command(
        input [7:0] opcode,
        input [15:0] txid,
        input [15:0] expected_status,
        input integer expected_app_len,
        input integer timeout_cycles
    );
        begin
            clear_request();
            finalize_request(opcode, txid, 0);
            launch_and_wait(timeout_cycles);
            check_response(opcode, txid, expected_status, expected_app_len);
        end
    endtask

    task automatic ntt_load_chunk(
        input [15:0] txid,
        input integer offset,
        input integer count
    );
        integer i;
        reg [15:0] value;
        begin
            clear_request();
            request_mem[11] = offset[7:0];
            request_mem[12] = count[7:0];
            for (i = 0; i < count; i = i + 1) begin
                value = ntt_inputs[offset+i];
                request_mem[13 + (2*i)] = value[15:8];
                request_mem[14 + (2*i)] = value[7:0];
            end
            finalize_request(8'h30, txid, 2 + (2*count));
            launch_and_wait(5000);
            check_response(8'h30, txid, STATUS_OK, 0);
            ack_current_response();
        end
    endtask

    task automatic ntt_read_and_check_chunk(
        input [15:0] txid,
        input integer offset,
        input integer count
    );
        integer i;
        reg [15:0] observed;
        begin
            clear_request();
            request_mem[11] = offset[7:0];
            request_mem[12] = count[7:0];
            finalize_request(8'h32, txid, 2);
            launch_and_wait(10000);
            check_response(8'h32, txid, STATUS_OK, 2*count);
            for (i = 0; i < count; i = i + 1) begin
                observed = {response_mem[13 + (2*i)], response_mem[14 + (2*i)]};
                if (observed !== ntt_expected[offset+i])
                    $fatal(1, "NTT endpoint mismatch at %0d got=%0d expected=%0d",
                           offset+i, observed, ntt_expected[offset+i]);
            end
            ack_current_response();
        end
    endtask

    integer i;
    integer saved_len;

    initial begin
        $readmemh("build/sim/forward_ntt_core_inputs.hex", ntt_inputs);
        $readmemh("build/sim/forward_ntt_core_expected.hex", ntt_expected);

        for (i = 0; i < MAX_FRAME_BYTES; i = i + 1) begin
            request_mem[i] = 8'h00;
            response_mem[i] = 8'h00;
            saved_response[i] = 8'h00;
        end

        // Expected STP packet for:
        // K=00..0F, NP=10..17, seq=18..1F, session=24252627,
        // flags=0, telemetry plaintext=20..37.
        expected_packet[0]=8'h50; expected_packet[1]=8'h51;
        expected_packet[2]=8'h01; expected_packet[3]=8'h03;
        expected_packet[4]=8'h00; expected_packet[5]=8'h00;
        expected_packet[6]=8'h00; expected_packet[7]=8'h18;
        expected_packet[8]=8'h24; expected_packet[9]=8'h25;
        expected_packet[10]=8'h26; expected_packet[11]=8'h27;
        expected_packet[12]=8'h18; expected_packet[13]=8'h19;
        expected_packet[14]=8'h1A; expected_packet[15]=8'h1B;
        expected_packet[16]=8'h1C; expected_packet[17]=8'h1D;
        expected_packet[18]=8'h1E; expected_packet[19]=8'h1F;
        expected_packet[20]=8'h00; expected_packet[21]=8'h18;
        expected_packet[22]=8'h01; expected_packet[23]=8'h00;
        expected_packet[24]=8'hB1; expected_packet[25]=8'hC8;
        expected_packet[26]=8'h15; expected_packet[27]=8'hAD;
        expected_packet[28]=8'h3A; expected_packet[29]=8'h1C;
        expected_packet[30]=8'h24; expected_packet[31]=8'h9B;
        expected_packet[32]=8'h9B; expected_packet[33]=8'h5A;
        expected_packet[34]=8'hBA; expected_packet[35]=8'h34;
        expected_packet[36]=8'h34; expected_packet[37]=8'hB4;
        expected_packet[38]=8'h8D; expected_packet[39]=8'h4A;
        expected_packet[40]=8'hE2; expected_packet[41]=8'hAD;
        expected_packet[42]=8'h8F; expected_packet[43]=8'h5A;
        expected_packet[44]=8'h0D; expected_packet[45]=8'hAC;
        expected_packet[46]=8'hA4; expected_packet[47]=8'h8E;
        expected_packet[48]=8'h72; expected_packet[49]=8'h80;
        expected_packet[50]=8'h79; expected_packet[51]=8'h2D;
        expected_packet[52]=8'hDC; expected_packet[53]=8'h14;
        expected_packet[54]=8'h67; expected_packet[55]=8'h6A;
        expected_packet[56]=8'hA0; expected_packet[57]=8'h4B;
        expected_packet[58]=8'hAD; expected_packet[59]=8'h3E;
        expected_packet[60]=8'hC7; expected_packet[61]=8'h52;
        expected_packet[62]=8'h04; expected_packet[63]=8'hE4;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        if (busy || response_valid || key_valid || retained_packet || fatal)
            $fatal(1, "endpoint not clean after reset");

        // PING nominal path.
        send_empty_command(8'h01, 16'h0001, STATUS_OK, 4, 2000);
        if ({response_mem[13],response_mem[14],response_mem[15],response_mem[16]} !==
            32'h504F4E47)
            $fatal(1, "PING payload is not PONG");
        saved_len = response_len;
        for (i = 0; i < saved_len; i = i + 1)
            saved_response[i] = response_mem[i];
        ack_current_response();

        // Same transaction/frame must be served from the duplicate cache.
        send_empty_command(8'h01, 16'h0001, STATUS_OK, 4, 2000);
        if (response_len !== saved_len)
            $fatal(1, "duplicate response length changed");
        for (i = 0; i < saved_len; i = i + 1)
            if (response_mem[i] !== saved_response[i])
                $fatal(1, "duplicate response changed at byte %0d", i);
        ack_current_response();

        // Same transaction ID with different content must be rejected.
        send_empty_command(8'h02, 16'h0001, ERR_TRANSACTION_COLLISION, 0, 2000);
        ack_current_response();

        // Stage K/NP/sequence context.
        clear_request();
        request_mem[11]=8'h24; request_mem[12]=8'h25;
        request_mem[13]=8'h26; request_mem[14]=8'h27;
        for (i = 0; i < 16; i = i + 1)
            request_mem[15+i] = i[7:0];
        for (i = 0; i < 8; i = i + 1)
            request_mem[31+i] = 8'h10 + i[7:0];
        for (i = 0; i < 8; i = i + 1)
            request_mem[39+i] = 8'h18 + i[7:0];
        request_mem[47]=8'h00; request_mem[48]=8'h00;
        request_mem[49]=8'h00; request_mem[50]=8'h00;
        finalize_request(8'h10, 16'h0002, 40);
        launch_and_wait(3000);
        check_response(8'h10, 16'h0002, STATUS_OK, 0);
        ack_current_response();

        // Atomic context commit.
        clear_request();
        request_mem[11]=8'h24; request_mem[12]=8'h25;
        request_mem[13]=8'h26; request_mem[14]=8'h27;
        finalize_request(8'h11, 16'h0003, 4);
        launch_and_wait(3000);
        check_response(8'h11, 16'h0003, STATUS_OK, 0);
        if (!key_valid)
            $fatal(1, "COMMIT_CONTEXT did not assert key_valid");
        ack_current_response();

        // Build and encrypt one fixed telemetry record. This validates the wrapper's
        // STP header/nonce byte order against an independently generated vector.
        clear_request();
        request_mem[11]=8'h00; request_mem[12]=8'h00;
        for (i = 0; i < 24; i = i + 1)
            request_mem[13+i] = 8'h20 + i[7:0];
        finalize_request(8'h20, 16'h0004, 26);
        launch_and_wait(20000);
        check_response(8'h20, 16'h0004, STATUS_OK, 64);
        if (!retained_packet)
            $fatal(1, "ASCON_ENCRYPT did not retain packet");
        for (i = 0; i < 64; i = i + 1)
            if (response_mem[13+i] !== expected_packet[i])
                $fatal(1, "STP packet mismatch byte=%0d got=%02x expected=%02x",
                       i, response_mem[13+i], expected_packet[i]);
        ack_current_response();

        // Retry returns the identical retained bytes without changing the sequence.
        send_empty_command(8'h21, 16'h0005, STATUS_OK, 64, 4000);
        for (i = 0; i < 64; i = i + 1)
            if (response_mem[13+i] !== expected_packet[i])
                $fatal(1, "STP_RETRY mismatch at byte %0d", i);
        ack_current_response();

        // Commit the retained sequence, then advance exactly once.
        clear_request();
        for (i = 0; i < 8; i = i + 1)
            request_mem[11+i] = 8'h18 + i[7:0];
        finalize_request(8'h22, 16'h0006, 8);
        launch_and_wait(3000);
        check_response(8'h22, 16'h0006, STATUS_OK, 8);
        if (retained_packet)
            $fatal(1, "STP_COMMIT did not release retained packet");
        for (i = 0; i < 7; i = i + 1)
            if (response_mem[13+i] !== (8'h18 + i[7:0]))
                $fatal(1, "next sequence prefix mismatch at byte %0d", i);
        if (response_mem[20] !== 8'h20)
            $fatal(1, "next sequence did not increment exactly once");
        ack_current_response();

        // Load a complete polynomial through the command wrapper in legal chunks.
        ntt_load_chunk(16'h0007, 0,   127);
        ntt_load_chunk(16'h0008, 127, 127);
        ntt_load_chunk(16'h0009, 254, 2);

        // Execute the already-verified forward NTT core through the endpoint.
        send_empty_command(8'h31, 16'h000A, STATUS_OK, 2, 20000);
        ack_current_response();

        // Read the complete transformed polynomial back through the mailbox wrapper.
        ntt_read_and_check_chunk(16'h000B, 0,   127);
        ntt_read_and_check_chunk(16'h000C, 127, 127);
        ntt_read_and_check_chunk(16'h000D, 254, 2);

        // Command zeroize must remove active key/session/retained state.
        send_empty_command(8'h12, 16'h000E, STATUS_OK, 0, 3000);
        if (key_valid || retained_packet || fatal)
            $fatal(1, "ZEROIZE left endpoint security state asserted");
        ack_current_response();

        // Status after zeroize reports no key and a zero session/sequence.
        send_empty_command(8'h03, 16'h000F, STATUS_OK, 18, 3000);
        if (response_mem[13][0] !== 1'b0)
            $fatal(1, "GET_STATUS reports key valid after zeroize");
        for (i = 4; i < 16; i = i + 1)
            if (response_mem[13+i] !== 8'h00)
                $fatal(1, "GET_STATUS retained nonzero session/sequence byte %0d", i);
        ack_current_response();

        $display("PASS: Primer1 endpoint PING/cache/session/Ascon/STP/NTT/zeroize integration");
        $finish;
    end
endmodule
