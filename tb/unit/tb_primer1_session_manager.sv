`timescale 1ns/1ps

module tb_primer1_session_manager;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic zeroize;
    logic secure_enable;
    logic load_begin;
    logic [31:0] load_session_id;
    logic [7:0] load_direction;
    logic [15:0] load_total_len;
    logic load_byte;
    logic [15:0] load_offset;
    logic [7:0] load_data;
    logic load_commit;
    logic [31:0] commit_session_id;
    logic [31:0] commit_policy_flags;
    logic load_abort;
    logic session_activate;
    logic [31:0] activate_session_id;
    logic tx_commit;
    logic [63:0] tx_commit_sequence;
    logic tx_reconcile;
    logic [63:0] rx_expected_sequence;

    logic staging_valid;
    logic [23:0] staging_write_mask;
    logic key_valid;
    logic session_active;
    logic [31:0] session_id;
    logic [127:0] traffic_key;
    logic [63:0] nonce_prefix;
    logic [63:0] tx_sequence;
    logic [31:0] policy_flags;
    logic event_valid;
    logic [15:0] event_code;

    primer1_session_manager dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .secure_enable_i(secure_enable),
        .load_begin_i(load_begin), .load_session_id_i(load_session_id),
        .load_direction_i(load_direction), .load_total_len_i(load_total_len),
        .load_byte_i(load_byte), .load_offset_i(load_offset),
        .load_data_i(load_data), .load_commit_i(load_commit),
        .commit_session_id_i(commit_session_id),
        .commit_policy_flags_i(commit_policy_flags),
        .load_abort_i(load_abort), .session_activate_i(session_activate),
        .activate_session_id_i(activate_session_id),
        .tx_commit_i(tx_commit), .tx_commit_sequence_i(tx_commit_sequence),
        .tx_reconcile_i(tx_reconcile),
        .rx_expected_sequence_i(rx_expected_sequence),
        .staging_valid_o(staging_valid),
        .staging_write_mask_o(staging_write_mask),
        .key_valid_o(key_valid), .session_active_o(session_active),
        .session_id_o(session_id), .traffic_key_o(traffic_key),
        .nonce_prefix_o(nonce_prefix), .tx_sequence_o(tx_sequence),
        .policy_flags_o(policy_flags), .event_valid_o(event_valid),
        .event_code_o(event_code)
    );

    task pulse_begin(input [31:0] sid, input [7:0] dir, input [15:0] len);
        begin
            @(negedge clk);
            load_session_id = sid;
            load_direction = dir;
            load_total_len = len;
            load_begin = 1'b1;
            @(negedge clk);
            load_begin = 1'b0;
        end
    endtask

    task write_byte(input [15:0] off, input [7:0] value);
        begin
            @(negedge clk);
            load_offset = off;
            load_data = value;
            load_byte = 1'b1;
            @(negedge clk);
            load_byte = 1'b0;
        end
    endtask

    initial begin
        zeroize = 0;
        secure_enable = 1;
        load_begin = 0;
        load_session_id = 0;
        load_direction = 0;
        load_total_len = 0;
        load_byte = 0;
        load_offset = 0;
        load_data = 0;
        load_commit = 0;
        commit_session_id = 0;
        commit_policy_flags = 0;
        load_abort = 0;
        session_activate = 0;
        activate_session_id = 0;
        tx_commit = 0;
        tx_commit_sequence = 0;
        tx_reconcile = 0;
        rx_expected_sequence = 0;

        repeat (3) @(negedge clk);
        rst_n = 1;

        /* Bad direction must not create staging state. Event is a one-cycle pulse. */
        pulse_begin(32'h01020304, 8'h02, 16'd24);
        #1;
        if (staging_valid || !event_valid || event_code != 16'h0203)
            $fatal(1, "bad direction not rejected");

        pulse_begin(32'h01020304, 8'h01, 16'd24);
        if (!staging_valid) $fatal(1, "staging did not start");

        for (integer i = 0; i < 24; i = i + 1)
            write_byte(i[15:0], i[7:0]);

        if (staging_write_mask !== 24'hFF_FFFF)
            $fatal(1, "staging mask incomplete: %h", staging_write_mask);

        @(negedge clk);
        commit_session_id = 32'h01020304;
        commit_policy_flags = 32'h11223344;
        load_commit = 1'b1;
        @(negedge clk);
        load_commit = 1'b0;

        if (!key_valid || session_active)
            $fatal(1, "commit must enter KEY_VALID but not ACTIVE");
        if (session_id != 32'h01020304 || tx_sequence != 0)
            $fatal(1, "committed session metadata incorrect");
        if (traffic_key[7:0] != 8'h00 || traffic_key[127:120] != 8'h0f)
            $fatal(1, "traffic key byte packing incorrect");
        if (nonce_prefix[7:0] != 8'h10 || nonce_prefix[63:56] != 8'h17)
            $fatal(1, "nonce prefix byte packing incorrect");

        @(negedge clk);
        activate_session_id = 32'h01020304;
        session_activate = 1'b1;
        @(negedge clk);
        session_activate = 1'b0;
        if (!session_active) $fatal(1, "session activation failed");

        /* Receiver commit advances exactly once. */
        @(negedge clk);
        tx_commit_sequence = 64'd0;
        tx_commit = 1'b1;
        @(negedge clk);
        tx_commit = 1'b0;
        if (tx_sequence != 64'd1) $fatal(1, "commit did not advance sequence");

        /* Lost ACK proof expected=sent+1 advances again. */
        @(negedge clk);
        rx_expected_sequence = 64'd2;
        tx_reconcile = 1'b1;
        @(negedge clk);
        tx_reconcile = 1'b0;
        if (tx_sequence != 64'd2) $fatal(1, "reconcile did not advance sequence");

        /* Arbitrary mismatch disables active TX and reports 0x0610. */
        @(negedge clk);
        rx_expected_sequence = 64'd9;
        tx_reconcile = 1'b1;
        @(posedge clk); #1;
        if (!event_valid || event_code != 16'h0610)
            $fatal(1, "sequence desync not reported");
        @(negedge clk);
        tx_reconcile = 1'b0;
        if (session_active) $fatal(1, "desync did not stop active session");

        zeroize = 1'b1;
        @(posedge clk); #1;
        if (key_valid || session_active || session_id != 0 ||
            traffic_key != 0 || nonce_prefix != 0 || tx_sequence != 0)
            $fatal(1, "zeroize failed");
        zeroize = 1'b0;

        $display("PASS: tb_primer1_session_manager");
        $finish;
    end
endmodule
