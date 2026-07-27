`timescale 1ns/1ps
module tb_supervisor_system_integration;
    localparam logic [15:0] E_MCU  = 16'h0701;
    localparam logic [15:0] E_PQC  = 16'h0702;
    localparam logic [15:0] E_CRY  = 16'h0703;
    localparam logic [15:0] E_TAMP = 16'h0704;
    localparam logic [15:0] E_MAN  = 16'h0705;
    localparam logic [15:0] E_AUTH = 16'h0608;
    localparam logic [2:0] ST_MONITOR  = 3'd2;
    localparam logic [2:0] ST_SAFE     = 3'd5;
    localparam logic [2:0] ST_RECOVERY = 3'd6;

    logic clk = 1'b0;
    logic p1_rst_n = 1'b0;
    logic p2_rst_n = 1'b0;
    logic hb_mcu = 1'b0;
    logic hb_mcu_run = 1'b1;
    logic [1:0] hb_mcu_div = '0;

    logic tamper_ext_n = 1'b1;
    logic manual_fault = 1'b0;
    logic clear_fault = 1'b0;
    logic btn_tamper_n = 1'b1;
    logic btn_clear_n = 1'b1;

    logic secure_enable;
    logic zeroize_n;
    logic system_reset_n;
    logic fault_latched;
    logic led_fault, led_secure;

    logic p1_hb, p2_hb;
    logic p1_fault, p2_fault;
    logic p1_miso, p2_miso;
    logic p1_irq_n, p2_irq_n;
    logic p1_busy, p2_busy;
    logic [6:0] p1_led_n, p2_led_n;

    integer p1_hb_edges = 0;
    integer p2_hb_edges = 0;
    logic p1_hb_prev = 1'b0;
    logic p2_hb_prev = 1'b0;
    logic zeroize_seen_before_reset = 1'b0;

    always #5 clk = ~clk;

    always_ff @(posedge clk) begin
        if (hb_mcu_run) begin
            if (hb_mcu_div == 2'd1) begin
                hb_mcu_div <= '0;
                hb_mcu <= ~hb_mcu;
            end else begin
                hb_mcu_div <= hb_mcu_div + 1'b1;
            end
        end

        if (p1_hb != p1_hb_prev) begin
            p1_hb_edges <= p1_hb_edges + 1;
            p1_hb_prev <= p1_hb;
        end
        if (p2_hb != p2_hb_prev) begin
            p2_hb_edges <= p2_hb_edges + 1;
            p2_hb_prev <= p2_hb;
        end

        if (!zeroize_n)
            zeroize_seen_before_reset <= 1'b1;
        if (!system_reset_n && !zeroize_seen_before_reset)
            $fatal(1, "SYSTEM_RESET_N asserted before ZEROIZE_N");
    end

    supervisor_top #(
        .CLK_HZ(1000),
        .POR_CYCLES(2),
        .BUTTON_DEBOUNCE_MS(1),
        .HB_TIMEOUT_MS(8),
        .STARTUP_ZEROIZE_MS(2),
        .STARTUP_GRACE_MS(4),
        .QUALIFY_MS(6),
        .ZEROIZE_HOLD_MS(2),
        .RESET_PULSE_MS(2),
        .RECOVERY_QUALIFY_MS(6),
        .RESET_ON_FATAL(1'b1)
    ) tiny (
        .clk_27m(clk),
        .hb_mcu_i(hb_mcu),
        .hb_pqc_i(p1_hb),
        .hb_crypto_i(p2_hb),
        .crypto_fault_i(p2_fault),
        .tamper_ext_ni(tamper_ext_n),
        .manual_fault_i(manual_fault),
        .clear_fault_i(clear_fault),
        .btn_tamper_n(btn_tamper_n),
        .btn_clear_n(btn_clear_n),
        .secure_enable_o(secure_enable),
        .zeroize_no(zeroize_n),
        .system_reset_no(system_reset_n),
        .fault_latched_o(fault_latched),
        .led_fault_o(led_fault),
        .led_secure_o(led_secure)
    );

    kiwi_primer20k_fpst_tx_top #(
        .CLOCK_HZ(27_000_000),
        .HEARTBEAT_TOGGLE_CYCLES(2)
    ) p1 (
        .sys_clk_i(clk), .rst_ni(p1_rst_n),
        .spi_sck_i(1'b0), .spi_cs_ni(1'b1), .spi_mosi_i(1'b0),
        .spi_miso_o(p1_miso), .irq_no(p1_irq_n), .busy_o(p1_busy), .fault_o(p1_fault),
        .secure_enable_i(secure_enable), .zeroize_ni(zeroize_n), .fatal_latched_i(fault_latched),
        .heartbeat_o(p1_hb),
        .led1_no(p1_led_n[0]), .led2_no(p1_led_n[1]), .led3_no(p1_led_n[2]),
        .led4_no(p1_led_n[3]), .led5_no(p1_led_n[4]), .led6_no(p1_led_n[5]), .led7_no(p1_led_n[6])
    );

    kiwi_primer20k_fpst_rx_top #(
        .CLOCK_HZ(27_000_000),
        .HEARTBEAT_TOGGLE_CYCLES(2)
    ) p2 (
        .sys_clk_i(clk), .rst_ni(p2_rst_n),
        .spi_sck_i(1'b0), .spi_cs_ni(1'b1), .spi_mosi_i(1'b0),
        .spi_miso_o(p2_miso), .irq_no(p2_irq_n), .busy_o(p2_busy), .fault_o(p2_fault),
        .secure_enable_i(secure_enable), .zeroize_ni(zeroize_n), .fatal_latched_i(fault_latched),
        .heartbeat_o(p2_hb),
        .led1_no(p2_led_n[0]), .led2_no(p2_led_n[1]), .led3_no(p2_led_n[2]),
        .led4_no(p2_led_n[3]), .led5_no(p2_led_n[4]), .led6_no(p2_led_n[5]), .led7_no(p2_led_n[6])
    );

    task automatic wait_state(input logic [2:0] expected, input integer limit);
        integer i;
        begin : wait_state_block
            for (i = 0; i < limit; i = i + 1) begin
                @(posedge clk);
                if (tiny.u_supervisor_core.state_q == expected)
                    disable wait_state_block;
            end
            $fatal(1, "timeout waiting state=%0d current=%0d", expected, tiny.u_supervisor_core.state_q);
        end
    endtask

    task automatic wait_fault_code(input logic [15:0] expected, input integer limit);
        integer i;
        begin : wait_fault_block
            for (i = 0; i < limit; i = i + 1) begin
                @(posedge clk);
                if (fault_latched && tiny.u_supervisor_core.error_code_q == expected)
                    disable wait_fault_block;
            end
            $fatal(1, "timeout waiting fault=%04h got fault=%0b code=%04h", expected,
                   fault_latched, tiny.u_supervisor_core.error_code_q);
        end
    endtask

    task automatic pulse_clear;
        begin
            /* Hold long enough for the 2-flop event synchronizer, then release. */
            clear_fault = 1'b1;
            repeat (2) @(posedge clk);
            clear_fault = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic recover_to_monitor;
        begin
            /* Allow async causes/reset-held heartbeat sources to settle healthy first. */
            repeat (8) @(posedge clk);
            pulse_clear();
            wait_state(ST_RECOVERY, 12);
            wait_state(ST_MONITOR, 80);
            if (fault_latched || !secure_enable || !zeroize_n)
                $fatal(1, "recovery failed fault=%0b secure=%0b zeroize_n=%0b", fault_latched, secure_enable, zeroize_n);
        end
    endtask

    task automatic prove_live_heartbeats_while_safe;
        integer p1_before, p2_before;
        begin
            p1_before = p1_hb_edges;
            p2_before = p2_hb_edges;
            repeat (12) @(posedge clk);
            if (p1_hb_edges <= p1_before || p2_hb_edges <= p2_before)
                $fatal(1, "Primer heartbeat stopped in safe/zeroize state");
        end
    endtask

    initial begin
        /* 1. startup zeroize -> qualify -> monitor. */
        repeat (4) @(posedge clk);
        p1_rst_n = 1'b1;
        p2_rst_n = 1'b1;
        if (zeroize_n !== 1'b0 || secure_enable !== 1'b0)
            $fatal(1, "startup is not fail-safe");
        wait_state(ST_MONITOR, 120);
        if (!secure_enable || !zeroize_n || fault_latched)
            $fatal(1, "failed initial qualification");

        /* 2. MCU heartbeat timeout. */
        hb_mcu_run = 1'b0;
        wait_fault_code(E_MCU, 40);
        wait_state(ST_SAFE, 30);
        hb_mcu_run = 1'b1;
        recover_to_monitor();

        /* 3. P1 heartbeat timeout is a real liveness loss (board reset held). */
        p1_rst_n = 1'b0;
        wait_fault_code(E_PQC, 50);
        wait_state(ST_SAFE, 30);
        p1_rst_n = 1'b1;
        recover_to_monitor();

        /* 4. P2 heartbeat timeout is a real liveness loss. */
        p2_rst_n = 1'b0;
        wait_fault_code(E_CRY, 50);
        wait_state(ST_SAFE, 30);
        p2_rst_n = 1'b1;
        recover_to_monitor();

        /* 5,7,8,9,10. Tamper, zeroize-before-reset, clear rejection, live HB, recovery. */
        zeroize_seen_before_reset = 1'b0;
        tamper_ext_n = 1'b0;
        wait_fault_code(E_TAMP, 20);
        wait_state(ST_SAFE, 30);
        if (secure_enable || zeroize_n)
            $fatal(1, "tamper did not force secure-disable/zeroize");
        prove_live_heartbeats_while_safe();
        pulse_clear();
        if (tiny.u_supervisor_core.state_q != ST_SAFE || !fault_latched)
            $fatal(1, "clear accepted while tamper remains active");
        tamper_ext_n = 1'b1;
        recover_to_monitor();

        /* 6. P2 auth-threshold local fault routes directly to Tiny as 0x0608. */
        force p2.auth_threshold_fault = 1'b1;
        wait_fault_code(E_AUTH, 20);
        wait_state(ST_SAFE, 30);
        prove_live_heartbeats_while_safe();
        pulse_clear();
        if (tiny.u_supervisor_core.state_q != ST_SAFE)
            $fatal(1, "clear accepted while P2 crypto cause active");
        release p2.auth_threshold_fault;
        recover_to_monitor();

        /* 11. A new fault during recovery must return to SAFE_LOCKED. */
        tamper_ext_n = 1'b0;
        wait_fault_code(E_TAMP, 20);
        wait_state(ST_SAFE, 30);
        tamper_ext_n = 1'b1;
        repeat (8) @(posedge clk);
        pulse_clear();
        wait_state(ST_RECOVERY, 12);
        manual_fault = 1'b1;
        wait_state(ST_SAFE, 20);
        if (!fault_latched || tiny.u_supervisor_core.error_code_q != E_TAMP)
            $fatal(1, "first-fatal cause changed during recovery fault");
        manual_fault = 1'b0;
        recover_to_monitor();

        /* 12. Recovery never recreates key/session state without explicit reprovision. */
        if (p1.key_valid || p1.session_active || p2.key_valid || p2.session_active)
            $fatal(1, "key/session state became valid without explicit reprovision");

        if (p2_fault !== 1'b0)
            $fatal(1, "P2 local crypto fault did not clear after recovery");

        $display("PASS: supervisor system integration matrix (12 safety cases)");
        $finish;
    end
endmodule
