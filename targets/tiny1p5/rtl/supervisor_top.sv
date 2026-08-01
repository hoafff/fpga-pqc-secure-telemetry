module supervisor_top #(
    parameter integer CLK_HZ               = 27_000_000,
    parameter integer POR_CYCLES           = 1024,
    parameter integer BUTTON_DEBOUNCE_MS   = 5,
    parameter integer HB_TIMEOUT_MS        = 350,
    parameter integer STARTUP_ZEROIZE_MS   = 10,
    parameter integer STARTUP_GRACE_MS     = 1000,
    parameter integer QUALIFY_MS           = 500,
    parameter integer ZEROIZE_HOLD_MS      = 10,
    parameter integer RECOVERY_QUALIFY_MS  = 500
) (
    input  logic clk_27m,
    input  logic hb_mcu_i,
    input  logic hb_pqc_i,
    input  logic hb_crypto_i,
    input  logic crypto_fault_i,
    input  logic tamper_ext_ni,
    input  logic manual_fault_i,
    input  logic clear_fault_i,
    input  logic btn_tamper_n,
    input  logic btn_clear_n,
    output logic secure_enable_o,
    output logic zeroize_no,
    output wire  tiny_fault_no,
    output logic fault_latched_o,
    output logic led_fault_o,
    output logic led_secure_o
);
    localparam integer POR_W = (POR_CYCLES <= 1) ? 1 : $clog2(POR_CYCLES + 1);

    logic [POR_W-1:0] por_count_q = '0;
    logic rst_ni_q = 1'b0;
    logic tick_ms_w;
    logic tamper_active_w;
    logic tamper_combined_n_w;
    logic clear_button_pulse_w;
    logic clear_external_pulse_w;
    logic clear_pulse_w;
    logic key_zeroize_core_w;
    logic [2:0] supervisor_state_w;
    logic supervisor_state_valid_w;
    logic tiny_fault_drive_low_w;

    always_ff @(posedge clk_27m) begin
        if (!rst_ni_q) begin
            if ((POR_CYCLES <= 1) || (por_count_q >= POR_CYCLES - 1)) rst_ni_q <= 1'b1;
            else por_count_q <= por_count_q + 1'b1;
        end
    end

    fpst_ms_tick #(.CLK_HZ(CLK_HZ)) u_ms_tick (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .tick_ms_o(tick_ms_w)
    );

    assign tamper_combined_n_w = btn_tamper_n & tamper_ext_ni;

    fpst_debounce_active_low #(.STABLE_MS(BUTTON_DEBOUNCE_MS)) u_tamper_button (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .tick_ms_i(tick_ms_w), .async_ni(tamper_combined_n_w),
        .active_o(tamper_active_w), .assert_pulse_o()
    );

    fpst_debounce_active_low #(.STABLE_MS(BUTTON_DEBOUNCE_MS)) u_clear_button (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .tick_ms_i(tick_ms_w), .async_ni(btn_clear_n),
        .active_o(), .assert_pulse_o(clear_button_pulse_w)
    );

    fpst_sync_rise_pulse u_external_clear (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .async_i(clear_fault_i), .pulse_o(clear_external_pulse_w)
    );
    assign clear_pulse_w = clear_button_pulse_w | clear_external_pulse_w;

    fpst_supervisor_core #(
        .HB_TIMEOUT_MS(HB_TIMEOUT_MS), .STARTUP_ZEROIZE_MS(STARTUP_ZEROIZE_MS),
        .STARTUP_GRACE_MS(STARTUP_GRACE_MS), .QUALIFY_MS(QUALIFY_MS),
        .ZEROIZE_HOLD_MS(ZEROIZE_HOLD_MS),
        .RECOVERY_QUALIFY_MS(RECOVERY_QUALIFY_MS)
    ) u_supervisor_core (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .tick_ms_i(tick_ms_w),
        .hb_mcu_i(hb_mcu_i), .hb_pqc_i(hb_pqc_i), .hb_crypto_i(hb_crypto_i),
        .crypto_fault_i(crypto_fault_i),
        .tamper_active_i(tamper_active_w), .clear_fault_pulse_i(clear_pulse_w), .manual_fault_i(manual_fault_i),
        .secure_enable_o(secure_enable_o), .key_zeroize_o(key_zeroize_core_w),
        .fault_latched_o(fault_latched_o), .error_code_o(), .first_fault_time_ms_o(), .state_o(supervisor_state_w),
        .hb_timeout_o(), .hb_seen_o(), .all_heartbeats_healthy_o()
    );

    /*
     * The reusable supervisor core follows FPST logical semantics and exposes
     * an active-high key-zeroize request. The physical two-Primer harness uses
     * active-low ZEROIZE_N inputs, so this wrapper performs the polarity
     * adaptation only at the Tiny J1 boundary.
     */
    assign zeroize_no = ~key_zeroize_core_w;

    /*
     * Tiny J1-9 is a single-driver active-low fault output. The only legal
     * actions are sink LOW during internal POR or for a latched/illegal-state
     * fault, then release Z only after a valid no-fault state is established.
     * There is deliberately no RTL path that drives a logic HIGH; the SN32
     * EVK's external 10 kOhm pull-up is the only intended source of HIGH.
     *
     * Encoding 3'd4 was the retired RESET_PULSE state and is intentionally
     * treated as illegal together with 3'd7 and any X/Z-corrupted state.
     */
    always_comb begin
        supervisor_state_valid_w = 1'b1;
        case (supervisor_state_w)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd5, 3'd6: begin end
            default: supervisor_state_valid_w = 1'b0;
        endcase
    end

    assign tiny_fault_drive_low_w =
        ~rst_ni_q | fault_latched_o | ~supervisor_state_valid_w;
    assign tiny_fault_no = tiny_fault_drive_low_w ? 1'b0 : 1'bz;

    assign led_fault_o  = fault_latched_o;
    assign led_secure_o = secure_enable_o;
endmodule
