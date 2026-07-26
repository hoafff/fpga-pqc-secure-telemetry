`timescale 1ns/1ps

module tb_btp_duplicate_guard;
    logic clk=0, rst_n=0, zeroize=0;
    always #5 clk=~clk;

    logic check;
    logic [10:0] frame_len;
    logic [15:0] txid;
    logic [7:0] opcode;
    logic [10:0] req_raddr;
    logic [7:0] req_rdata;
    logic response_ready;
    logic busy, decision_valid, is_new, duplicate, collision, cache_valid;
    logic [7:0] mem [0:15];

    assign req_rdata = mem[req_raddr];

    /* Production cache lifetime is ~1 second. Keep this TB lifetime long enough
     * that the compare FSM itself cannot expire the cache while checking 4 bytes. */
    btp_duplicate_guard #(.MAX_FRAME_BYTES(16), .CACHE_CYCLES(128)) dut (
        .clk_i(clk), .rst_ni(rst_n), .zeroize_i(zeroize),
        .check_i(check), .frame_len_i(frame_len),
        .transaction_id_i(txid), .opcode_i(opcode),
        .req_raddr_o(req_raddr), .req_rdata_i(req_rdata),
        .response_ready_i(response_ready), .busy_o(busy),
        .decision_valid_o(decision_valid), .new_request_o(is_new),
        .duplicate_o(duplicate), .collision_o(collision),
        .cache_valid_o(cache_valid)
    );

    task start_check;
        begin
            @(negedge clk); check=1;
            @(negedge clk); check=0;
            wait(decision_valid); #1;
        end
    endtask

    task pulse_response_ready;
        begin
            @(negedge clk); response_ready=1;
            @(negedge clk); response_ready=0;
        end
    endtask

    initial begin
        check=0; response_ready=0; frame_len=4; txid=16'h1234; opcode=8'h60;
        mem[0]=8'h10; mem[1]=8'h20; mem[2]=8'h30; mem[3]=8'h40;
        repeat(3) @(negedge clk); rst_n=1;

        start_check();
        if (!is_new || duplicate || collision)
            $fatal(1,"first request not classified new");
        pulse_response_ready();
        if (!cache_valid) $fatal(1,"response did not arm cache");

        start_check();
        if (is_new || !duplicate || collision)
            $fatal(1,"identical request not classified duplicate");

        /* Same txid/opcode/length but one byte differs -> collision. */
        mem[2]=8'h31;
        start_check();
        if (is_new || duplicate || !collision)
            $fatal(1,"changed request not classified collision");
        pulse_response_ready();

        /* Collision request is now the one-entry cache key. */
        start_check();
        if (!duplicate || is_new || collision)
            $fatal(1,"collision response cache not reusable");

        /* Let the one-entry cache expire, then the request becomes new again. */
        repeat(140) @(negedge clk);
        if (cache_valid) $fatal(1,"cache did not expire");
        start_check();
        if (!is_new || duplicate || collision)
            $fatal(1,"expired request not classified new");

        zeroize=1;
        @(posedge clk); #1;
        if (cache_valid || busy) $fatal(1,"zeroize did not invalidate cache");
        zeroize=0;

        $display("PASS: tb_btp_duplicate_guard");
        $finish;
    end
endmodule
