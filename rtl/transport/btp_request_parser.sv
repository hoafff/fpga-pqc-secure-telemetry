module btp_request_parser #(
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic zeroize_i,

    input  logic frame_valid_i,
    input  logic [COUNT_W-1:0] frame_len_i,
    input  logic frame_overflow_i,
    output logic frame_accept_o,
    output logic [COUNT_W-1:0] frame_rd_addr_o,
    input  logic [7:0] frame_rd_data_i,

    output logic request_valid_o,
    input  logic request_accept_i,
    output logic [7:0] request_opcode_o,
    output logic [7:0] request_flags_o,
    output logic [15:0] request_transaction_id_o,
    output logic [15:0] request_payload_len_o,
    output logic [31:0] request_crc32_o,
    output logic request_error_o,
    output logic [15:0] request_error_code_o,

    input  logic [9:0] payload_rd_addr_i,
    output logic [7:0] payload_rd_data_o
);
    import fpst_btp_pkg::*;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_SCAN,
        ST_HOLD,
        ST_DRAIN
    } state_t;
    state_t state_q;

    logic [COUNT_W-1:0] scan_index_q;
    logic [COUNT_W-1:0] frame_len_q;
    logic frame_overflow_q;
    logic [15:0] sof_q;
    logic [7:0] version_q;
    logic [7:0] opcode_q;
    logic [7:0] flags_q;
    logic [7:0] reserved_q;
    logic [15:0] transaction_id_q;
    logic [15:0] payload_len_q;
    logic [31:0] crc_q;
    logic [31:0] observed_crc_q;
    logic [31:0] request_crc32_q;

    logic [31:0] observed_crc_with_current;
    logic [31:0] expected_crc;
    logic [17:0] expected_frame_len;
    logic crc_data_region;
    logic crc_wire_region;

    assign request_valid_o = (state_q == ST_HOLD);
    assign request_opcode_o = opcode_q;
    assign request_flags_o = flags_q;
    assign request_transaction_id_o = transaction_id_q;
    assign request_payload_len_o = payload_len_q;
    assign request_crc32_o = request_crc32_q;

    assign expected_crc = crc32_finalize(crc_q);
    assign observed_crc_with_current = {observed_crc_q[23:0], frame_rd_data_i};
    /* Keep the full 18-bit sum; range checks below reject values above BTP_MAX_PAYLOAD. */
    assign expected_frame_len = BTP_HEADER_BYTES + payload_len_q + BTP_CRC_BYTES;
    assign crc_data_region = (frame_len_q >= BTP_CRC_BYTES) &&
                             (scan_index_q >= 2) &&
                             (scan_index_q < (frame_len_q - BTP_CRC_BYTES));
    assign crc_wire_region = (frame_len_q >= BTP_CRC_BYTES) &&
                             (scan_index_q >= (frame_len_q - BTP_CRC_BYTES));

    /* During HOLD the endpoint reads payload bytes directly from immutable rx_mem. */
    always_comb begin
        if (state_q == ST_SCAN)
            frame_rd_addr_o = scan_index_q;
        else
            frame_rd_addr_o = BTP_HEADER_BYTES + payload_rd_addr_i;
        payload_rd_data_o = frame_rd_data_i;
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            scan_index_q <= '0;
            frame_len_q <= '0;
            frame_overflow_q <= 1'b0;
            sof_q <= '0;
            version_q <= '0;
            opcode_q <= '0;
            flags_q <= '0;
            reserved_q <= '0;
            transaction_id_q <= '0;
            payload_len_q <= '0;
            crc_q <= 32'hFFFFFFFF;
            observed_crc_q <= '0;
            request_crc32_q <= '0;
            request_error_o <= 1'b0;
            request_error_code_o <= ERR_OK;
            frame_accept_o <= 1'b0;
        end else begin
            frame_accept_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (frame_valid_i) begin
                        frame_len_q <= frame_len_i;
                        frame_overflow_q <= frame_overflow_i;
                        scan_index_q <= '0;
                        sof_q <= '0;
                        version_q <= '0;
                        opcode_q <= '0;
                        flags_q <= '0;
                        reserved_q <= '0;
                        transaction_id_q <= '0;
                        payload_len_q <= '0;
                        crc_q <= 32'hFFFFFFFF;
                        observed_crc_q <= '0;
                        request_crc32_q <= '0;
                        request_error_o <= 1'b0;
                        request_error_code_o <= ERR_OK;
                        state_q <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    /* Capture fixed header fields. */
                    case (scan_index_q)
                        0: sof_q[15:8] <= frame_rd_data_i;
                        1: sof_q[7:0] <= frame_rd_data_i;
                        2: version_q <= frame_rd_data_i;
                        3: opcode_q <= frame_rd_data_i;
                        4: flags_q <= frame_rd_data_i;
                        5: reserved_q <= frame_rd_data_i;
                        6: transaction_id_q[15:8] <= frame_rd_data_i;
                        7: transaction_id_q[7:0] <= frame_rd_data_i;
                        8: payload_len_q[15:8] <= frame_rd_data_i;
                        9: payload_len_q[7:0] <= frame_rd_data_i;
                        default: begin end
                    endcase

                    /* CRC covers version..payload and excludes SOF + CRC field. */
                    if (crc_data_region)
                        crc_q <= crc32_update_byte(crc_q, frame_rd_data_i);

                    if (crc_wire_region)
                        observed_crc_q <= {observed_crc_q[23:0], frame_rd_data_i};

                    if (scan_index_q + 1'b1 >= frame_len_q) begin
                        request_crc32_q <= expected_crc;
                        request_error_o <= 1'b0;
                        request_error_code_o <= ERR_OK;

                        if (frame_overflow_q ||
                            (frame_len_q < (BTP_HEADER_BYTES + BTP_CRC_BYTES)) ||
                            (frame_len_q > MAX_FRAME_BYTES)) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_BTP_LENGTH;
                        end else if (sof_q != BTP_SOF) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_BTP_SOF;
                        end else if (version_q != BTP_VERSION) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_BTP_VERSION;
                        end else if (reserved_q != 8'h00 ||
                                     ((flags_q & BTP_FLAG_RESERVED_M) != 0) ||
                                     ((flags_q & (BTP_FLAG_RESPONSE |
                                                  BTP_FLAG_ERROR |
                                                  BTP_FLAG_ASYNC_EVENT)) != 0)) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_RESERVED_FIELD;
                        end else if (payload_len_q > BTP_MAX_PAYLOAD ||
                                     expected_frame_len != frame_len_q) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_BTP_LENGTH;
                        end else if (observed_crc_with_current != expected_crc) begin
                            request_error_o <= 1'b1;
                            request_error_code_o <= ERR_BTP_CRC;
                        end

                        state_q <= ST_HOLD;
                    end else begin
                        scan_index_q <= scan_index_q + 1'b1;
                    end
                end

                ST_HOLD: begin
                    if (request_accept_i) begin
                        /*
                         * frame_accept_o is registered, while rx_pending_q in
                         * btp_spi_slave is cleared on the following clk edge.
                         * Do not return directly to IDLE here: doing so lets the
                         * still-high frame_valid_i be mistaken for a new frame.
                         */
                        frame_accept_o <= 1'b1;
                        request_error_o <= 1'b0;
                        request_error_code_o <= ERR_OK;
                        state_q <= ST_DRAIN;
                    end
                end

                ST_DRAIN: begin
                    /* Re-arm only after the producer has visibly dropped valid. */
                    if (!frame_valid_i)
                        state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase

            if (zeroize_i) begin
                state_q <= ST_IDLE;
                scan_index_q <= '0;
                frame_len_q <= '0;
                frame_overflow_q <= 1'b0;
                sof_q <= '0;
                version_q <= '0;
                opcode_q <= '0;
                flags_q <= '0;
                reserved_q <= '0;
                transaction_id_q <= '0;
                payload_len_q <= '0;
                crc_q <= 32'hFFFFFFFF;
                observed_crc_q <= '0;
                request_crc32_q <= '0;
                request_error_o <= 1'b0;
                request_error_code_o <= ERR_OK;
                frame_accept_o <= 1'b0;
            end
        end
    end
endmodule
