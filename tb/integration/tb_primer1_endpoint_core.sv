`timescale 1ns/1ps

module tb_primer1_endpoint_core;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic external_zeroize, secure_enable, safe_locked;
    logic req_valid;
    logic [10:0] req_len;
    logic req_take;
    logic [10:0] req_raddr;
    logic [7:0] req_rdata;
    logic rsp_we;
    logic [10:0] rsp_waddr;
    logic [7:0] rsp_wdata;
    logic [10:0] rsp_len;
    logic rsp_commit, rsp_rearm, rsp_consumed;
    logic endpoint_busy, key_valid, session_active, retained_valid;
    logic [63:0] tx_sequence;
    logic [15:0] last_error;

    logic [7:0] req_mem [0:63];
    logic [7:0] rsp_mem [0:127];
    integer response_commit_count;
    integer response_rearm_count;

    assign req_rdata = req_mem[req_raddr];

    always_ff @(posedge clk) begin
        if (rsp_we) rsp_mem[rsp_waddr] <= rsp_wdata;
        if (rsp_commit) response_commit_count <= response_commit_count + 1;
        if (rsp_rearm) response_rearm_count <= response_rearm_count + 1;
    end

    primer1_endpoint_core #(
        .SYS_CLK_HZ(1_000_000),
        .RESPONSE_CACHE_CYCLES(10000)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .external_zeroize_i(external_zeroize),
        .secure_enable_i(secure_enable), .safe_locked_i(safe_locked),
        .req_valid_i(req_valid), .req_len_i(req_len),
        .req_take_o(req_take), .req_raddr_o(req_raddr),
        .req_rdata_i(req_rdata),
        .rsp_we_o(rsp_we), .rsp_waddr_o(rsp_waddr),
        .rsp_wdata_o(rsp_wdata), .rsp_len_o(rsp_len),
        .rsp_commit_o(rsp_commit), .rsp_rearm_o(rsp_rearm),
        .rsp_consumed_i(rsp_consumed),
        .endpoint_busy_o(endpoint_busy), .key_valid_o(key_valid),
        .session_active_o(session_active), .retained_valid_o(retained_valid),
        .tx_sequence_o(tx_sequence), .last_error_o(last_error)
    );

    function automatic [31:0] crc32_byte(
        input [31:0] crc_in, input [7:0] byte_in
    );
        reg [31:0] c;
        integer b;
        begin
            c = crc_in ^ byte_in;
            for (b=0;b<8;b=b+1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    task build_zero_payload_request(input [7:0] opcode, input [15:0] txid);
        reg [31:0] crc;
        begin
            for (integer k=0;k<64;k=k+1) req_mem[k]=0;
            req_mem[0]=8'hA5; req_mem[1]=8'h5A; req_mem[2]=8'h01;
            req_mem[3]=opcode; req_mem[4]=8'h00; req_mem[5]=8'h00;
            req_mem[6]=txid[15:8]; req_mem[7]=txid[7:0];
            req_mem[8]=8'h00; req_mem[9]=8'h00;
            crc=32'hFFFFFFFF;
            for (integer k=2;k<10;k=k+1) crc=crc32_byte(crc,req_mem[k]);
            crc=crc ^ 32'hFFFFFFFF;
            req_mem[10]=crc[31:24]; req_mem[11]=crc[23:16];
            req_mem[12]=crc[15:8]; req_mem[13]=crc[7:0];
            req_len=14;
        end
    endtask

    task issue_request_and_wait_take;
        begin
            @(negedge clk); req_valid=1;
            wait(req_take);
            @(negedge clk); req_valid=0;
            @(negedge clk);
        end
    endtask

    initial begin
        external_zeroize=0; secure_enable=1; safe_locked=0;
        req_valid=0; req_len=0; rsp_consumed=0;
        response_commit_count=0; response_rearm_count=0;
        for (integer k=0;k<128;k=k+1) rsp_mem[k]=0;

        repeat(4) @(negedge clk); rst_n=1;
        repeat(2) @(negedge clk);

        /* First request executes normally and creates a cached response. */
        build_zero_payload_request(8'h7F,16'h1234);
        issue_request_and_wait_take();
        if (response_commit_count != 1)
            $fatal(1,"PING response was not built");
        if (rsp_mem[0] != 8'hA5 || rsp_mem[1] != 8'h5A ||
            rsp_mem[3] != 8'h7F || rsp_mem[4] != 8'h01)
            $fatal(1,"PING response header incorrect");
        if (rsp_mem[10] != 0 || rsp_mem[11] != 0)
            $fatal(1,"PING returned error status");
        if ({rsp_mem[22],rsp_mem[23],rsp_mem[24],rsp_mem[25]} != 32'h46505354)
            $fatal(1,"PING application payload incorrect");

        /* Byte-identical retry must re-arm cache, not re-execute/build. */
        build_zero_payload_request(8'h7F,16'h1234);
        issue_request_and_wait_take();
        if (response_commit_count != 1 || response_rearm_count != 1)
            $fatal(1,"duplicate was not served from response cache");

        /* Same transaction ID with a different request is a collision. */
        build_zero_payload_request(8'h02,16'h1234);
        issue_request_and_wait_take();
        if (response_commit_count != 2)
            $fatal(1,"collision response was not built");
        if (rsp_mem[4] != 8'h03 || {rsp_mem[10],rsp_mem[11]} != 16'h0207)
            $fatal(1,"collision error response incorrect");
        if (last_error != 16'h0207)
            $fatal(1,"collision was not latched as last error");

        if (key_valid || session_active || retained_valid || tx_sequence != 0)
            $fatal(1,"control-plane smoke test modified secure state");

        $display("PASS: tb_primer1_endpoint_core");
        $finish;
    end
endmodule
