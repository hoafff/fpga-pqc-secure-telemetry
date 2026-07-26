// FPST STP v1 transmitter for the mandatory 24-byte telemetry format 0x01.
//
// Packet retained here is exactly:
//   HEADER[24] || CIPHERTEXT[24] || TAG[16]
// The sequence counter is owned by the session block and is committed by the
// BTP endpoint only after the complete BTP response transaction is consumed.
module stp_tx_telemetry (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         start_i,
    output logic         ready_o,
    input  logic [31:0]  session_id_i,
    input  logic [63:0]  sequence_i,
    input  logic [127:0] traffic_key_i,
    input  logic [63:0]  nonce_prefix_i,
    input  logic [191:0] telemetry_i,
    input  logic [15:0]  flags_i,

    input  logic         discard_retained_i,
    output logic         packet_valid_o,
    output logic [6:0]   packet_length_o,
    input  logic [6:0]   packet_addr_i,
    output logic [7:0]   packet_data_o,

    output logic         done_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [15:0] ERR_BUSY = 16'h0301;
    localparam logic [15:0] ERR_ASCON_LENGTH = 16'h0501;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CORE_START,
        ST_FEED,
        ST_WAIT_CORE
    } state_t;

    state_t state_q;

    logic [31:0]  session_id_q;
    logic [63:0]  sequence_q;
    logic [127:0] traffic_key_q;
    logic [63:0]  nonce_prefix_q;
    logic [191:0] telemetry_q;
    logic [15:0]  flags_q;

    logic [7:0] packet_mem [0:63];
    logic [5:0] feed_index_q;
    logic [4:0] cipher_index_q;

    logic        core_ready;
    logic        core_in_ready;
    logic        core_out_valid;
    logic [7:0]  core_out_data;
    logic        core_out_last;
    logic        core_tag_valid;
    logic [127:0] core_tag;
    logic        core_done;
    logic        core_error_valid;
    logic [15:0] core_error_code;

    function automatic logic [7:0] header_byte(
        input logic [4:0] index,
        input logic [31:0] sid,
        input logic [63:0] seq,
        input logic [15:0] flg
    );
        begin
            case (index)
                5'd0:  header_byte = 8'h50;
                5'd1:  header_byte = 8'h51;
                5'd2:  header_byte = 8'h01;
                5'd3:  header_byte = 8'h03; // TELEMETRY_DATA
                5'd4:  header_byte = flg[15:8];
                5'd5:  header_byte = flg[7:0];
                5'd6:  header_byte = 8'h00;
                5'd7:  header_byte = 8'h18;
                5'd8:  header_byte = sid[31:24];
                5'd9:  header_byte = sid[23:16];
                5'd10: header_byte = sid[15:8];
                5'd11: header_byte = sid[7:0];
                5'd12: header_byte = seq[63:56];
                5'd13: header_byte = seq[55:48];
                5'd14: header_byte = seq[47:40];
                5'd15: header_byte = seq[39:32];
                5'd16: header_byte = seq[31:24];
                5'd17: header_byte = seq[23:16];
                5'd18: header_byte = seq[15:8];
                5'd19: header_byte = seq[7:0];
                5'd20: header_byte = 8'h00;
                5'd21: header_byte = 8'h18;
                5'd22: header_byte = 8'h01; // telemetry payload format 0x01
                5'd23: header_byte = 8'h00;
                default: header_byte = 8'h00;
            endcase
        end
    endfunction

    function automatic logic [63:0] numeric_be64_to_ascon_bus(
        input logic [63:0] value
    );
        begin
            numeric_be64_to_ascon_bus = {
                value[7:0], value[15:8], value[23:16], value[31:24],
                value[39:32], value[47:40], value[55:48], value[63:56]
            };
        end
    endfunction

    wire [127:0] nonce_bus = {
        numeric_be64_to_ascon_bus(sequence_q),
        nonce_prefix_q
    };

    wire core_start = (state_q == ST_CORE_START);
    wire core_in_valid = (state_q == ST_FEED);
    wire [7:0] core_in_data = (feed_index_q < 6'd24)
        ? header_byte(feed_index_q[4:0], session_id_q, sequence_q, flags_q)
        : telemetry_q[8*(feed_index_q-6'd24) +: 8];
    wire core_in_last = (feed_index_q == 6'd47);

    assign ready_o = (state_q == ST_IDLE) && !packet_valid_o;
    assign packet_length_o = 7'd64;
    assign packet_data_o = (packet_addr_i < 7'd64) ? packet_mem[packet_addr_i] : 8'h00;

    ascon_aead_encrypt u_encrypt (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .start_i        (core_start),
        .ready_o        (core_ready),
        .key_i          (traffic_key_q),
        .nonce_i        (nonce_bus),
        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),
        .in_valid_i     (core_in_valid),
        .in_ready_o     (core_in_ready),
        .in_data_i      (core_in_data),
        .in_last_i      (core_in_last),
        .out_valid_o    (core_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (core_out_data),
        .out_last_o     (core_out_last),
        .tag_valid_o    (core_tag_valid),
        .tag_ready_i    (1'b1),
        .tag_o          (core_tag),
        .done_o         (core_done),
        .error_valid_o  (core_error_valid),
        .error_code_o   (core_error_code)
    );

    integer i;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q          <= ST_IDLE;
            session_id_q     <= 32'h0;
            sequence_q       <= 64'h0;
            traffic_key_q    <= 128'h0;
            nonce_prefix_q   <= 64'h0;
            telemetry_q      <= 192'h0;
            flags_q          <= 16'h0;
            feed_index_q     <= 6'd0;
            cipher_index_q   <= 5'd0;
            packet_valid_o   <= 1'b0;
            done_o           <= 1'b0;
            error_valid_o    <= 1'b0;
            error_code_o     <= 16'h0000;
            for (i = 0; i < 64; i = i + 1)
                packet_mem[i] <= 8'h00;
        end else if (zeroize_i) begin
            state_q          <= ST_IDLE;
            session_id_q     <= 32'h0;
            sequence_q       <= 64'h0;
            traffic_key_q    <= 128'h0;
            nonce_prefix_q   <= 64'h0;
            telemetry_q      <= 192'h0;
            flags_q          <= 16'h0;
            feed_index_q     <= 6'd0;
            cipher_index_q   <= 5'd0;
            packet_valid_o   <= 1'b0;
            done_o           <= 1'b0;
            error_valid_o    <= 1'b0;
            error_code_o     <= 16'h0000;
            for (i = 0; i < 64; i = i + 1)
                packet_mem[i] <= 8'h00;
        end else begin
            done_o        <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            if (discard_retained_i && (state_q == ST_IDLE)) begin
                packet_valid_o <= 1'b0;
                for (i = 0; i < 64; i = i + 1)
                    packet_mem[i] <= 8'h00;
            end

            if (core_error_valid) begin
                error_valid_o <= 1'b1;
                error_code_o  <= core_error_code;
                packet_valid_o <= 1'b0;
                state_q <= ST_IDLE;
            end else begin
                if (core_out_valid) begin
                    if (cipher_index_q < 5'd24) begin
                        packet_mem[24 + cipher_index_q] <= core_out_data;
                        cipher_index_q <= cipher_index_q + 1'b1;
                    end else begin
                        error_valid_o <= 1'b1;
                        error_code_o  <= ERR_ASCON_LENGTH;
                    end
                end

                if (core_tag_valid) begin
                    for (i = 0; i < 16; i = i + 1)
                        packet_mem[48+i] <= core_tag[8*i +: 8];
                end

                case (state_q)
                    ST_IDLE: begin
                        if (start_i) begin
                            if (packet_valid_o) begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_BUSY;
                            end else begin
                                session_id_q   <= session_id_i;
                                sequence_q     <= sequence_i;
                                traffic_key_q  <= traffic_key_i;
                                nonce_prefix_q <= nonce_prefix_i;
                                telemetry_q    <= telemetry_i;
                                flags_q        <= flags_i & 16'h0007;
                                feed_index_q   <= 6'd0;
                                cipher_index_q <= 5'd0;
                                for (i = 0; i < 24; i = i + 1)
                                    packet_mem[i] <= header_byte(i[4:0], session_id_i,
                                                                 sequence_i,
                                                                 flags_i & 16'h0007);
                                state_q <= ST_CORE_START;
                            end
                        end
                    end

                    ST_CORE_START: begin
                        if (core_ready)
                            state_q <= ST_FEED;
                    end

                    ST_FEED: begin
                        if (core_in_valid && core_in_ready) begin
                            if (feed_index_q == 6'd47)
                                state_q <= ST_WAIT_CORE;
                            else
                                feed_index_q <= feed_index_q + 1'b1;
                        end
                    end

                    ST_WAIT_CORE: begin
                        if (core_done) begin
                            if (cipher_index_q == 5'd24) begin
                                packet_valid_o <= 1'b1;
                                done_o         <= 1'b1;
                            end else begin
                                error_valid_o <= 1'b1;
                                error_code_o  <= ERR_ASCON_LENGTH;
                            end
                            state_q <= ST_IDLE;
                        end
                    end

                    default: state_q <= ST_IDLE;
                endcase
            end
        end
    end
endmodule
