module fpst_btp_spi_slave #(
    parameter integer MAX_PAYLOAD_BYTES = 1024
) (
    input  logic         sys_clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         spi_sclk_i,
    input  logic         spi_mosi_i,
    output logic         spi_miso_o,
    input  logic         spi_cs_ni,

    output logic         irq_no,
    output logic         busy_o,
    output logic         fault_o,

    output logic         cmd_valid_o,
    input  logic         cmd_ready_i,
    output logic [7:0]   cmd_opcode_o,
    output logic [7:0]   cmd_flags_o,
    output logic [15:0]  cmd_transaction_id_o,
    output logic [15:0]  cmd_payload_len_o,
    input  logic [9:0]   cmd_payload_addr_i,
    output logic [7:0]   cmd_payload_data_o,

    input  logic         rsp_payload_we_i,
    input  logic [9:0]   rsp_payload_addr_i,
    input  logic [7:0]   rsp_payload_data_i,
    input  logic         rsp_valid_i,
    output logic         rsp_ready_o,
    input  logic [7:0]   rsp_opcode_i,
    input  logic [7:0]   rsp_flags_i,
    input  logic [15:0]  rsp_transaction_id_i,
    input  logic [15:0]  rsp_payload_len_i,

    output logic         link_error_valid_o,
    output logic [15:0]  link_error_code_o
);
    localparam integer HEADER_BYTES = 10;
    localparam integer TRAILER_BYTES = 4;
    localparam integer MAX_FRAME_BYTES = HEADER_BYTES + MAX_PAYLOAD_BYTES + TRAILER_BYTES;
    localparam integer FRAME_COUNT_W = $clog2(MAX_FRAME_BYTES + 1);

    localparam logic [15:0] ERR_BTP_SOF         = 16'h0101;
    localparam logic [15:0] ERR_BTP_VERSION     = 16'h0102;
    localparam logic [15:0] ERR_BTP_LENGTH      = 16'h0103;
    localparam logic [15:0] ERR_BTP_CRC         = 16'h0104;
    localparam logic [15:0] ERR_BTP_TRANSACTION = 16'h0105;

    localparam logic [7:0] BTP_VERSION  = 8'h01;
    localparam logic [7:0] FLAG_RESPONSE = 8'h01;
    localparam logic [7:0] FLAG_ERROR    = 8'h02;

    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] rsp_payload_mem [0:MAX_PAYLOAD_BYTES-1];

    /*
     * FPST v1.1 bring-up profile is SPI Mode 0, MSB first, 1 MHz. SYS_CLK is
     * 27 MHz, therefore SCLK/CS/MOSI are synchronized and edge-detected in the
     * system domain. This keeps request/response/key-bearing memories in one
     * clock domain and gives zeroize deterministic ownership over them.
     */
    logic sclk_meta_q, sclk_sync_q, sclk_prev_q;
    logic cs_meta_q, cs_sync_q, cs_prev_q;
    logic mosi_meta_q, mosi_sync_q;
    logic sclk_rise, sclk_fall, cs_fall, cs_rise;

    logic transaction_response_q;
    logic [7:0] rx_shift_q;
    logic [2:0] rx_bit_q;
    logic [2:0] tx_bit_q;
    logic [FRAME_COUNT_W-1:0] rx_count_q;
    logic [FRAME_COUNT_W-1:0] tx_count_q;
    logic [FRAME_COUNT_W-1:0] request_len_q;
    logic request_pending_q;
    logic miso_q;

    logic rsp_pending_q;
    logic [FRAME_COUNT_W-1:0] rsp_frame_len_q;

    typedef enum logic [2:0] {
        C_IDLE,
        C_CHECK,
        C_REQ_CRC,
        C_PUBLISH,
        C_RSP_HEADER_CRC,
        C_RSP_PAYLOAD_CRC,
        C_RSP_FINALIZE
    } control_state_t;

    control_state_t control_state_q;
    logic [FRAME_COUNT_W-1:0] crc_index_q;
    logic [31:0] crc_q;
    logic [31:0] crc_next;
    logic [31:0] crc_final;
    logic [15:0] parsed_payload_len_q;
    logic [15:0] parsed_transaction_id_q;
    logic [7:0] parsed_opcode_q;
    logic [7:0] parsed_flags_q;
    logic [31:0] parsed_request_crc_q;

    logic [15:0] build_payload_len_q;
    logic [15:0] build_payload_index_q;
    logic [7:0] build_opcode_q;
    logic [15:0] build_transaction_id_q;
    logic build_cacheable_q;

    logic cache_valid_q;
    logic [15:0] cache_transaction_id_q;
    logic [7:0] cache_opcode_q;
    logic [31:0] cache_request_crc_q;

    logic auto_error_pending_q;
    logic [15:0] auto_error_code_q;

    integer i;

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data
    );
        logic [31:0] c;
        integer k;
        begin
            c = crc_in ^ data;
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    function automatic logic [31:0] rx_load_be32(input integer base);
        begin
            rx_load_be32 = {rx_mem[base], rx_mem[base+1],
                            rx_mem[base+2], rx_mem[base+3]};
        end
    endfunction

    assign sclk_rise = sclk_sync_q && !sclk_prev_q;
    assign sclk_fall = !sclk_sync_q && sclk_prev_q;
    assign cs_fall = !cs_sync_q && cs_prev_q;
    assign cs_rise = cs_sync_q && !cs_prev_q;
    assign spi_miso_o = miso_q;

    assign cmd_payload_data_o =
        (cmd_payload_addr_i < cmd_payload_len_o) ?
        rx_mem[HEADER_BYTES + cmd_payload_addr_i] : 8'h00;

    assign irq_no = ~rsp_pending_q;
    assign busy_o = request_pending_q || cmd_valid_o ||
                    (control_state_q != C_IDLE);
    assign fault_o = 1'b0;
    assign rsp_ready_o = (control_state_q == C_IDLE) && !request_pending_q &&
                         !cmd_valid_o && !rsp_pending_q && !auto_error_pending_q;

    always_comb begin
        if (control_state_q == C_REQ_CRC)
            crc_next = crc32_byte(crc_q, rx_mem[crc_index_q]);
        else if (control_state_q == C_RSP_HEADER_CRC)
            crc_next = crc32_byte(crc_q, tx_mem[crc_index_q]);
        else
            crc_next = crc32_byte(crc_q, rsp_payload_mem[build_payload_index_q]);
        crc_final = ~crc_q;
    end

    always_ff @(posedge sys_clk_i) begin
        if (!rst_ni) begin
            sclk_meta_q <= 1'b0;
            sclk_sync_q <= 1'b0;
            sclk_prev_q <= 1'b0;
            cs_meta_q <= 1'b1;
            cs_sync_q <= 1'b1;
            cs_prev_q <= 1'b1;
            mosi_meta_q <= 1'b0;
            mosi_sync_q <= 1'b0;

            transaction_response_q <= 1'b0;
            rx_shift_q <= 8'h00;
            rx_bit_q <= 3'd0;
            tx_bit_q <= 3'd0;
            rx_count_q <= '0;
            tx_count_q <= '0;
            request_len_q <= '0;
            request_pending_q <= 1'b0;
            miso_q <= 1'b0;

            rsp_pending_q <= 1'b0;
            rsp_frame_len_q <= '0;
            control_state_q <= C_IDLE;
            crc_index_q <= '0;
            crc_q <= 32'hFFFFFFFF;
            parsed_payload_len_q <= '0;
            parsed_transaction_id_q <= '0;
            parsed_opcode_q <= '0;
            parsed_flags_q <= '0;
            parsed_request_crc_q <= '0;

            build_payload_len_q <= '0;
            build_payload_index_q <= '0;
            build_opcode_q <= '0;
            build_transaction_id_q <= '0;
            build_cacheable_q <= 1'b0;

            cache_valid_q <= 1'b0;
            cache_transaction_id_q <= '0;
            cache_opcode_q <= '0;
            cache_request_crc_q <= '0;

            auto_error_pending_q <= 1'b0;
            auto_error_code_q <= '0;

            cmd_valid_o <= 1'b0;
            cmd_opcode_o <= '0;
            cmd_flags_o <= '0;
            cmd_transaction_id_o <= '0;
            cmd_payload_len_o <= '0;
            link_error_valid_o <= 1'b0;
            link_error_code_o <= 16'h0000;

            for (i = 0; i < MAX_FRAME_BYTES; i = i + 1) begin
                rx_mem[i] <= 8'h00;
                tx_mem[i] <= 8'h00;
            end
            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                rsp_payload_mem[i] <= 8'h00;
        end else begin
            sclk_meta_q <= spi_sclk_i;
            sclk_sync_q <= sclk_meta_q;
            sclk_prev_q <= sclk_sync_q;
            cs_meta_q <= spi_cs_ni;
            cs_sync_q <= cs_meta_q;
            cs_prev_q <= cs_sync_q;
            mosi_meta_q <= spi_mosi_i;
            mosi_sync_q <= mosi_meta_q;

            link_error_valid_o <= 1'b0;
            link_error_code_o <= 16'h0000;

            if (zeroize_i) begin
                request_pending_q <= 1'b0;
                cmd_valid_o <= 1'b0;
                rsp_pending_q <= 1'b0;
                cache_valid_q <= 1'b0;
                auto_error_pending_q <= 1'b0;
                control_state_q <= C_IDLE;
                rx_shift_q <= 8'h00;
                rx_bit_q <= 3'd0;
                tx_bit_q <= 3'd0;
                rx_count_q <= '0;
                tx_count_q <= '0;
                miso_q <= 1'b0;
                for (i = 0; i < MAX_FRAME_BYTES; i = i + 1) begin
                    rx_mem[i] <= 8'h00;
                    tx_mem[i] <= 8'h00;
                end
                for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                    rsp_payload_mem[i] <= 8'h00;
            end else begin
                if (rsp_payload_we_i && rsp_payload_addr_i < MAX_PAYLOAD_BYTES)
                    rsp_payload_mem[rsp_payload_addr_i] <= rsp_payload_data_i;

                /* Start of one CS-bounded BTP transaction. If a response is
                 * pending this transaction is response-only; otherwise it is
                 * request-only. */
                if (cs_fall) begin
                    transaction_response_q <= rsp_pending_q;
                    rx_shift_q <= 8'h00;
                    rx_bit_q <= 3'd0;
                    tx_bit_q <= 3'd0;
                    rx_count_q <= '0;
                    tx_count_q <= '0;
                    miso_q <= rsp_pending_q ? tx_mem[0][7] : 1'b0;
                end

                /* Mode-0 request capture: MOSI sampled on rising SCLK. */
                if (!cs_sync_q && !transaction_response_q && sclk_rise) begin
                    rx_shift_q <= {rx_shift_q[6:0], mosi_sync_q};
                    if (rx_bit_q == 3'd7) begin
                        rx_bit_q <= 3'd0;
                        if (rx_count_q < MAX_FRAME_BYTES) begin
                            rx_mem[rx_count_q] <= {rx_shift_q[6:0], mosi_sync_q};
                            rx_count_q <= rx_count_q + 1'b1;
                        end
                    end else begin
                        rx_bit_q <= rx_bit_q + 1'b1;
                    end
                end

                /* Mode-0 response drive: next MISO bit changes after falling
                 * SCLK and is stable before the following rising SCLK. */
                if (!cs_sync_q && transaction_response_q && sclk_fall) begin
                    if (tx_bit_q == 3'd7) begin
                        tx_bit_q <= 3'd0;
                        tx_count_q <= tx_count_q + 1'b1;
                        if (tx_count_q + 1'b1 < rsp_frame_len_q)
                            miso_q <= tx_mem[tx_count_q + 1'b1][7];
                        else
                            miso_q <= 1'b0;
                    end else begin
                        tx_bit_q <= tx_bit_q + 1'b1;
                        miso_q <= tx_mem[tx_count_q][6-tx_bit_q];
                    end
                end

                /* End of transaction. Exactly one request or one response frame
                 * exists under one CS assertion. */
                if (cs_rise) begin
                    miso_q <= 1'b0;
                    if (transaction_response_q) begin
                        if (tx_count_q >= rsp_frame_len_q)
                            rsp_pending_q <= 1'b0;
                    end else if (!request_pending_q && !cmd_valid_o &&
                                 rx_count_q >= HEADER_BYTES + TRAILER_BYTES) begin
                        request_len_q <= rx_count_q;
                        request_pending_q <= 1'b1;
                    end
                end

                if (cmd_valid_o && cmd_ready_i)
                    cmd_valid_o <= 1'b0;

                case (control_state_q)
                    C_IDLE: begin
                        if (auto_error_pending_q && !rsp_pending_q) begin
                            rsp_payload_mem[0] <= auto_error_code_q[15:8];
                            rsp_payload_mem[1] <= auto_error_code_q[7:0];
                            build_opcode_q <= parsed_opcode_q;
                            build_transaction_id_q <= parsed_transaction_id_q;
                            build_payload_len_q <= 16'd2;
                            build_cacheable_q <= 1'b0;
                            tx_mem[0] <= 8'hA5;
                            tx_mem[1] <= 8'h5A;
                            tx_mem[2] <= BTP_VERSION;
                            tx_mem[3] <= parsed_opcode_q;
                            tx_mem[4] <= FLAG_RESPONSE | FLAG_ERROR;
                            tx_mem[5] <= 8'h00;
                            tx_mem[6] <= parsed_transaction_id_q[15:8];
                            tx_mem[7] <= parsed_transaction_id_q[7:0];
                            tx_mem[8] <= 8'h00;
                            tx_mem[9] <= 8'h02;
                            crc_q <= 32'hFFFFFFFF;
                            crc_index_q <= 2;
                            auto_error_pending_q <= 1'b0;
                            link_error_valid_o <= 1'b1;
                            link_error_code_o <= auto_error_code_q;
                            control_state_q <= C_RSP_HEADER_CRC;
                        end else if (request_pending_q && !cmd_valid_o && !rsp_pending_q) begin
                            parsed_opcode_q <= rx_mem[3];
                            parsed_flags_q <= rx_mem[4];
                            parsed_transaction_id_q <= {rx_mem[6], rx_mem[7]};
                            parsed_payload_len_q <= {rx_mem[8], rx_mem[9]};
                            control_state_q <= C_CHECK;
                        end else if (rsp_valid_i && rsp_ready_o) begin
                            if (rsp_payload_len_i > MAX_PAYLOAD_BYTES) begin
                                link_error_valid_o <= 1'b1;
                                link_error_code_o <= ERR_BTP_LENGTH;
                            end else begin
                                build_opcode_q <= rsp_opcode_i;
                                build_transaction_id_q <= rsp_transaction_id_i;
                                build_payload_len_q <= rsp_payload_len_i;
                                build_cacheable_q <= 1'b1;
                                tx_mem[0] <= 8'hA5;
                                tx_mem[1] <= 8'h5A;
                                tx_mem[2] <= BTP_VERSION;
                                tx_mem[3] <= rsp_opcode_i;
                                tx_mem[4] <= rsp_flags_i | FLAG_RESPONSE;
                                tx_mem[5] <= 8'h00;
                                tx_mem[6] <= rsp_transaction_id_i[15:8];
                                tx_mem[7] <= rsp_transaction_id_i[7:0];
                                tx_mem[8] <= rsp_payload_len_i[15:8];
                                tx_mem[9] <= rsp_payload_len_i[7:0];
                                crc_q <= 32'hFFFFFFFF;
                                crc_index_q <= 2;
                                control_state_q <= C_RSP_HEADER_CRC;
                            end
                        end
                    end

                    C_CHECK: begin
                        if (request_len_q < HEADER_BYTES + TRAILER_BYTES ||
                            rx_mem[0] != 8'hA5 || rx_mem[1] != 8'h5A) begin
                            auto_error_code_q <= ERR_BTP_SOF;
                            auto_error_pending_q <= 1'b1;
                            request_pending_q <= 1'b0;
                            control_state_q <= C_IDLE;
                        end else if (rx_mem[2] != BTP_VERSION) begin
                            auto_error_code_q <= ERR_BTP_VERSION;
                            auto_error_pending_q <= 1'b1;
                            request_pending_q <= 1'b0;
                            control_state_q <= C_IDLE;
                        end else if (rx_mem[5] != 8'h00 ||
                                     rx_mem[4][7:3] != 5'b00000 ||
                                     rx_mem[4][0] != 1'b0 ||
                                     {rx_mem[8], rx_mem[9]} > MAX_PAYLOAD_BYTES ||
                                     request_len_q != HEADER_BYTES +
                                         {rx_mem[8], rx_mem[9]} + TRAILER_BYTES) begin
                            auto_error_code_q <= ERR_BTP_LENGTH;
                            auto_error_pending_q <= 1'b1;
                            request_pending_q <= 1'b0;
                            control_state_q <= C_IDLE;
                        end else begin
                            parsed_request_crc_q <=
                                rx_load_be32(HEADER_BYTES + {rx_mem[8], rx_mem[9]});
                            crc_q <= 32'hFFFFFFFF;
                            crc_index_q <= 2;
                            control_state_q <= C_REQ_CRC;
                        end
                    end

                    C_REQ_CRC: begin
                        crc_q <= crc_next;
                        if (crc_index_q == HEADER_BYTES + parsed_payload_len_q - 1) begin
                            if ((~crc_next) != parsed_request_crc_q) begin
                                auto_error_code_q <= ERR_BTP_CRC;
                                auto_error_pending_q <= 1'b1;
                                request_pending_q <= 1'b0;
                                control_state_q <= C_IDLE;
                            end else if (cache_valid_q &&
                                         parsed_transaction_id_q == cache_transaction_id_q) begin
                                if (parsed_opcode_q == cache_opcode_q &&
                                    parsed_request_crc_q == cache_request_crc_q) begin
                                    /* Lost response: replay byte-identical cached response. */
                                    rsp_pending_q <= 1'b1;
                                end else begin
                                    /* Same transaction ID carrying a different request. */
                                    auto_error_code_q <= ERR_BTP_TRANSACTION;
                                    auto_error_pending_q <= 1'b1;
                                end
                                request_pending_q <= 1'b0;
                                control_state_q <= C_IDLE;
                            end else begin
                                cmd_opcode_o <= parsed_opcode_q;
                                cmd_flags_o <= parsed_flags_q;
                                cmd_transaction_id_o <= parsed_transaction_id_q;
                                cmd_payload_len_o <= parsed_payload_len_q;
                                cmd_valid_o <= 1'b1;
                                request_pending_q <= 1'b0;
                                control_state_q <= C_PUBLISH;
                            end
                        end else begin
                            crc_index_q <= crc_index_q + 1'b1;
                        end
                    end

                    C_PUBLISH: begin
                        if (!cmd_valid_o)
                            control_state_q <= C_IDLE;
                    end

                    C_RSP_HEADER_CRC: begin
                        crc_q <= crc_next;
                        if (crc_index_q == 9) begin
                            build_payload_index_q <= 0;
                            if (build_payload_len_q == 0)
                                control_state_q <= C_RSP_FINALIZE;
                            else
                                control_state_q <= C_RSP_PAYLOAD_CRC;
                        end else begin
                            crc_index_q <= crc_index_q + 1'b1;
                        end
                    end

                    C_RSP_PAYLOAD_CRC: begin
                        tx_mem[HEADER_BYTES + build_payload_index_q] <=
                            rsp_payload_mem[build_payload_index_q];
                        crc_q <= crc_next;
                        if (build_payload_index_q + 1'b1 == build_payload_len_q)
                            control_state_q <= C_RSP_FINALIZE;
                        else
                            build_payload_index_q <= build_payload_index_q + 1'b1;
                    end

                    C_RSP_FINALIZE: begin
                        tx_mem[HEADER_BYTES + build_payload_len_q + 0] <= crc_final[31:24];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 1] <= crc_final[23:16];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 2] <= crc_final[15:8];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 3] <= crc_final[7:0];
                        rsp_frame_len_q <= HEADER_BYTES + build_payload_len_q + TRAILER_BYTES;
                        rsp_pending_q <= 1'b1;
                        if (build_cacheable_q) begin
                            cache_valid_q <= 1'b1;
                            cache_transaction_id_q <= build_transaction_id_q;
                            cache_opcode_q <= build_opcode_q;
                            cache_request_crc_q <= parsed_request_crc_q;
                        end
                        control_state_q <= C_IDLE;
                    end

                    default: control_state_q <= C_IDLE;
                endcase
            end
        end
    end
endmodule
