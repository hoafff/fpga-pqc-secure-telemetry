`timescale 1ns/1ps

module tb_primer2_stp_rx_bad_config;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic packet_wr_en = 1'b0;
    logic [7:0] packet_wr_addr = '0;
    logic [7:0] packet_wr_data = '0;
    logic start = 1'b0;
    logic ready;
    logic busy;
    logic done;
    logic error_valid;
    logic [15:0] error_code;
    logic sequence_commit;
    logic release_valid;

    always #5 clk = ~clk;

    /*
     * Deliberately reproduce the old invalid defaults. The fixed-profile
     * receiver must report ERR_ASCON_LENGTH and return idle, never hang.
     */
    primer2_stp_rx #(
        .MAX_PAYLOAD_BYTES(128),
        .MAX_PACKET_BYTES(168)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .zeroize_i(1'b0),
        .secure_enable_i(1'b1),
        .fatal_latched_i(1'b0),
        .key_valid_i(1'b1),
        .session_active_i(1'b1),
        .session_id_i(32'h1020_3040),
        .traffic_key_i(128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100),
        .nonce_prefix_i(64'h1716_1514_1312_1110),
        .expected_sequence_i(64'd0),
        .packet_wr_en_i(packet_wr_en),
        .packet_wr_addr_i(packet_wr_addr),
        .packet_wr_data_i(packet_wr_data),
        .packet_len_i(8'd64),
        .start_i(start),
        .ready_o(ready),
        .busy_o(busy),
        .done_o(done),
        .error_valid_o(error_valid),
        .error_code_o(error_code),
        .sequence_commit_o(sequence_commit),
        .result_sequence_o(),
        .release_valid_o(release_valid),
        .release_len_o(),
        .release_rd_addr_i(8'd0),
        .release_rd_data_o(),
        .accepted_count_o(),
        .replay_count_o(),
        .auth_fail_count_o(),
        .consecutive_auth_fail_o(),
        .fatal_request_o()
    );

    task automatic write_byte(input logic [7:0] addr, input logic [7:0] value);
        begin
            @(negedge clk);
            packet_wr_addr = addr;
            packet_wr_data = value;
            packet_wr_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            packet_wr_en = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        write_byte(8'd0, 8'h50);
        write_byte(8'd1, 8'h51);
        write_byte(8'd2, 8'h01);
        write_byte(8'd3, 8'h03);
        write_byte(8'd6, 8'h00);
        write_byte(8'd7, 8'h18);
        write_byte(8'd8, 8'h10);
        write_byte(8'd9, 8'h20);
        write_byte(8'd10, 8'h30);
        write_byte(8'd11, 8'h40);
        write_byte(8'd20, 8'h00);
        write_byte(8'd21, 8'h18);
        write_byte(8'd22, 8'h01);

        while (!ready) @(posedge clk);
        @(negedge clk);
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        begin : wait_terminal_error
            integer cycles;
            logic seen;
            cycles = 0;
            seen = 1'b0;
            while (!seen && cycles < 32) begin
                @(posedge clk);
                #1;
                seen = done;
                cycles = cycles + 1;
            end
            if (!seen)
                $fatal(1, "bad-config receiver hung instead of terminating");
        end

        if (!error_valid || error_code != 16'h0501)
            $fatal(1, "expected ERR_ASCON_LENGTH, got valid=%0b code=%04h",
                   error_valid, error_code);
        if (sequence_commit || release_valid)
            $fatal(1, "bad-config receiver committed or released plaintext");

        @(posedge clk);
        #1;
        if (!ready || busy)
            $fatal(1, "bad-config receiver did not return idle");

        $display("PASS: Primer2 invalid profile fails fast without RX timeout");
        $finish;
    end
endmodule
