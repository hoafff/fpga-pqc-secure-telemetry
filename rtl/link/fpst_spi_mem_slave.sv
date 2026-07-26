module fpst_spi_mem_slave #(
    parameter integer MAX_FRAME_BYTES = 269
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         spi_sclk_i,
    input  logic         spi_cs_ni,
    input  logic         spi_mosi_i,
    output wire          spi_miso_o,

    input  logic         endpoint_busy_i,
    input  logic         endpoint_fatal_i,
    input  logic         response_valid_i,
    input  logic [15:0]  response_len_i,
    input  logic [15:0]  response_id_i,
    input  logic [15:0]  error_code_i,

    output logic         request_doorbell_o,
    output logic         response_ack_o,
    output logic         link_reset_o,
    output logic [15:0]  request_len_o,
    output logic [15:0]  request_id_o,

    input  logic [8:0]   request_rd_addr_i,
    output logic [7:0]   request_rd_data_o,

    input  logic         response_we_i,
    input  logic [8:0]   response_waddr_i,
    input  logic [7:0]   response_wdata_i
);
    localparam logic [7:0] CMD_MEM_WRITE = 8'hA1;
    localparam logic [7:0] CMD_MEM_READ  = 8'hA2;

    localparam logic [7:0] BURST_OK       = 8'h00;
    localparam logic [7:0] BURST_CRC      = 8'hE1;
    localparam logic [7:0] BURST_RANGE    = 8'hE2;
    localparam logic [7:0] BURST_BUSY     = 8'hE3;

    localparam logic [15:0] REG_CONTROL      = 16'h0000;
    localparam logic [15:0] REG_STATUS       = 16'h0004;
    localparam logic [15:0] REG_REQUEST_LEN  = 16'h0008;
    localparam logic [15:0] REG_RESPONSE_LEN = 16'h000A;
    localparam logic [15:0] REG_REQUEST_ID   = 16'h000C;
    localparam logic [15:0] REG_RESPONSE_ID  = 16'h000E;
    localparam logic [15:0] REG_ERROR_CODE   = 16'h0010;
    localparam logic [15:0] REQUEST_BASE     = 16'h0100;
    localparam logic [15:0] RESPONSE_BASE    = 16'h0300;

    localparam logic [31:0] CTRL_REQUEST_DOORBELL = 32'h0000_0001;
    localparam logic [31:0] CTRL_RESPONSE_ACK     = 32'h0000_0002;
    localparam logic [31:0] CTRL_LINK_RESET       = 32'h0000_0004;

    typedef enum logic [3:0] {
        SPI_IDLE,
        SPI_HEADER,
        SPI_WRITE_DATA,
        SPI_WRITE_CRC_HI,
        SPI_WRITE_CRC_LO,
        SPI_WRITE_REJECT_DRAIN,
        SPI_WRITE_STATUS,
        SPI_READ_STATUS,
        SPI_READ_DATA,
        SPI_READ_CRC_HI,
        SPI_READ_CRC_LO,
        SPI_READ_REJECT_STATUS
    } spi_state_t;

    typedef enum logic [2:0] {
        WR_NONE,
        WR_CONTROL,
        WR_REQUEST_LEN,
        WR_REQUEST_ID,
        WR_REQUEST_MAILBOX
    } write_target_t;

    logic [7:0] request_mailbox_bank0_q [0:MAX_FRAME_BYTES-1];
    logic [7:0] request_mailbox_bank1_q [0:MAX_FRAME_BYTES-1];
    logic [7:0] response_mailbox_q      [0:MAX_FRAME_BYTES-1];
    logic       request_active_bank_q;

    (* ASYNC_REG = "TRUE" *) logic [2:0] sclk_sync_q;
    (* ASYNC_REG = "TRUE" *) logic [2:0] cs_sync_q;
    (* ASYNC_REG = "TRUE" *) logic [2:0] mosi_sync_q;

    logic [2:0] bit_count_q;
    logic [7:0] rx_shift_q;
    logic [7:0] tx_shift_q;
    logic [7:0] tx_next_byte_q;

    spi_state_t    state_q;
    write_target_t write_target_q;

    logic [2:0]  header_index_q;
    logic [7:0]  command_q;
    logic [15:0] address_q;
    logic [15:0] length_q;
    logic [7:0]  header_crc_hi_q;
    logic [15:0] header_crc_q;

    logic [15:0] write_crc_q;
    logic [7:0]  observed_payload_crc_hi_q;
    logic [15:0] write_index_q;
    logic [7:0]  small_write_q [0:3];

    logic [15:0] read_crc_q;
    logic [15:0] read_index_q;

    logic [16:0] reject_remaining_q;
    logic [7:0]  reject_status_q;

    wire sclk_rise  = (sclk_sync_q[2:1] == 2'b01);
    wire sclk_fall  = (sclk_sync_q[2:1] == 2'b10);
    wire cs_assert  = (cs_sync_q[2:1] == 2'b10);
    wire cs_release = (cs_sync_q[2:1] == 2'b01);
    wire cs_active  = !cs_sync_q[2];
    wire [7:0] rx_byte_now = {rx_shift_q[6:0], mosi_sync_q[2]};

    function automatic logic [15:0] crc16_byte(
        input logic [15:0] crc_in,
        input logic [7:0] data
    );
        logic [15:0] crc;
        integer i;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_byte = crc;
        end
    endfunction

    function automatic logic write_range_valid(
        input logic [15:0] address,
        input logic [15:0] length
    );
        begin
            write_range_valid =
                (address == REG_CONTROL     && length == 16'd4) ||
                (address == REG_REQUEST_LEN && length == 16'd2) ||
                (address == REG_REQUEST_ID  && length == 16'd2) ||
                (address == REQUEST_BASE && length > 16'd0 &&
                 length <= MAX_FRAME_BYTES);
        end
    endfunction

    function automatic logic read_range_valid(
        input logic [15:0] address,
        input logic [15:0] length
    );
        logic [16:0] end_address;
        begin
            end_address = {1'b0, address} + {1'b0, length};
            read_range_valid = 1'b0;
            if ((address == REG_STATUS       && length == 16'd4) ||
                (address == REG_REQUEST_LEN  && length == 16'd2) ||
                (address == REG_RESPONSE_LEN && length == 16'd2) ||
                (address == REG_REQUEST_ID   && length == 16'd2) ||
                (address == REG_RESPONSE_ID  && length == 16'd2) ||
                (address == REG_ERROR_CODE   && length == 16'd2)) begin
                read_range_valid = 1'b1;
            end else if ((address >= RESPONSE_BASE) &&
                         (end_address <= RESPONSE_BASE + MAX_FRAME_BYTES)) begin
                read_range_valid = 1'b1;
            end
        end
    endfunction

    function automatic logic [7:0] mapped_read_byte(
        input logic [15:0] address
    );
        logic [31:0] status_word;
        integer index;
        begin
            status_word = 32'h0000_0000;
            status_word[0]  = !endpoint_busy_i && !response_valid_i && !endpoint_fatal_i;
            status_word[1]  = endpoint_busy_i;
            status_word[2]  = response_valid_i;
            status_word[31] = endpoint_fatal_i;

            mapped_read_byte = 8'h00;
            case (address)
                REG_STATUS + 16'd0: mapped_read_byte = status_word[31:24];
                REG_STATUS + 16'd1: mapped_read_byte = status_word[23:16];
                REG_STATUS + 16'd2: mapped_read_byte = status_word[15:8];
                REG_STATUS + 16'd3: mapped_read_byte = status_word[7:0];

                REG_REQUEST_LEN + 16'd0:  mapped_read_byte = request_len_o[15:8];
                REG_REQUEST_LEN + 16'd1:  mapped_read_byte = request_len_o[7:0];
                REG_RESPONSE_LEN + 16'd0: mapped_read_byte = response_len_i[15:8];
                REG_RESPONSE_LEN + 16'd1: mapped_read_byte = response_len_i[7:0];
                REG_REQUEST_ID + 16'd0:   mapped_read_byte = request_id_o[15:8];
                REG_REQUEST_ID + 16'd1:   mapped_read_byte = request_id_o[7:0];
                REG_RESPONSE_ID + 16'd0:  mapped_read_byte = response_id_i[15:8];
                REG_RESPONSE_ID + 16'd1:  mapped_read_byte = response_id_i[7:0];
                REG_ERROR_CODE + 16'd0:   mapped_read_byte = error_code_i[15:8];
                REG_ERROR_CODE + 16'd1:   mapped_read_byte = error_code_i[7:0];
                default: begin
                    if ((address >= RESPONSE_BASE) &&
                        (address < RESPONSE_BASE + MAX_FRAME_BYTES)) begin
                        index = address - RESPONSE_BASE;
                        mapped_read_byte = response_mailbox_q[index];
                    end
                end
            endcase
        end
    endfunction

    assign spi_miso_o = spi_cs_ni ? 1'bz : tx_shift_q[7];

    always_comb begin
        if (request_rd_addr_i < MAX_FRAME_BYTES) begin
            if (request_active_bank_q)
                request_rd_data_o = request_mailbox_bank1_q[request_rd_addr_i];
            else
                request_rd_data_o = request_mailbox_bank0_q[request_rd_addr_i];
        end else begin
            request_rd_data_o = 8'h00;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            sclk_sync_q <= 3'b000;
            cs_sync_q   <= 3'b111;
            mosi_sync_q <= 3'b000;
        end else begin
            sclk_sync_q <= {sclk_sync_q[1:0], spi_sclk_i};
            cs_sync_q   <= {cs_sync_q[1:0], spi_cs_ni};
            mosi_sync_q <= {mosi_sync_q[1:0], spi_mosi_i};
        end
    end

    always_ff @(posedge clk_i) begin
        integer i;
        logic [31:0] control_value;
        logic [15:0] payload_crc_next;
        logic [7:0]  read_data_byte;
        logic [7:0]  reject_status;

        if (!rst_ni) begin
            state_q                   <= SPI_IDLE;
            write_target_q            <= WR_NONE;
            bit_count_q               <= 3'd0;
            rx_shift_q                <= 8'h00;
            tx_shift_q                <= 8'h00;
            tx_next_byte_q            <= 8'h00;
            header_index_q            <= 3'd0;
            command_q                 <= 8'h00;
            address_q                 <= 16'h0000;
            length_q                  <= 16'h0000;
            header_crc_hi_q           <= 8'h00;
            header_crc_q              <= 16'hFFFF;
            write_crc_q               <= 16'hFFFF;
            observed_payload_crc_hi_q <= 8'h00;
            write_index_q             <= 16'd0;
            read_crc_q                <= 16'hFFFF;
            read_index_q              <= 16'd0;
            reject_remaining_q        <= 17'd0;
            reject_status_q           <= BURST_OK;
            request_active_bank_q     <= 1'b0;
            request_len_o             <= 16'd0;
            request_id_o              <= 16'd0;
            request_doorbell_o        <= 1'b0;
            response_ack_o            <= 1'b0;
            link_reset_o              <= 1'b0;
            for (i = 0; i < 4; i = i + 1)
                small_write_q[i] <= 8'h00;
        end else begin
            request_doorbell_o <= 1'b0;
            response_ack_o     <= 1'b0;
            link_reset_o       <= 1'b0;

            if (response_we_i && response_waddr_i < MAX_FRAME_BYTES)
                response_mailbox_q[response_waddr_i] <= response_wdata_i;

            if (cs_release) begin
                state_q        <= SPI_IDLE;
                bit_count_q    <= 3'd0;
                rx_shift_q     <= 8'h00;
                tx_shift_q     <= 8'h00;
                tx_next_byte_q <= 8'h00;
                header_index_q <= 3'd0;
                write_target_q <= WR_NONE;
            end else if (cs_assert) begin
                state_q                   <= SPI_HEADER;
                write_target_q            <= WR_NONE;
                bit_count_q               <= 3'd0;
                rx_shift_q                <= 8'h00;
                tx_shift_q                <= 8'h00;
                tx_next_byte_q            <= 8'h00;
                header_index_q            <= 3'd0;
                command_q                 <= 8'h00;
                address_q                 <= 16'h0000;
                length_q                  <= 16'h0000;
                header_crc_hi_q           <= 8'h00;
                header_crc_q              <= 16'hFFFF;
                write_crc_q               <= 16'hFFFF;
                observed_payload_crc_hi_q <= 8'h00;
                write_index_q             <= 16'd0;
                read_crc_q                <= 16'hFFFF;
                read_index_q              <= 16'd0;
                reject_remaining_q        <= 17'd0;
                reject_status_q           <= BURST_OK;
            end else if (cs_active) begin
                if (sclk_fall) begin
                    if (bit_count_q == 3'd0)
                        tx_shift_q <= tx_next_byte_q;
                    else
                        tx_shift_q <= {tx_shift_q[6:0], 1'b0};
                end

                if (sclk_rise) begin
                    if (bit_count_q == 3'd7) begin
                        bit_count_q <= 3'd0;
                        rx_shift_q  <= 8'h00;

                        case (state_q)
                            SPI_HEADER: begin
                                case (header_index_q)
                                    3'd0: begin
                                        command_q      <= rx_byte_now;
                                        header_crc_q   <= crc16_byte(16'hFFFF, rx_byte_now);
                                        header_index_q <= 3'd1;
                                    end
                                    3'd1: begin
                                        address_q[15:8] <= rx_byte_now;
                                        header_crc_q    <= crc16_byte(header_crc_q, rx_byte_now);
                                        header_index_q  <= 3'd2;
                                    end
                                    3'd2: begin
                                        address_q[7:0] <= rx_byte_now;
                                        header_crc_q   <= crc16_byte(header_crc_q, rx_byte_now);
                                        header_index_q <= 3'd3;
                                    end
                                    3'd3: begin
                                        length_q[15:8] <= rx_byte_now;
                                        header_crc_q   <= crc16_byte(header_crc_q, rx_byte_now);
                                        header_index_q <= 3'd4;
                                    end
                                    3'd4: begin
                                        length_q[7:0] <= rx_byte_now;
                                        header_crc_q  <= crc16_byte(header_crc_q, rx_byte_now);
                                        header_index_q <= 3'd5;
                                    end
                                    3'd5: begin
                                        header_crc_hi_q <= rx_byte_now;
                                        header_index_q  <= 3'd6;
                                    end
                                    3'd6: begin
                                        header_index_q <= 3'd0;

                                        if (command_q == CMD_MEM_WRITE) begin
                                            reject_status = BURST_OK;
                                            if ({header_crc_hi_q, rx_byte_now} != header_crc_q)
                                                reject_status = BURST_CRC;
                                            else if (!write_range_valid(address_q, length_q))
                                                reject_status = BURST_RANGE;
                                            else if ((address_q != REG_CONTROL) &&
                                                     (endpoint_busy_i || response_valid_i || endpoint_fatal_i))
                                                reject_status = BURST_BUSY;

                                            if (reject_status != BURST_OK) begin
                                                reject_status_q    <= reject_status;
                                                reject_remaining_q <= {1'b0, length_q} + 17'd2;
                                                state_q            <= SPI_WRITE_REJECT_DRAIN;
                                            end else begin
                                                write_index_q <= 16'd0;
                                                write_crc_q   <= 16'hFFFF;
                                                if (address_q == REG_CONTROL)
                                                    write_target_q <= WR_CONTROL;
                                                else if (address_q == REG_REQUEST_LEN)
                                                    write_target_q <= WR_REQUEST_LEN;
                                                else if (address_q == REG_REQUEST_ID)
                                                    write_target_q <= WR_REQUEST_ID;
                                                else
                                                    write_target_q <= WR_REQUEST_MAILBOX;

                                                if (length_q == 16'd0)
                                                    state_q <= SPI_WRITE_CRC_HI;
                                                else
                                                    state_q <= SPI_WRITE_DATA;
                                            end
                                        end else if (command_q == CMD_MEM_READ) begin
                                            if ({header_crc_hi_q, rx_byte_now} != header_crc_q) begin
                                                tx_next_byte_q <= BURST_CRC;
                                                state_q <= SPI_READ_REJECT_STATUS;
                                            end else if (!read_range_valid(address_q, length_q)) begin
                                                tx_next_byte_q <= BURST_RANGE;
                                                state_q <= SPI_READ_REJECT_STATUS;
                                            end else begin
                                                tx_next_byte_q <= BURST_OK;
                                                read_index_q   <= 16'd0;
                                                read_crc_q     <= 16'hFFFF;
                                                state_q        <= SPI_READ_STATUS;
                                            end
                                        end else begin
                                            tx_next_byte_q <= BURST_RANGE;
                                            state_q <= SPI_READ_REJECT_STATUS;
                                        end
                                    end
                                    default: state_q <= SPI_IDLE;
                                endcase
                            end

                            SPI_WRITE_DATA: begin
                                if (write_target_q == WR_REQUEST_MAILBOX) begin
                                    if (request_active_bank_q)
                                        request_mailbox_bank0_q[write_index_q] <= rx_byte_now;
                                    else
                                        request_mailbox_bank1_q[write_index_q] <= rx_byte_now;
                                end else if (write_index_q < 16'd4) begin
                                    small_write_q[write_index_q[1:0]] <= rx_byte_now;
                                end

                                write_crc_q <= crc16_byte(write_crc_q, rx_byte_now);
                                if (write_index_q + 16'd1 == length_q) begin
                                    write_index_q <= write_index_q + 16'd1;
                                    state_q       <= SPI_WRITE_CRC_HI;
                                end else begin
                                    write_index_q <= write_index_q + 16'd1;
                                end
                            end

                            SPI_WRITE_CRC_HI: begin
                                observed_payload_crc_hi_q <= rx_byte_now;
                                state_q <= SPI_WRITE_CRC_LO;
                            end

                            SPI_WRITE_CRC_LO: begin
                                if ({observed_payload_crc_hi_q, rx_byte_now} != write_crc_q) begin
                                    tx_next_byte_q <= BURST_CRC;
                                end else begin
                                    control_value = {small_write_q[0], small_write_q[1],
                                                     small_write_q[2], small_write_q[3]};
                                    case (write_target_q)
                                        WR_CONTROL: begin
                                            if ((control_value & CTRL_REQUEST_DOORBELL) != 0) begin
                                                if (endpoint_busy_i || response_valid_i || endpoint_fatal_i)
                                                    tx_next_byte_q <= BURST_BUSY;
                                                else begin
                                                    request_doorbell_o <= 1'b1;
                                                    tx_next_byte_q <= BURST_OK;
                                                end
                                            end else begin
                                                if ((control_value & CTRL_RESPONSE_ACK) != 0)
                                                    response_ack_o <= 1'b1;
                                                if ((control_value & CTRL_LINK_RESET) != 0) begin
                                                    link_reset_o  <= 1'b1;
                                                    request_len_o <= 16'd0;
                                                    request_id_o  <= 16'd0;
                                                end
                                                tx_next_byte_q <= BURST_OK;
                                            end
                                        end
                                        WR_REQUEST_LEN: begin
                                            request_len_o <= {small_write_q[0], small_write_q[1]};
                                            tx_next_byte_q <= BURST_OK;
                                        end
                                        WR_REQUEST_ID: begin
                                            request_id_o <= {small_write_q[0], small_write_q[1]};
                                            tx_next_byte_q <= BURST_OK;
                                        end
                                        WR_REQUEST_MAILBOX: begin
                                            request_active_bank_q <= ~request_active_bank_q;
                                            tx_next_byte_q <= BURST_OK;
                                        end
                                        default: tx_next_byte_q <= BURST_RANGE;
                                    endcase
                                end
                                state_q <= SPI_WRITE_STATUS;
                            end

                            SPI_WRITE_REJECT_DRAIN: begin
                                if (reject_remaining_q <= 17'd1) begin
                                    reject_remaining_q <= 17'd0;
                                    tx_next_byte_q <= reject_status_q;
                                    state_q <= SPI_WRITE_STATUS;
                                end else begin
                                    reject_remaining_q <= reject_remaining_q - 17'd1;
                                end
                            end

                            SPI_WRITE_STATUS: begin
                                // The byte being sampled here is the master's final dummy.
                                // Hold the status value until CS rises.
                                tx_next_byte_q <= tx_next_byte_q;
                            end

                            SPI_READ_STATUS: begin
                                if (length_q == 16'd0) begin
                                    tx_next_byte_q <= 8'hFF;
                                    read_crc_q     <= 16'hFFFF;
                                    state_q        <= SPI_READ_CRC_HI;
                                end else begin
                                    read_data_byte = mapped_read_byte(address_q);
                                    tx_next_byte_q <= read_data_byte;
                                    read_index_q   <= 16'd0;
                                    read_crc_q     <= 16'hFFFF;
                                    state_q        <= SPI_READ_DATA;
                                end
                            end

                            SPI_READ_DATA: begin
                                read_data_byte = mapped_read_byte(address_q + read_index_q);
                                payload_crc_next = crc16_byte(read_crc_q, read_data_byte);
                                read_crc_q <= payload_crc_next;

                                if (read_index_q + 16'd1 == length_q) begin
                                    tx_next_byte_q <= payload_crc_next[15:8];
                                    state_q <= SPI_READ_CRC_HI;
                                end else begin
                                    read_index_q <= read_index_q + 16'd1;
                                    tx_next_byte_q <= mapped_read_byte(address_q + read_index_q + 16'd1);
                                end
                            end

                            SPI_READ_CRC_HI: begin
                                tx_next_byte_q <= read_crc_q[7:0];
                                state_q <= SPI_READ_CRC_LO;
                            end

                            SPI_READ_CRC_LO: begin
                                tx_next_byte_q <= 8'h00;
                            end

                            SPI_READ_REJECT_STATUS: begin
                                tx_next_byte_q <= tx_next_byte_q;
                            end

                            default: state_q <= SPI_IDLE;
                        endcase
                    end else begin
                        bit_count_q <= bit_count_q + 3'd1;
                        rx_shift_q  <= {rx_shift_q[6:0], mosi_sync_q[2]};
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(request_doorbell_o && endpoint_busy_i))
                else $error("fpst_spi_mem_slave: doorbell emitted while endpoint busy");
            assert (request_len_o <= MAX_FRAME_BYTES)
                else $error("fpst_spi_mem_slave: request length exceeds mailbox");
        end
    end
`endif
endmodule
