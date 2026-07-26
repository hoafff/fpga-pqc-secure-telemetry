// FPST-SYS-SPEC-001 v1.1, Section 9 physical BTP transport.
//
// The serial pins are sampled into the 27 MHz system clock domain through
// two-flop synchronizers.  This deliberately targets the normative 1 MHz
// bring-up rate first; higher SPI rates must be qualified on the real board.
// Mode 0: sample MOSI / present MISO for the master's rising edge, MSB first.
module btp_spi_slave #(
    parameter integer MAX_FRAME_BYTES = 1038
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        spi_sclk_i,
    input  logic        spi_mosi_i,
    output logic        spi_miso_o,
    input  logic        spi_cs_ni,

    output logic        request_txn_start_o,
    output logic        request_byte_valid_o,
    output logic [7:0]  request_byte_o,
    output logic        request_txn_end_o,

    input  logic        response_pending_i,
    input  logic [10:0] response_length_i,
    output logic [10:0] response_addr_o,
    input  logic [7:0]  response_data_i,
    output logic        response_read_done_o,

    output logic        selected_o,
    output logic        response_txn_o
);
    logic [1:0] sclk_sync_q;
    logic [1:0] cs_sync_q;
    logic [1:0] mosi_sync_q;
    logic       sclk_prev_q;
    logic       cs_prev_q;

    logic       selected_q;
    logic       tx_mode_q;
    logic [2:0] bit_count_q;
    logic [7:0] rx_shift_q;
    logic [10:0] tx_byte_index_q;
    logic [10:0] tx_bytes_complete_q;

    wire sclk_rise = !sclk_prev_q && sclk_sync_q[1];
    wire cs_fall   =  cs_prev_q && !cs_sync_q[1];
    wire cs_rise   = !cs_prev_q &&  cs_sync_q[1];

    assign selected_o      = selected_q;
    assign response_txn_o  = selected_q && tx_mode_q;
    assign response_addr_o = tx_byte_index_q;

    // response_data_i is a combinational read from the endpoint response
    // cache.  Keeping the bit index unchanged until the sampling edge makes
    // the current MISO bit stable during the master's setup interval.
    always_comb begin
        spi_miso_o = 1'b0;
        if (selected_q && tx_mode_q &&
            (tx_byte_index_q < response_length_i)) begin
            spi_miso_o = response_data_i[7 - bit_count_q];
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            sclk_sync_q <= 2'b00;
            cs_sync_q   <= 2'b11;
            mosi_sync_q <= 2'b00;
            sclk_prev_q <= 1'b0;
            cs_prev_q   <= 1'b1;
        end else begin
            sclk_sync_q <= {sclk_sync_q[0], spi_sclk_i};
            cs_sync_q   <= {cs_sync_q[0], spi_cs_ni};
            mosi_sync_q <= {mosi_sync_q[0], spi_mosi_i};
            sclk_prev_q <= sclk_sync_q[1];
            cs_prev_q   <= cs_sync_q[1];
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            selected_q             <= 1'b0;
            tx_mode_q              <= 1'b0;
            bit_count_q            <= 3'd0;
            rx_shift_q             <= 8'h00;
            tx_byte_index_q        <= 11'd0;
            tx_bytes_complete_q     <= 11'd0;
            request_txn_start_o    <= 1'b0;
            request_byte_valid_o   <= 1'b0;
            request_byte_o         <= 8'h00;
            request_txn_end_o      <= 1'b0;
            response_read_done_o   <= 1'b0;
        end else begin
            request_txn_start_o  <= 1'b0;
            request_byte_valid_o <= 1'b0;
            request_txn_end_o    <= 1'b0;
            response_read_done_o <= 1'b0;

            if (cs_fall) begin
                selected_q         <= 1'b1;
                tx_mode_q          <= response_pending_i;
                bit_count_q        <= 3'd0;
                rx_shift_q         <= 8'h00;
                tx_byte_index_q    <= 11'd0;
                tx_bytes_complete_q <= 11'd0;

                if (!response_pending_i)
                    request_txn_start_o <= 1'b1;
            end

            if (selected_q && sclk_rise) begin
                if (tx_mode_q) begin
                    if (bit_count_q == 3'd7) begin
                        bit_count_q <= 3'd0;
                        if (tx_byte_index_q < response_length_i) begin
                            tx_bytes_complete_q <= tx_bytes_complete_q + 1'b1;
                            if ((tx_byte_index_q + 1'b1) < response_length_i)
                                tx_byte_index_q <= tx_byte_index_q + 1'b1;
                        end
                    end else begin
                        bit_count_q <= bit_count_q + 1'b1;
                    end
                end else begin
                    rx_shift_q <= {rx_shift_q[6:0], mosi_sync_q[1]};
                    if (bit_count_q == 3'd7) begin
                        bit_count_q          <= 3'd0;
                        request_byte_o       <= {rx_shift_q[6:0], mosi_sync_q[1]};
                        request_byte_valid_o <= 1'b1;
                    end else begin
                        bit_count_q <= bit_count_q + 1'b1;
                    end
                end
            end

            if (cs_rise && selected_q) begin
                selected_q <= 1'b0;
                if (tx_mode_q) begin
                    // A truncated response transaction does not consume the
                    // cache; irq_n therefore remains asserted and the MCU can
                    // repeat the response read transaction.
                    if ((tx_bytes_complete_q == response_length_i) &&
                        (response_length_i != 11'd0))
                        response_read_done_o <= 1'b1;
                end else begin
                    request_txn_end_o <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (response_length_i <= MAX_FRAME_BYTES)
                else $error("btp_spi_slave: response length exceeds frame limit");
        end
    end
`endif
endmodule
