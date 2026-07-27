module fpst_heartbeat_watchdog #(
    parameter integer TIMEOUT_MS = 350
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic tick_ms_i,
    input  logic heartbeat_async_i,
    input  logic armed_i,
    output logic seen_o,
    output logic timeout_o,
    output logic healthy_o,
    output logic transition_pulse_o
);
    localparam integer AGE_W = (TIMEOUT_MS <= 1) ? 1 : $clog2(TIMEOUT_MS + 1);

    logic hb_sync_w;
    logic hb_prev_q;
    logic [1:0] sync_ready_q;
    logic [AGE_W-1:0] age_ms_q;

    fpst_sync_bit #(
        .RESET_VALUE(1'b0)
    ) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .async_i(heartbeat_async_i),
        .sync_o (hb_sync_w)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hb_prev_q          <= 1'b0;
            sync_ready_q       <= 2'b00;
            age_ms_q           <= '0;
            seen_o             <= 1'b0;
            transition_pulse_o <= 1'b0;
        end else begin
            transition_pulse_o <= 1'b0;
            sync_ready_q <= {sync_ready_q[0], 1'b1};

            if (!sync_ready_q[1]) begin
                hb_prev_q <= hb_sync_w;
                age_ms_q  <= '0;
            end else if (hb_sync_w != hb_prev_q) begin
                hb_prev_q          <= hb_sync_w;
                age_ms_q           <= '0;
                seen_o             <= 1'b1;
                transition_pulse_o <= 1'b1;
            end else if (tick_ms_i) begin
                if (age_ms_q < TIMEOUT_MS) begin
                    age_ms_q <= age_ms_q + 1'b1;
                end
            end
        end
    end

    always_comb begin
        timeout_o = 1'b0;
        if (armed_i && sync_ready_q[1] && (age_ms_q >= TIMEOUT_MS)) begin
            timeout_o = 1'b1;
        end
    end

    assign healthy_o = seen_o && !timeout_o;
endmodule
