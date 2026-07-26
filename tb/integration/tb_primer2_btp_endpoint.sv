`timescale 1ns/1ps

module tb_primer2_btp_endpoint;
    import fpst_btp_pkg::*;

    localparam integer MAX_FRAME_BYTES = 1038;
    localparam integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic fatal_latched;

    logic request_valid;
    logic request_accept;
    logic [7:0] request_opcode;
    logic [7:0] request_flags;
    logic [15:0] request_transaction_id;
    logic [15:0] request_payload_len;
    logic [31:0] request_crc32;
    logic request_error;
    logic [15:0] request_error_code;
    logic [9:0] request_payload_rd_addr;
    logic [7:0] request_payload_rd_data;

    logic tx_frame_commit;
    logic [COUNT_W-1:0] tx_frame_len;
    logic tx_wr_en;
    logic [COUNT_W-1:0] tx_wr_addr;
    logic [7:0] tx_wr_data;

    logic irq_pending;
    logic endpoint_busy;
    logic key_valid;
    logic session_active;
    logic [63:0] expected_sequence;
    logic auth_threshold_fault;
    logic [15:0] last_error;

    logic [7:0] request_mem [0:1023];
    logic [7:0] response_mem [0:MAX_FRAME_BYTES-1];
    integer transaction_counter = 1;

    logic tx_start;
    logic tx_ready;
    logic tx_done;
    logic tx_error_valid;
    logic [15:0] tx_error_code;
    logic tx_retained_valid;
    logic [6:0] tx_retained_len;
    logic [5:0] tx_packet_addr;
    logic [7:0] tx_packet_data;
    logic [191:0] telemetry_record;

    localparam logic [31:0] SESSION_ID = 32'h1020_3040;
    localparam logic [127:0] KEY_BUS =
        128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    localparam logic [63:0] NP_BUS = 64'h1716_1514_1312_1110;

    always #5 clk = ~clk;

    assign request_payload_rd_data = request_mem[request_payload_rd_addr];

    always_ff @(posedge clk) begin
        if (tx_wr_en)
            response_mem[tx_wr_addr] <= tx_wr_data;
    end

    primer2_btp_endpoint_deploy #(
        .CLOCK_HZ(1000),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_endpoint (
        .clk_i(clk),
        .rst_ni(rst_n),
        .transport_zeroize_i(1'b0),
        .secure_enable_i(1'b1),
        .fatal_latched_i(fatal_latched),
        .request_valid_i(request_valid),
        .request_accept_o(request_accept),
        .request_opcode_i(request_opcode),
        .request_flags_i(request_flags),
        .request_transaction_id_i(request_transaction_id),
        .request_payload_len_i(request_payload_len),
        .request_crc32_i(request_crc32),
        .request_error_i(request_error),
        .request_error_code_i(request_error_code),
        .request_payload_rd_addr_o(request_payload_rd_addr),
        .request_payload_rd_data_i(request_payload_rd_data),
        .tx_frame_ready_i(1'b0),
        .tx_frame_consumed_i(1'b0),
        .tx_frame_commit_o(tx_frame_commit),
        .tx_frame_len_o(tx_frame_len),
        .tx_wr_en_o(tx_wr_en),
        .tx_wr_addr_o(tx_wr_addr),
        .tx_wr_data_o(tx_wr_data),
        .irq_pending_o(irq_pending),
        .busy_o(endpoint_busy),
        .key_valid_o(key_valid),
        .session_active_o(session_active),
        .expected_sequence_o(expected_sequence),
        .auth_threshold_fault_o(auth_threshold_fault),
        .last_error_code_o(last_error)
    );

    primer1_stp_tx u_sender (
        .clk_i(clk),
        .rst_ni(rst_n),
        .zeroize_i(1'b0),
        .secure_enable_i(1'b1),
        .fatal_latched_i(1'b0),
        .key_valid_i(1'b1),
        .session_active_i(1'b1),
        .session_id_i(SESSION_ID),
        .traffic_key_i(KEY_BUS),
        .nonce_prefix_i(NP_BUS),
        .tx_sequence_i(64'd0),
        .start_i(tx_start),
        .telemetry_record_i(telemetry_record),
        .ready_o(tx_ready),
        .busy_o(),
        .done_o(tx_done),
        .error_valid_o(tx_error_valid),
        .error_code_o(tx_error_code),
        .retained_valid_o(tx_retained_valid),
        .retained_sequence_o(),
        .retained_len_o(tx_retained_len),
        .packet_rd_addr_i(tx_packet_addr),
        .packet_rd_data_o(tx_packet_data),
        .packet_commit_i(1'b0),
        .sequence_commit_o()
    );

    function automatic logic [15:0] resp_be16(input integer index);
        resp_be16 = {response_mem[index], response_mem[index+1]};
    endfunction

    function automatic logic [31:0] resp_be32(input integer index);
        resp_be32 = {response_mem[index], response_mem[index+1],
                     response_mem[index+2], response_mem[index+3]};
    endfunction

    function automatic logic [63:0] resp_be64(input integer index);
        resp_be64 = {response_mem[index], response_mem[index+1],
                     response_mem[index+2], response_mem[index+3],
                     response_mem[index+4], response_mem[index+5],
                     response_mem[index+6], response_mem[index+7]};
    endfunction

    task automatic clear_request;
        integer i;
        begin
            for (i = 0; i < 1024; i = i + 1)
                request_mem[i] = 8'h00;
        end
    endtask

    task automatic issue_request(
        input logic [7:0] opcode,
        input integer payload_len
    );
        integer timeout_cycles;
        begin
            while (endpoint_busy)
                @(posedge clk);

            @(negedge clk);
            request_opcode = opcode;
            request_payload_len = payload_len[15:0];
            request_transaction_id = transaction_counter[15:0];
            request_crc32 = 32'hCA00_0000 ^ transaction_counter;
            transaction_counter = transaction_counter + 1;
            request_valid = 1'b1;

            timeout_cycles = 0;
            while (!request_accept && timeout_cycles < 20000) begin
                @(posedge clk);
                #1;
                timeout_cycles = timeout_cycles + 1;
            end
            if (!request_accept)
                $fatal(1,"request accept timeout opcode=%02h state=%0d",opcode,u_endpoint.state_q);

            @(negedge clk);
            request_valid = 1'b0;

            timeout_cycles = 0;
            while (!tx_frame_commit && timeout_cycles < 30000) begin
                @(posedge clk);
                #1;
                timeout_cycles = timeout_cycles + 1;
            end
            if (!tx_frame_commit)
                $fatal(1,"response timeout opcode=%02h state=%0d",opcode,u_endpoint.state_q);
            #1;
        end
    endtask

    task automatic expect_generic(
        input logic [7:0] opcode,
        input logic [15:0] status,
        input logic [15:0] detail,
        input logic [15:0] app_len
    );
        logic [15:0] payload_len;
        begin
            payload_len = 16'd12 + app_len;
            if (response_mem[0] !== 8'hA5 || response_mem[1] !== 8'h5A ||
                response_mem[2] !== 8'h01 || response_mem[3] !== opcode)
                $fatal(1,"bad BTP response header opcode=%02h",opcode);
            if ((status == ERR_OK && response_mem[4] !== BTP_FLAG_RESPONSE) ||
                (status != ERR_OK && response_mem[4] !==
                    (BTP_FLAG_RESPONSE | BTP_FLAG_ERROR)))
                $fatal(1,"bad response flags opcode=%02h flags=%02h",opcode,response_mem[4]);
            if (resp_be16(8) !== payload_len)
                $fatal(1,"bad payload length opcode=%02h got=%0d exp=%0d",
                       opcode,resp_be16(8),payload_len);
            if (resp_be16(10) !== status || resp_be16(12) !== detail)
                $fatal(1,"bad generic status opcode=%02h status=%04h detail=%04h",
                       opcode,resp_be16(10),resp_be16(12));
            if (resp_be32(18) !== app_len)
                $fatal(1,"bad generic data_len opcode=%02h got=%0d exp=%0d",
                       opcode,resp_be32(18),app_len);
            if (tx_frame_len !== (10 + payload_len + 4))
                $fatal(1,"bad frame length opcode=%02h got=%0d exp=%0d",
                       opcode,tx_frame_len,(10+payload_len+4));
        end
    endtask

    task automatic provision_receiver;
        integer i;
        begin
            clear_request();
            request_mem[0] = SESSION_ID[31:24];
            request_mem[1] = SESSION_ID[23:16];
            request_mem[2] = SESSION_ID[15:8];
            request_mem[3] = SESSION_ID[7:0];
            request_mem[4] = 8'h02;
            request_mem[5] = 8'h00;
            request_mem[6] = 8'h18;
            issue_request(OP_KEY_LOAD_BEGIN,7);
            expect_generic(OP_KEY_LOAD_BEGIN,ERR_OK,16'h0000,16'd0);

            clear_request();
            request_mem[0] = 8'h00;
            request_mem[1] = 8'h00;
            for (i = 0; i < 16; i = i + 1)
                request_mem[2+i] = KEY_BUS[8*i +: 8];
            for (i = 0; i < 8; i = i + 1)
                request_mem[18+i] = NP_BUS[8*i +: 8];
            issue_request(OP_KEY_LOAD_CHUNK,26);
            expect_generic(OP_KEY_LOAD_CHUNK,ERR_OK,16'h0000,16'd0);

            clear_request();
            request_mem[0] = SESSION_ID[31:24];
            request_mem[1] = SESSION_ID[23:16];
            request_mem[2] = SESSION_ID[15:8];
            request_mem[3] = SESSION_ID[7:0];
            request_mem[4] = 8'h02;
            request_mem[5] = 8'h00;
            request_mem[6] = 8'h18;
            issue_request(OP_KEY_LOAD_COMMIT,7);
            expect_generic(OP_KEY_LOAD_COMMIT,ERR_OK,16'h0000,16'd0);

            clear_request();
            request_mem[0] = SESSION_ID[31:24];
            request_mem[1] = SESSION_ID[23:16];
            request_mem[2] = SESSION_ID[15:8];
            request_mem[3] = SESSION_ID[7:0];
            issue_request(OP_SESSION_ACTIVATE,4);
            expect_generic(OP_SESSION_ACTIVATE,ERR_OK,16'h0000,16'd0);

            if (!key_valid || !session_active || expected_sequence != 0)
                $fatal(1,"receiver session did not activate cleanly");

            clear_request();
            issue_request(OP_KEY_STATUS,0);
            expect_generic(OP_KEY_STATUS,ERR_OK,16'h0000,16'd16);
            if (response_mem[22] !== 8'h00 ||
                response_mem[23] !== 8'h01 ||
                response_mem[24] !== 8'h01 ||
                resp_be32(26) !== SESSION_ID ||
                resp_be64(30) !== 64'd0)
                $fatal(1,"KEY_STATUS response contract mismatch");
        end
    endtask

    task automatic load_sender_packet;
        integer i;
        begin
            clear_request();
            for (i = 0; i < 64; i = i + 1) begin
                tx_packet_addr = i[5:0];
                #1;
                request_mem[i] = tx_packet_data;
            end
        end
    endtask

    task automatic build_sender_packet;
        integer timeout_cycles;
        begin
            while (!tx_ready)
                @(posedge clk);
            @(negedge clk);
            tx_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tx_start = 1'b0;

            timeout_cycles = 0;
            while (!tx_retained_valid && timeout_cycles < 10000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!tx_retained_valid || tx_retained_len != 7'd64 || tx_error_valid)
                $fatal(1,"Primer1 STP generation failed err=%04h",tx_error_code);

            load_sender_packet();
        end
    endtask

    task automatic expect_zero_counters(input logic [63:0] expected_seq);
        begin
            clear_request();
            issue_request(OP_STP_GET_COUNTERS,0);
            expect_generic(OP_STP_GET_COUNTERS,ERR_OK,16'h0000,16'd20);
            if (resp_be32(22) !== 32'd0 ||
                resp_be32(26) !== 32'd0 ||
                resp_be32(30) !== 32'd0 ||
                resp_be64(34) !== expected_seq)
                $fatal(1,"STP counters not zero after epoch reset exp_seq=%0d",expected_seq);
        end
    endtask

    initial begin : watchdog
        #8_000_000;
        $fatal(1,"Primer2 BTP endpoint regression timeout state=%0d",u_endpoint.state_q);
    end

    initial begin
        integer i;
        request_valid = 1'b0;
        request_opcode = 8'h00;
        request_flags = 8'h00;
        request_transaction_id = 16'h0000;
        request_payload_len = 16'h0000;
        request_crc32 = 32'h0000_0000;
        request_error = 1'b0;
        request_error_code = 16'h0000;
        tx_start = 1'b0;
        tx_packet_addr = '0;
        telemetry_record = '0;
        fatal_latched = 1'b0;
        clear_request();
        for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
            response_mem[i] = 8'h00;

        for (i = 0; i < 24; i = i + 1)
            telemetry_record[8*i +: 8] = 8'h20 + i[7:0];
        telemetry_record[8*16 +: 8] = 8'h00;
        telemetry_record[8*17 +: 8] = 8'h00;
        telemetry_record[8*18 +: 8] = 8'hC3;
        telemetry_record[8*19 +: 8] = 8'h50;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        provision_receiver();
        build_sender_packet();

        issue_request(OP_STP_RX_PACKET,64);
        expect_generic(OP_STP_RX_PACKET,ERR_OK,16'h0001,16'd34);
        if (resp_be64(22) !== 64'd0 || resp_be16(30) !== 16'd24)
            $fatal(1,"STP commit response sequence/length mismatch");
        for (i = 0; i < 24; i = i + 1) begin
            if (response_mem[32+i] !== telemetry_record[8*i +: 8])
                $fatal(1,"STP plaintext response mismatch byte=%0d",i);
        end
        if (expected_sequence !== 64'd1)
            $fatal(1,"receiver expected_sequence did not commit to 1");

        /* Same STP bytes in a fresh BTP transaction must reconcile as replay. */
        issue_request(OP_STP_RX_PACKET,64);
        expect_generic(OP_STP_RX_PACKET,ERR_REPLAY,16'h0002,16'd8);
        if (resp_be64(22) !== 64'd1)
            $fatal(1,"replay response did not expose expected_sequence=1");

        clear_request();
        issue_request(OP_STP_GET_COUNTERS,0);
        expect_generic(OP_STP_GET_COUNTERS,ERR_OK,16'h0000,16'd20);
        if (resp_be32(22) !== 32'd1 ||
            resp_be32(26) !== 32'd1 ||
            resp_be32(30) !== 32'd0 ||
            resp_be64(34) !== 64'd1)
            $fatal(1,"STP counter response contract mismatch");

        if (auth_threshold_fault || last_error != ERR_REPLAY)
            $fatal(1,"unexpected endpoint fault state");

        /* Explicit ZEROIZE resets both raw counters and visible counter epoch. */
        clear_request();
        request_mem[0] = 8'h00;
        request_mem[1] = 8'h00;
        issue_request(OP_ZEROIZE,2);
        expect_generic(OP_ZEROIZE,ERR_OK,16'h0000,16'd0);
        repeat (2) @(posedge clk);
        if (key_valid || session_active || expected_sequence !== 64'd0)
            $fatal(1,"explicit ZEROIZE did not clear receiver session");
        expect_zero_counters(64'd0);

        /* Recreate a nonzero counter epoch, clear the visible counter, then
         * assert external fatal. Raw RX counters zeroize on fatal, so the
         * visible baseline must also return to zero instead of wrapping. */
        provision_receiver();
        load_sender_packet();
        issue_request(OP_STP_RX_PACKET,64);
        expect_generic(OP_STP_RX_PACKET,ERR_OK,16'h0001,16'd34);
        if (expected_sequence !== 64'd1)
            $fatal(1,"second receiver session did not commit sequence 0");

        clear_request();
        request_mem[0] = 8'h07;
        issue_request(OP_STP_CLEAR_COUNTERS,1);
        expect_generic(OP_STP_CLEAR_COUNTERS,ERR_OK,16'h0000,16'd0);
        expect_zero_counters(64'd1);

        @(negedge clk);
        fatal_latched = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        fatal_latched = 1'b0;
        repeat (2) @(posedge clk);

        if (key_valid || session_active || expected_sequence !== 64'd0)
            $fatal(1,"fatal_latched did not zeroize receiver session");
        expect_zero_counters(64'd0);

        $display("PASS: Primer2 BTP session/STP/replay plus counter zeroize/fatal epochs");
        $finish;
    end
endmodule
