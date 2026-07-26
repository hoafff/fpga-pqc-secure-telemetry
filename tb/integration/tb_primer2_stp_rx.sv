`timescale 1ns/1ps

module tb_primer2_stp_rx;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic zeroize = 1'b0;
    logic secure_enable = 1'b1;
    logic fatal_latched = 1'b0;

    logic [31:0] session_id = 32'h10203040;
    logic [127:0] traffic_key =
        128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    logic [63:0] nonce_prefix = 64'h1716_1514_1312_1110;
    logic [63:0] tx_sequence = 64'd0;
    logic [63:0] expected_sequence = 64'd0;
    logic [191:0] telemetry_record;

    logic tx_start;
    logic tx_ready;
    logic tx_done;
    logic tx_error_valid;
    logic [15:0] tx_error_code;
    logic tx_retained_valid;
    logic [6:0] tx_retained_len;
    logic [5:0] tx_rd_addr;
    logic [7:0] tx_rd_data;
    logic tx_packet_commit;

    logic rx_wr_en;
    logic [7:0] rx_wr_addr;
    logic [7:0] rx_wr_data;
    logic [7:0] rx_packet_len;
    logic rx_start;
    logic rx_ready;
    logic rx_done;
    logic rx_error_valid;
    logic [15:0] rx_error_code;
    logic rx_sequence_commit;
    logic [63:0] rx_result_sequence;
    logic rx_release_valid;
    logic [7:0] rx_release_len;
    logic [7:0] rx_release_addr;
    logic [7:0] rx_release_data;
    logic [31:0] accepted_count;
    logic [31:0] replay_count;
    logic [31:0] auth_fail_count;
    logic [1:0] consecutive_auth_fail;
    logic fatal_request;

    always #5 clk = ~clk;

    primer1_stp_tx u_tx (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .secure_enable_i(secure_enable), .fatal_latched_i(fatal_latched),
        .key_valid_i(1'b1), .session_active_i(1'b1),
        .session_id_i(session_id), .traffic_key_i(traffic_key),
        .nonce_prefix_i(nonce_prefix), .tx_sequence_i(tx_sequence),
        .start_i(tx_start), .telemetry_record_i(telemetry_record),
        .ready_o(tx_ready), .busy_o(), .done_o(tx_done),
        .error_valid_o(tx_error_valid), .error_code_o(tx_error_code),
        .retained_valid_o(tx_retained_valid), .retained_sequence_o(),
        .retained_len_o(tx_retained_len), .packet_rd_addr_i(tx_rd_addr),
        .packet_rd_data_o(tx_rd_data), .packet_commit_i(tx_packet_commit),
        .sequence_commit_o()
    );

    primer2_stp_rx u_rx (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .secure_enable_i(secure_enable), .fatal_latched_i(fatal_latched),
        .key_valid_i(1'b1), .session_active_i(1'b1),
        .session_id_i(session_id), .traffic_key_i(traffic_key),
        .nonce_prefix_i(nonce_prefix), .expected_sequence_i(expected_sequence),
        .packet_wr_en_i(rx_wr_en), .packet_wr_addr_i(rx_wr_addr),
        .packet_wr_data_i(rx_wr_data), .packet_len_i(rx_packet_len),
        .start_i(rx_start), .ready_o(rx_ready), .busy_o(), .done_o(rx_done),
        .error_valid_o(rx_error_valid), .error_code_o(rx_error_code),
        .sequence_commit_o(rx_sequence_commit),
        .result_sequence_o(rx_result_sequence),
        .release_valid_o(rx_release_valid), .release_len_o(rx_release_len),
        .release_rd_addr_i(rx_release_addr), .release_rd_data_o(rx_release_data),
        .accepted_count_o(accepted_count), .replay_count_o(replay_count),
        .auth_fail_count_o(auth_fail_count),
        .consecutive_auth_fail_o(consecutive_auth_fail),
        .fatal_request_o(fatal_request)
    );

    task automatic pulse_tx_start;
        begin
            while (!tx_ready) @(posedge clk);
            @(negedge clk); tx_start = 1'b1;
            @(posedge clk); @(negedge clk); tx_start = 1'b0;
        end
    endtask

    task automatic wait_tx_retained;
        integer n;
        begin
            n = 0;
            while (!tx_retained_valid && n < 5000) begin
                @(posedge clk); n = n + 1;
            end
            if (!tx_retained_valid || tx_retained_len != 7'd64 || tx_error_valid)
                $fatal(1,"TX packet generation failed err=%04h",tx_error_code);
        end
    endtask

    task automatic copy_packet(
        input integer mutate_index,
        input logic [7:0] mutate_xor
    );
        integer n;
        logic [7:0] value;
        begin
            while (!rx_ready) @(posedge clk);
            for (n = 0; n < 64; n = n + 1) begin
                tx_rd_addr = n[5:0];
                #1;
                value = tx_rd_data;
                if (n == mutate_index) value = value ^ mutate_xor;
                @(negedge clk);
                rx_wr_addr = n[7:0];
                rx_wr_data = value;
                rx_wr_en = 1'b1;
                @(posedge clk);
                @(negedge clk);
                rx_wr_en = 1'b0;
            end
            rx_packet_len = 8'd64;
        end
    endtask

    task automatic pulse_rx_start;
        begin
            while (!rx_ready) @(posedge clk);
            @(negedge clk); rx_start = 1'b1;
            @(posedge clk); @(negedge clk); rx_start = 1'b0;
        end
    endtask

    task automatic wait_rx_done;
        integer n;
        begin
            n = 0;
            while (!rx_done && n < 5000) begin
                @(posedge clk); n = n + 1;
            end
            if (!rx_done) $fatal(1,"RX timeout");
            #1;
        end
    endtask

    task automatic clear_tx_packet;
        begin
            @(negedge clk); tx_packet_commit = 1'b1;
            @(posedge clk); @(negedge clk); tx_packet_commit = 1'b0;
            while (tx_retained_valid) @(posedge clk);
        end
    endtask

    initial begin : watchdog
        #5_000_000;
        $fatal(1,"Primer2 STP RX test timeout");
    end

    initial begin
        tx_start = 1'b0;
        tx_rd_addr = '0;
        tx_packet_commit = 1'b0;
        rx_wr_en = 1'b0;
        rx_wr_addr = '0;
        rx_wr_data = '0;
        rx_packet_len = '0;
        rx_start = 1'b0;
        rx_release_addr = '0;
        telemetry_record = '0;

        /* 24-byte canonical sample, wire byte i is bits [8*i +: 8]. */
        for (integer k = 0; k < 24; k = k + 1)
            telemetry_record[8*k +: 8] = 8'h20 + k[7:0];
        /* humidity_mpermille = 50000, within the required <=100000 range. */
        telemetry_record[8*16 +: 8] = 8'h00;
        telemetry_record[8*17 +: 8] = 8'h00;
        telemetry_record[8*18 +: 8] = 8'hc3;
        telemetry_record[8*19 +: 8] = 8'h50;

        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (3) @(posedge clk);

        /* 1) Valid sequence 0: authenticate, release exactly 24 bytes, commit once. */
        pulse_tx_start();
        wait_tx_retained();
        copy_packet(-1,8'h00);
        pulse_rx_start();
        wait_rx_done();
        if (rx_error_valid) $fatal(1,"valid packet rejected %04h",rx_error_code);
        if (!rx_release_valid || rx_release_len != 8'd24 || !rx_sequence_commit)
            $fatal(1,"valid packet was not atomically released/committed");
        if (accepted_count != 32'd1 || rx_result_sequence != 64'd0)
            $fatal(1,"valid packet counters/sequence wrong");
        for (integer k = 0; k < 24; k = k + 1) begin
            rx_release_addr = k[7:0]; #1;
            if (rx_release_data !== telemetry_record[8*k +: 8])
                $fatal(1,"plaintext mismatch byte %0d",k);
        end

        /* Session context would atomically advance after the commit pulse. */
        expected_sequence = 64'd1;

        /* 2) Identical sequence 0 is a replay and is rejected before decrypt. */
        copy_packet(-1,8'h00);
        pulse_rx_start();
        wait_rx_done();
        if (!rx_error_valid || rx_error_code != 16'h0605 || replay_count != 32'd1)
            $fatal(1,"replay policy failure err=%04h",rx_error_code);

        /* 3) Change only wire sequence byte 19 from 0 to 2: strict gap reject. */
        copy_packet(19,8'h02);
        pulse_rx_start();
        wait_rx_done();
        if (!rx_error_valid || rx_error_code != 16'h0606 ||
            rx_result_sequence != expected_sequence)
            $fatal(1,"sequence-gap policy failure err=%04h",rx_error_code);

        /* Generate a correct sequence-1 packet, then corrupt one tag bit. */
        clear_tx_packet();
        tx_sequence = 64'd1;
        pulse_tx_start();
        wait_tx_retained();

        /* 4) Three consecutive tag failures never release plaintext and latch fatal. */
        for (integer attempt = 0; attempt < 3; attempt = attempt + 1) begin
            copy_packet(63,8'h01);
            pulse_rx_start();
            wait_rx_done();
            if (!rx_error_valid || rx_release_valid || rx_sequence_commit)
                $fatal(1,"auth failure leaked/committed plaintext attempt=%0d",attempt);
            if ((attempt < 2) && (rx_error_code != 16'h0502))
                $fatal(1,"expected ERR_AUTH_TAG attempt=%0d got=%04h",attempt,rx_error_code);
            if ((attempt == 2) && (rx_error_code != 16'h0608))
                $fatal(1,"expected ERR_AUTH_THRESHOLD got=%04h",rx_error_code);
        end
        if (!fatal_request || auth_fail_count != 32'd3 ||
            consecutive_auth_fail != 2'd3 || expected_sequence != 64'd1)
            $fatal(1,"auth threshold state/counters wrong");

        $display("PASS: Primer2 STP RX valid release, replay/gap and auth-threshold policy");
        $finish;
    end
endmodule
