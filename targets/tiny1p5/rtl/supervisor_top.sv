module supervisor_top #(
    parameter integer CLK_HZ               = 27_000_000,
    parameter integer POR_CYCLES           = 1024,
    parameter integer BUTTON_DEBOUNCE_MS   = 5,
    parameter integer HB_TIMEOUT_MS        = 350,
    parameter integer STARTUP_ZEROIZE_MS   = 10,
    parameter integer STARTUP_GRACE_MS     = 1000,
    parameter integer QUALIFY_MS           = 500,
    parameter integer ZEROIZE_HOLD_MS      = 10,
    parameter integer RESET_PULSE_MS       = 10,
    parameter integer RECOVERY_QUALIFY_MS  = 500,
    parameter bit     RESET_ON_FATAL       = 1'b1
) (
    input  logic clk_27m,
    input  logic hb_mcu_i,
    input  logic hb_pqc_i,
    input  logic hb_crypto_i,
    input  logic tamper_ext_ni,
    input  logic manual_fault_i,
    input  logic clear_fault_i,
    input  logic btn_tamper_n,
    input  logic btn_clear_n,
    output logic secure_enable_o,
    output logic key_zeroize_o,
    output logic system_reset_no,
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
        .ZEROIZE_HOLD_MS(ZEROIZE_HOLD_MS), .RESET_PULSE_MS(RESET_PULSE_MS),
        .RECOVERY_QUALIFY_MS(RECOVERY_QUALIFY_MS), .RESET_ON_FATAL(RESET_ON_FATAL)
    ) u_supervisor_core (
        .clk_i(clk_27m), .rst_ni(rst_ni_q), .tick_ms_i(tick_ms_w),
        .hb_mcu_i(hb_mcu_i), .hb_pqc_i(hb_pqc_i), .hb_crypto_i(hb_crypto_i),
        .tamper_active_i(tamper_active_w), .clear_fault_pulse_i(clear_pulse_w), .manual_fault_i(manual_fault_i),
        .secure_enable_o(secure_enable_o), .key_zeroize_o(key_zeroize_o), .system_reset_no(system_reset_no),
        .fault_latched_o(fault_latched_o), .error_code_o(), .first_fault_time_ms_o(), .state_o(),
        .hb_timeout_o(), .hb_seen_o(), .all_heartbeats_healthy_o()
    );

    assign led_fault_o  = fault_latched_o;
    assign led_secure_o = secure_enable_o;
endmodule
