module fpst_supervisor_core #(
    parameter integer HB_TIMEOUT_MS          = 350,
    parameter integer STARTUP_ZEROIZE_MS     = 10,
    parameter integer STARTUP_GRACE_MS       = 1000,
    parameter integer QUALIFY_MS             = 500,
    parameter integer ZEROIZE_HOLD_MS        = 10,
    parameter integer RESET_PULSE_MS         = 10,
    parameter integer RECOVERY_QUALIFY_MS    = 500,
    parameter bit     RESET_ON_FATAL         = 1'b1
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        tick_ms_i,
    input  logic        hb_mcu_i,
    input  logic        hb_pqc_i,
    input  logic        hb_crypto_i,
    input  logic        crypto_fault_i,
    input  logic        tamper_active_i,
    input  logic        clear_fault_pulse_i,
    input  logic        manual_fault_i,
    output logic        secure_enable_o,
    output logic        key_zeroize_o,
    output logic        system_reset_no,
    output logic        fault_latched_o,
    output logic [15:0] error_code_o,
    output logic [31:0] first_fault_time_ms_o,
    output logic [2:0]  state_o,
    output logic [2:0]  hb_timeout_o,
    output logic [2:0]  hb_seen_o,
    output logic        all_heartbeats_healthy_o
);
    localparam logic [15:0] ERR_NONE              = 16'h0000;
    localparam logic [15:0] ERR_HB_MCU_TIMEOUT    = 16'h0701;
    localparam logic [15:0] ERR_HB_PQC_TIMEOUT    = 16'h0702;
    localparam logic [15:0] ERR_HB_CRYPTO_TIMEOUT = 16'h0703;
    localparam logic [15:0] ERR_TAMPER            = 16'h0704;
    localparam logic [15:0] ERR_MANUAL_FAULT      = 16'h0705;
    localparam logic [15:0] ERR_SUP_ILLEGAL_STATE = 16'h0706;
    /* Common FPST registry: P2 consecutive authentication failure threshold. */
    localparam logic [15:0] ERR_AUTH_THRESHOLD    = 16'h0608;

    localparam logic [2:0] ST_STARTUP          = 3'd0;
    localparam logic [2:0] ST_QUALIFY          = 3'd1;
    localparam logic [2:0] ST_MONITOR          = 3'd2;
    localparam logic [2:0] ST_ZEROIZE          = 3'd3;
    localparam logic [2:0] ST_RESET_PULSE      = 3'd4;
    localparam logic [2:0] ST_SAFE_LOCKED      = 3'd5;
    localparam logic [2:0] ST_RECOVERY_QUALIFY = 3'd6;

    logic [2:0] state_q;
    logic [31:0] uptime_ms_q;
    logic [15:0] state_timer_ms_q;
    logic [15:0] error_code_q;
    logic [31:0] first_fault_time_ms_q;
    logic fault_latched_q;

    logic manual_fault_sync_w;
    logic crypto_fault_sync_w;
    logic hb_mcu_seen_w, hb_pqc_seen_w, hb_crypto_seen_w;
    logic hb_mcu_timeout_w, hb_pqc_timeout_w, hb_crypto_timeout_w;
    logic hb_mcu_healthy_w, hb_pqc_healthy_w, hb_crypto_healthy_w;
    logic hb_arm_w;
    logic all_hb_healthy_w;
    logic fatal_request_w;
    logic [15:0] fatal_code_w;

    fpst_sync_bit #(.RESET_VALUE(1'b0)) u_manual_fault_sync (
        .clk_i(clk_i), .rst_ni(rst_ni), .async_i(manual_fault_i), .sync_o(manual_fault_sync_w)
    );

    fpst_sync_bit #(.RESET_VALUE(1'b0)) u_crypto_fault_sync (
        .clk_i(clk_i), .rst_ni(rst_ni), .async_i(crypto_fault_i), .sync_o(crypto_fault_sync_w)
    );

    assign hb_arm_w = (uptime_ms_q >= STARTUP_GRACE_MS);

    fpst_heartbeat_watchdog #(.TIMEOUT_MS(HB_TIMEOUT_MS)) u_hb_mcu (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_ms_i(tick_ms_i), .heartbeat_async_i(hb_mcu_i),
        .armed_i(hb_arm_w), .seen_o(hb_mcu_seen_w), .timeout_o(hb_mcu_timeout_w),
        .healthy_o(hb_mcu_healthy_w), .transition_pulse_o()
    );
    fpst_heartbeat_watchdog #(.TIMEOUT_MS(HB_TIMEOUT_MS)) u_hb_pqc (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_ms_i(tick_ms_i), .heartbeat_async_i(hb_pqc_i),
        .armed_i(hb_arm_w), .seen_o(hb_pqc_seen_w), .timeout_o(hb_pqc_timeout_w),
        .healthy_o(hb_pqc_healthy_w), .transition_pulse_o()
    );
    fpst_heartbeat_watchdog #(.TIMEOUT_MS(HB_TIMEOUT_MS)) u_hb_crypto (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_ms_i(tick_ms_i), .heartbeat_async_i(hb_crypto_i),
        .armed_i(hb_arm_w), .seen_o(hb_crypto_seen_w), .timeout_o(hb_crypto_timeout_w),
        .healthy_o(hb_crypto_healthy_w), .transition_pulse_o()
    );

    assign all_hb_healthy_w = hb_mcu_healthy_w && hb_pqc_healthy_w && hb_crypto_healthy_w;

    /*
     * Same-cycle first-fatal priority is deterministic. The local P2 crypto
     * fault is above heartbeat timeouts because it is the direct root cause;
     * heartbeat remains a liveness channel after FIX-001.
     */
    always_comb begin
        fatal_request_w = 1'b0;
        fatal_code_w = ERR_NONE;
        if (tamper_active_i) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_TAMPER;
        end else if (manual_fault_sync_w) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_MANUAL_FAULT;
        end else if (crypto_fault_sync_w) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_AUTH_THRESHOLD;
        end else if (hb_arm_w && hb_mcu_timeout_w) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_HB_MCU_TIMEOUT;
        end else if (hb_arm_w && hb_pqc_timeout_w) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_HB_PQC_TIMEOUT;
        end else if (hb_arm_w && hb_crypto_timeout_w) begin
            fatal_request_w = 1'b1; fatal_code_w = ERR_HB_CRYPTO_TIMEOUT;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_STARTUP;
            uptime_ms_q <= 32'd0;
            state_timer_ms_q <= 16'd0;
            error_code_q <= ERR_NONE;
            first_fault_time_ms_q <= 32'd0;
            fault_latched_q <= 1'b0;
        end else begin
            if (tick_ms_i) uptime_ms_q <= uptime_ms_q + 1'b1;
            case (state_q)
                ST_STARTUP: begin
                    if (fatal_request_w) begin
                        if (!fault_latched_q) begin
                            fault_latched_q <= 1'b1;
                            error_code_q <= fatal_code_w;
                            first_fault_time_ms_q <= uptime_ms_q;
                        end
                        state_q <= ST_ZEROIZE;
                        state_timer_ms_q <= 16'd0;
                    end else if (tick_ms_i) begin
                        if ((STARTUP_ZEROIZE_MS <= 1) || (state_timer_ms_q >= STARTUP_ZEROIZE_MS - 1)) begin
                            state_q <= ST_QUALIFY;
                            state_timer_ms_q <= 16'd0;
                        end else begin
                            state_timer_ms_q <= state_timer_ms_q + 1'b1;
                        end
                    end
                end
                ST_QUALIFY: begin
                    if (fatal_request_w) begin
                        if (!fault_latched_q) begin
                            fault_latched_q <= 1'b1;
                            error_code_q <= fatal_code_w;
                            first_fault_time_ms_q <= uptime_ms_q;
                        end
                        state_q <= ST_ZEROIZE;
                        state_timer_ms_q <= 16'd0;
                    end else if (!hb_arm_w || !all_hb_healthy_w) begin
                        state_timer_ms_q <= 16'd0;
                    end else if (tick_ms_i) begin
                        if ((QUALIFY_MS <= 1) || (state_timer_ms_q >= QUALIFY_MS - 1)) begin
                            state_q <= ST_MONITOR;
                            state_timer_ms_q <= 16'd0;
                        end else begin
                            state_timer_ms_q <= state_timer_ms_q + 1'b1;
                        end
                    end
                end
                ST_MONITOR: begin
                    if (fatal_request_w) begin
                        if (!fault_latched_q) begin
                            fault_latched_q <= 1'b1;
                            error_code_q <= fatal_code_w;
                            first_fault_time_ms_q <= uptime_ms_q;
                        end
                        state_q <= ST_ZEROIZE;
                        state_timer_ms_q <= 16'd0;
                    end
                end
                ST_ZEROIZE: begin
                    if (tick_ms_i) begin
                        if ((ZEROIZE_HOLD_MS <= 1) || (state_timer_ms_q >= ZEROIZE_HOLD_MS - 1)) begin
                            state_timer_ms_q <= 16'd0;
                            if (RESET_ON_FATAL) state_q <= ST_RESET_PULSE;
                            else state_q <= ST_SAFE_LOCKED;
                        end else begin
                            state_timer_ms_q <= state_timer_ms_q + 1'b1;
                        end
                    end
                end
                ST_RESET_PULSE: begin
                    if (tick_ms_i) begin
                        if ((RESET_PULSE_MS <= 1) || (state_timer_ms_q >= RESET_PULSE_MS - 1)) begin
                            state_q <= ST_SAFE_LOCKED;
                            state_timer_ms_q <= 16'd0;
                        end else begin
                            state_timer_ms_q <= state_timer_ms_q + 1'b1;
                        end
                    end
                end
                ST_SAFE_LOCKED: begin
                    state_timer_ms_q <= 16'd0;
                    if (clear_fault_pulse_i &&
                        !tamper_active_i &&
                        !manual_fault_sync_w &&
                        !crypto_fault_sync_w &&
                        all_hb_healthy_w)
                        state_q <= ST_RECOVERY_QUALIFY;
                end
                ST_RECOVERY_QUALIFY: begin
                    if (tamper_active_i || manual_fault_sync_w || crypto_fault_sync_w || !all_hb_healthy_w) begin
                        state_q <= ST_SAFE_LOCKED;
                        state_timer_ms_q <= 16'd0;
                    end else if (tick_ms_i) begin
                        if ((RECOVERY_QUALIFY_MS <= 1) || (state_timer_ms_q >= RECOVERY_QUALIFY_MS - 1)) begin
                            fault_latched_q <= 1'b0;
                            error_code_q <= ERR_NONE;
                            first_fault_time_ms_q <= 32'd0;
                            state_q <= ST_STARTUP;
                            state_timer_ms_q <= 16'd0;
                        end else begin
                            state_timer_ms_q <= state_timer_ms_q + 1'b1;
                        end
                    end
                end
                default: begin
                    if (!fault_latched_q) begin
                        fault_latched_q <= 1'b1;
                        error_code_q <= ERR_SUP_ILLEGAL_STATE;
                        first_fault_time_ms_q <= uptime_ms_q;
                    end
                    state_q <= ST_ZEROIZE;
                    state_timer_ms_q <= 16'd0;
                end
            endcase
        end
    end

    always_comb begin
        secure_enable_o = 1'b0;
        key_zeroize_o = 1'b1;
        system_reset_no = 1'b1;
        case (state_q)
            ST_QUALIFY: begin key_zeroize_o = 1'b0; end
            ST_MONITOR: begin secure_enable_o = 1'b1; key_zeroize_o = 1'b0; end
            ST_RESET_PULSE: begin system_reset_no = 1'b0; end
            ST_STARTUP, ST_ZEROIZE, ST_SAFE_LOCKED, ST_RECOVERY_QUALIFY: begin end
            default: begin system_reset_no = 1'b0; end
        endcase
    end

    assign fault_latched_o = fault_latched_q;
    assign error_code_o = error_code_q;
    assign first_fault_time_ms_o = first_fault_time_ms_q;
    assign state_o = state_q;
    assign hb_timeout_o = {hb_crypto_timeout_w, hb_pqc_timeout_w, hb_mcu_timeout_w};
    assign hb_seen_o = {hb_crypto_seen_w, hb_pqc_seen_w, hb_mcu_seen_w};
    assign all_heartbeats_healthy_o = all_hb_healthy_w;
endmodule
