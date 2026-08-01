`timescale 1ns/1ps
module tb_supervisor_top_open_drain;
    logic clk = 1'b0;
    logic manual_fault = 1'b0;
    wire fault_pad;
    wire illegal_pad;
    logic fault_latched;
    logic illegal_latched;

    always #5 clk = ~clk;

    supervisor_top #(
        .CLK_HZ(1000), .POR_CYCLES(2), .BUTTON_DEBOUNCE_MS(1),
        .HB_TIMEOUT_MS(8), .STARTUP_ZEROIZE_MS(2),
        .STARTUP_GRACE_MS(100), .QUALIFY_MS(2),
        .ZEROIZE_HOLD_MS(2), .RECOVERY_QUALIFY_MS(2)
    ) dut_fault (
        .clk_27m(clk), .hb_mcu_i(1'b0), .hb_pqc_i(1'b0),
        .hb_crypto_i(1'b0), .crypto_fault_i(1'b0),
        .tamper_ext_ni(1'b1), .manual_fault_i(manual_fault),
        .clear_fault_i(1'b0), .btn_tamper_n(1'b1), .btn_clear_n(1'b1),
        .secure_enable_o(), .zeroize_no(), .tiny_fault_no(fault_pad),
        .fault_latched_o(fault_latched), .led_fault_o(), .led_secure_o()
    );

    supervisor_top #(
        .CLK_HZ(1000), .POR_CYCLES(2), .BUTTON_DEBOUNCE_MS(1),
        .HB_TIMEOUT_MS(8), .STARTUP_ZEROIZE_MS(2),
        .STARTUP_GRACE_MS(100), .QUALIFY_MS(2),
        .ZEROIZE_HOLD_MS(2), .RECOVERY_QUALIFY_MS(2)
    ) dut_illegal (
        .clk_27m(clk), .hb_mcu_i(1'b0), .hb_pqc_i(1'b0),
        .hb_crypto_i(1'b0), .crypto_fault_i(1'b0),
        .tamper_ext_ni(1'b1), .manual_fault_i(1'b0),
        .clear_fault_i(1'b0), .btn_tamper_n(1'b1), .btn_clear_n(1'b1),
        .secure_enable_o(), .zeroize_no(), .tiny_fault_no(illegal_pad),
        .fault_latched_o(illegal_latched), .led_fault_o(), .led_secure_o()
    );

    task automatic assert_0_or_z(input pad, input [255:0] label);
        begin
            if ((pad !== 1'b0) && (pad !== 1'bz))
                $fatal(1, "%0s drove %b; Tiny_FAULT_N is restricted to 0/Z", label, pad);
        end
    endtask

    /* A delta-cycle X before combinational settling is not a push-pull HIGH.
     * Monitor every pad transition for the forbidden electrical value, then
     * sample the stricter 0/Z contract at all stable reset/state checkpoints.
     */
    always @(fault_pad)
        assert (fault_pad !== 1'b1)
            else $fatal(1, "fault DUT drove forbidden push-pull HIGH");
    always @(illegal_pad)
        assert (illegal_pad !== 1'b1)
            else $fatal(1, "illegal-state DUT drove forbidden push-pull HIGH");

    initial begin
        #1;
        assert_0_or_z(fault_pad, "fault DUT during POR");
        assert_0_or_z(illegal_pad, "illegal DUT during POR");
        if (fault_pad !== 1'b0 || illegal_pad !== 1'b0)
            $fatal(1, "internal POR must fail closed by sinking J1-9 LOW");

        repeat (8) @(posedge clk);
        #1;
        if (fault_pad !== 1'bz || illegal_pad !== 1'bz)
            $fatal(1, "no-fault state must release J1-9 to Z");

        manual_fault = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if (!fault_latched || fault_pad !== 1'b0)
            $fatal(1, "latched fault must sink J1-9 LOW");

        /* 3'd4 is the retired RESET_PULSE encoding and must fail closed. */
        force dut_illegal.u_supervisor_core.state_q = 3'd4;
        #1;
        if (illegal_pad !== 1'b0)
            $fatal(1, "retired/illegal state must immediately sink J1-9 LOW");
        @(posedge clk);
        release dut_illegal.u_supervisor_core.state_q;
        repeat (2) @(posedge clk);
        #1;
        if (!illegal_latched || illegal_pad !== 1'b0)
            $fatal(1, "illegal-state recovery path must retain fault LOW");

        $display("PASS: tb_supervisor_top_open_drain (J1-9 is 0/Z only)");
        $finish;
    end
endmodule
