`timescale 1ns/1ps

module tb_ascon_aead_decrypt;
    logic clk;
    logic rst_n;
    logic zeroize;
    logic start;
    logic ready;
    logic [127:0] key;
    logic [127:0] nonce;
    logic [15:0] ad_len;
    logic [15:0] data_len;
    logic in_valid;
    logic in_ready;
    logic [7:0] in_data;
    logic in_last;
    logic tag_valid;
    logic tag_ready;
    logic [127:0] tag;
    logic out_valid;
    logic out_ready;
    logic [7:0] out_data;
    logic out_last;
    logic done;
    logic auth_valid;
    logic auth_ok;
    logic error_valid;
    logic [15:0] error_code;

    logic [7:0] output_bytes [0:127];
    integer output_count;
    integer auth_success_count;
    integer auth_fail_count;

    localparam logic [127:0] KEY_BUS =
        128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    localparam logic [127:0] NONCE_BUS =
        128'h1f1e_1d1c_1b1a_1918_1716_1514_1312_1110;
    localparam logic [127:0] KAT_TAG_BUS =
        128'h59ae_4270_2c02_9d01_9bec_0552_44af_ebdf;

    logic [7:0] ciphertext [0:23];

    ascon_aead_decrypt dut (
        .clk_i         (clk),
        .rst_ni        (rst_n),
        .zeroize_i     (zeroize),
        .start_i       (start),
        .ready_o       (ready),
        .key_i         (key),
        .nonce_i       (nonce),
        .ad_len_i      (ad_len),
        .data_len_i    (data_len),
        .in_valid_i    (in_valid),
        .in_ready_o    (in_ready),
        .in_data_i     (in_data),
        .in_last_i     (in_last),
        .tag_valid_i   (tag_valid),
        .tag_ready_o   (tag_ready),
        .tag_i         (tag),
        .out_valid_o   (out_valid),
        .out_ready_i   (out_ready),
        .out_data_o    (out_data),
        .out_last_o    (out_last),
        .done_o        (done),
        .auth_valid_o  (auth_valid),
        .auth_ok_o     (auth_ok),
        .error_valid_o (error_valid),
        .error_code_o  (error_code)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            output_count <= 0;
            auth_success_count <= 0;
            auth_fail_count <= 0;
        end else begin
            if (out_valid && out_ready) begin
                output_bytes[output_count] <= out_data;
                output_count <= output_count + 1;
            end
            if (auth_valid) begin
                if (auth_ok)
                    auth_success_count <= auth_success_count + 1;
                else
                    auth_fail_count <= auth_fail_count + 1;
            end
        end
    end

    task automatic pulse_start(
        input logic [15:0] requested_ad_len,
        input logic [15:0] requested_data_len
    );
        begin
            while (!ready)
                @(posedge clk);
            @(negedge clk);
            ad_len = requested_ad_len;
            data_len = requested_data_len;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic send_byte(
        input logic [7:0] value,
        input logic last
    );
        begin
            @(negedge clk);
            in_data = value;
            in_last = last;
            in_valid = 1'b1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
            in_last = 1'b0;
        end
    endtask

    task automatic send_tag(input logic [127:0] value);
        begin
            @(negedge clk);
            tag = value;
            tag_valid = 1'b1;
            do @(posedge clk); while (!tag_ready);
            @(negedge clk);
            tag_valid = 1'b0;
        end
    endtask

    task automatic wait_done;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while (!done && timeout_cycles < 5000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!done) begin
                $display("FAIL: timeout waiting for decrypt done state=%0d", dut.state_q);
                $fatal(1);
            end
            @(posedge clk);
        end
    endtask

    task automatic feed_kat_packet;
        integer i;
        begin
            for (i = 0; i < 24; i = i + 1)
                send_byte(8'h30 + i[7:0], 1'b0);
            for (i = 0; i < 24; i = i + 1)
                send_byte(ciphertext[i], (i == 23));
        end
    endtask

    task automatic check_plaintext;
        integer i;
        begin
            if (output_count != 24) begin
                $display("FAIL: plaintext length got=%0d expected=24", output_count);
                $fatal(1);
            end
            for (i = 0; i < 24; i = i + 1) begin
                if (output_bytes[i] !== (8'h20 + i[7:0])) begin
                    $display("FAIL: plaintext[%0d]=%02h expected=%02h",
                             i, output_bytes[i], (8'h20+i[7:0]));
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin : watchdog
        #2_000_000;
        $display("FAIL: global decrypt testbench timeout state=%0d", dut.state_q);
        $fatal(1);
    end

    initial begin
        ciphertext[0]=8'h9d; ciphertext[1]=8'h29;
        ciphertext[2]=8'hf9; ciphertext[3]=8'hd5;
        ciphertext[4]=8'h2a; ciphertext[5]=8'hdf;
        ciphertext[6]=8'h94; ciphertext[7]=8'h70;
        ciphertext[8]=8'haf; ciphertext[9]=8'h4c;
        ciphertext[10]=8'hbc; ciphertext[11]=8'he0;
        ciphertext[12]=8'ha4; ciphertext[13]=8'h48;
        ciphertext[14]=8'h1a; ciphertext[15]=8'hc7;
        ciphertext[16]=8'hfc; ciphertext[17]=8'hb1;
        ciphertext[18]=8'hb3; ciphertext[19]=8'h29;
        ciphertext[20]=8'h76; ciphertext[21]=8'h46;
        ciphertext[22]=8'h98; ciphertext[23]=8'h92;

        clk = 1'b0;
        rst_n = 1'b0;
        zeroize = 1'b0;
        start = 1'b0;
        key = KEY_BUS;
        nonce = NONCE_BUS;
        ad_len = '0;
        data_len = '0;
        in_valid = 1'b0;
        in_data = '0;
        in_last = 1'b0;
        tag_valid = 1'b0;
        tag = '0;
        out_ready = 1'b1;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* Valid official-vector pair. No plaintext is permitted before tag acceptance. */
        output_count = 0;
        pulse_start(16'd24,16'd24);
        feed_kat_packet();
        repeat (10) begin
            @(posedge clk);
            if (out_valid) begin
                $display("FAIL: unauthenticated plaintext was exposed before tag");
                $fatal(1);
            end
        end
        send_tag(KAT_TAG_BUS);
        wait_done();
        check_plaintext();
        if (auth_success_count != 1 || auth_fail_count != 0) begin
            $display("FAIL: valid tag auth pulse count success=%0d fail=%0d",
                     auth_success_count, auth_fail_count);
            $fatal(1);
        end

        /* One-bit tag corruption must discard quarantine and emit no plaintext. */
        @(negedge clk);
        output_count = 0;
        pulse_start(16'd24,16'd24);
        feed_kat_packet();
        send_tag(KAT_TAG_BUS ^ 128'h1);
        wait_done();
        if (output_count != 0) begin
            $display("FAIL: plaintext leaked after bad authentication tag");
            $fatal(1);
        end
        if (auth_fail_count != 1) begin
            $display("FAIL: bad tag did not produce auth failure pulse");
            $fatal(1);
        end

        /* Declared payload limit is enforced before any stream consumption. */
        pulse_start(16'd0,16'd129);
        #1;
        if (!done || !error_valid || error_code != 16'h0501) begin
            $display("FAIL: data_len=129 did not terminate with ERR_ASCON_LENGTH");
            $fatal(1);
        end

        $display("PASS: Ascon-AEAD128 decrypt KAT, verify-before-release and limits");
        $finish;
    end
endmodule
