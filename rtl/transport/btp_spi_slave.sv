module btp_spi_slave #(
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic zeroize_i,

    input  logic spi_sck_i,
    input  logic spi_cs_ni,
    input  logic spi_mosi_i,
    output logic spi_miso_o,

    output logic rx_frame_valid_o,
    output logic [COUNT_W-1:0] rx_frame_len_o,
    input  logic rx_frame_accept_i,
    input  logic [COUNT_W-1:0] rx_rd_addr_i,
    output logic [7:0] rx_rd_data_o,

    input  logic tx_frame_commit_i,
    input  logic [COUNT_W-1:0] tx_frame_len_i,
    input  logic [COUNT_W-1:0] tx_wr_addr_i,
    input  logic [7:0] tx_wr_data_i,
    input  logic tx_wr_en_i,
    output logic tx_frame_ready_o,
    output logic tx_frame_consumed_o,

    output logic overflow_o
);
    /*
     * BTP v1 uses two CS-bounded transactions.  rx_mem is written only while
     * no response is pending.  tx_mem is filled in the 27 MHz domain, then
     * made immutable by tx_frame_commit_i until the complete response has
     * been clocked out.  The ready level is deliberately held across the
     * clock-domain boundary; the MCU is required to wait for IRQ/ready before
     * asserting CS for the response, so the level and tx_mem are stable well
     * before the first response sampling edge.
     */
    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];

    /* SCK-domain request capture. */
    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_q;
    logic [COUNT_W-1:0] rx_count_q;
    logic [COUNT_W-1:0] rx_len_snapshot_q;
    logic rx_overflow_q;
    logic rx_overflow_snapshot_q;
    logic rx_done_toggle_q;

    /* System-domain receive handshake. */
    logic rx_done_sync1_q, rx_done_sync2_q, rx_done_seen_q;
    logic [COUNT_W-1:0] rx_len_hold_q;
    logic rx_overflow_hold_q;
    logic rx_pending_q;

    /* System-owned immutable response image. */
    logic [COUNT_W-1:0] tx_len_hold_q;
    logic tx_ready_q;

    /* SCK-domain response progress. */
    logic [COUNT_W-1:0] tx_byte_q;
    logic [2:0] tx_bit_q;
    logic tx_complete_q;
    logic tx_consumed_toggle_q;

    /* System-domain response completion handshake. */
    logic tx_consumed_sync1_q, tx_consumed_sync2_q, tx_consumed_seen_q;
    integer i;

    assign rx_rd_data_o = rx_mem[rx_rd_addr_i];
    assign rx_frame_valid_o = rx_pending_q;
    assign rx_frame_len_o = rx_len_hold_q;
    assign overflow_o = rx_overflow_hold_q;
    assign tx_frame_ready_o = tx_ready_q;

    /*
     * Mode-0 first-bit requirement: MISO must already contain bit 7 before
     * the master's first rising SCK edge.  Using the committed, immutable
     * response image here avoids waiting for an SCK edge to synchronize a
     * commit toggle after the clock has been stopped between transactions.
     */
    always_comb begin
        if (!spi_cs_ni && tx_ready_q &&
            (tx_byte_q < tx_len_hold_q) && !tx_complete_q)
            spi_miso_o = tx_mem[tx_byte_q][tx_bit_q];
        else
            spi_miso_o = 1'b0;
    end

    /* 27 MHz system-clock side. */
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_done_sync1_q <= 1'b0;
            rx_done_sync2_q <= 1'b0;
            rx_done_seen_q <= 1'b0;
            rx_len_hold_q <= '0;
            rx_overflow_hold_q <= 1'b0;
            rx_pending_q <= 1'b0;

            tx_len_hold_q <= '0;
            tx_ready_q <= 1'b0;
            tx_consumed_sync1_q <= 1'b0;
            tx_consumed_sync2_q <= 1'b0;
            tx_consumed_seen_q <= 1'b0;
            tx_frame_consumed_o <= 1'b0;
            for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                tx_mem[i] <= 8'h00;
        end else begin
            rx_done_sync1_q <= rx_done_toggle_q;
            rx_done_sync2_q <= rx_done_sync1_q;
            tx_consumed_sync1_q <= tx_consumed_toggle_q;
            tx_consumed_sync2_q <= tx_consumed_sync1_q;
            tx_frame_consumed_o <= 1'b0;

            if (tx_wr_en_i && !tx_ready_q && (tx_wr_addr_i < MAX_FRAME_BYTES))
                tx_mem[tx_wr_addr_i] <= tx_wr_data_i;

            if (tx_frame_commit_i && !tx_ready_q &&
                (tx_frame_len_i != 0) && (tx_frame_len_i <= MAX_FRAME_BYTES)) begin
                tx_len_hold_q <= tx_frame_len_i;
                tx_ready_q <= 1'b1;
            end

            if (rx_done_sync2_q != rx_done_seen_q) begin
                rx_done_seen_q <= rx_done_sync2_q;
                rx_len_hold_q <= rx_len_snapshot_q;
                rx_overflow_hold_q <= rx_overflow_snapshot_q;
                rx_pending_q <= 1'b1;
            end

            if (rx_frame_accept_i)
                rx_pending_q <= 1'b0;

            if (tx_consumed_sync2_q != tx_consumed_seen_q) begin
                tx_consumed_seen_q <= tx_consumed_sync2_q;
                if (tx_ready_q) begin
                    tx_ready_q <= 1'b0;
                    tx_len_hold_q <= '0;
                    tx_frame_consumed_o <= 1'b1;
                end
            end

            if (zeroize_i) begin
                rx_len_hold_q <= '0;
                rx_overflow_hold_q <= 1'b0;
                rx_pending_q <= 1'b0;
                tx_len_hold_q <= '0;
                tx_ready_q <= 1'b0;
                tx_frame_consumed_o <= 1'b0;
                for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                    tx_mem[i] <= 8'h00;
            end
        end
    end

    /*
     * Request transaction: MOSI is sampled on rising SCK in mode 0.
     * While a committed response is pending, MOSI clocks are dummy clocks for
     * the second BTP transaction and MUST NOT create another request frame.
     */
    always_ff @(posedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            rx_count_q <= '0;
            rx_len_snapshot_q <= '0;
            rx_overflow_q <= 1'b0;
            rx_overflow_snapshot_q <= 1'b0;
            rx_done_toggle_q <= 1'b0;
        end else if (spi_cs_ni) begin
            if (!tx_ready_q && ((rx_count_q != 0) || (rx_bit_q != 0))) begin
                rx_len_snapshot_q <= rx_count_q;
                rx_overflow_snapshot_q <= rx_overflow_q || (rx_bit_q != 0);
                rx_done_toggle_q <= ~rx_done_toggle_q;
            end
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            rx_count_q <= '0;
            rx_overflow_q <= 1'b0;
        end else if (!tx_ready_q) begin
            rx_shift_q <= {rx_shift_q[6:0], spi_mosi_i};
            if (rx_bit_q == 3'd7) begin
                if (rx_count_q < MAX_FRAME_BYTES) begin
                    rx_mem[rx_count_q] <= {rx_shift_q[6:0], spi_mosi_i};
                    rx_count_q <= rx_count_q + 1'b1;
                end else begin
                    rx_overflow_q <= 1'b1;
                end
                rx_bit_q <= 3'd0;
            end else begin
                rx_bit_q <= rx_bit_q + 1'b1;
            end
        end
    end

    /*
     * Response transaction: bit/byte indices advance on falling SCK so data
     * remains stable around every rising sampling edge.  A truncated response
     * does not consume the cached frame; a later transaction may read the same
     * byte-identical response again.
     */
    always_ff @(negedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_byte_q <= '0;
            tx_bit_q <= 3'd7;
            tx_complete_q <= 1'b0;
            tx_consumed_toggle_q <= 1'b0;
        end else if (spi_cs_ni) begin
            if (tx_ready_q && tx_complete_q)
                tx_consumed_toggle_q <= ~tx_consumed_toggle_q;
            tx_byte_q <= '0;
            tx_bit_q <= 3'd7;
            tx_complete_q <= 1'b0;
        end else if (tx_ready_q && !tx_complete_q) begin
            if (tx_bit_q == 3'd0) begin
                if ((tx_byte_q + 1'b1) >= tx_len_hold_q) begin
                    tx_complete_q <= 1'b1;
                end else begin
                    tx_byte_q <= tx_byte_q + 1'b1;
                    tx_bit_q <= 3'd7;
                end
            end else begin
                tx_bit_q <= tx_bit_q - 1'b1;
            end
        end
    end
endmodule
