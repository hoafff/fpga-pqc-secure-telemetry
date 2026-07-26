module primer1_session_context (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         load_begin_i,
    input  logic [31:0]  load_session_id_i,
    input  logic [15:0]  load_total_len_i,
    input  logic         load_chunk_i,
    input  logic [5:0]   load_offset_i,
    input  logic [7:0]   load_byte_i,
    input  logic         load_commit_i,
    input  logic         load_abort_i,
    input  logic         session_activate_i,
    input  logic [31:0]  activate_session_id_i,

    output logic         key_loading_o,
    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [31:0]  session_id_o,
    output logic [127:0] traffic_key_o,
    output logic [63:0]  nonce_prefix_o,
    output logic [63:0]  tx_sequence_o,
    input  logic         tx_sequence_commit_i,

    output logic         staging_complete_o,
    output logic         staging_conflict_o,
    output logic         commit_ok_o,
    output logic         commit_failed_o
);
    localparam integer CONTEXT_BYTES = 24;

    logic [7:0] staging_q [0:CONTEXT_BYTES-1];
    logic [CONTEXT_BYTES-1:0] coverage_q;
    logic [31:0] staging_session_id_q;
    logic [15:0] staging_total_len_q;
    integer i;

    always_comb begin
        staging_complete_o = key_loading_o &&
                             (staging_total_len_q == CONTEXT_BYTES) &&
                             (&coverage_q) &&
                             !staging_conflict_o;
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            key_loading_o <= 1'b0;
            key_valid_o <= 1'b0;
            session_active_o <= 1'b0;
            session_id_o <= 32'h0;
            traffic_key_o <= 128'h0;
            nonce_prefix_o <= 64'h0;
            tx_sequence_o <= 64'h0;
            coverage_q <= '0;
            staging_session_id_q <= 32'h0;
            staging_total_len_q <= 16'h0;
            staging_conflict_o <= 1'b0;
            commit_ok_o <= 1'b0;
            commit_failed_o <= 1'b0;
            for (i = 0; i < CONTEXT_BYTES; i = i + 1)
                staging_q[i] <= 8'h00;
        end else begin
            commit_ok_o <= 1'b0;
            commit_failed_o <= 1'b0;

            if (load_begin_i) begin
                /* A new key load invalidates the previous active key immediately. */
                key_loading_o <= 1'b1;
                key_valid_o <= 1'b0;
                session_active_o <= 1'b0;
                session_id_o <= 32'h0;
                traffic_key_o <= 128'h0;
                nonce_prefix_o <= 64'h0;
                tx_sequence_o <= 64'h0;
                staging_session_id_q <= load_session_id_i;
                staging_total_len_q <= load_total_len_i;
                coverage_q <= '0;
                staging_conflict_o <= 1'b0;
                for (i = 0; i < CONTEXT_BYTES; i = i + 1)
                    staging_q[i] <= 8'h00;
            end

            if (load_chunk_i && key_loading_o && (load_offset_i < CONTEXT_BYTES)) begin
                if (!coverage_q[load_offset_i]) begin
                    staging_q[load_offset_i] <= load_byte_i;
                    coverage_q[load_offset_i] <= 1'b1;
                end else if (staging_q[load_offset_i] != load_byte_i) begin
                    /* Same-byte retransmission is harmless; conflicting data is not. */
                    staging_conflict_o <= 1'b1;
                end
            end

            if (load_abort_i) begin
                key_loading_o <= 1'b0;
                coverage_q <= '0;
                staging_session_id_q <= 32'h0;
                staging_total_len_q <= 16'h0;
                staging_conflict_o <= 1'b0;
                for (i = 0; i < CONTEXT_BYTES; i = i + 1)
                    staging_q[i] <= 8'h00;
            end

            if (load_commit_i) begin
                if (staging_complete_o && (staging_session_id_q != 32'h0)) begin
                    session_id_o <= staging_session_id_q;
                    for (i = 0; i < 16; i = i + 1)
                        traffic_key_o[8*i +: 8] <= staging_q[i];
                    for (i = 0; i < 8; i = i + 1)
                        nonce_prefix_o[8*i +: 8] <= staging_q[16+i];
                    tx_sequence_o <= 64'h0;
                    key_valid_o <= 1'b1;
                    session_active_o <= 1'b0;
                    key_loading_o <= 1'b0;
                    coverage_q <= '0;
                    staging_session_id_q <= 32'h0;
                    staging_total_len_q <= 16'h0;
                    staging_conflict_o <= 1'b0;
                    commit_ok_o <= 1'b1;
                    for (i = 0; i < CONTEXT_BYTES; i = i + 1)
                        staging_q[i] <= 8'h00;
                end else begin
                    commit_failed_o <= 1'b1;
                end
            end

            if (session_activate_i && key_valid_o &&
                (activate_session_id_i == session_id_o) &&
                (activate_session_id_i != 32'h0))
                session_active_o <= 1'b1;

            /* Driven only after receiver commit/reconciliation, never on BTP readout. */
            if (tx_sequence_commit_i && session_active_o)
                tx_sequence_o <= tx_sequence_o + 1'b1;

            /* Highest priority: secret state is invalid in the same clock. */
            if (zeroize_i) begin
                key_loading_o <= 1'b0;
                key_valid_o <= 1'b0;
                session_active_o <= 1'b0;
                session_id_o <= 32'h0;
                traffic_key_o <= 128'h0;
                nonce_prefix_o <= 64'h0;
                tx_sequence_o <= 64'h0;
                coverage_q <= '0;
                staging_session_id_q <= 32'h0;
                staging_total_len_q <= 16'h0;
                staging_conflict_o <= 1'b0;
                commit_ok_o <= 1'b0;
                commit_failed_o <= 1'b0;
                for (i = 0; i < CONTEXT_BYTES; i = i + 1)
                    staging_q[i] <= 8'h00;
            end
        end
    end
endmodule
