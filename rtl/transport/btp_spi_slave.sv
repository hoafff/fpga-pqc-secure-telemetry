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
     * FPST BTP v1 uses two CS-bounded SPI transactions.  Bit shifting remains
     * entirely in the SPI clock domain.  The 27 MHz domain observes only
     * stable frame memory plus synchronized event/CS state.
     *
     * The response image is written and committed while SCK is stopped.  The
     * master waits for IRQ before the response transaction, so tx_ready_q,
     * tx_len_hold_q and tx_mem are stable well before the first sampling edge.
     */
    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];

    /* ------------------------ request / SCK domain ------------------------ */
    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_q;
    logic [COUNT_W-1:0] rx_count_q;
    logic rx_overflow_q;
    logic rx_first_q;
    logic rx_activity_toggle_q;

    /* ------------------------ response / SCK domain ----------------------- */
    logic [COUNT_W-1:0] tx_byte_q;
    logic [2:0] tx_bit_q;
    logic tx_done_sck_q;
    logic tx_complete_toggle_q;

    /* ------------------------- 27 MHz system domain ----------------------- */
    logic cs_sync1_q, cs_sync2_q, cs_prev_q;
    logic rx_activity_sync1_q, rx_activity_sync2_q, rx_activity_seen_q;
    logic tx_complete_sync1_q, tx_complete_sync2_q, tx_complete_seen_q;
    logic tx_complete_pending_q;

    logic [COUNT_W-1:0] rx_len_hold_q;
    logic rx_overflow_hold_q;
    logic rx_pending_q;

    logic [COUNT_W-1:0] tx_len_hold_q;
    logic tx_ready_q;

    logic cs_rise_sys;
    logic tx_complete_event_sys;

    assign cs_rise_sys = cs_sync2_q && !cs_prev_q;
    assign tx_complete_event_sys = (tx_complete_sync2_q != tx_complete_seen_q);

    assign rx_rd_data_o = rx_mem[rx_rd_addr_i];
    assign rx_frame_valid_o = rx_pending_q;
    assign rx_frame_len_o = rx_len_hold_q;
    assign overflow_o = rx_overflow_hold_q;
    assign tx_frame_ready_o = tx_ready_q;

    /*
     * Mode 0 requires MISO bit 7 to be valid before the first rising SCK edge.
     * tx_byte_q/tx_bit_q are reset to byte 0/bit 7 by CS rising, while the
     * committed response memory remains immutable until a complete read.
     *
     * The physical FPST harness is a multi-slave SPI0 bus: Primer #1, Primer #2
     * and the disabled onboard flash share MISO.  An endpoint therefore MUST
     * release MISO whenever its CS is high.  The top-level Z below is intended
     * to infer the FPGA output-enable/tri-state buffer; driving a logic 0 while
     * deselected would cause bus contention when the other Primer returns a 1.
     */
    always_comb begin
        if (!spi_cs_ni && tx_ready_q && !tx_done_sck_q &&
            (tx_byte_q < tx_len_hold_q))
            spi_miso_o = tx_mem[tx_byte_q][tx_bit_q];
        else
            spi_miso_o = 1'bz;
    end

    /*
     * CS is asynchronous to clk_i.  Synchronizing the idle-high level lets the
     * system domain detect the end of a request after rx_mem/count/flags have
     * become stable.  rx_count_q is deliberately not cleared by CS; it remains
     * stable during CS high and is reset on the first SCK of the next request.
     */
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            cs_sync1_q <= 1'b1;
            cs_sync2_q <= 1'b1;
            cs_prev_q <= 1'b1;
            rx_activity_sync1_q <= 1'b0;
            rx_activity_sync2_q <= 1'b0;
            rx_activity_seen_q <= 1'b0;
            tx_complete_sync1_q <= 1'b0;
            tx_complete_sync2_q <= 1'b0;
            tx_complete_seen_q <= 1'b0;
            tx_complete_pending_q <= 1'b0;

            rx_len_hold_q <= '0;
            rx_overflow_hold_q <= 1'b0;
            rx_pending_q <= 1'b0;

            tx_len_hold_q <= '0;
            tx_ready_q <= 1'b0;
            tx_frame_consumed_o <= 1'b0;
        end else begin
            cs_sync1_q <= spi_cs_ni;
            cs_sync2_q <= cs_sync1_q;
            cs_prev_q <= cs_sync2_q;

            rx_activity_sync1_q <= rx_activity_toggle_q;
            rx_activity_sync2_q <= rx_activity_sync1_q;
            tx_complete_sync1_q <= tx_complete_toggle_q;
            tx_complete_sync2_q <= tx_complete_sync1_q;

            tx_frame_consumed_o <= 1'b0;

            /* Response RAM may be changed only while no response is visible. */
            if (tx_wr_en_i && !tx_ready_q && (tx_wr_addr_i < MAX_FRAME_BYTES))
                tx_mem[tx_wr_addr_i] <= tx_wr_data_i;

            if (tx_frame_commit_i && !tx_ready_q &&
                (tx_frame_len_i != 0) && (tx_frame_len_i <= MAX_FRAME_BYTES)) begin
                tx_len_hold_q <= tx_frame_len_i;
                tx_ready_q <= 1'b1;
            end

            /*
             * A completed request has had many system clocks for the activity
             * toggle to synchronize before CS rises.  Sampling rx_count/flags
             * here is therefore a bundled-data CDC: the multi-bit values are
             * static for the whole CS-high processing interval.
             */
            if (cs_rise_sys && !tx_ready_q && !rx_pending_q &&
                (rx_activity_sync2_q != rx_activity_seen_q)) begin
                rx_activity_seen_q <= rx_activity_sync2_q;
                rx_len_hold_q <= rx_count_q;
                rx_overflow_hold_q <= rx_overflow_q || (rx_bit_q != 0);
                rx_pending_q <= 1'b1;
            end

            if (rx_frame_accept_i)
                rx_pending_q <= 1'b0;

            /* Synchronize the exact-last-bit event independently from CS. */
            if (tx_complete_event_sys) begin
                tx_complete_seen_q <= tx_complete_sync2_q;
                tx_complete_pending_q <= 1'b1;
            end

            /*
             * Consume only after both conditions are true: every response bit
             * was clocked and CS is observed high.  If CS rises before the
             * toggle reaches clk_i, the complete-event branch below still sees
             * synchronized CS high on the following cycle.
             */
            if (tx_ready_q && cs_sync2_q &&
                (tx_complete_pending_q || tx_complete_event_sys)) begin
                tx_ready_q <= 1'b0;
                tx_len_hold_q <= '0;
                tx_complete_pending_q <= 1'b0;
                tx_frame_consumed_o <= 1'b1;
            end

            /* Invalidate all architected transport state; RAM contents become unreadable. */
            if (zeroize_i) begin
                rx_len_hold_q <= '0;
                rx_overflow_hold_q <= 1'b0;
                rx_pending_q <= 1'b0;
                rx_activity_seen_q <= rx_activity_sync2_q;

                tx_len_hold_q <= '0;
                tx_ready_q <= 1'b0;
                tx_complete_pending_q <= 1'b0;
                tx_complete_seen_q <= tx_complete_sync2_q;
                tx_frame_consumed_o <= 1'b0;
            end
        end
    end

    /*
     * rx_first_q is the only state using CS as an asynchronous SET.  The SET
     * value is constant and synthesizable; the first following SCK clears it.
     * This lets rx_count remain untouched and stable throughout CS high.
     */
    always_ff @(posedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni)
            rx_first_q <= 1'b1;
        else if (spi_cs_ni)
            rx_first_q <= 1'b1;
        else
            rx_first_q <= 1'b0;
    end

    /* Request bytes are captured on rising SCK (SPI mode 0). */
    always_ff @(posedge spi_sck_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            rx_count_q <= '0;
            rx_overflow_q <= 1'b0;
            rx_activity_toggle_q <= 1'b0;
        end else if (!spi_cs_ni && !tx_ready_q) begin
            if (rx_first_q) begin
                rx_shift_q <= {7'h00, spi_mosi_i};
                rx_bit_q <= 3'd1;
                rx_count_q <= '0;
                rx_overflow_q <= 1'b0;
                rx_activity_toggle_q <= ~rx_activity_toggle_q;
            end else begin
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
    end

    /*
     * Response indices advance on falling SCK so each MISO bit is stable around
     * the next rising sampling edge.  CS rising performs only constant async
     * resets of these counters, which maps cleanly to FPGA flip-flops.
     */
    always_ff @(negedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_byte_q <= '0;
            tx_bit_q <= 3'd7;
            tx_done_sck_q <= 1'b0;
        end else if (spi_cs_ni) begin
            tx_byte_q <= '0;
            tx_bit_q <= 3'd7;
            tx_done_sck_q <= 1'b0;
        end else if (tx_ready_q && !tx_done_sck_q) begin
            if (tx_bit_q == 3'd0) begin
                if ((tx_byte_q + 1'b1) >= tx_len_hold_q) begin
                    tx_done_sck_q <= 1'b1;
                end else begin
                    tx_byte_q <= tx_byte_q + 1'b1;
                    tx_bit_q <= 3'd7;
                end
            end else begin
                tx_bit_q <= tx_bit_q - 1'b1;
            end
        end
    end

    /* Toggle exactly once when the final response bit has just been shifted. */
    always_ff @(negedge spi_sck_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_complete_toggle_q <= 1'b0;
        end else if (!spi_cs_ni && tx_ready_q && !tx_done_sck_q &&
                     (tx_bit_q == 3'd0) &&
                     ((tx_byte_q + 1'b1) >= tx_len_hold_q)) begin
            tx_complete_toggle_q <= ~tx_complete_toggle_q;
        end
    end
endmodule
