`timescale 1ns/1ps

module tb_twiddle_rom_3329;
    localparam int unsigned Q = 3329;
    localparam int unsigned DEPTH = 128;
    localparam int unsigned MAX_EXPECTED = 1024;

    logic        clk;
    logic        rst_n;
    logic        valid_i;
    logic [6:0]  addr_i;
    logic        valid_o;
    logic [15:0] zeta_o;

    logic [15:0] expected_rom [0:DEPTH-1];
    logic [15:0] expected_queue [0:MAX_EXPECTED-1];

    logic expected_valid_s1;
    logic expected_valid_now;

    integer unsigned head;
    integer unsigned tail;
    integer unsigned sent_count;
    integer unsigned recv_count;
    integer unsigned i;
    logic [31:0] prng;

    twiddle_rom_3329 dut (
        .clk_i   (clk),
        .rst_ni  (rst_n),
        .valid_i (valid_i),
        .addr_i  (addr_i),
        .valid_o (valid_o),
        .zeta_o  (zeta_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic drive_address(
        input logic drive_valid,
        input integer unsigned address
    );
    begin
        @(negedge clk);
        valid_i = drive_valid;
        addr_i  = address[6:0];

        if (drive_valid) begin
            if (tail >= MAX_EXPECTED)
                $fatal(1, "tb_twiddle_rom_3329: expected queue overflow");

            expected_queue[tail] = expected_rom[address];
            tail                 = tail + 1;
            sent_count           = sent_count + 1;
        end
    end
    endtask

    task automatic prng_next;
    begin
        prng = prng ^ (prng << 13);
        prng = prng ^ (prng >> 17);
        prng = prng ^ (prng << 5);
    end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            expected_valid_s1  = 1'b0;
            expected_valid_now = 1'b0;
            head       = 0;
            tail       = 0;
            sent_count = 0;
            recv_count = 0;
        end else begin
            // valid_o corresponds to valid_i from one earlier rising edge.
            expected_valid_now = expected_valid_s1;
            expected_valid_s1  = valid_i;

            #1;

            if (valid_o !== expected_valid_now)
                $fatal(1,
                    "twiddle_rom_3329 valid mismatch: got=%0b expected=%0b",
                    valid_o, expected_valid_now);

            if (expected_valid_now) begin
                if (head >= tail)
                    $fatal(1, "twiddle_rom_3329 produced an unexpected output");

                if (zeta_o !== expected_queue[head])
                    $fatal(1,
                        "twiddle_rom_3329 data mismatch: index=%0d got=%0d expected=%0d",
                        head, zeta_o, expected_queue[head]);

                if (zeta_o >= Q)
                    $fatal(1,
                        "twiddle_rom_3329 produced non-canonical zeta=%0d",
                        zeta_o);

                head       = head + 1;
                recv_count = recv_count + 1;
            end
        end
    end

    initial begin
        $readmemh("tb/vectors/twiddle_3329_standard.hex", expected_rom);

        // Independent spot checks for the generated vector.
        if (expected_rom[0] !== 16'd1)
            $fatal(1, "twiddle vector address 0 must equal 1");
        if (expected_rom[1] !== 16'd1729)
            $fatal(1, "twiddle vector address 1 mismatch");
        if (expected_rom[64] !== 16'd17)
            $fatal(1, "twiddle vector address 64 must equal root 17");
        if (expected_rom[127] !== 16'd2154)
            $fatal(1, "twiddle vector address 127 mismatch");

        for (i = 0; i < DEPTH; i = i + 1)
            if (expected_rom[i] >= Q)
                $fatal(1,
                    "twiddle vector contains non-canonical value at address=%0d value=%0d",
                    i, expected_rom[i]);

        rst_n   = 1'b0;
        valid_i = 1'b0;
        addr_i  = '0;
        prng    = 32'h2468ace1;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Exhaustively read every ROM address with continuous traffic.
        for (i = 0; i < DEPTH; i = i + 1)
            drive_address(1'b1, i);

        // Reproducible random traffic with bubbles.
        for (i = 0; i < 512; i = i + 1) begin
            prng_next();
            if (prng[2:0] == 3'b000)
                drive_address(1'b0, 0);
            else
                drive_address(1'b1, prng[6:0]);
        end

        // Drain the one-cycle pipeline.
        repeat (4)
            drive_address(1'b0, 0);

        @(negedge clk);
        if (head != tail)
            $fatal(1,
                "tb_twiddle_rom_3329 did not drain: head=%0d tail=%0d",
                head, tail);

        $display(
            "PASS: twiddle_rom_3329 sent=%0d received=%0d",
            sent_count, recv_count);
        $finish;
    end
endmodule
