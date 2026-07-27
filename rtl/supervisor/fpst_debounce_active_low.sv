module fpst_debounce_active_low #(
    parameter integer STABLE_MS = 5
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic tick_ms_i,
    input  logic async_ni,
    output logic active_o,
    output logic assert_pulse_o
);
    localparam integer COUNT_W = (STABLE_MS <= 1) ? 1 : $clog2(STABLE_MS + 1);

    logic sync_n_w;
    logic debounced_n_q;
    logic [COUNT_W-1:0] stable_count_q;

    fpst_sync_bit #(
        .RESET_VALUE(1'b1)
    ) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .async_i(async_ni),
        .sync_o (sync_n_w)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            debounced_n_q <= 1'b1;
            stable_count_q <= '0;
            assert_pulse_o <= 1'b0;
        end else begin
            assert_pulse_o <= 1'b0;

            if (sync_n_w == debounced_n_q) begin
                stable_count_q <= '0;
            end else if (tick_ms_i) begin
                if ((STABLE_MS <= 1) || (stable_count_q >= STABLE_MS - 1)) begin
                    debounced_n_q <= sync_n_w;
                    stable_count_q <= '0;
                    if (sync_n_w == 1'b0) begin
                        assert_pulse_o <= 1'b1;
                    end
                end else begin
                    stable_count_q <= stable_count_q + 1'b1;
                end
            end
        end
    end

    assign active_o = ~debounced_n_q;
endmodule
