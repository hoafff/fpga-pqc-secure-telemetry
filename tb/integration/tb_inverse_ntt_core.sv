`timescale 1ns/1ps

module tb_inverse_ntt_core;
    logic clk_i = 1'b0;
    logic rst_ni = 1'b0;

    logic fwd_start;
    logic fwd_busy;
    logic fwd_done;
    logic fwd_re;
    logic fwd_we;
    logic [7:0] fwd_addr;
    logic [15:0] fwd_wdata;
    logic fwd_ready;
    logic fwd_rvalid;
    logic [15:0] fwd_rdata;
    logic [2:0] fwd_stage;
    logic fwd_barrier;
    logic fwd_bank;

    logic inv_start;
    logic inv_busy;
    logic inv_done;
    logic inv_re;
    logic inv_we;
    logic [7:0] inv_addr;
    logic [15:0] inv_wdata;
    logic inv_ready;
    logic inv_rvalid;
    logic [15:0] inv_rdata;
    logic [2:0] inv_stage;
    logic inv_barrier;
    logic inv_bank;

    integer i;
    integer timeout_count;
    logic [15:0] expected [0:255];

    always #5 clk_i = ~clk_i;

    forward_ntt_core u_forward (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_i(fwd_start), .busy_o(fwd_busy), .done_o(fwd_done),
        .host_re_i(fwd_re), .host_we_i(fwd_we), .host_addr_i(fwd_addr),
        .host_wdata_i(fwd_wdata), .host_ready_o(fwd_ready),
        .host_rvalid_o(fwd_rvalid), .host_rdata_o(fwd_rdata),
        .stage_o(fwd_stage), .stage_barrier_o(fwd_barrier),
        .active_bank_o(fwd_bank)
    );

    inverse_ntt_core u_inverse (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .start_i(inv_start), .busy_o(inv_busy), .done_o(inv_done),
        .host_re_i(inv_re), .host_we_i(inv_we), .host_addr_i(inv_addr),
        .host_wdata_i(inv_wdata), .host_ready_o(inv_ready),
        .host_rvalid_o(inv_rvalid), .host_rdata_o(inv_rdata),
        .stage_o(inv_stage), .stage_barrier_o(inv_barrier),
        .active_bank_o(inv_bank)
    );

    task automatic fwd_write(input [7:0] addr, input [15:0] data);
        begin
            @(negedge clk_i);
            fwd_addr = addr;
            fwd_wdata = data;
            fwd_we = 1'b1;
            @(negedge clk_i);
            fwd_we = 1'b0;
        end
    endtask

    task automatic fwd_read(input [7:0] addr, output [15:0] data);
        begin
            @(negedge clk_i);
            fwd_addr = addr;
            fwd_re = 1'b1;
            @(negedge clk_i);
            fwd_re = 1'b0;
            while (!fwd_rvalid) @(negedge clk_i);
            data = fwd_rdata;
        end
    endtask

    task automatic inv_write(input [7:0] addr, input [15:0] data);
        begin
            @(negedge clk_i);
            inv_addr = addr;
            inv_wdata = data;
            inv_we = 1'b1;
            @(negedge clk_i);
            inv_we = 1'b0;
        end
    endtask

    task automatic inv_read(input [7:0] addr, output [15:0] data);
        begin
            @(negedge clk_i);
            inv_addr = addr;
            inv_re = 1'b1;
            @(negedge clk_i);
            inv_re = 1'b0;
            while (!inv_rvalid) @(negedge clk_i);
            data = inv_rdata;
        end
    endtask

    task automatic run_case(input integer case_id);
        logic [15:0] tmp;
        integer value;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                if (case_id == 0)
                    value = i;
                else
                    value = ((i*i) + 17*i + 123) % 3329;
                expected[i] = value[15:0];
                fwd_write(i[7:0], value[15:0]);
            end

            @(negedge clk_i);
            fwd_start = 1'b1;
            @(negedge clk_i);
            fwd_start = 1'b0;

            timeout_count = 0;
            while (!fwd_done && timeout_count < 20000) begin
                @(negedge clk_i);
                timeout_count = timeout_count + 1;
            end
            if (!fwd_done) $fatal(1, "forward NTT timeout");

            // Transfer the verified forward transform image into the inverse
            // core through the same host interface used by the BTP endpoint.
            for (i = 0; i < 256; i = i + 1) begin
                fwd_read(i[7:0], tmp);
                inv_write(i[7:0], tmp);
            end

            @(negedge clk_i);
            inv_start = 1'b1;
            @(negedge clk_i);
            inv_start = 1'b0;

            timeout_count = 0;
            while (!inv_done && timeout_count < 30000) begin
                @(negedge clk_i);
                timeout_count = timeout_count + 1;
            end
            if (!inv_done) $fatal(1, "inverse NTT timeout");

            for (i = 0; i < 256; i = i + 1) begin
                inv_read(i[7:0], tmp);
                if (tmp !== expected[i])
                    $fatal(1,
                        "forward->inverse mismatch case=%0d index=%0d got=%0d expected=%0d",
                        case_id, i, tmp, expected[i]);
            end
        end
    endtask

    initial begin
        fwd_start = 1'b0;
        fwd_re = 1'b0;
        fwd_we = 1'b0;
        fwd_addr = 8'h00;
        fwd_wdata = 16'h0000;
        inv_start = 1'b0;
        inv_re = 1'b0;
        inv_we = 1'b0;
        inv_addr = 8'h00;
        inv_wdata = 16'h0000;

        repeat (6) @(negedge clk_i);
        rst_ni = 1'b1;
        repeat (4) @(negedge clk_i);

        run_case(0);
        run_case(1);

        $display("PASS: inverse_ntt_core exactly inverts forward_ntt_core for two 256-coefficient vectors");
        $finish;
    end
endmodule
