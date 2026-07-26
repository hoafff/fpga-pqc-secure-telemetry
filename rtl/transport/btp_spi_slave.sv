module btp_spi_slave #(
    parameter integer MAX_FRAME_BYTES = 1038
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,

    input  logic        spi_sclk_i,
    input  logic        spi_mosi_i,
    input  logic        spi_cs_ni,
    output logic        spi_miso_o,
    output logic        spi_miso_oe_o,

    output logic        req_valid_o,
    input  logic        req_take_i,
    output logic [10:0] req_len_o,
    input  logic [10:0] req_raddr_i,
    output logic [7:0]  req_rdata_o,

    input  logic        rsp_we_i,
    input  logic [10:0] rsp_waddr_i,
    input  logic [7:0]  rsp_wdata_i,
    input  logic [10:0] rsp_len_i,
    input  logic        rsp_commit_i,
    input  logic        rsp_rearm_i,
    output logic        rsp_pending_o,
    output logic        rsp_consumed_o,

    output logic        irq_no,
    output logic        overflow_o
);
    /*
     * The MCU starts at 1 MHz while this block runs at 27 MHz.  SCK/CS/MOSI are
     * synchronized and edge-detected in the system-clock domain, so no raw
     * multi-bit bus crosses a clock boundary.  This is the deliberately simple
     * bring-up implementation; any future SPI-rate increase must re-run timing
     * and error-rate characterization.
     */

    logic [7:0] req_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] rsp_mem [0:MAX_FRAME_BYTES-1];

    logic sclk_meta_q, sclk_sync_q, sclk_prev_q;
    logic cs_meta_q, cs_sync_q, cs_prev_q;
    logic mosi_meta_q, mosi_sync_q;

    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_count_q;
    logic [10:0] rx_byte_count_q;

    logic response_phase_q;
    logic [10:0] rsp_len_q;
    logic [10:0] tx_byte_index_q;
    logic [2:0] tx_bit_index_q;
    logic [10:0] tx_bytes_sampled_q;

    logic req_valid_q;
    logic rsp_pending_q;

    wire sclk_rise = sclk_sync_q && !sclk_prev_q;
    wire sclk_fall = !sclk_sync_q && sclk_prev_q;
    wire cs_fall   = !cs_sync_q && cs_prev_q;
    wire cs_rise   = cs_sync_q && !cs_prev_q;

    assign req_valid_o = req_valid_q;
    assign req_len_o = rx_byte_count_q;
    assign req_rdata_o = (req_raddr_i < MAX_FRAME_BYTES) ?
                         req_mem[req_raddr_i] : 8'h00;
    assign rsp_pending_o = rsp_pending_q;
    assign irq_no = ~rsp_pending_q;

    /* Release shared MISO immediately when the physical CS pin is inactive. */
    assign spi_miso_oe_o = ~spi_cs_ni;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            sclk_meta_q <= 1'b0;
            sclk_sync_q <= 1'b0;
            sclk_prev_q <= 1'b0;
            cs_meta_q   <= 1'b1;
            cs_sync_q   <= 1'b1;
            cs_prev_q   <= 1'b1;
            mosi_meta_q <= 1'b0;
            mosi_sync_q <= 1'b0;
        end else begin
            sclk_meta_q <= spi_sclk_i;
            sclk_sync_q <= sclk_meta_q;
            sclk_prev_q <= sclk_sync_q;
            cs_meta_q   <= spi_cs_ni;
            cs_sync_q   <= cs_meta_q;
            cs_prev_q   <= cs_sync_q;
            mosi_meta_q <= spi_mosi_i;
            mosi_sync_q <= mosi_meta_q;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            rx_shift_q          <= 8'h00;
            rx_bit_count_q      <= 3'd0;
            rx_byte_count_q     <= 11'd0;
            response_phase_q    <= 1'b0;
            rsp_len_q           <= 11'd0;
            tx_byte_index_q     <= 11'd0;
            tx_bit_index_q      <= 3'd7;
            tx_bytes_sampled_q  <= 11'd0;
            req_valid_q         <= 1'b0;
            rsp_pending_q       <= 1'b0;
            rsp_consumed_o      <= 1'b0;
            spi_miso_o          <= 1'b0;
            overflow_o          <= 1'b0;
        end else begin
            rsp_consumed_o <= 1'b0;

            if (req_take_i)
                req_valid_q <= 1'b0;

            if (rsp_we_i && (rsp_waddr_i < MAX_FRAME_BYTES))
                rsp_mem[rsp_waddr_i] <= rsp_wdata_i;

            if (rsp_commit_i) begin
                rsp_len_q     <= rsp_len_i;
                rsp_pending_q <= (rsp_len_i != 0);
            end else if (rsp_rearm_i && (rsp_len_q != 0)) begin
                rsp_pending_q <= 1'b1;
            end

            if (cs_fall) begin
                response_phase_q   <= rsp_pending_q;
                rx_shift_q         <= 8'h00;
                rx_bit_count_q     <= 3'd0;
                rx_byte_count_q    <= 11'd0;
                tx_byte_index_q    <= 11'd0;
                tx_bit_index_q     <= 3'd7;
                tx_bytes_sampled_q <= 11'd0;
                overflow_o         <= 1'b0;

                if (rsp_pending_q && (rsp_len_q != 0))
                    spi_miso_o <= rsp_mem[0][7];
                else
                    spi_miso_o <= 1'b0;
            end

            if (!cs_sync_q) begin
                if (!response_phase_q && sclk_rise) begin
                    rx_shift_q <= {rx_shift_q[6:0], mosi_sync_q};
                    if (rx_bit_count_q == 3'd7) begin
                        rx_bit_count_q <= 3'd0;
                        if (rx_byte_count_q < MAX_FRAME_BYTES) begin
                            req_mem[rx_byte_count_q] <=
                                {rx_shift_q[6:0], mosi_sync_q};
                            rx_byte_count_q <= rx_byte_count_q + 11'd1;
                        end else begin
                            overflow_o <= 1'b1;
                        end
                    end else begin
                        rx_bit_count_q <= rx_bit_count_q + 3'd1;
                    end
                end

                if (response_phase_q && sclk_rise) begin
                    if (tx_bit_index_q == 3'd0)
                        tx_bytes_sampled_q <= tx_bytes_sampled_q + 11'd1;
                end

                if (response_phase_q && sclk_fall) begin
                    if (tx_bit_index_q == 3'd0) begin
                        tx_bit_index_q <= 3'd7;
                        if ((tx_byte_index_q + 11'd1) < rsp_len_q) begin
                            tx_byte_index_q <= tx_byte_index_q + 11'd1;
                            spi_miso_o <= rsp_mem[tx_byte_index_q + 11'd1][7];
                        end else begin
                            spi_miso_o <= 1'b0;
                        end
                    end else begin
                        tx_bit_index_q <= tx_bit_index_q - 3'd1;
                        spi_miso_o <= rsp_mem[tx_byte_index_q][tx_bit_index_q - 3'd1];
                    end
                end
            end

            if (cs_rise) begin
                spi_miso_o <= 1'b0;
                if (response_phase_q) begin
                    if (tx_bytes_sampled_q >= rsp_len_q) begin
                        rsp_pending_q  <= 1'b0;
                        rsp_consumed_o <= 1'b1;
                    end
                end else if (!overflow_o &&
                             (rx_byte_count_q != 0) &&
                             (rx_bit_count_q == 3'd0)) begin
                    /* One request per CS assertion. Endpoint owns validation. */
                    if (!req_valid_q)
                        req_valid_q <= 1'b1;
                    else
                        overflow_o <= 1'b1;
                end
                response_phase_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (MAX_FRAME_BYTES <= 2048)
            else $error("btp_spi_slave: MAX_FRAME_BYTES exceeds 11-bit address interface");
    end
`endif
endmodule
