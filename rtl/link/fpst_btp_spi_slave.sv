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

    localparam logic [7:0] BTP_VERSION = 8'h01;
    localparam logic [7:0] FLAG_RESPONSE = 8'h01;
    localparam logic [7:0] FLAG_ERROR = 8'h02;

    logic [7:0] rx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] tx_mem [0:MAX_FRAME_BYTES-1];
    logic [7:0] rsp_payload_mem [0:MAX_PAYLOAD_BYTES-1];

    logic [7:0] rx_shift_q;
    logic [2:0] spi_bit_q;
    logic [FRAME_COUNT_W-1:0] spi_rx_count_q;
    logic [FRAME_COUNT_W-1:0] spi_tx_count_q;
    logic req_toggle_spi_q;
    logic rsp_consumed_toggle_spi_q;
    logic req_ack_meta_q, req_ack_sync_q;
    logic req_outstanding_spi;

    logic rsp_pending_q;
    logic [FRAME_COUNT_W-1:0] rsp_frame_len_q;

    /* The response buffer and rsp_pending_q are held stable before irq_no is
     * asserted. MCU observes IRQ before starting transaction #2, so this is a
     * bundled-data crossing from the 27 MHz domain into the SPI clock domain. */
    assign spi_miso_o = (!spi_cs_ni && rsp_pending_q &&
                         spi_tx_count_q < rsp_frame_len_q) ?
                        tx_mem[spi_tx_count_q][7-spi_bit_q] : 1'b0;

    assign req_outstanding_spi = (req_toggle_spi_q != req_ack_sync_q);

    /* SPI Mode 0: sample MOSI at rising SCLK. CS deassertion terminates one
     * complete BTP transaction and resets the bit counter. */
    always @(posedge spi_sclk_i or posedge spi_cs_ni or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_shift_q <= 8'h00;
            spi_bit_q <= 3'd0;
            spi_rx_count_q <= '0;
            spi_tx_count_q <= '0;
            req_toggle_spi_q <= 1'b0;
            rsp_consumed_toggle_spi_q <= 1'b0;
            req_ack_meta_q <= 1'b0;
            req_ack_sync_q <= 1'b0;
        end else if (spi_cs_ni) begin
            if (rsp_pending_q) begin
                if (spi_tx_count_q >= rsp_frame_len_q)
                    rsp_consumed_toggle_spi_q <= ~rsp_consumed_toggle_spi_q;
            end else if (!req_outstanding_spi &&
                         spi_rx_count_q >= HEADER_BYTES + TRAILER_BYTES) begin
                req_toggle_spi_q <= ~req_toggle_spi_q;
            end
            rx_shift_q <= 8'h00;
            spi_bit_q <= 3'd0;
            spi_rx_count_q <= '0;
            spi_tx_count_q <= '0;
        end else begin
            req_ack_meta_q <= req_ack_toggle_q;
            req_ack_sync_q <= req_ack_meta_q;

            if (rsp_pending_q) begin
                if (spi_bit_q == 3'd7) begin
                    spi_bit_q <= 3'd0;
                    if (spi_tx_count_q < MAX_FRAME_BYTES)
                        spi_tx_count_q <= spi_tx_count_q + 1'b1;
                end else begin
                    spi_bit_q <= spi_bit_q + 1'b1;
                end
            end else begin
                rx_shift_q <= {rx_shift_q[6:0], spi_mosi_i};
                if (spi_bit_q == 3'd7) begin
                    spi_bit_q <= 3'd0;
                    if (spi_rx_count_q < MAX_FRAME_BYTES) begin
                        rx_mem[spi_rx_count_q] <= {rx_shift_q[6:0], spi_mosi_i};
                        spi_rx_count_q <= spi_rx_count_q + 1'b1;
                    end
                end else begin
                    spi_bit_q <= spi_bit_q + 1'b1;
                end
            end
        end
    end

    logic req_meta_q, req_sync_q, req_seen_q;
    logic rsp_cons_meta_q, rsp_cons_sync_q, rsp_cons_seen_q;
    logic req_ack_toggle_q;
    logic [FRAME_COUNT_W-1:0] request_len_q;

    typedef enum logic [3:0] {
        P_IDLE,
        P_CHECK,
        P_CRC,
        P_PUBLISH,
        P_ERROR,
        R_IDLE,
        R_HEADER_CRC,
        R_PAYLOAD_CRC,
        R_FINALIZE
    } control_state_t;

    control_state_t control_state_q;
    logic [FRAME_COUNT_W-1:0] crc_index_q;
    logic [31:0] crc_q;
    logic [15:0] parsed_payload_len_q;
    logic [15:0] parsed_transaction_id_q;
    logic [7:0] parsed_opcode_q;
    logic [7:0] parsed_flags_q;
    logic [15:0] pending_error_q;

    logic [15:0] build_payload_len_q;
    logic [15:0] build_payload_index_q;
    logic [7:0] build_opcode_q;
    logic [7:0] build_flags_q;
    logic [15:0] build_transaction_id_q;

    logic cache_valid_q;
    logic [15:0] cache_transaction_id_q;
    logic [7:0] cache_opcode_q;

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

    function automatic logic [31:0] load_be32_mem(input integer base);
        begin
            load_be32_mem = {rx_mem[base], rx_mem[base+1],
                             rx_mem[base+2], rx_mem[base+3]};
        end
    endfunction

    assign cmd_payload_data_o =
        (cmd_payload_addr_i < cmd_payload_len_o) ?
        rx_mem[HEADER_BYTES + cmd_payload_addr_i] : 8'h00;

    assign irq_no = ~rsp_pending_q;
    assign busy_o = (control_state_q != P_IDLE) &&
                    (control_state_q != P_PUBLISH) &&
                    (control_state_q != R_IDLE);
    assign fault_o = 1'b0;
    assign rsp_ready_o = (control_state_q == P_IDLE ||
                          control_state_q == P_PUBLISH) && !rsp_pending_q;

    always_ff @(posedge sys_clk_i) begin
        if (!rst_ni) begin
            req_meta_q <= 1'b0;
            req_sync_q <= 1'b0;
            req_seen_q <= 1'b0;
            rsp_cons_meta_q <= 1'b0;
            rsp_cons_sync_q <= 1'b0;
            rsp_cons_seen_q <= 1'b0;
            req_ack_toggle_q <= 1'b0;
            request_len_q <= '0;
            control_state_q <= P_IDLE;
            crc_index_q <= '0;
            crc_q <= 32'hFFFFFFFF;
            parsed_payload_len_q <= '0;
            parsed_transaction_id_q <= '0;
            parsed_opcode_q <= '0;
            parsed_flags_q <= '0;
            pending_error_q <= '0;
            cmd_valid_o <= 1'b0;
            cmd_opcode_o <= '0;
            cmd_flags_o <= '0;
            cmd_transaction_id_o <= '0;
            cmd_payload_len_o <= '0;
            rsp_pending_q <= 1'b0;
            rsp_frame_len_q <= '0;
            build_payload_len_q <= '0;
            build_payload_index_q <= '0;
            build_opcode_q <= '0;
            build_flags_q <= '0;
            build_transaction_id_q <= '0;
            cache_valid_q <= 1'b0;
            cache_transaction_id_q <= '0;
            cache_opcode_q <= '0;
            link_error_valid_o <= 1'b0;
            link_error_code_o <= 16'h0000;
            for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                rsp_payload_mem[i] <= 8'h00;
            for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                tx_mem[i] <= 8'h00;
        end else begin
            req_meta_q <= req_toggle_spi_q;
            req_sync_q <= req_meta_q;
            rsp_cons_meta_q <= rsp_consumed_toggle_spi_q;
            rsp_cons_sync_q <= rsp_cons_meta_q;
            link_error_valid_o <= 1'b0;
            link_error_code_o <= 16'h0000;

            if (zeroize_i) begin
                cmd_valid_o <= 1'b0;
                rsp_pending_q <= 1'b0;
                cache_valid_q <= 1'b0;
                control_state_q <= P_IDLE;
                for (i = 0; i < MAX_PAYLOAD_BYTES; i = i + 1)
                    rsp_payload_mem[i] <= 8'h00;
                for (i = 0; i < MAX_FRAME_BYTES; i = i + 1)
                    tx_mem[i] <= 8'h00;
            end else begin
                if (rsp_cons_sync_q != rsp_cons_seen_q) begin
                    rsp_cons_seen_q <= rsp_cons_sync_q;
                    rsp_pending_q <= 1'b0;
                end

                if (rsp_payload_we_i && rsp_payload_addr_i < MAX_PAYLOAD_BYTES)
                    rsp_payload_mem[rsp_payload_addr_i] <= rsp_payload_data_i;

                if (cmd_valid_o && cmd_ready_i) begin
                    cmd_valid_o <= 1'b0;
                    req_ack_toggle_q <= req_sync_q;
                    if (control_state_q == P_PUBLISH)
                        control_state_q <= P_IDLE;
                end

                case (control_state_q)
                    P_IDLE: begin
                        if (req_sync_q != req_seen_q && !rsp_pending_q) begin
                            req_seen_q <= req_sync_q;
                            /* rx count is stable after CS rose and before ack. */
                            request_len_q <= spi_rx_count_q;
                            control_state_q <= P_CHECK;
                        end else if (rsp_valid_i && rsp_ready_o) begin
                            if (rsp_payload_len_i > MAX_PAYLOAD_BYTES) begin
                                link_error_valid_o <= 1'b1;
                                link_error_code_o <= ERR_BTP_LENGTH;
                            end else begin
                                build_opcode_q <= rsp_opcode_i;
                                build_flags_q <= rsp_flags_i | FLAG_RESPONSE;
                                build_transaction_id_q <= rsp_transaction_id_i;
                                build_payload_len_q <= rsp_payload_len_i;
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
                                control_state_q <= R_HEADER_CRC;
                            end
                        end
                    end

                    P_CHECK: begin
                        parsed_opcode_q <= rx_mem[3];
                        parsed_flags_q <= rx_mem[4];
                        parsed_transaction_id_q <= {rx_mem[6], rx_mem[7]};
                        parsed_payload_len_q <= {rx_mem[8], rx_mem[9]};

                        if (request_len_q < HEADER_BYTES + TRAILER_BYTES ||
                            rx_mem[0] != 8'hA5 || rx_mem[1] != 8'h5A) begin
                            pending_error_q <= ERR_BTP_SOF;
                            control_state_q <= P_ERROR;
                        end else if (rx_mem[2] != BTP_VERSION) begin
                            pending_error_q <= ERR_BTP_VERSION;
                            control_state_q <= P_ERROR;
                        end else if (rx_mem[5] != 8'h00 ||
                                     {rx_mem[8], rx_mem[9]} > MAX_PAYLOAD_BYTES ||
                                     request_len_q != HEADER_BYTES +
                                         {rx_mem[8], rx_mem[9]} + TRAILER_BYTES) begin
                            pending_error_q <= ERR_BTP_LENGTH;
                            control_state_q <= P_ERROR;
                        end else begin
                            crc_q <= 32'hFFFFFFFF;
                            crc_index_q <= 2;
                            control_state_q <= P_CRC;
                        end
                    end

                    P_CRC: begin
                        logic [31:0] crc_next;
                        crc_next = crc32_byte(crc_q, rx_mem[crc_index_q]);
                        crc_q <= crc_next;
                        if (crc_index_q == HEADER_BYTES + parsed_payload_len_q - 1) begin
                            if ((~crc_next) !=
                                load_be32_mem(HEADER_BYTES + parsed_payload_len_q)) begin
                                pending_error_q <= ERR_BTP_CRC;
                                control_state_q <= P_ERROR;
                            end else if (cache_valid_q &&
                                         parsed_transaction_id_q == cache_transaction_id_q &&
                                         parsed_opcode_q == cache_opcode_q) begin
                                /* Duplicate request after response loss: replay the byte-identical
                                 * cached response without repeating the operation. */
                                rsp_pending_q <= 1'b1;
                                req_ack_toggle_q <= req_sync_q;
                                control_state_q <= P_IDLE;
                            end else begin
                                cmd_opcode_o <= parsed_opcode_q;
                                cmd_flags_o <= parsed_flags_q;
                                cmd_transaction_id_o <= parsed_transaction_id_q;
                                cmd_payload_len_o <= parsed_payload_len_q;
                                cmd_valid_o <= 1'b1;
                                control_state_q <= P_PUBLISH;
                            end
                        end else begin
                            crc_index_q <= crc_index_q + 1'b1;
                        end
                    end

                    P_PUBLISH: begin
                        /* Dispatcher owns cmd_ready_i after it has copied/consumed
                         * all payload bytes and scheduled a response. */
                    end

                    P_ERROR: begin
                        link_error_valid_o <= 1'b1;
                        link_error_code_o <= pending_error_q;
                        rsp_payload_mem[0] <= pending_error_q[15:8];
                        rsp_payload_mem[1] <= pending_error_q[7:0];
                        build_opcode_q <= parsed_opcode_q;
                        build_flags_q <= FLAG_RESPONSE | FLAG_ERROR;
                        build_transaction_id_q <= parsed_transaction_id_q;
                        build_payload_len_q <= 16'd2;
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
                        req_ack_toggle_q <= req_sync_q;
                        control_state_q <= R_HEADER_CRC;
                    end

                    R_HEADER_CRC: begin
                        logic [31:0] crc_next;
                        crc_next = crc32_byte(crc_q, tx_mem[crc_index_q]);
                        crc_q <= crc_next;
                        if (crc_index_q == 9) begin
                            build_payload_index_q <= 0;
                            if (build_payload_len_q == 0)
                                control_state_q <= R_FINALIZE;
                            else
                                control_state_q <= R_PAYLOAD_CRC;
                        end else begin
                            crc_index_q <= crc_index_q + 1'b1;
                        end
                    end

                    R_PAYLOAD_CRC: begin
                        logic [31:0] crc_next;
                        tx_mem[HEADER_BYTES + build_payload_index_q] <=
                            rsp_payload_mem[build_payload_index_q];
                        crc_next = crc32_byte(crc_q,
                                             rsp_payload_mem[build_payload_index_q]);
                        crc_q <= crc_next;
                        if (build_payload_index_q + 1'b1 == build_payload_len_q) begin
                            control_state_q <= R_FINALIZE;
                        end else begin
                            build_payload_index_q <= build_payload_index_q + 1'b1;
                        end
                    end

                    R_FINALIZE: begin
                        logic [31:0] final_crc;
                        final_crc = ~crc_q;
                        tx_mem[HEADER_BYTES + build_payload_len_q + 0] <= final_crc[31:24];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 1] <= final_crc[23:16];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 2] <= final_crc[15:8];
                        tx_mem[HEADER_BYTES + build_payload_len_q + 3] <= final_crc[7:0];
                        rsp_frame_len_q <= HEADER_BYTES + build_payload_len_q + TRAILER_BYTES;
                        rsp_pending_q <= 1'b1;
                        cache_valid_q <= 1'b1;
                        cache_transaction_id_q <= build_transaction_id_q;
                        cache_opcode_q <= build_opcode_q;
                        control_state_q <= P_IDLE;
                    end

                    default: control_state_q <= P_IDLE;
                endcase
            end
        end
    end
endmodule
