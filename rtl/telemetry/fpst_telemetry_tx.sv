module fpst_telemetry_tx (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    input  logic         start_i,
    output logic         ready_o,
    input  logic [191:0] telemetry_record_i,

    input  logic         session_active_i,
    input  logic [31:0]  session_id_i,
    input  logic [127:0] key_i,
    input  logic [63:0]  nonce_prefix_i,
    input  logic [63:0]  sequence_i,

    output logic         busy_o,
    output logic         done_o,
    output logic         packet_valid_o,
    output logic [15:0]  packet_len_o,
    output logic [63:0]  packet_sequence_o,
    input  logic [6:0]   packet_addr_i,
    output logic [7:0]   packet_data_o,
    input  logic         packet_release_i,

    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam integer HEADER_BYTES = 24;
    localparam integer DATA_BYTES = 24;
    localparam integer TAG_BYTES = 16;
    localparam integer PACKET_BYTES = HEADER_BYTES + DATA_BYTES + TAG_BYTES;

    localparam logic [15:0] ERR_BUSY            = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE   = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY          = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED = 16'h0304;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_START,
        ST_FEED,
        ST_WAIT_TAG,
        ST_DONE
    } state_t;

    state_t state_q;
    logic [191:0] sample_q;
    logic [31:0] session_id_q;
    logic [127:0] key_q;
    logic [63:0] nonce_prefix_q;
    logic [63:0] sequence_q;
    logic [127:0] nonce_q;
    logic [5:0] input_index_q;
    logic [5:0] ciphertext_index_q;
    logic [7:0] packet_mem [0:PACKET_BYTES-1];

    logic ascon_start;
    logic ascon_ready;
    logic ascon_in_valid;
    logic ascon_in_ready;
    logic [7:0] ascon_in_data;
    logic ascon_in_last;
    logic ascon_out_valid;
    logic [7:0] ascon_out_data;
    logic ascon_out_last;
    logic ascon_tag_valid;
    logic [127:0] ascon_tag;
    logic ascon_done;
    logic ascon_error_valid;
    logic [15:0] ascon_error_code;

    integer i;

    function automatic logic [7:0] header_byte(
        input integer index,
        input logic [31:0] sid,
        input logic [63:0] seq
    );
        begin
            case (index)
                0:  header_byte = 8'h50;
                1:  header_byte = 8'h51;
                2:  header_byte = 8'h01;
                3:  header_byte = 8'h03; /* TELEMETRY_DATA */
                4:  header_byte = 8'h00;
                5:  header_byte = 8'h00;
                6:  header_byte = 8'h00;
                7:  header_byte = 8'h18;
                8:  header_byte = sid[31:24];
                9:  header_byte = sid[23:16];
                10: header_byte = sid[15:8];
                11: header_byte = sid[7:0];
                12: header_byte = seq[63:56];
                13: header_byte = seq[55:48];
                14: header_byte = seq[47:40];
                15: header_byte = seq[39:32];
                16: header_byte = seq[31:24];
                17: header_byte = seq[23:16];
                18: header_byte = seq[15:8];
                19: header_byte = seq[7:0];
                20: header_byte = 8'h00;
                21: header_byte = 8'h18;
                22: header_byte = 8'h01; /* telemetry payload format */
                default: header_byte = 8'h00;
            endcase
        end
    endfunction

    always_comb begin
        nonce_q = '0;
        /* nonce_prefix_i uses byte 0 at bits [7:0], matching the Ascon bus
         * convention. Sequence bytes are appended in network order. */
        for (i = 0; i < 8; i = i + 1)
            nonce_q[8*i +: 8] = nonce_prefix_q[8*i +: 8];
        nonce_q[8*8  +: 8] = sequence_q[63:56];
        nonce_q[8*9  +: 8] = sequence_q[55:48];
        nonce_q[8*10 +: 8] = sequence_q[47:40];
        nonce_q[8*11 +: 8] = sequence_q[39:32];
        nonce_q[8*12 +: 8] = sequence_q[31:24];
        nonce_q[8*13 +: 8] = sequence_q[23:16];
        nonce_q[8*14 +: 8] = sequence_q[15:8];
        nonce_q[8*15 +: 8] = sequence_q[7:0];
    end

    assign ready_o = (state_q == ST_IDLE) && !packet_valid_o;
    assign busy_o = (state_q != ST_IDLE);
    assign packet_len_o = PACKET_BYTES;
    assign packet_data_o = (packet_addr_i < PACKET_BYTES) ?
                           packet_mem[packet_addr_i] : 8'h00;

    assign ascon_start = (state_q == ST_START);
    assign ascon_in_valid = (state_q == ST_FEED);
    assign ascon_in_data = (input_index_q < HEADER_BYTES) ?
                           header_byte(input_index_q, session_id_q, sequence_q) :
                           sample_q[8*(input_index_q-HEADER_BYTES) +: 8];
    assign ascon_in_last = (input_index_q == HEADER_BYTES + DATA_BYTES - 1);

    ascon_aead_core u_ascon (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .zeroize_i      (zeroize_i),
        .mode_decrypt_i (1'b0),
        .start_i        (ascon_start),
        .ready_o        (ascon_ready),
        .key_i          (key_q),
        .nonce_i        (nonce_q),
        .ad_len_i       (16'd24),
        .data_len_i     (16'd24),
        .in_valid_i     (ascon_in_valid),
        .in_ready_o     (ascon_in_ready),
        .in_data_i      (ascon_in_data),
        .in_last_i      (ascon_in_last),
        .tag_valid_i    (1'b0),
        .tag_ready_o    (),
        .tag_i          ('0),
        .out_valid_o    (ascon_out_valid),
        .out_ready_i    (1'b1),
        .out_data_o     (ascon_out_data),
        .out_last_o     (ascon_out_last),
        .tag_valid_o    (ascon_tag_valid),
        .tag_ready_i    (1'b1),
        .tag_o          (ascon_tag),
        .done_o         (ascon_done),
        .auth_valid_o   (),
        .auth_ok_o      (),
        .error_valid_o  (ascon_error_valid),
        .error_code_o   (ascon_error_code)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            sample_q <= '0;
            session_id_q <= '0;
            key_q <= '0;
            nonce_prefix_q <= '0;
            sequence_q <= '0;
            input_index_q <= '0;
            ciphertext_index_q <= '0;
            packet_valid_o <= 1'b0;
            packet_sequence_o <= '0;
            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;
            for (i = 0; i < PACKET_BYTES; i = i + 1)
                packet_mem[i] <= 8'h00;
        end else if (zeroize_i) begin
            state_q <= ST_IDLE;
            sample_q <= '0;
            session_id_q <= '0;
            key_q <= '0;
            nonce_prefix_q <= '0;
            sequence_q <= '0;
            input_index_q <= '0;
            ciphertext_index_q <= '0;
            packet_valid_o <= 1'b0;
            packet_sequence_o <= '0;
            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;
            for (i = 0; i < PACKET_BYTES; i = i + 1)
                packet_mem[i] <= 8'h00;
        end else begin
            done_o <= 1'b0;
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;

            if (packet_release_i) begin
                packet_valid_o <= 1'b0;
                for (i = 0; i < PACKET_BYTES; i = i + 1)
                    packet_mem[i] <= 8'h00;
            end

            if (start_i && !ready_o) begin
                error_valid_o <= 1'b1;
                error_code_o <= ERR_BUSY;
            end

            if (ascon_error_valid) begin
                state_q <= ST_IDLE;
                error_valid_o <= 1'b1;
                error_code_o <= ascon_error_code;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i && ready_o) begin
                            if (!secure_enable_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_SECURE_DISABLED;
                            end else if (!session_active_i) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_NO_KEY;
                            end else if (session_id_i == 32'h00000000) begin
                                error_valid_o <= 1'b1;
                                error_code_o <= ERR_INVALID_STATE;
                            end else begin
                                sample_q <= telemetry_record_i;
                                session_id_q <= session_id_i;
                                key_q <= key_i;
                                nonce_prefix_q <= nonce_prefix_i;
                                sequence_q <= sequence_i;
                                input_index_q <= '0;
                                ciphertext_index_q <= '0;
                                packet_sequence_o <= sequence_i;
                                for (i = 0; i < HEADER_BYTES; i = i + 1)
                                    packet_mem[i] <= header_byte(i, session_id_i, sequence_i);
                                state_q <= ST_START;
                            end
                        end
                    end

                    ST_START: begin
                        if (ascon_ready)
                            state_q <= ST_FEED;
                    end

                    ST_FEED: begin
                        if (ascon_in_valid && ascon_in_ready) begin
                            if (input_index_q == HEADER_BYTES + DATA_BYTES - 1)
                                state_q <= ST_WAIT_TAG;
                            input_index_q <= input_index_q + 1'b1;
                        end
                        if (ascon_out_valid) begin
                            packet_mem[HEADER_BYTES + ciphertext_index_q] <= ascon_out_data;
                            ciphertext_index_q <= ciphertext_index_q + 1'b1;
                        end
                    end

                    ST_WAIT_TAG: begin
                        if (ascon_out_valid) begin
                            packet_mem[HEADER_BYTES + ciphertext_index_q] <= ascon_out_data;
                            ciphertext_index_q <= ciphertext_index_q + 1'b1;
                        end
                        if (ascon_tag_valid) begin
                            for (i = 0; i < TAG_BYTES; i = i + 1)
                                packet_mem[HEADER_BYTES + DATA_BYTES + i] <= ascon_tag[8*i +: 8];
                            packet_valid_o <= 1'b1;
                            state_q <= ST_DONE;
                        end
                    end

                    ST_DONE: begin
                        if (ascon_done || packet_valid_o) begin
                            done_o <= 1'b1;
                            state_q <= ST_IDLE;
                        end
                    end

                    default: state_q <= ST_IDLE;
                endcase
            end
        end
    end
endmodule
