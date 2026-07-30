module btp_response_builder #(
    parameter integer MAX_PAYLOAD_BYTES = 1024,
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic zeroize_i,

    input  logic payload_wr_en_i,
    input  logic [9:0] payload_wr_addr_i,
    input  logic [7:0] payload_wr_data_i,

    input  logic start_i,
    input  logic [7:0] opcode_i,
    input  logic [15:0] transaction_id_i,
    input  logic [15:0] payload_len_i,
    input  logic error_i,
    output logic busy_o,
    output logic done_o,
    output logic [COUNT_W-1:0] frame_len_o,

    output logic tx_wr_en_o,
    output logic [COUNT_W-1:0] tx_wr_addr_o,
    output logic [7:0] tx_wr_data_o
);
    import fpst_btp_pkg::*;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_HEADER,
        ST_PAYLOAD_PREFETCH,
        ST_PAYLOAD,
        ST_PREP_CRC,
        ST_CRC,
        ST_DONE
    } state_t;

    state_t state_q;

    /*
     * Response payload RAM.
     *
     * The old combinational read:
     *
     *     payload_mem[payload_index_q]
     *
     * builds a very large LUT mux for a 1024-byte memory. A registered,
     * synchronous read lets Gowin infer BSRAM and avoids inference stalls.
     * Do not reset this array in parallel; every advertised payload byte is
     * overwritten before start_i.
     */
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] payload_mem [0:MAX_PAYLOAD_BYTES-1];

    logic [7:0] opcode_q;
    logic [15:0] transaction_id_q;
    logic [15:0] payload_len_q;
    logic [7:0] flags_q;

    logic [3:0] header_index_q;
    logic [9:0] payload_index_q;
    logic [9:0] payload_rd_addr_q;
    logic [7:0] payload_rd_data_q;

    logic [10:0] payload_index_plus_one;
    logic [10:0] payload_index_plus_two;

    logic [1:0] crc_index_q;
    logic [COUNT_W-1:0] frame_index_q;

    logic [31:0] crc_q;
    logic [31:0] final_crc_q;
    logic [7:0] current_header_byte;

    logic [17:0] frame_len_calc;

    localparam logic [17:0] BTP_HEADER_BYTES_18 = BTP_HEADER_BYTES;
    localparam logic [17:0] BTP_CRC_BYTES_18    = BTP_CRC_BYTES;

    assign payload_index_plus_one = {1'b0, payload_index_q} + 11'd1;
    assign payload_index_plus_two = {1'b0, payload_index_q} + 11'd2;

    always_comb begin
        frame_len_calc = BTP_HEADER_BYTES_18 +
                         {2'b00, payload_len_i} +
                         BTP_CRC_BYTES_18;
    end

    assign busy_o = (state_q != ST_IDLE) && (state_q != ST_DONE);

    always_comb begin
        case (header_index_q)
            4'd0: current_header_byte = BTP_SOF[15:8];
            4'd1: current_header_byte = BTP_SOF[7:0];
            4'd2: current_header_byte = BTP_VERSION;
            4'd3: current_header_byte = opcode_q;
            4'd4: current_header_byte = flags_q;
            4'd5: current_header_byte = 8'h00;
            4'd6: current_header_byte = transaction_id_q[15:8];
            4'd7: current_header_byte = transaction_id_q[7:0];
            4'd8: current_header_byte = payload_len_q[15:8];
            4'd9: current_header_byte = payload_len_q[7:0];
            default: current_header_byte = 8'h00;
        endcase
    end

    always_comb begin
        tx_wr_en_o   = 1'b0;
        tx_wr_addr_o = frame_index_q;
        tx_wr_data_o = 8'h00;

        case (state_q)
            ST_HEADER: begin
                tx_wr_en_o   = 1'b1;
                tx_wr_data_o = current_header_byte;
            end

            ST_PAYLOAD: begin
                tx_wr_en_o   = 1'b1;
                tx_wr_data_o = payload_rd_data_q;
            end

            ST_CRC: begin
                tx_wr_en_o = 1'b1;
                case (crc_index_q)
                    2'd0: tx_wr_data_o = final_crc_q[31:24];
                    2'd1: tx_wr_data_o = final_crc_q[23:16];
                    2'd2: tx_wr_data_o = final_crc_q[15:8];
                    default: tx_wr_data_o = final_crc_q[7:0];
                endcase
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q           <= ST_IDLE;
            opcode_q          <= '0;
            transaction_id_q  <= '0;
            payload_len_q     <= '0;
            flags_q           <= BTP_FLAG_RESPONSE;
            header_index_q    <= '0;
            payload_index_q   <= '0;
            payload_rd_addr_q <= '0;
            payload_rd_data_q <= 8'h00;
            crc_index_q       <= '0;
            frame_index_q     <= '0;
            crc_q             <= 32'hFFFF_FFFF;
            final_crc_q       <= '0;
            frame_len_o       <= '0;
            done_o            <= 1'b0;
        end else begin
            done_o <= 1'b0;

            /* Payload writes occur only while the builder is idle. */
            if (payload_wr_en_i &&
                (state_q == ST_IDLE) &&
                (payload_wr_addr_i < MAX_PAYLOAD_BYTES)) begin
                payload_mem[payload_wr_addr_i] <= payload_wr_data_i;
            end

            /* Synchronous BSRAM read and one-byte look-ahead pipeline. */
            if ((state_q == ST_PAYLOAD_PREFETCH) ||
                (state_q == ST_PAYLOAD)) begin
                payload_rd_data_q <= payload_mem[payload_rd_addr_q];
            end

            case (state_q)
                ST_IDLE: begin
                    if (start_i &&
                        (payload_len_i <= MAX_PAYLOAD_BYTES) &&
                        (frame_len_calc <= MAX_FRAME_BYTES)) begin
                        opcode_q          <= opcode_i;
                        transaction_id_q  <= transaction_id_i;
                        payload_len_q     <= payload_len_i;
                        flags_q           <= BTP_FLAG_RESPONSE |
                                             (error_i ? BTP_FLAG_ERROR : 8'h00);
                        header_index_q    <= '0;
                        payload_index_q   <= '0;
                        payload_rd_addr_q <= '0;
                        crc_index_q       <= '0;
                        frame_index_q     <= '0;
                        crc_q             <= 32'hFFFF_FFFF;
                        final_crc_q       <= '0;
                        frame_len_o       <= frame_len_calc[COUNT_W-1:0];
                        state_q           <= ST_HEADER;
                    end
                end

                ST_HEADER: begin
                    if (header_index_q >= 4'd2)
                        crc_q <= crc32_update_byte(crc_q, current_header_byte);

                    frame_index_q <= frame_index_q + 1'b1;

                    if (header_index_q == 4'd9) begin
                        header_index_q <= '0;

                        if (payload_len_q == 0) begin
                            state_q <= ST_PREP_CRC;
                        end else begin
                            payload_index_q   <= '0;
                            payload_rd_addr_q <= '0;
                            state_q           <= ST_PAYLOAD_PREFETCH;
                        end
                    end else begin
                        header_index_q <= header_index_q + 1'b1;
                    end
                end

                /*
                 * One cycle is required to fetch payload byte zero from the
                 * synchronous RAM. At the same edge, prepare address one.
                 */
                ST_PAYLOAD_PREFETCH: begin
                    if (payload_len_q > 16'd1)
                        payload_rd_addr_q <= 10'd1;
                    else
                        payload_rd_addr_q <= '0;

                    state_q <= ST_PAYLOAD;
                end

                ST_PAYLOAD: begin
                    crc_q         <= crc32_update_byte(crc_q, payload_rd_data_q);
                    frame_index_q <= frame_index_q + 1'b1;

                    if (payload_index_plus_one >= payload_len_q) begin
                        payload_index_q   <= '0;
                        payload_rd_addr_q <= '0;
                        state_q           <= ST_PREP_CRC;
                    end else begin
                        payload_index_q <= payload_index_plus_one[9:0];

                        if (payload_index_plus_two < payload_len_q)
                            payload_rd_addr_q <= payload_index_plus_two[9:0];
                    end
                end

                ST_PREP_CRC: begin
                    final_crc_q <= crc32_finalize(crc_q);
                    crc_index_q <= '0;
                    state_q     <= ST_CRC;
                end

                ST_CRC: begin
                    frame_index_q <= frame_index_q + 1'b1;

                    if (crc_index_q == 2'd3) begin
                        crc_index_q <= '0;
                        state_q     <= ST_DONE;
                    end else begin
                        crc_index_q <= crc_index_q + 1'b1;
                    end
                end

                ST_DONE: begin
                    done_o  <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase

            if (zeroize_i) begin
                state_q           <= ST_IDLE;
                opcode_q          <= '0;
                transaction_id_q  <= '0;
                payload_len_q     <= '0;
                flags_q           <= BTP_FLAG_RESPONSE;
                header_index_q    <= '0;
                payload_index_q   <= '0;
                payload_rd_addr_q <= '0;
                payload_rd_data_q <= 8'h00;
                crc_index_q       <= '0;
                frame_index_q     <= '0;
                crc_q             <= 32'hFFFF_FFFF;
                final_crc_q       <= '0;
                frame_len_o       <= '0;
                done_o            <= 1'b0;
            end
        end
    end
endmodule
