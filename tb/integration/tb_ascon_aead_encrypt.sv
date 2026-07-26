`timescale 1ns/1ps

module tb_ascon_aead_encrypt;
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
    logic out_valid;
    logic out_ready;
    logic [7:0] out_data;
    logic out_last;
    logic tag_valid;
    logic tag_ready;
    logic [127:0] tag;
    logic done;
    logic error_valid;
    logic [15:0] error_code;

    logic [7:0] output_bytes [0:127];
    integer output_count;
    integer cycle_count;
    logic enable_output_stalls;

    localparam logic [127:0] KEY_BUS =
        128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    localparam logic [127:0] NONCE_BUS =
        128'h1f1e_1d1c_1b1a_1918_1716_1514_1312_1110;
    localparam logic [127:0] EMPTY_TAG_BUS =
        128'hc62e_8bee_468f_f66b_31c9_be11_8227_9c4f;
    localparam logic [127:0] KAT_TAG_BUS =
        128'h59ae_4270_2c02_9d01_9bec_0552_44af_ebdf;

    ascon_aead_encrypt dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .zeroize_i      (zeroize),
        .start_i        (start),
        .ready_o        (ready),
        .key_i          (key),
        .nonce_i        (nonce),
        .ad_len_i       (ad_len),
        .data_len_i     (data_len),
        .in_valid_i     (in_valid),
        .in_ready_o     (in_ready),
        .in_data_i      (in_data),
        .in_last_i      (in_last),
        .out_valid_o    (out_valid),
        .out_ready_i    (out_ready),
        .out_data_o     (out_data),
        .out_last_o     (out_last),
        .tag_valid_o    (tag_valid),
        .tag_ready_i    (tag_ready),
        .tag_o          (tag),
        .done_o         (done),
        .error_valid_o  (error_valid),
        .error_code_o   (error_code)
    );

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            output_count <= 0;
            cycle_count  <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (out_valid && out_ready) begin
                output_bytes[output_count] <= out_data;
                output_count <= output_count + 1;
            end
        end
    end

    always_comb begin
        if (!enable_output_stalls)
            out_ready = 1'b1;
        else
            out_ready = (cycle_count[1:0] != 2'b01);
    end

    task automatic pulse_start(
        input logic [15:0] requested_ad_len,
        input logic [15:0] requested_data_len
    );
        begin
            while (!ready)
                @(posedge clk);
            @(negedge clk);
            ad_len   = requested_ad_len;
            data_len = requested_data_len;
            start    = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start    = 1'b0;
        end
    endtask

    task automatic send_byte(
        input logic [7:0] value,
        input logic       last
    );
        begin
            @(negedge clk);
            in_data  = value;
            in_last  = last;
            in_valid = 1'b1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
            in_last  = 1'b0;
        end
    endtask

    task automatic accept_and_check_tag(
        input logic [127:0] expected_tag
    );
        logic [127:0] held_tag;
        integer i;
        begin
            @(negedge clk);
            tag_ready = 1'b0;
            while (!tag_valid)
                @(posedge clk);

            held_tag = tag;
            if (held_tag !== expected_tag) begin
                $display("FAIL: tag mismatch got=%032h expected=%032h",
                         held_tag, expected_tag);
                $fatal(1);
            end

            for (i = 0; i < 3; i = i + 1) begin
                @(posedge clk);
                if (!tag_valid || tag !== held_tag) begin
                    $display("FAIL: tag changed under backpressure");
                    $fatal(1);
                end
            end

            @(negedge clk);
            tag_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tag_ready = 1'b0;
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
                $display("FAIL: timeout waiting for done state=%0d", dut.state_q);
                $fatal(1);
            end
            @(posedge clk);
        end
    endtask

    task automatic check_24_byte_ciphertext;
        logic [7:0] expected [0:23];
        integer i;
        begin
            expected[0]=8'h9d; expected[1]=8'h29;
            expected[2]=8'hf9; expected[3]=8'hd5;
            expected[4]=8'h2a; expected[5]=8'hdf;
            expected[6]=8'h94; expected[7]=8'h70;
            expected[8]=8'haf; expected[9]=8'h4c;
            expected[10]=8'hbc; expected[11]=8'he0;
            expected[12]=8'ha4; expected[13]=8'h48;
            expected[14]=8'h1a; expected[15]=8'hc7;
            expected[16]=8'hfc; expected[17]=8'hb1;
            expected[18]=8'hb3; expected[19]=8'h29;
            expected[20]=8'h76; expected[21]=8'h46;
            expected[22]=8'h98; expected[23]=8'h92;

            if (output_count != 24) begin
                $display("FAIL: ciphertext length got=%0d expected=24",
                         output_count);
                $fatal(1);
            end

            for (i = 0; i < 24; i = i + 1) begin
                if (output_bytes[i] !== expected[i]) begin
                    $display("FAIL: ciphertext[%0d]=%02h expected=%02h",
                             i, output_bytes[i], expected[i]);
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin : watchdog
        #2_000_000;
        $display("FAIL: global testbench timeout state=%0d ready=%b in_ready=%b tag_valid=%b",
                 dut.state_q, ready, in_ready, tag_valid);
        $fatal(1);
    end

    initial begin
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
        tag_ready = 1'b0;
        enable_output_stalls = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        output_count = 0;
        pulse_start(16'd0, 16'd0);
        accept_and_check_tag(EMPTY_TAG_BUS);
        wait_done();
        if (output_count != 0) begin
            $display("FAIL: empty plaintext emitted ciphertext");
            $fatal(1);
        end

        @(negedge clk);
        output_count = 0;
        enable_output_stalls = 1'b1;
        pulse_start(16'd24, 16'd24);

        for (integer i = 0; i < 24; i = i + 1)
            send_byte(8'h30 + i[7:0], 1'b0);
        for (integer i = 0; i < 24; i = i + 1)
            send_byte(8'h20 + i[7:0], (i == 23));

        accept_and_check_tag(KAT_TAG_BUS);
        wait_done();
        check_24_byte_ciphertext();

        enable_output_stalls = 1'b0;
        pulse_start(16'd0, 16'd129);
        #1;
        if (!error_valid || error_code != 16'h0501) begin
            $display("FAIL: data_len=129 did not raise ERR_ASCON_LENGTH");
            $fatal(1);
        end

        $display("PASS: Ascon-AEAD128 encrypt KATs, streaming and limits");
        $finish;
    end
endmodule
