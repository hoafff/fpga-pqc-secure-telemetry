`timescale 1ns/1ps

module tb_primer1_telemetry_tx;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic zeroize;
    logic start;
    logic [191:0] telemetry;
    logic [15:0] stp_flags;
    logic secure_enable;
    logic key_valid;
    logic session_active;
    logic [31:0] session_id;
    logic [127:0] traffic_key;
    logic [63:0] nonce_prefix;
    logic [63:0] tx_sequence;
    logic release_retained;
    logic [6:0] packet_raddr;
    logic [7:0] packet_rdata;
    logic [6:0] packet_len;
    logic retained_valid;
    logic [63:0] retained_sequence;
    logic busy;
    logic done;
    logic error_valid;
    logic [15:0] error_code;

    /* Byte 0 is the left-most byte below. */
    localparam logic [511:0] EXPECTED_PACKET = 512'h
        50510103000000180102030418191a1b1c1d1e1f00180100
        12a62bb1d21fb4838266123691f2a90c7b2f1ad98cd77349
        ceef16213c2d0845608d8cb1c8732851;

    primer1_telemetry_tx #(
        .SYS_CLK_HZ(1_000_000),
        .ASCON_TIMEOUT_MS(10)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .start_i(start), .telemetry_i(telemetry), .stp_flags_i(stp_flags),
        .secure_enable_i(secure_enable), .key_valid_i(key_valid),
        .session_active_i(session_active), .session_id_i(session_id),
        .traffic_key_i(traffic_key), .nonce_prefix_i(nonce_prefix),
        .tx_sequence_i(tx_sequence), .release_retained_i(release_retained),
        .packet_raddr_i(packet_raddr), .packet_rdata_o(packet_rdata),
        .packet_len_o(packet_len), .retained_valid_o(retained_valid),
        .retained_sequence_o(retained_sequence), .busy_o(busy), .done_o(done),
        .error_valid_o(error_valid), .error_code_o(error_code)
    );

    task pulse_start;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
        end
    endtask

    initial begin
        zeroize = 0;
        start = 0;
        stp_flags = 16'h0000;
        secure_enable = 1;
        key_valid = 1;
        session_active = 1;
        session_id = 32'h01020304;
        traffic_key = 128'h0f0e0d0c0b0a09080706050403020100;
        nonce_prefix = 64'h1716151413121110;
        tx_sequence = 64'h18191a1b1c1d1e1f;
        /* Wire plaintext:
         * timestamp=0102030405060708, sensor=11223344,
         * temperature=-12345, humidity=54321, counter=A1B2C3D4.
         * Byte 0 is stored in telemetry[7:0], hence reversed packed literal. */
        telemetry = 192'hd4c3b2a131d40000c7cfffff443322110807060504030201;
        release_retained = 0;
        packet_raddr = 0;

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        pulse_start();
        wait (busy);

        /* Prove the wrapper uses a snapshot, not live changing session inputs. */
        @(negedge clk);
        session_id = 32'hdeadbeef;
        traffic_key = '0;
        nonce_prefix = '0;
        tx_sequence = 64'hffff_ffff_ffff_ffff;
        telemetry = '0;

        wait (done);
        @(negedge clk);

        if (!retained_valid || packet_len != 7'd64)
            $fatal(1, "retained packet missing");
        if (retained_sequence != 64'h18191a1b1c1d1e1f)
            $fatal(1, "retained sequence changed");

        for (integer i = 0; i < 64; i = i + 1) begin
            packet_raddr = i[6:0];
            #1;
            if (packet_rdata !== EXPECTED_PACKET[511 - 8*i -: 8]) begin
                $fatal(1, "packet byte %0d mismatch got=%02x expected=%02x",
                       i, packet_rdata, EXPECTED_PACKET[511 - 8*i -: 8]);
            end
        end

        /* A retained packet blocks a new encryption. */
        @(negedge clk); start = 1'b1;
        @(posedge clk); #1;
        if (!error_valid || error_code != 16'h0301)
            $fatal(1, "retained packet did not block new TX");
        @(negedge clk); start = 1'b0;

        /* Release retained bytes before accepting another sample. */
        @(negedge clk); release_retained = 1'b1;
        @(negedge clk); release_retained = 1'b0;
        if (retained_valid || packet_len != 0)
            $fatal(1, "retained release failed");

        /* Restore a valid session but encode humidity=100001 -> ERR_ARGUMENT. */
        session_id = 32'h01020304;
        traffic_key = 128'h0f0e0d0c0b0a09080706050403020100;
        nonce_prefix = 64'h1716151413121110;
        tx_sequence = 0;
        telemetry = 192'h000000000000000000000000000000000000000000000000;
        telemetry[8*16 +: 8] = 8'h00;
        telemetry[8*17 +: 8] = 8'h01;
        telemetry[8*18 +: 8] = 8'h86;
        telemetry[8*19 +: 8] = 8'ha1; /* 100001 */

        @(negedge clk); start = 1'b1;
        @(posedge clk); #1;
        if (!error_valid || error_code != 16'h0203 || busy)
            $fatal(1, "invalid humidity not rejected");
        @(negedge clk); start = 1'b0;

        zeroize = 1'b1;
        @(posedge clk); #1;
        if (retained_valid || busy || packet_len != 0)
            $fatal(1, "zeroize failed");
        zeroize = 1'b0;

        $display("PASS: tb_primer1_telemetry_tx");
        $finish;
    end
endmodule
