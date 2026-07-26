// FPST-SYS-SPEC-001 v1.1 BTP response serializer.
//
// Every response contains the common 12-byte response payload prefix:
//   status[15:0] || detail[15:0] || device_state[31:0] || value[31:0]
// followed by opcode-specific bytes supplied through extra_*.
module btp_response_builder #(
    parameter integer MAX_PAYLOAD_BYTES = 1024
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        abort_i,

    input  logic        start_i,
    output logic        ready_o,
    input  logic [7:0]  opcode_i,
    input  logic [15:0] transaction_id_i,
    input  logic        error_i,
    input  logic [15:0] status_i,
    input  logic [15:0] detail_i,
    input  logic [31:0] device_state_i,
    input  logic [31:0] value_i,
    input  logic [10:0] extra_length_i,

    output logic        extra_request_o,
    output logic [10:0] extra_index_o,
    input  logic        extra_valid_i,
    input  logic [7:0]  extra_data_i,

    output logic        ram_we_o,
    output logic [10:0] ram_waddr_o,
    output logic [7:0]  ram_wdata_o,

    output logic        done_o,
    output logic [10:0] frame_length_o
);
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_DATA,
        ST_CRC
    } state_t;

    state_t state_q;

    logic [7:0]  opcode_q;
    logic [15:0] transaction_id_q;
    logic        error_q;
    logic [15:0] status_q;
    logic [15:0] detail_q;
    logic [31:0] device_state_q;
    logic [31:0] value_q;
    logic [15:0] payload_length_q;
    logic [10:0] extra_length_q;

    logic [10:0] frame_index_q;
    logic [31:0] crc_q;
    logic [31:0] crc_final_q;
    logic [1:0]  crc_byte_q;

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc_in,
        input logic [7:0] data_in
    );
        logic [31:0] c;
        logic [7:0] d;
        integer k;
        begin
            c = crc_in;
            d = data_in;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0] ^ d[0])
                    c = (c >> 1) ^ 32'hedb8_8320;
                else
                    c = c >> 1;
                d = d >> 1;
            end
            crc32_byte = c;
        end
    endfunction

    function automatic logic [7:0] common_payload_byte(
        input logic [3:0] index,
        input logic [15:0] status,
        input logic [15:0] detail,
        input logic [31:0] device_state,
        input logic [31:0] value
    );
        begin
            case (index)
                4'd0:  common_payload_byte = status[15:8];
                4'd1:  common_payload_byte = status[7:0];
                4'd2:  common_payload_byte = detail[15:8];
                4'd3:  common_payload_byte = detail[7:0];
                4'd4:  common_payload_byte = device_state[31:24];
                4'd5:  common_payload_byte = device_state[23:16];
                4'd6:  common_payload_byte = device_state[15:8];
                4'd7:  common_payload_byte = device_state[7:0];
                4'd8:  common_payload_byte = value[31:24];
                4'd9:  common_payload_byte = value[23:16];
                4'd10: common_payload_byte = value[15:8];
                4'd11: common_payload_byte = value[7:0];
                default: common_payload_byte = 8'h00;
            endcase
        end
    endfunction

    logic [7:0] current_byte;
    logic       current_valid;
    logic [31:0] crc_after_current;

    always_comb begin
        current_byte  = 8'h00;
        current_valid = 1'b1;

        if (frame_index_q == 11'd0)
            current_byte = 8'ha5;
        else if (frame_index_q == 11'd1)
            current_byte = 8'h5a;
        else if (frame_index_q == 11'd2)
            current_byte = 8'h01;
        else if (frame_index_q == 11'd3)
            current_byte = opcode_q;
        else if (frame_index_q == 11'd4)
            current_byte = 8'h01 | (error_q ? 8'h02 : 8'h00);
        else if (frame_index_q == 11'd5)
            current_byte = 8'h00;
        else if (frame_index_q == 11'd6)
            current_byte = transaction_id_q[15:8];
        else if (frame_index_q == 11'd7)
            current_byte = transaction_id_q[7:0];
        else if (frame_index_q == 11'd8)
            current_byte = payload_length_q[15:8];
        else if (frame_index_q == 11'd9)
            current_byte = payload_length_q[7:0];
        else if (frame_index_q < 11'd22)
            current_byte = common_payload_byte(frame_index_q - 11'd10,
                                               status_q, detail_q,
                                               device_state_q, value_q);
        else begin
            current_byte  = extra_data_i;
            current_valid = extra_valid_i;
        end
    end

    assign extra_request_o = (state_q == ST_DATA) &&
                             (frame_index_q >= 11'd22);
    assign extra_index_o = frame_index_q - 11'd22;

    assign ready_o = (state_q == ST_IDLE);

    always_comb begin
        if (frame_index_q >= 11'd2)
            crc_after_current = crc32_byte(crc_q, current_byte);
        else
            crc_after_current = crc_q;
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni || abort_i) begin
            state_q           <= ST_IDLE;
            opcode_q          <= 8'h00;
            transaction_id_q  <= 16'h0000;
            error_q           <= 1'b0;
            status_q          <= 16'h0000;
            detail_q          <= 16'h0000;
            device_state_q    <= 32'h0000_0000;
            value_q           <= 32'h0000_0000;
            payload_length_q  <= 16'd12;
            extra_length_q    <= 11'd0;
            frame_index_q     <= 11'd0;
            crc_q             <= 32'hffff_ffff;
            crc_final_q       <= 32'h0000_0000;
            crc_byte_q        <= 2'd0;
            ram_we_o          <= 1'b0;
            ram_waddr_o       <= 11'd0;
            ram_wdata_o       <= 8'h00;
            done_o            <= 1'b0;
            frame_length_o    <= 11'd0;
        end else begin
            ram_we_o <= 1'b0;
            done_o   <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_i) begin
                        opcode_q         <= opcode_i;
                        transaction_id_q <= transaction_id_i;
                        error_q          <= error_i;
                        status_q         <= status_i;
                        detail_q         <= detail_i;
                        device_state_q   <= device_state_i;
                        value_q          <= value_i;
                        extra_length_q   <= extra_length_i;
                        payload_length_q <= 16'd12 + extra_length_i;
                        frame_index_q    <= 11'd0;
                        crc_q            <= 32'hffff_ffff;
                        state_q          <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    if (current_valid) begin
                        ram_we_o    <= 1'b1;
                        ram_waddr_o <= frame_index_q;
                        ram_wdata_o <= current_byte;

                        if (frame_index_q >= 11'd2)
                            crc_q <= crc_after_current;

                        if (frame_index_q == (11'd9 + payload_length_q)) begin
                            crc_final_q <= crc_after_current ^ 32'hffff_ffff;
                            crc_byte_q  <= 2'd0;
                            state_q     <= ST_CRC;
                        end else begin
                            frame_index_q <= frame_index_q + 1'b1;
                        end
                    end
                end

                ST_CRC: begin
                    ram_we_o    <= 1'b1;
                    ram_waddr_o <= 11'd10 + payload_length_q + crc_byte_q;
                    case (crc_byte_q)
                        2'd0: ram_wdata_o <= crc_final_q[31:24];
                        2'd1: ram_wdata_o <= crc_final_q[23:16];
                        2'd2: ram_wdata_o <= crc_final_q[15:8];
                        2'd3: ram_wdata_o <= crc_final_q[7:0];
                    endcase

                    if (crc_byte_q == 2'd3) begin
                        frame_length_o <= 11'd14 + payload_length_q;
                        done_o         <= 1'b1;
                        state_q        <= ST_IDLE;
                    end else begin
                        crc_byte_q <= crc_byte_q + 1'b1;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && start_i && ready_o) begin
            assert ((16'd12 + extra_length_i) <= MAX_PAYLOAD_BYTES)
                else $error("btp_response_builder: response payload exceeds BTP maximum");
        end
    end
`endif
endmodule
