`timescale 1ns/1ps

module tb_btp_frame_validator;
    logic clk = 0;
    logic rst_n = 0;
    logic zeroize = 0;
    always #5 clk = ~clk;

    logic start;
    logic [10:0] frame_len;
    logic [10:0] mem_raddr;
    logic [7:0] mem_rdata;
    logic busy, done, valid;
    logic [15:0] error_code;
    logic [7:0] opcode, flags;
    logic [15:0] transaction_id, payload_len;
    logic [7:0] mem [0:63];

    assign mem_rdata = mem[mem_raddr];

    btp_frame_validator #(.MAX_PAYLOAD_BYTES(32), .MAX_FRAME_BYTES(64)) dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .start_i(start), .frame_len_i(frame_len),
        .mem_raddr_o(mem_raddr), .mem_rdata_i(mem_rdata),
        .busy_o(busy), .done_o(done), .valid_o(valid),
        .error_code_o(error_code), .opcode_o(opcode), .flags_o(flags),
        .transaction_id_o(transaction_id), .payload_len_o(payload_len)
    );

    task load_good_frame;
        begin
            /* A55A 01 7F 00 00 1234 0003 010203 CRC32=7AA98E84 */
            mem[0]=8'hA5; mem[1]=8'h5A; mem[2]=8'h01; mem[3]=8'h7F;
            mem[4]=8'h00; mem[5]=8'h00; mem[6]=8'h12; mem[7]=8'h34;
            mem[8]=8'h00; mem[9]=8'h03;
            mem[10]=8'h01; mem[11]=8'h02; mem[12]=8'h03;
            mem[13]=8'h7A; mem[14]=8'hA9; mem[15]=8'h8E; mem[16]=8'h84;
            frame_len=17;
        end
    endtask

    task run_validation;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
            wait(done);
            #1;
        end
    endtask

    initial begin
        start=0; frame_len=0;
        for (integer i=0; i<64; i=i+1) mem[i]=0;
        repeat(3) @(negedge clk); rst_n=1;

        load_good_frame();
        run_validation();
        if (!valid || error_code != 0 || opcode != 8'h7F || flags != 0 ||
            transaction_id != 16'h1234 || payload_len != 16'd3)
            $fatal(1,"valid frame rejected err=%04x",error_code);

        load_good_frame();
        mem[11] = 8'h82;
        run_validation();
        if (valid || error_code != 16'h0104)
            $fatal(1,"CRC corruption not rejected err=%04x",error_code);

        load_good_frame();
        mem[5] = 8'h01;
        run_validation();
        if (valid || error_code != 16'h0202)
            $fatal(1,"reserved byte not rejected err=%04x",error_code);

        load_good_frame();
        frame_len = 16;
        run_validation();
        if (valid || error_code != 16'h0103)
            $fatal(1,"length mismatch not rejected err=%04x",error_code);

        load_good_frame();
        mem[0] = 8'h00;
        run_validation();
        if (valid || error_code != 16'h0101)
            $fatal(1,"SOF mismatch not rejected err=%04x",error_code);

        $display("PASS: tb_btp_frame_validator");
        $finish;
    end
endmodule
