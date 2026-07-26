`timescale 1ns/1ps

module tb_primer1_pqc_accelerator;
    logic clk_i = 1'b0;
    logic rst_ni = 1'b0;
    logic start_ntt_i = 1'b0;
    logic start_intt_i = 1'b0;
    logic start_ready_o;
    logic busy_o;
    logic done_o;
    logic result_is_intt_o;
    logic host_re_i = 1'b0;
    logic host_we_i = 1'b0;
    logic [7:0] host_addr_i = 8'h00;
    logic [15:0] host_wdata_i = 16'h0000;
    logic host_ready_o;
    logic host_rvalid_o;
    logic [15:0] host_rdata_o;
    logic staged_complete_o;
    logic [2:0] stage_o;
    logic stage_barrier_o;
    logic active_bank_o;

    logic [15:0] transformed [0:255];
    integer i;
    integer timeout_count;

    always #5 clk_i = ~clk_i;

    primer1_pqc_accelerator dut (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_ntt_i(start_ntt_i), .start_intt_i(start_intt_i),
        .start_ready_o(start_ready_o), .busy_o(busy_o), .done_o(done_o),
        .result_is_intt_o(result_is_intt_o),
        .host_re_i(host_re_i), .host_we_i(host_we_i),
        .host_addr_i(host_addr_i), .host_wdata_i(host_wdata_i),
        .host_ready_o(host_ready_o), .host_rvalid_o(host_rvalid_o),
        .host_rdata_o(host_rdata_o), .staged_complete_o(staged_complete_o),
        .stage_o(stage_o), .stage_barrier_o(stage_barrier_o),
        .active_bank_o(active_bank_o)
    );

    task automatic host_write(input [7:0] addr, input [15:0] data);
        begin
            while (!host_ready_o) @(negedge clk_i);
            host_addr_i = addr;
            host_wdata_i = data;
            host_we_i = 1'b1;
            @(negedge clk_i);
            host_we_i = 1'b0;
        end
    endtask

    task automatic host_read(input [7:0] addr, output [15:0] data);
        begin
            while (!host_ready_o) @(negedge clk_i);
            host_addr_i = addr;
            host_re_i = 1'b1;
            @(negedge clk_i);
            host_re_i = 1'b0;
            while (!host_rvalid_o) @(negedge clk_i);
            data = host_rdata_o;
        end
    endtask

    task automatic wait_done;
        begin
            timeout_count = 0;
            while (!done_o && timeout_count < 40000) begin
                @(negedge clk_i);
                timeout_count = timeout_count + 1;
            end
            if (!done_o) $fatal(1, "transform timeout");
        end
    endtask

    logic [15:0] tmp;
    initial begin
        repeat (6) @(negedge clk_i);
        rst_ni = 1'b1;
        repeat (4) @(negedge clk_i);

        // A transform cannot start from uninitialized/stale local memories.
        if (start_ready_o) $fatal(1, "start_ready asserted before full staging");

        for (i=0;i<256;i=i+1)
            host_write(i[7:0], i[15:0]);
        if (!staged_complete_o) $fatal(1, "full 256-coefficient staging not detected");

        @(negedge clk_i);
        start_ntt_i = 1'b1;
        @(negedge clk_i);
        start_ntt_i = 1'b0;
        wait_done();
        if (result_is_intt_o) $fatal(1, "NTT result owner incorrect");
        if (staged_complete_o) $fatal(1, "staging coverage was not consumed by NTT start");

        for (i=0;i<256;i=i+1) begin
            host_read(i[7:0], tmp);
            transformed[i] = tmp;
        end

        // Reload the complete transformed polynomial into both local memories,
        // then execute INTT. This is the real command-level handoff contract.
        for (i=0;i<256;i=i+1)
            host_write(i[7:0], transformed[i]);
        if (!staged_complete_o) $fatal(1, "INTT input staging incomplete");

        @(negedge clk_i);
        start_intt_i = 1'b1;
        @(negedge clk_i);
        start_intt_i = 1'b0;
        wait_done();
        if (!result_is_intt_o) $fatal(1, "INTT result owner incorrect");

        for (i=0;i<256;i=i+1) begin
            host_read(i[7:0], tmp);
            if (tmp !== i[15:0])
                $fatal(1, "service NTT->INTT mismatch index=%0d got=%0d expected=%0d",
                       i, tmp, i);
        end

        $display("PASS: Primer #1 PQC service stages 256 coefficients and executes NTT/INTT correctly");
        $finish;
    end
endmodule
