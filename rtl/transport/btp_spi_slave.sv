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
    output logic tx_frame_consumed_o,

    output logic overflow_o
);
    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];

    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_q;
    logic [COUNT_W-1:0] rx_count_q;
    logic [COUNT_W-1:0] rx_len_snapshot_q;
    logic rx_overflow_q, rx_overflow_snapshot_q;
    logic rx_done_toggle_q;

    logic [7:0] tx_shift_q;
    logic [2:0] tx_bit_q;
    logic [COUNT_W-1:0] tx_count_q;
    logic [COUNT_W-1:0] tx_len_sck_q;
    logic tx_active_q;
    logic tx_seen_commit_toggle_q;
    logic tx_consumed_toggle_q;

    logic tx_commit_toggle_q;
    logic [COUNT_W-1:0] tx_len_hold_q;
    logic tx_commit_sync1_q, tx_commit_sync2_q;

    logic rx_done_sync1_q, rx_done_sync2_q, rx_done_seen_q;
    logic [COUNT_W-1:0] rx_len_hold_q;
    logic rx_overflow_hold_q;
    logic rx_pending_q;

    logic tx_consumed_sync1_q, tx_consumed_sync2_q, tx_consumed_seen_q;
    integer i;

    assign rx_rd_data_o = rx_mem[rx_rd_addr_i];
    assign rx_frame_valid_o = rx_pending_q;
    assign rx_frame_len_o = rx_len_hold_q;
    assign overflow_o = rx_overflow_hold_q;

    /* System-clock side. Memories are only consumed after the corresponding
       toggle crosses the clock boundary and has been synchronized twice. */
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            tx_commit_toggle_q <= 1'b0;
            tx_len_hold_q <= '0;
            rx_done_sync1_q <= 1'b0;
            rx_done_sync2_q <= 1'b0;
            rx_done_seen_q <= 1'b0;
            rx_len_hold_q <= '0;
            rx_overflow_hold_q <= 1'b0;
            rx_pending_q <= 1'b0;
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

            if (tx_wr_en_i)
                tx_mem[tx_wr_addr_i] <= tx_wr_data_i;

            if (tx_frame_commit_i) begin
                tx_len_hold_q <= tx_frame_len_i;
                tx_commit_toggle_q <= ~tx_commit_toggle_q;
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
                tx_frame_consumed_o <= 1'b1;
            end

            if (zeroize_i) begin
                tx_len_hold_q <= '0;
                rx_len_hold_q <= '0;
                rx_overflow_hold_q <= 1'b0;
                rx_pending_q <= 1'b0;
                for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                    tx_mem[i] <= 8'h00;
            end
        end
    end

    /* MOSI is sampled on rising SCK for SPI mode 0. */
    always_ff @(posedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            rx_count_q <= '0;
            rx_len_snapshot_q <= '0;
            rx_overflow_q <= 1'b0;
            rx_overflow_snapshot_q <= 1'b0;
            rx_done_toggle_q <= 1'b0;
            tx_commit_sync1_q <= 1'b0;
            tx_commit_sync2_q <= 1'b0;
        end else if (spi_cs_ni) begin
            if ((rx_count_q != 0) || (rx_bit_q != 0)) begin
                rx_len_snapshot_q <= rx_count_q;
                rx_overflow_snapshot_q <= rx_overflow_q || (rx_bit_q != 0);
                rx_done_toggle_q <= ~rx_done_toggle_q;
            end
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            rx_count_q <= '0;
            rx_overflow_q <= 1'b0;
        end else begin
            tx_commit_sync1_q <= tx_commit_toggle_q;
            tx_commit_sync2_q <= tx_commit_sync1_q;
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

    /* MISO changes on falling SCK for SPI mode 0. The complete response is
       immutable in tx_mem from commit until this CS transaction completes. */
    always_ff @(negedge spi_sck_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            spi_miso_o <= 1'b0;
            tx_shift_q <= 8'h00;
            tx_bit_q <= 3'd7;
            tx_count_q <= '0;
            tx_len_sck_q <= '0;
            tx_active_q <= 1'b0;
            tx_seen_commit_toggle_q <= 1'b0;
            tx_consumed_toggle_q <= 1'b0;
        end else if (spi_cs_ni) begin
            if (tx_active_q)
                tx_consumed_toggle_q <= ~tx_consumed_toggle_q;
            spi_miso_o <= 1'b0;
            tx_shift_q <= 8'h00;
            tx_bit_q <= 3'd7;
            tx_count_q <= '0;
            tx_active_q <= 1'b0;
        end else begin
            if (!tx_active_q && (tx_commit_sync2_q != tx_seen_commit_toggle_q)) begin
                tx_seen_commit_toggle_q <= tx_commit_sync2_q;
                tx_len_sck_q <= tx_len_hold_q;
                tx_count_q <= '0;
                tx_bit_q <= 3'd7;
                tx_shift_q <= tx_mem[0];
                tx_active_q <= (tx_len_hold_q != 0);
                spi_miso_o <= tx_mem[0][7];
            end else if (tx_active_q) begin
                spi_miso_o <= tx_shift_q[tx_bit_q];
                if (tx_bit_q == 3'd0) begin
                    if ((tx_count_q + 1'b1) < tx_len_sck_q) begin
                        tx_count_q <= tx_count_q + 1'b1;
                        tx_shift_q <= tx_mem[tx_count_q + 1'b1];
                        tx_bit_q <= 3'd7;
                    end else begin
                        tx_active_q <= 1'b0;
                        tx_bit_q <= 3'd7;
                    end
                end else begin
                    tx_bit_q <= tx_bit_q - 1'b1;
                end
            end else begin
                spi_miso_o <= 1'b0;
            end
        end
    end
endmodule
