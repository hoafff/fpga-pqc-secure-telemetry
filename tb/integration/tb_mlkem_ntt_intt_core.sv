`timescale 1ns/1ps

module tb_mlkem_ntt_intt_core;
    localparam integer N = 256;
    localparam integer CASE_COUNT = 5;
    localparam integer TOTAL_VALUES = N * CASE_COUNT;
    localparam integer TIMEOUT_CYCLES = 50000;

    logic clk, rst_n;
    logic start_ntt, start_intt;
    logic busy, done, inverse_active;
    logic host_re, host_we;
    logic [7:0] host_addr;
    logic [15:0] host_wdata;
    logic host_ready, host_rvalid;
    logic [15:0] host_rdata;
    logic [2:0] stage;
    logic barrier, active_bank;

    logic [15:0] input_vectors [0:TOTAL_VALUES-1];
    logic [15:0] ntt_vectors [0:TOTAL_VALUES-1];

    mlkem_ntt_intt_core dut (
        .clk_i(clk), .rst_ni(rst_n),
        .start_ntt_i(start_ntt), .start_intt_i(start_intt),
        .busy_o(busy), .done_o(done), .inverse_active_o(inverse_active),
        .host_re_i(host_re), .host_we_i(host_we), .host_addr_i(host_addr),
        .host_wdata_i(host_wdata), .host_ready_o(host_ready),
        .host_rvalid_o(host_rvalid), .host_rdata_o(host_rdata),
        .stage_o(stage), .stage_barrier_o(barrier), .active_bank_o(active_bank)
    );

    always #5 clk = ~clk;

    task automatic reset_dut;
    begin
        rst_n = 1'b0;
        start_ntt = 1'b0;
        start_intt = 1'b0;
        host_re = 1'b0;
        host_we = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        if (!host_ready || busy)
            $fatal(1, "shared transform core failed to idle after reset");
    end
    endtask

    task automatic load_vector(input integer case_index, input logic use_ntt_vector);
        integer i;
    begin
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            if (!host_ready)
                $fatal(1, "host not ready during vector load");
            host_we = 1'b1;
            host_addr = i[7:0];
            host_wdata = use_ntt_vector
                       ? ntt_vectors[case_index*N+i]
                       : input_vectors[case_index*N+i];
        end
        @(negedge clk);
        host_we = 1'b0;
    end
    endtask

    task automatic pulse_transform(input logic inverse);
    begin
        @(negedge clk);
        if (inverse)
            start_intt = 1'b1;
        else
            start_ntt = 1'b1;
        @(negedge clk);
        start_ntt = 1'b0;
        start_intt = 1'b0;
        wait (busy);
        if (host_ready)
            $fatal(1, "host remained ready during transform");
    end
    endtask

    task automatic wait_done;
        integer cycles;
    begin
        cycles = 0;
        while (!done && cycles < TIMEOUT_CYCLES) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end
        if (!done)
            $fatal(1, "shared transform timeout after %0d cycles", cycles);
        if (busy || !host_ready)
            $fatal(1, "shared transform did not release host on done");
        @(posedge clk);
        #1;
        if (done)
            $fatal(1, "done must be a one-cycle pulse");
    end
    endtask

    task automatic read_coeff(input integer index, output logic [15:0] value);
    begin
        @(negedge clk);
        host_re = 1'b1;
        host_addr = index[7:0];
        @(posedge clk);
        #1;
        if (!host_rvalid)
            $fatal(1, "missing host read response");
        value = host_rdata;
        @(negedge clk);
        host_re = 1'b0;
    end
    endtask

    task automatic check_vector(input integer case_index, input logic expect_ntt);
        integer i;
        logic [15:0] observed;
        logic [15:0] expected;
    begin
        for (i = 0; i < N; i = i + 1) begin
            read_coeff(i, observed);
            expected = expect_ntt
                     ? ntt_vectors[case_index*N+i]
                     : input_vectors[case_index*N+i];
            if (observed !== expected)
                $fatal(1, "case=%0d coeff=%0d got=%0d expected=%0d",
                       case_index, i, observed, expected);
            if (observed >= 3329)
                $fatal(1, "non-canonical coefficient %0d at %0d", observed, i);
        end
    end
    endtask

    integer c;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start_ntt = 1'b0;
        start_intt = 1'b0;
        host_re = 1'b0;
        host_we = 1'b0;
        host_addr = '0;
        host_wdata = '0;

        $readmemh("build/sim/forward_ntt_core_inputs.hex", input_vectors);
        $readmemh("build/sim/forward_ntt_core_expected.hex", ntt_vectors);
        reset_dut();

        for (c = 0; c < CASE_COUNT; c = c + 1) begin
            load_vector(c, 1'b0);
            pulse_transform(1'b0);
            wait_done();
            check_vector(c, 1'b1);

            // Independently load the software-generated NTT image before INTT.
            load_vector(c, 1'b1);
            pulse_transform(1'b1);
            if (!inverse_active)
                $fatal(1, "inverse_active was not asserted during INTT");
            wait_done();
            check_vector(c, 1'b0);
            $display("PASS: shared NTT/INTT core case %0d", c);
        end

        $display("PASS: shared ML-KEM NTT/INTT core matched %0d FIPS-style vectors", CASE_COUNT);
        $finish;
    end
endmodule
