`timescale 1ns/1ps
module tb_fpst_telemetry_tx;
    logic clk=0, rst_n=0, zeroize=0, secure_enable=1, start=0;
    logic ready,busy,done,packet_valid,err_v,release;
    logic [15:0] packet_len,err;
    logic [63:0] packet_seq;
    logic [6:0] packet_addr;
    logic [7:0] packet_data;
    logic [191:0] sample;
    integer i;
    always #5 clk=~clk;

    fpst_telemetry_tx dut(
        .clk_i(clk),.rst_ni(rst_n),.zeroize_i(zeroize),.secure_enable_i(secure_enable),
        .start_i(start),.ready_o(ready),.telemetry_record_i(sample),
        .session_active_i(1'b1),.session_id_i(32'h01020304),
        .key_i(128'h0f0e0d0c0b0a09080706050403020100),
        .nonce_prefix_i(64'h1716151413121110),.sequence_i(64'h0102030405060708),
        .busy_o(busy),.done_o(done),.packet_valid_o(packet_valid),.packet_len_o(packet_len),
        .packet_sequence_o(packet_seq),.packet_addr_i(packet_addr),.packet_data_o(packet_data),
        .packet_release_i(release),.error_valid_o(err_v),.error_code_o(err));

    task check_byte(input integer a,input [7:0] e);
        begin packet_addr=a[6:0]; #1; if(packet_data!==e) $fatal(1,"packet[%0d]=%02x expected %02x",a,packet_data,e); end
    endtask

    initial begin
        sample='0; release=0; packet_addr=0;
        for(i=0;i<24;i=i+1) sample[8*i +: 8]=8'h20+i;
        repeat(3) @(posedge clk); rst_n=1; @(negedge clk);
        if(!ready) $fatal(1,"tx not ready");
        start=1; @(posedge clk); @(negedge clk); start=0;
        fork
            begin wait(packet_valid); end
            begin repeat(5000) @(posedge clk); $fatal(1,"telemetry timeout"); end
        join_any
        disable fork;
        if(packet_len!==16'd64 || packet_seq!==64'h0102030405060708) $fatal(1,"packet metadata wrong");
        check_byte(0,8'h50); check_byte(1,8'h51); check_byte(2,8'h01); check_byte(3,8'h03);
        check_byte(4,8'h00); check_byte(5,8'h00); check_byte(6,8'h00); check_byte(7,8'h18);
        check_byte(8,8'h01); check_byte(9,8'h02); check_byte(10,8'h03); check_byte(11,8'h04);
        check_byte(12,8'h01); check_byte(13,8'h02); check_byte(14,8'h03); check_byte(15,8'h04);
        check_byte(16,8'h05); check_byte(17,8'h06); check_byte(18,8'h07); check_byte(19,8'h08);
        check_byte(20,8'h00); check_byte(21,8'h18); check_byte(22,8'h01); check_byte(23,8'h00);
        repeat(5) @(posedge clk);
        if(!packet_valid) $fatal(1,"retained packet did not persist");
        release=1; @(posedge clk); @(negedge clk); release=0;
        if(packet_valid) $fatal(1,"packet release failed");
        $display("PASS: fpst_telemetry_tx STP header/retention");
        $finish;
    end
endmodule
