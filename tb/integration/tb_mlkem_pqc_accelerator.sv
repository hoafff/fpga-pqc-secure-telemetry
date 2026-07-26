`timescale 1ns/1ps

module tb_mlkem_pqc_accelerator;
    localparam integer Q = 3329;
    localparam integer N = 256;
    localparam integer TIMEOUT_CYCLES = 100000;

    logic clk, rst_n;
    logic start_ntt, start_intt, start_pointwise, start_addsub, addsub_sub;
    logic [9:0] operand_base;
    logic [9:0] operand_addr;
    logic [7:0] operand_data;
    logic host_re, host_we;
    logic [7:0] host_addr;
    logic [15:0] host_wdata;
    logic host_ready, host_rvalid;
    logic [15:0] host_rdata;
    logic busy, done, operand_error;
    logic [7:0] operand_error_index;
    logic inverse_active;
    logic [2:0] stage;
    logic barrier, active_bank;

    logic [7:0] operand_mem [0:512];
    logic [15:0] twiddle [0:127];
    logic [15:0] a_vec [0:255];
    logic [15:0] b_vec [0:255];
    logic [15:0] expected [0:255];

    assign operand_data = operand_mem[operand_addr];

    mlkem_pqc_accelerator dut (
        .clk_i(clk), .rst_ni(rst_n),
        .start_ntt_i(start_ntt), .start_intt_i(start_intt),
        .start_pointwise_i(start_pointwise), .start_addsub_i(start_addsub),
        .addsub_sub_i(addsub_sub), .operand_base_i(operand_base),
        .operand_byte_addr_o(operand_addr), .operand_byte_data_i(operand_data),
        .host_re_i(host_re), .host_we_i(host_we), .host_addr_i(host_addr),
        .host_wdata_i(host_wdata), .host_ready_o(host_ready),
        .host_rvalid_o(host_rvalid), .host_rdata_o(host_rdata),
        .busy_o(busy), .done_o(done), .operand_error_o(operand_error),
        .operand_error_index_o(operand_error_index),
        .inverse_active_o(inverse_active), .stage_o(stage),
        .stage_barrier_o(barrier), .active_bank_o(active_bank)
    );

    always #5 clk = ~clk;

    function automatic integer modq(input integer value);
        integer t;
        begin
            t = value % Q;
            if (t < 0) t = t + Q;
            modq = t;
        end
    endfunction

    task automatic reset_dut;
    begin
        rst_n = 1'b0;
        start_ntt = 0; start_intt = 0; start_pointwise = 0; start_addsub = 0;
        addsub_sub = 0; operand_base = 0; host_re = 0; host_we = 0;
        host_addr = 0; host_wdata = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
    end
    endtask

    task automatic load_a;
        integer i;
    begin
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            if (!host_ready) $fatal(1, "host not ready during load");
            host_we = 1'b1;
            host_addr = i[7:0];
            host_wdata = a_vec[i];
        end
        @(negedge clk); host_we = 1'b0;
    end
    endtask

    task automatic fill_operand(input integer base);
        integer i;
    begin
        for (i = 0; i < N; i = i + 1) begin
            operand_mem[base + 2*i] = b_vec[i][15:8];
            operand_mem[base + 2*i + 1] = b_vec[i][7:0];
        end
    end
    endtask

    task automatic pulse_binary(input logic pointwise, input logic subtract, input integer base);
    begin
        @(negedge clk);
        operand_base = base[9:0];
        addsub_sub = subtract;
        start_pointwise = pointwise;
        start_addsub = !pointwise;
        @(negedge clk);
        start_pointwise = 0;
        start_addsub = 0;
        wait (busy);
    end
    endtask

    task automatic wait_done;
        integer cycles;
    begin
        cycles = 0;
        while (!done && cycles < TIMEOUT_CYCLES) begin
            @(posedge clk); #1; cycles = cycles + 1;
        end
        if (!done) $fatal(1, "PQC accelerator timeout");
        @(posedge clk); #1;
    end
    endtask

    task automatic read_coeff(input integer idx, output logic [15:0] value);
    begin
        @(negedge clk);
        host_re = 1'b1;
        host_addr = idx[7:0];
        @(posedge clk); #1;
        if (!host_rvalid) $fatal(1, "missing host read response");
        value = host_rdata;
        @(negedge clk); host_re = 1'b0;
    end
    endtask

    task automatic check_expected;
        integer i;
        logic [15:0] got;
    begin
        for (i = 0; i < N; i = i + 1) begin
            read_coeff(i, got);
            if (got !== expected[i])
                $fatal(1, "coefficient %0d got=%0d expected=%0d", i, got, expected[i]);
        end
    end
    endtask

    integer i, pair;
    integer gamma;
    integer p00, p11, p01, p10;
    logic [15:0] before0;

    initial begin
        clk = 0;
        for (i = 0; i <= 512; i = i + 1) operand_mem[i] = 0;
        $readmemh("tb/vectors/twiddle_3329_standard.hex", twiddle);
        reset_dut();

        for (i = 0; i < N; i = i + 1) begin
            a_vec[i] = (17*i + 3) % Q;
            b_vec[i] = (29*i + 11) % Q;
        end

        // Coordinate-wise polynomial addition.
        fill_operand(1);
        operand_mem[0] = 8'h00;
        for (i = 0; i < N; i = i + 1)
            expected[i] = modq(a_vec[i] + b_vec[i]);
        load_a();
        pulse_binary(1'b0, 1'b0, 1);
        wait_done();
        if (operand_error) $fatal(1, "valid add operand rejected");
        check_expected();
        $display("PASS: ML-KEM polynomial add");

        // Coordinate-wise polynomial subtraction.
        for (i = 0; i < N; i = i + 1)
            expected[i] = modq(a_vec[i] - b_vec[i]);
        load_a();
        pulse_binary(1'b0, 1'b1, 1);
        wait_done();
        check_expected();
        $display("PASS: ML-KEM polynomial sub");

        // FIPS 203 MultiplyNTTs / BaseCaseMultiply. Pair gamma mapping matches
        // the reference implementation: even pair uses zetas[64+i/2], odd pair
        // uses its additive inverse.
        for (pair = 0; pair < 128; pair = pair + 1) begin
            gamma = twiddle[64 + (pair >> 1)];
            if (pair & 1) gamma = modq(-gamma);
            p00 = modq(a_vec[2*pair] * b_vec[2*pair]);
            p11 = modq(a_vec[2*pair+1] * b_vec[2*pair+1]);
            p01 = modq(a_vec[2*pair] * b_vec[2*pair+1]);
            p10 = modq(a_vec[2*pair+1] * b_vec[2*pair]);
            expected[2*pair] = modq(p00 + modq(p11 * gamma));
            expected[2*pair+1] = modq(p01 + p10);
        end
        fill_operand(0);
        load_a();
        pulse_binary(1'b1, 1'b0, 0);
        wait_done();
        check_expected();
        $display("PASS: ML-KEM MultiplyNTTs base-case path");

        // Malformed second operand must be rejected before any writeback. The
        // error flag and completion pulse are produced by the same registered
        // transition, so sample them together before the next clock clears the
        // one-cycle error indication.
        load_a();
        fill_operand(1);
        operand_mem[1 + 2*200] = 8'h0d;
        operand_mem[1 + 2*200 + 1] = 8'h01; // 3329, outside canonical range.
        read_coeff(0, before0);
        pulse_binary(1'b0, 1'b0, 1);
        wait (done);
        if (!operand_error || operand_error_index !== 8'd200)
            $fatal(1, "malformed operand did not report coefficient 200: error=%0d index=%0d",
                   operand_error, operand_error_index);
        read_coeff(0, before0);
        if (before0 !== a_vec[0])
            $fatal(1, "validation failure caused partial writeback");
        $display("PASS: binary operand validation is side-effect free");

        $display("PASS: complete ML-KEM polynomial arithmetic accelerator regression");
        $finish;
    end
endmodule
