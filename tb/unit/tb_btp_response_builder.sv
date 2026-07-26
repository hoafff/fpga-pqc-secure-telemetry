`timescale 1ns/1ps

module tb_btp_response_builder;
    logic clk=0, rst_n=0, zeroize=0;
    always #5 clk=~clk;

    logic start;
    logic [9:0] app_raddr;
    logic [7:0] app_rdata;
    logic rsp_we;
    logic [10:0] rsp_waddr;
    logic [7:0] rsp_wdata;
    logic [10:0] rsp_len;
    logic rsp_commit, busy, done, arg_error;
    logic [7:0] app_mem [0:1];
    logic [7:0] rsp_mem [0:63];

    assign app_rdata = (app_raddr < 2) ? app_mem[app_raddr] : 8'h00;

    btp_response_builder #(.MAX_PAYLOAD_BYTES(64)) dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .start_i(start), .opcode_i(8'h7F), .flags_i(8'h00),
        .transaction_id_i(16'h1234), .status_code_i(16'h0000),
        .detail_code_i(16'h0000), .device_state_i(32'h11223344),
        .result_meta_i(32'h00000002), .app_len_i(10'd2),
        .app_raddr_o(app_raddr), .app_rdata_i(app_rdata),
        .rsp_we_o(rsp_we), .rsp_waddr_o(rsp_waddr),
        .rsp_wdata_o(rsp_wdata), .rsp_len_o(rsp_len),
        .rsp_commit_o(rsp_commit), .busy_o(busy), .done_o(done),
        .argument_error_o(arg_error)
    );

    always_ff @(posedge clk) begin
        if (rsp_we) rsp_mem[rsp_waddr] <= rsp_wdata;
    end

    localparam logic [223:0] EXPECTED = 224'h
        a55a017f01001234000e000000001122334400000002dead59751e86;

    initial begin
        start=0;
        app_mem[0]=8'hDE;
        app_mem[1]=8'hAD;
        for (integer i=0;i<64;i=i+1) rsp_mem[i]=0;
        repeat(3) @(negedge clk); rst_n=1;

        @(negedge clk); start=1;
        @(negedge clk); start=0;
        wait(done);
        #1;
        if (arg_error || rsp_len != 11'd28)
            $fatal(1,"bad response length/error");
        if (!rsp_commit)
            $fatal(1,"response commit did not coincide with completion");

        /* Last write and testbench capture both happen on the done edge. */
        @(negedge clk);
        for (integer i=0;i<28;i=i+1) begin
            if (rsp_mem[i] !== EXPECTED[223-8*i -: 8])
                $fatal(1,"response byte %0d got=%02x expected=%02x",
                       i,rsp_mem[i],EXPECTED[223-8*i -: 8]);
        end

        $display("PASS: tb_btp_response_builder");
        $finish;
    end
endmodule
