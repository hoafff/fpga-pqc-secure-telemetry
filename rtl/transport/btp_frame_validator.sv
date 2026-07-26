module btp_frame_validator #(
    parameter integer MAX_PAYLOAD_BYTES = 1024,
    parameter integer MAX_FRAME_BYTES = 1038
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,

    input  logic        start_i,
    input  logic [10:0] frame_len_i,
    output logic [10:0] mem_raddr_o,
    input  logic [7:0]  mem_rdata_i,

    output logic        busy_o,
    output logic        done_o,
    output logic        valid_o,
    output logic [15:0] error_code_o,
    output logic [7:0]  opcode_o,
    output logic [7:0]  flags_o,
    output logic [15:0] transaction_id_o,
    output logic [15:0] payload_len_o
);
    localparam logic [15:0] ERR_BTP_SOF      = 16'h0101;
    localparam logic [15:0] ERR_BTP_VERSION  = 16'h0102;
    localparam logic [15:0] ERR_BTP_LENGTH   = 16'h0103;
    localparam logic [15:0] ERR_BTP_CRC      = 16'h0104;
    localparam logic [15:0] ERR_RESERVED     = 16'h0202;

    typedef enum logic [1:0] {V_IDLE, V_SCAN, V_FINISH} state_t;
    state_t state_q;

    logic [10:0] index_q;
    logic [31:0] crc_q;
    logic [31:0] observed_crc_q;
    logic [15:0] payload_len_q;
    logic [7:0] opcode_q;
    logic [7:0] flags_q;
    logic [15:0] transaction_id_q;
    logic [15:0] error_q;
    logic valid_q;

    function automatic logic [31:0] crc32_update_byte(
        input logic [31:0] crc_in,
        input logic [7:0]  byte_in
    );
        logic [31:0] c;
        integer bit_index;
        begin
            c = crc_in ^ {24'h0, byte_in};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (c[0]) c = (c >> 1) ^ 32'hEDB8_8320;
                else      c = c >> 1;
            end
            crc32_update_byte = c;
        end
    endfunction

    assign busy_o = (state_q == V_SCAN);
    assign mem_raddr_o = index_q;
    assign opcode_o = opcode_q;
    assign flags_o = flags_q;
    assign transaction_id_o = transaction_id_q;
    assign payload_len_o = payload_len_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            state_q          <= V_IDLE;
            index_q          <= '0;
            crc_q            <= 32'hFFFF_FFFF;
            observed_crc_q   <= '0;
            payload_len_q    <= '0;
            opcode_q         <= '0;
            flags_q          <= '0;
            transaction_id_q <= '0;
            error_q          <= 16'h0000;
            valid_q          <= 1'b0;
            done_o           <= 1'b0;
            valid_o          <= 1'b0;
            error_code_o     <= 16'h0000;
        end else begin
            done_o <= 1'b0;

            case (state_q)
                V_IDLE: begin
                    valid_o      <= 1'b0;
                    error_code_o <= 16'h0000;
                    if (start_i) begin
                        index_q          <= 11'd0;
                        crc_q            <= 32'hFFFF_FFFF;
                        observed_crc_q   <= 32'h0000_0000;
                        payload_len_q    <= 16'd0;
                        opcode_q         <= 8'd0;
                        flags_q          <= 8'd0;
                        transaction_id_q <= 16'd0;
                        error_q          <= 16'h0000;
                        valid_q          <= 1'b1;

                        if ((frame_len_i < 11'd14) ||
                            (frame_len_i > MAX_FRAME_BYTES)) begin
                            error_q <= ERR_BTP_LENGTH;
                            valid_q <= 1'b0;
                            state_q <= V_FINISH;
                        end else begin
                            state_q <= V_SCAN;
                        end
                    end
                end

                V_SCAN: begin
                    /* Header checks and field extraction. */
                    if (index_q == 11'd0 && mem_rdata_i != 8'hA5 && error_q == 0) begin
                        error_q <= ERR_BTP_SOF;
                        valid_q <= 1'b0;
                    end
                    if (index_q == 11'd1 && mem_rdata_i != 8'h5A && error_q == 0) begin
                        error_q <= ERR_BTP_SOF;
                        valid_q <= 1'b0;
                    end
                    if (index_q == 11'd2 && mem_rdata_i != 8'h01 && error_q == 0) begin
                        error_q <= ERR_BTP_VERSION;
                        valid_q <= 1'b0;
                    end
                    if (index_q == 11'd3)
                        opcode_q <= mem_rdata_i;
                    if (index_q == 11'd4) begin
                        flags_q <= mem_rdata_i;
                        if ((mem_rdata_i[7:4] != 4'h0) && error_q == 0) begin
                            error_q <= ERR_RESERVED;
                            valid_q <= 1'b0;
                        end
                    end
                    if (index_q == 11'd5 && mem_rdata_i != 8'h00 && error_q == 0) begin
                        error_q <= ERR_RESERVED;
                        valid_q <= 1'b0;
                    end
                    if (index_q == 11'd6)
                        transaction_id_q[15:8] <= mem_rdata_i;
                    if (index_q == 11'd7)
                        transaction_id_q[7:0] <= mem_rdata_i;
                    if (index_q == 11'd8)
                        payload_len_q[15:8] <= mem_rdata_i;
                    if (index_q == 11'd9) begin
                        payload_len_q[7:0] <= mem_rdata_i;
                        if (({payload_len_q[15:8], mem_rdata_i} > MAX_PAYLOAD_BYTES) ||
                            (frame_len_i != 11'd14 +
                             {payload_len_q[15:8], mem_rdata_i})) begin
                            if (error_q == 0) error_q <= ERR_BTP_LENGTH;
                            valid_q <= 1'b0;
                        end
                    end

                    /* CRC covers VERSION through final payload byte. */
                    if ((index_q >= 11'd2) &&
                        (index_q < 11'd10 + payload_len_q)) begin
                        crc_q <= crc32_update_byte(crc_q, mem_rdata_i);
                    end

                    /* Capture wire CRC MSB-first. */
                    if (index_q >= 11'd10 + payload_len_q) begin
                        observed_crc_q <= {observed_crc_q[23:0], mem_rdata_i};
                    end

                    if (index_q == frame_len_i - 11'd1) begin
                        if ({observed_crc_q[23:0], mem_rdata_i} !=
                            (crc_q ^ 32'hFFFF_FFFF)) begin
                            if (error_q == 0) error_q <= ERR_BTP_CRC;
                            valid_q <= 1'b0;
                        end
                        state_q <= V_FINISH;
                    end else begin
                        index_q <= index_q + 11'd1;
                    end
                end

                V_FINISH: begin
                    done_o       <= 1'b1;
                    valid_o      <= valid_q;
                    error_code_o <= error_q;
                    state_q      <= V_IDLE;
                end

                default: state_q <= V_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (MAX_FRAME_BYTES >= MAX_PAYLOAD_BYTES + 14)
            else $error("btp_frame_validator: frame size parameter too small");
    end
`endif
endmodule
