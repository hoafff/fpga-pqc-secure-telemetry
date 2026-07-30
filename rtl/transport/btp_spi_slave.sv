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
     * FPST BTP SPI slave
     * ------------------
     *
     * Physical interface remains unchanged:
     *   - SPI mode 0
     *   - MSB first
     *   - SCK / CS / MOSI / MISO pins unchanged
     *
     * spi_sck_i is NOT used as an FPGA clock.
     *
     * SCK, CS and MOSI are synchronized into the 27 MHz clk_i domain.
     * Rising/falling SCK events are reconstructed with edge detectors.
     *
     * At the locked FPST SPI rate of 1 MHz there are about 27 clk_i cycles
     * per SPI period, providing ample margin for synchronization.
     */

    /* --------------------------------------------------------------------- */
    /* Frame memories                                                        */
    /* --------------------------------------------------------------------- */

    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];

    /*
     * Keep the synchronous-read TX RAM inference added for Gowin.
     * Without this, the 1038-byte TX image may be expanded into thousands
     * of flip-flops.
     */
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];


    /* --------------------------------------------------------------------- */
    /* Asynchronous SPI input synchronizers                                  */
    /* --------------------------------------------------------------------- */

    logic sck_meta_q;
    logic sck_sync_q;
    logic sck_prev_q;

    /*
     * CS deliberately receives one additional synchronization stage versus
     * SCK. This guarantees that the final falling SCK event is processed
     * before the synchronized CS-rising/end-of-transaction event.
     */
    logic cs_meta_q;
    logic cs_sync_q;
    logic cs_delay_q;
    logic cs_prev_q;

    logic mosi_meta_q;
    logic mosi_sync_q;

    logic sck_rise_sys;
    logic sck_fall_sys;
    logic cs_fall_sys;
    logic cs_rise_sys;

    assign sck_rise_sys =  sck_sync_q && !sck_prev_q;
    assign sck_fall_sys = !sck_sync_q &&  sck_prev_q;

    assign cs_fall_sys = !cs_delay_q &&  cs_prev_q;
    assign cs_rise_sys =  cs_delay_q && !cs_prev_q;


    /* --------------------------------------------------------------------- */
    /* RX/request state                                                      */
    /* --------------------------------------------------------------------- */

    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_q;
    logic [COUNT_W-1:0] rx_count_q;
    logic rx_overflow_q;
    logic rx_capture_active_q;

    logic [COUNT_W-1:0] rx_len_hold_q;
    logic rx_overflow_hold_q;
    logic rx_pending_q;


    /* --------------------------------------------------------------------- */
    /* TX/response state                                                     */
    /* --------------------------------------------------------------------- */

    logic [COUNT_W-1:0] tx_len_hold_q;

    logic [COUNT_W-1:0] tx_byte_q;
    logic [2:0] tx_bit_q;

    logic [7:0] tx_rd_data_q;

    logic tx_ready_q;
    logic tx_done_q;
    logic tx_transaction_active_q;


    /* --------------------------------------------------------------------- */
    /* External status/read paths                                            */
    /* --------------------------------------------------------------------- */

    assign rx_rd_data_o = rx_mem[rx_rd_addr_i];

    assign rx_frame_valid_o = rx_pending_q;
    assign rx_frame_len_o   = rx_len_hold_q;
    assign overflow_o       = rx_overflow_hold_q;

    assign tx_frame_ready_o = tx_ready_q;


    /* --------------------------------------------------------------------- */
    /* MISO                                                                  */
    /* --------------------------------------------------------------------- */

    /*
     * SPI mode 0:
     *   - master samples MISO on rising SCK
     *   - slave changes/advances MISO after falling SCK
     *
     * The raw CS input is intentionally used only for the output-enable.
     * This releases the shared MISO bus immediately when this Primer is
     * deselected.
     *
     * No sequential logic is clocked by raw CS or raw SCK.
     */
    always_comb begin
        if (!spi_cs_ni &&
            tx_ready_q &&
            !tx_done_q &&
            (tx_byte_q < tx_len_hold_q)) begin

            spi_miso_o = tx_rd_data_q[tx_bit_q];

        end else begin
            spi_miso_o = 1'bz;
        end
    end


    /* --------------------------------------------------------------------- */
    /* Entire transport now runs in the 27 MHz system-clock domain           */
    /* --------------------------------------------------------------------- */

    always_ff @(posedge clk_i) begin

        if (!rst_ni) begin

            /* Input synchronizers: SPI bus idles CS=1, SCK=0. */
            sck_meta_q <= 1'b0;
            sck_sync_q <= 1'b0;
            sck_prev_q <= 1'b0;

            cs_meta_q  <= 1'b1;
            cs_sync_q  <= 1'b1;
            cs_delay_q <= 1'b1;
            cs_prev_q  <= 1'b1;

            mosi_meta_q <= 1'b0;
            mosi_sync_q <= 1'b0;


            /* RX state. */
            rx_shift_q          <= 8'h00;
            rx_bit_q            <= 3'd0;
            rx_count_q          <= '0;
            rx_overflow_q       <= 1'b0;
            rx_capture_active_q <= 1'b0;

            rx_len_hold_q       <= '0;
            rx_overflow_hold_q  <= 1'b0;
            rx_pending_q        <= 1'b0;


            /* TX state. */
            tx_len_hold_q           <= '0;
            tx_byte_q               <= '0;
            tx_bit_q                <= 3'd7;
            tx_rd_data_q            <= 8'h00;
            tx_ready_q              <= 1'b0;
            tx_done_q               <= 1'b0;
            tx_transaction_active_q <= 1'b0;

            tx_frame_consumed_o <= 1'b0;

        end else begin

            /* ------------------------------------------------------------- */
            /* Synchronize asynchronous external SPI signals                 */
            /* ------------------------------------------------------------- */

            sck_meta_q <= spi_sck_i;
            sck_sync_q <= sck_meta_q;
            sck_prev_q <= sck_sync_q;

            cs_meta_q  <= spi_cs_ni;
            cs_sync_q  <= cs_meta_q;
            cs_delay_q <= cs_sync_q;
            cs_prev_q  <= cs_delay_q;

            mosi_meta_q <= spi_mosi_i;
            mosi_sync_q <= mosi_meta_q;


            /* Default one-clock pulse. */
            tx_frame_consumed_o <= 1'b0;


            /* ------------------------------------------------------------- */
            /* TX RAM                                                        */
            /* ------------------------------------------------------------- */

            /*
             * Synchronous read keeps TX storage compatible with Gowin BSRAM
             * inference.
             *
             * tx_byte_q changes shortly after falling SCK. At SPI=1 MHz and
             * clk_i=27 MHz, many system clocks occur before the following
             * rising SCK samples MISO.
             */
            tx_rd_data_q <= tx_mem[tx_byte_q];

            /*
             * Response memory can be modified only while no committed
             * response is exposed to the SPI master.
             */
            if (tx_wr_en_i &&
                !tx_ready_q &&
                (tx_wr_addr_i < MAX_FRAME_BYTES)) begin

                tx_mem[tx_wr_addr_i] <= tx_wr_data_i;
            end


            /* Commit complete response image. */
            if (tx_frame_commit_i &&
                !tx_ready_q &&
                (tx_frame_len_i != 0) &&
                (tx_frame_len_i <= MAX_FRAME_BYTES)) begin

                tx_len_hold_q <= tx_frame_len_i;
                tx_ready_q    <= 1'b1;

                /*
                 * Keep byte zero prefetched while waiting for the master to
                 * assert CS after IRQ.
                 */
                tx_byte_q <= '0;
                tx_bit_q  <= 3'd7;
                tx_done_q <= 1'b0;
            end


            /* ------------------------------------------------------------- */
            /* CS falling: start one SPI transaction                         */
            /* ------------------------------------------------------------- */

            if (cs_fall_sys) begin

                /*
                 * If a response is ready, this is a response transaction.
                 * Otherwise it is a request transaction.
                 */
                if (tx_ready_q) begin

                    tx_transaction_active_q <= 1'b1;

                    tx_byte_q <= '0;
                    tx_bit_q  <= 3'd7;
                    tx_done_q <= 1'b0;

                    rx_capture_active_q <= 1'b0;

                end else begin

                    rx_capture_active_q <= 1'b1;

                    rx_shift_q    <= 8'h00;
                    rx_bit_q      <= 3'd0;
                    rx_count_q    <= '0;
                    rx_overflow_q <= 1'b0;

                    tx_transaction_active_q <= 1'b0;
                end
            end


            /* ------------------------------------------------------------- */
            /* Rising SCK: sample MOSI                                       */
            /* ------------------------------------------------------------- */

            if (sck_rise_sys && rx_capture_active_q) begin

                rx_shift_q <= {rx_shift_q[6:0], mosi_sync_q};

                if (rx_bit_q == 3'd7) begin

                    if (rx_count_q < MAX_FRAME_BYTES) begin

                        rx_mem[rx_count_q] <= {
                            rx_shift_q[6:0],
                            mosi_sync_q
                        };

                        rx_count_q <= rx_count_q + 1'b1;

                    end else begin

                        rx_overflow_q <= 1'b1;
                    end

                    rx_bit_q <= 3'd0;

                end else begin

                    rx_bit_q <= rx_bit_q + 1'b1;
                end
            end


            /* ------------------------------------------------------------- */
            /* Falling SCK: advance MISO                                     */
            /* ------------------------------------------------------------- */

            if (sck_fall_sys &&
                tx_transaction_active_q &&
                tx_ready_q &&
                !tx_done_q) begin

                if (tx_bit_q == 3'd0) begin

                    /*
                     * Current byte's bit 0 has just been sampled on the
                     * preceding rising edge.
                     */
                    if ((tx_byte_q + 1'b1) >= tx_len_hold_q) begin

                        /* Final response byte is complete. */
                        tx_done_q <= 1'b1;

                    end else begin

                        tx_byte_q <= tx_byte_q + 1'b1;
                        tx_bit_q  <= 3'd7;
                    end

                end else begin

                    tx_bit_q <= tx_bit_q - 1'b1;
                end
            end


            /* ------------------------------------------------------------- */
            /* CS rising: finish transaction                                 */
            /* ------------------------------------------------------------- */

            if (cs_rise_sys) begin

                /*
                 * Request transaction:
                 *
                 * rx_count_q already contains the number of complete bytes.
                 * A non-zero rx_bit_q means CS rose in the middle of a byte.
                 */
                if (rx_capture_active_q) begin

                    rx_capture_active_q <= 1'b0;

                    if (!rx_pending_q) begin

                        rx_len_hold_q      <= rx_count_q;
                        rx_overflow_hold_q <=
                            rx_overflow_q || (rx_bit_q != 3'd0);

                        rx_pending_q <= 1'b1;
                    end
                end


                /*
                 * Response transaction:
                 *
                 * Consume only if every committed response bit was actually
                 * clocked by the master.
                 *
                 * If CS rises early, tx_ready_q stays asserted so the master
                 * may retry the complete response from byte zero.
                 */
                if (tx_transaction_active_q) begin

                    tx_transaction_active_q <= 1'b0;

                    if (tx_ready_q && tx_done_q) begin

                        tx_ready_q         <= 1'b0;
                        tx_len_hold_q      <= '0;
                        tx_frame_consumed_o <= 1'b1;
                    end

                    /*
                     * Return addressing state to the beginning while CS is
                     * high. This also keeps byte 0 prefetched for a retry.
                     */
                    tx_byte_q <= '0;
                    tx_bit_q  <= 3'd7;
                    tx_done_q <= 1'b0;
                end
            end


            /* Request consumer acknowledgment. */
            if (rx_frame_accept_i) begin
                rx_pending_q <= 1'b0;
            end


            /* ------------------------------------------------------------- */
            /* Security zeroize                                              */
            /* ------------------------------------------------------------- */

            /*
             * RAM arrays are deliberately not bulk-reset because that would
             * prevent efficient FPGA RAM inference.
             *
             * All architected valid/length/readability state is invalidated,
             * so stale RAM contents cannot be exposed after zeroize.
             */
            if (zeroize_i) begin

                rx_shift_q          <= 8'h00;
                rx_bit_q            <= 3'd0;
                rx_count_q          <= '0;
                rx_overflow_q       <= 1'b0;
                rx_capture_active_q <= 1'b0;

                rx_len_hold_q      <= '0;
                rx_overflow_hold_q <= 1'b0;
                rx_pending_q       <= 1'b0;


                tx_len_hold_q           <= '0;
                tx_byte_q               <= '0;
                tx_bit_q                <= 3'd7;
                tx_rd_data_q            <= 8'h00;
                tx_ready_q              <= 1'b0;
                tx_done_q               <= 1'b0;
                tx_transaction_active_q <= 1'b0;

                tx_frame_consumed_o <= 1'b0;
            end
        end
    end

endmodule