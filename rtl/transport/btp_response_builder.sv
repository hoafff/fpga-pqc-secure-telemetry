module btp_response_builder #(
    parameter integer MAX_PAYLOAD_BYTES = 1024
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,

    input  logic        start_i,
    input  logic [7:0]  opcode_i,
    input  logic [7:0]  flags_i,
    input  logic [15:0] transaction_id_i,
    input  logic [15:0] status_code_i,
    input  logic [15:0] detail_code_i,
    input  logic [31:0] device_state_i,
    input  logic [31:0] result_meta_i,
    input  logic [9:0]  app_len_i,
    output logic [9:0]  app_raddr_o,
    input  logic [7:0]  app_rdata_i,

    output logic        rsp_we_o,
    output logic [10:0] rsp_waddr_o,
    output logic [7:0]  rsp_wdata_o,
    output logic [10:0] rsp_len_o,
    output logic        rsp_commit_o,
    output logic        busy_o,
    output logic        done_o,
    output logic        argument_error_o
);
    localparam integer GENERIC_BYTES = 12;
    localparam integer MAX_APP_BYTES = MAX_PAYLOAD_BYTES - GENERIC_BYTES;

    typedef enum logic [1:0] {
        B_IDLE,
        B_EMIT,
        B_COMMIT
    } state_t;

    state_t state_q;
    logic [10:0] index_q;
    logic [15:0] payload_len_q;
    logic [31:0] crc_q;

    logic [7:0]  opcode_q;
    logic [7:0]  flags_q;
    logic [15:0] transaction_id_q;
    logic [15:0] status_code_q;
    logic [15:0] detail_code_q;
    logic [31:0] device_state_q;
    logic [31:0] result_meta_q;
    logic [9:0]  app_len_q;

    logic [7:0] emit_byte;
    logic [31:0] crc_final;

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

    assign busy_o = (state_q != B_IDLE);
    assign crc_final = crc_q ^ 32'hFFFF_FFFF;
    assign app_raddr_o = (index_q >= 11'd22) ? index_q - 11'd22 : 10'd0;

    /* These are combinational write-bus outputs. The consumer samples them on
     * the same rising edge on which index_q is retired. B_COMMIT is a separate
     * cycle so the response cache cannot be marked valid before its final CRC
     * byte has physically been written. */
    assign rsp_we_o    = (state_q == B_EMIT);
    assign rsp_waddr_o = index_q;
    assign rsp_wdata_o = emit_byte;

    always_comb begin
        emit_byte = 8'h00;
        case (index_q)
            11'd0: emit_byte = 8'hA5;
            11'd1: emit_byte = 8'h5A;
            11'd2: emit_byte = 8'h01;
            11'd3: emit_byte = opcode_q;
            11'd4: emit_byte = flags_q | 8'h01; /* RESPONSE */
            11'd5: emit_byte = 8'h00;
            11'd6: emit_byte = transaction_id_q[15:8];
            11'd7: emit_byte = transaction_id_q[7:0];
            11'd8: emit_byte = payload_len_q[15:8];
            11'd9: emit_byte = payload_len_q[7:0];
            11'd10: emit_byte = status_code_q[15:8];
            11'd11: emit_byte = status_code_q[7:0];
            11'd12: emit_byte = detail_code_q[15:8];
            11'd13: emit_byte = detail_code_q[7:0];
            11'd14: emit_byte = device_state_q[31:24];
            11'd15: emit_byte = device_state_q[23:16];
            11'd16: emit_byte = device_state_q[15:8];
            11'd17: emit_byte = device_state_q[7:0];
            11'd18: emit_byte = result_meta_q[31:24];
            11'd19: emit_byte = result_meta_q[23:16];
            11'd20: emit_byte = result_meta_q[15:8];
            11'd21: emit_byte = result_meta_q[7:0];
            default: begin
                if (index_q < 11'd10 + payload_len_q) begin
                    emit_byte = app_rdata_i;
                end else begin
                    case (index_q - (11'd10 + payload_len_q))
                        0: emit_byte = crc_final[31:24];
                        1: emit_byte = crc_final[23:16];
                        2: emit_byte = crc_final[15:8];
                        3: emit_byte = crc_final[7:0];
                        default: emit_byte = 8'h00;
                    endcase
                end
            end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            state_q           <= B_IDLE;
            index_q           <= '0;
            payload_len_q     <= '0;
            crc_q             <= 32'hFFFF_FFFF;
            opcode_q          <= '0;
            flags_q           <= '0;
            transaction_id_q  <= '0;
            status_code_q     <= '0;
            detail_code_q     <= '0;
            device_state_q    <= '0;
            result_meta_q     <= '0;
            app_len_q         <= '0;
            rsp_len_o         <= '0;
            rsp_commit_o      <= 1'b0;
            done_o            <= 1'b0;
            argument_error_o  <= 1'b0;
        end else begin
            rsp_commit_o     <= 1'b0;
            done_o           <= 1'b0;
            argument_error_o <= 1'b0;

            case (state_q)
                B_IDLE: begin
                    if (start_i) begin
                        if (app_len_i > MAX_APP_BYTES) begin
                            argument_error_o <= 1'b1;
                        end else begin
                            opcode_q         <= opcode_i;
                            flags_q          <= flags_i;
                            transaction_id_q <= transaction_id_i;
                            status_code_q    <= status_code_i;
                            detail_code_q    <= detail_code_i;
                            device_state_q   <= device_state_i;
                            result_meta_q    <= result_meta_i;
                            app_len_q        <= app_len_i;
                            payload_len_q    <= GENERIC_BYTES + app_len_i;
                            rsp_len_o        <= 11'd14 + GENERIC_BYTES + app_len_i;
                            index_q          <= 11'd0;
                            crc_q            <= 32'hFFFF_FFFF;
                            state_q          <= B_EMIT;
                        end
                    end
                end

                B_EMIT: begin
                    if ((index_q >= 11'd2) &&
                        (index_q < 11'd10 + payload_len_q)) begin
                        crc_q <= crc32_update_byte(crc_q, emit_byte);
                    end

                    if (index_q == rsp_len_o - 11'd1) begin
                        state_q <= B_COMMIT;
                    end else begin
                        index_q <= index_q + 11'd1;
                    end
                end

                B_COMMIT: begin
                    rsp_commit_o <= 1'b1;
                    done_o       <= 1'b1;
                    state_q      <= B_IDLE;
                end

                default: state_q <= B_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (MAX_PAYLOAD_BYTES >= GENERIC_BYTES)
            else $error("btp_response_builder: payload parameter too small");
    end
`endif
endmodule
