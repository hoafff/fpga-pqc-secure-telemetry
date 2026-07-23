module kiwi_primer20k_ntt_selftest_top #(
    parameter integer AUTO_START_DELAY_CYCLES = 2_700_000,
    parameter integer HEARTBEAT_BIT = 23
) (
    input  logic sys_clk_i,
    input  logic rst_ni,
    input  logic btn1_ni,

    output logic led1_no,
    output logic led2_no,
    output logic led3_no,
    output logic led4_no,
    output logic led5_no,
    output logic led6_no,
    output logic led7_no
);
    localparam integer AUTO_COUNTER_WIDTH =
        (AUTO_START_DELAY_CYCLES <= 1)
            ? 1
            : $clog2(AUTO_START_DELAY_CYCLES + 1);
    localparam integer HEARTBEAT_WIDTH = HEARTBEAT_BIT + 1;

    logic [1:0] reset_sync_q;
    logic internal_rst_n;

    logic [1:0] button_sync_q;
    logic button_previous_q;
    logic button_press_pulse;

    logic [AUTO_COUNTER_WIDTH-1:0] auto_counter_q;
    logic auto_start_fired_q;
    logic auto_start_pulse;
    logic selftest_start;

    logic [HEARTBEAT_WIDTH-1:0] heartbeat_counter_q;
    logic heartbeat;

    logic selftest_running;
    logic selftest_complete;
    logic selftest_done;
    logic selftest_pass;
    logic selftest_fail;
    logic core_busy;
    logic [2:0] core_stage;
    logic core_stage_barrier;
    logic core_active_bank;
    logic [7:0] mismatch_addr;
    logic [15:0] mismatch_observed;
    logic [15:0] mismatch_expected;

    // Asynchronous assertion and synchronous release protect the internal logic
    // from a reset-button release close to a clock edge.
    always_ff @(posedge sys_clk_i or negedge rst_ni) begin
        if (!rst_ni)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end

    assign internal_rst_n = reset_sync_q[1];

    // BTN1 is active low. A two-flop synchronizer and falling-edge detector are
    // sufficient here because a running self-test ignores additional button
    // transitions; mechanical bounce cannot start concurrent transforms.
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n) begin
            button_sync_q     <= 2'b11;
            button_previous_q <= 1'b1;
        end else begin
            button_sync_q     <= {button_sync_q[0], btn1_ni};
            button_previous_q <= button_sync_q[1];
        end
    end

    assign button_press_pulse = button_previous_q && !button_sync_q[1];

    // Run one automatic self-test shortly after reset. BTN1 can run it again.
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n) begin
            auto_counter_q     <= '0;
            auto_start_fired_q <= 1'b0;
            auto_start_pulse   <= 1'b0;
        end else begin
            auto_start_pulse <= 1'b0;

            if (!auto_start_fired_q) begin
                if (AUTO_START_DELAY_CYCLES <= 1) begin
                    auto_start_fired_q <= 1'b1;
                    auto_start_pulse   <= 1'b1;
                end else if (auto_counter_q == AUTO_START_DELAY_CYCLES - 1) begin
                    auto_start_fired_q <= 1'b1;
                    auto_start_pulse   <= 1'b1;
                end else begin
                    auto_counter_q <= auto_counter_q + 1'b1;
                end
            end
        end
    end

    assign selftest_start = auto_start_pulse || button_press_pulse;

    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n)
            heartbeat_counter_q <= '0;
        else
            heartbeat_counter_q <= heartbeat_counter_q + 1'b1;
    end

    assign heartbeat = heartbeat_counter_q[HEARTBEAT_BIT];

    forward_ntt_board_selftest u_selftest (
        .clk_i                   (sys_clk_i),
        .rst_ni                  (internal_rst_n),
        .start_i                 (selftest_start),
        .running_o               (selftest_running),
        .complete_o              (selftest_complete),
        .done_o                  (selftest_done),
        .pass_o                  (selftest_pass),
        .fail_o                  (selftest_fail),
        .core_busy_o             (core_busy),
        .core_stage_o            (core_stage),
        .core_stage_barrier_o    (core_stage_barrier),
        .core_active_bank_o      (core_active_bank),
        .mismatch_addr_o         (mismatch_addr),
        .mismatch_observed_o     (mismatch_observed),
        .mismatch_expected_o     (mismatch_expected)
    );

    // The seven onboard LEDs are active low.
    assign led1_no = ~heartbeat;
    assign led2_no = ~selftest_running;
    assign led3_no = ~selftest_complete;
    assign led4_no = ~selftest_pass;
    assign led5_no = ~selftest_fail;
    assign led6_no = ~core_stage_barrier;
    assign led7_no = ~core_active_bank;

`ifndef SYNTHESIS
    logic unused_debug;
    always_comb begin
        unused_debug = selftest_done ^ core_busy ^ (^core_stage) ^
            (^mismatch_addr) ^ (^mismatch_observed) ^ (^mismatch_expected);
    end
`endif
endmodule
