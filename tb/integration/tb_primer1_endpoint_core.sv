`timescale 1ns/1ps
module tb_primer1_endpoint_core;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic zeroize = 1'b0;
    logic secure_enable = 1'b1;

    logic cmd_valid;
    logic cmd_ready;
    logic [7:0] cmd_opcode;
    logic [7:0] cmd_flags;
    logic [15:0] cmd_txid;
    logic [15:0] cmd_len;
    logic [9:0] cmd_addr;
    logic [7:0] cmd_data;

    logic rsp_we;
    logic [9:0] rsp_addr;
    logic [7:0] rsp_data;
    logic rsp_valid;
    logic rsp_ready;
    logic [7:0] rsp_opcode;
    logic [7:0] rsp_flags;
    logic [15:0] rsp_txid;
    logic [15:0] rsp_len;

    logic tx_commit_valid;
    logic [63:0] tx_commit_sequence;
    logic key_valid;
    logic session_active;
    logic [63:0] tx_sequence;
    logic retained;
    logic endpoint_busy;
    logic error_valid;
    logic [15:0] error_code;

    logic [7:0] request_mem [0:1023];
    logic [7:0] response_mem [0:1023];
    integer i;
    integer timeout_count;

    always #5 clk = ~clk;
    assign cmd_data = request_mem[cmd_addr];

    primer1_endpoint_core dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .zeroize_i(zeroize),
        .secure_enable_i(secure_enable),
        .cmd_valid_i(cmd_valid),
        .cmd_ready_o(cmd_ready),
        .cmd_opcode_i(cmd_opcode),
        .cmd_flags_i(cmd_flags),
        .cmd_transaction_id_i(cmd_txid),
        .cmd_payload_len_i(cmd_len),
        .cmd_payload_addr_o(cmd_addr),
        .cmd_payload_data_i(cmd_data),
        .rsp_payload_we_o(rsp_we),
        .rsp_payload_addr_o(rsp_addr),
        .rsp_payload_data_o(rsp_data),
        .rsp_valid_o(rsp_valid),
        .rsp_ready_i(rsp_ready),
        .rsp_opcode_o(rsp_opcode),
        .rsp_flags_o(rsp_flags),
        .rsp_transaction_id_o(rsp_txid),
        .rsp_payload_len_o(rsp_len),
        .tx_commit_valid_i(tx_commit_valid),
        .tx_commit_sequence_i(tx_commit_sequence),
        .key_valid_o(key_valid),
        .session_active_o(session_active),
        .tx_sequence_o(tx_sequence),
        .tx_packet_retained_o(retained),
        .endpoint_busy_o(endpoint_busy),
        .error_valid_o(error_valid),
        .error_code_o(error_code)
    );

    always_ff @(posedge clk) begin
        if (rsp_we)
            response_mem[rsp_addr] <= rsp_data;
    end

    task clear_request;
        begin
            for (i = 0; i < 1024; i = i + 1)
                request_mem[i] = 8'h00;
            for (i = 0; i < 1024; i = i + 1)
                response_mem[i] = 8'h00;
        end
    endtask

    task run_command(input [7:0] opcode, input [15:0] length);
        begin
            cmd_opcode = opcode;
            cmd_flags = 8'h00;
            cmd_len = length;
            cmd_txid = cmd_txid + 1'b1;
            cmd_valid = 1'b1;

            timeout_count = 0;
            while (!rsp_valid && timeout_count < 20000) begin
                @(posedge clk);
                if (cmd_ready)
                    cmd_valid <= 1'b0;
                timeout_count = timeout_count + 1;
            end
            if (!rsp_valid)
                $fatal(1, "timeout waiting response opcode=%02x", opcode);
            if (rsp_opcode !== opcode || rsp_txid !== cmd_txid)
                $fatal(1, "response identity mismatch opcode=%02x", opcode);
            @(posedge clk);
            cmd_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    task expect_ok;
        begin
            if (response_mem[0] !== 8'h00 || response_mem[1] !== 8'h00)
                $fatal(1, "remote status not OK: %02x%02x",
                       response_mem[0], response_mem[1]);
        end
    endtask

    initial begin
        cmd_valid = 1'b0;
        cmd_opcode = 8'h00;
        cmd_flags = 8'h00;
        cmd_txid = 16'h1000;
        cmd_len = 16'h0000;
        rsp_ready = 1'b1;
        tx_commit_valid = 1'b0;
        tx_commit_sequence = 64'h0;
        clear_request();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* PING uses frozen Appendix-B opcode 0x7F. */
        run_command(8'h7F, 16'd0);
        expect_ok();

        /* KEY_LOAD_BEGIN with session_id=1 proves the full 32-bit non-zero
         * check; an old implementation incorrectly rejected upper16==0. */
        clear_request();
        request_mem[0] = 8'h00;
        request_mem[1] = 8'h00;
        request_mem[2] = 8'h00;
        request_mem[3] = 8'h01;
        request_mem[4] = 8'h01;  // TX direction
        request_mem[5] = 8'h00;
        request_mem[6] = 8'h18;  // K_TX + NP_TX = 24 bytes
        run_command(8'h40, 16'd7);
        expect_ok();

        /* One complete atomic key-material chunk. */
        clear_request();
        request_mem[0] = 8'h00;
        request_mem[1] = 8'h00;
        for (i = 0; i < 24; i = i + 1)
            request_mem[2+i] = i[7:0];
        run_command(8'h41, 16'd26);
        expect_ok();

        /* COMMIT: session_id=1, fresh sequence=0, policy=0. */
        clear_request();
        request_mem[0] = 8'h00;
        request_mem[1] = 8'h00;
        request_mem[2] = 8'h00;
        request_mem[3] = 8'h01;
        for (i = 4; i < 16; i = i + 1)
            request_mem[i] = 8'h00;
        run_command(8'h42, 16'd16);
        expect_ok();
        if (!key_valid || session_active)
            $fatal(1, "key commit state wrong");

        /* SESSION_ACTIVATE(session_id=1). */
        clear_request();
        request_mem[0] = 8'h00;
        request_mem[1] = 8'h00;
        request_mem[2] = 8'h00;
        request_mem[3] = 8'h01;
        run_command(8'h46, 16'd4);
        expect_ok();
        if (!session_active || tx_sequence !== 64'd0)
            $fatal(1, "session activation/initial sequence wrong");

        /* TELEMETRY_TX_SAMPLE is exactly 24 bytes. */
        clear_request();
        for (i = 0; i < 24; i = i + 1)
            request_mem[i] = 8'h20 + i[7:0];
        run_command(8'h60, 16'd24);
        expect_ok();
        if (rsp_len !== 16'd76)
            $fatal(1, "telemetry response length=%0d expected 76", rsp_len);
        if (!retained || tx_sequence !== 64'd0)
            $fatal(1, "packet must remain retained at sequence zero");
        if (response_mem[10] !== 8'h00 || response_mem[11] !== 8'h40)
            $fatal(1, "retained packet length field wrong");
        if (response_mem[12] !== 8'h50 || response_mem[13] !== 8'h51)
            $fatal(1, "STP magic missing in returned packet");
        if (response_mem[20] !== 8'h00 || response_mem[21] !== 8'h00 ||
            response_mem[22] !== 8'h00 || response_mem[23] !== 8'h01)
            $fatal(1, "STP session_id does not preserve 0x00000001");

        /* Wrong commit evidence must not release packet or increment seq. */
        tx_commit_sequence = 64'd1;
        tx_commit_valid = 1'b1;
        @(posedge clk);
        tx_commit_valid = 1'b0;
        @(posedge clk);
        if (!retained || tx_sequence !== 64'd0)
            $fatal(1, "mismatched commit mutated TX state");

        /* Exact commit releases retained packet and increments once. */
        tx_commit_sequence = 64'd0;
        tx_commit_valid = 1'b1;
        @(posedge clk);
        tx_commit_valid = 1'b0;
        repeat (2) @(posedge clk);
        if (retained || tx_sequence !== 64'd1)
            $fatal(1, "matching commit did not atomically advance TX state");

        /* ZEROIZE is a frozen 0x45 command. */
        clear_request();
        run_command(8'h45, 16'd0);
        expect_ok();
        if (key_valid || session_active || retained)
            $fatal(1, "zeroize did not clear endpoint security state");

        $display("PASS: primer1_endpoint_core key/session/STP/commit integration");
        $finish;
    end
endmodule
