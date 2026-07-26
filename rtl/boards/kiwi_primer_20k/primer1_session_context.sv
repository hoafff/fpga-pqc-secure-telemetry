// Atomic TX session context for Kiwi Primer 20K #1.
//
// Deployment profile for FPST v1.1:
//   key-load byte offsets  0..15 : K_TX bytes in wire order
//   key-load byte offsets 16..23 : NP_TX bytes in wire order
//
// The bus packing matches rtl/ascon/ascon_aead_encrypt.sv: external byte 0
// occupies bits [7:0], byte 1 occupies bits [15:8], etc.
module primer1_session_context (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,

    input  logic         begin_i,
    input  logic [31:0]  begin_session_id_i,
    input  logic [7:0]   begin_direction_i,
    input  logic [15:0]  begin_total_len_i,

    input  logic         chunk_valid_i,
    input  logic [15:0]  chunk_offset_i,
    input  logic [7:0]   chunk_data_i,

    input  logic         commit_i,
    input  logic [31:0]  commit_session_id_i,
    input  logic         abort_i,

    input  logic         activate_i,
    input  logic [31:0]  activate_session_id_i,
    input  logic         sequence_commit_i,

    output logic         key_loading_o,
    output logic         staging_complete_o,
    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [31:0]  session_id_o,
    output logic [127:0] traffic_key_o,
    output logic [63:0]  nonce_prefix_o,
    output logic [63:0]  tx_sequence_o,

    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [15:0] ERR_INVALID_STATE       = 16'h0302;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT           = 16'h0505;

    localparam logic [7:0]  DIRECTION_TX = 8'h00;
    localparam logic [15:0] CONTEXT_BYTES = 16'd24;

    logic [31:0]  staging_session_id_q;
    logic [127:0] staging_key_q;
    logic [63:0]  staging_prefix_q;
    logic [23:0]  coverage_q;
    logic         staging_conflict_q;

    assign staging_complete_o = (coverage_q == 24'hff_ffff) &&
                                !staging_conflict_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            key_loading_o         <= 1'b0;
            key_valid_o           <= 1'b0;
            session_active_o      <= 1'b0;
            session_id_o          <= 32'h0000_0000;
            traffic_key_o         <= 128'h0;
            nonce_prefix_o        <= 64'h0;
            tx_sequence_o         <= 64'h0;
            staging_session_id_q  <= 32'h0;
            staging_key_q         <= 128'h0;
            staging_prefix_q      <= 64'h0;
            coverage_q            <= 24'h0;
            staging_conflict_q    <= 1'b0;
            error_valid_o         <= 1'b0;
            error_code_o          <= 16'h0000;
        end else if (zeroize_i) begin
            // FPST zeroize wins every race. key_valid drops on this edge and
            // all session/key/staging state is cleared on the same edge.
            key_loading_o         <= 1'b0;
            key_valid_o           <= 1'b0;
            session_active_o      <= 1'b0;
            session_id_o          <= 32'h0000_0000;
            traffic_key_o         <= 128'h0;
            nonce_prefix_o        <= 64'h0;
            tx_sequence_o         <= 64'h0;
            staging_session_id_q  <= 32'h0;
            staging_key_q         <= 128'h0;
            staging_prefix_q      <= 64'h0;
            coverage_q            <= 24'h0;
            staging_conflict_q    <= 1'b0;
            error_valid_o         <= 1'b0;
            error_code_o          <= 16'h0000;
        end else begin
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            if (abort_i) begin
                key_loading_o        <= 1'b0;
                staging_session_id_q <= 32'h0;
                staging_key_q        <= 128'h0;
                staging_prefix_q     <= 64'h0;
                coverage_q           <= 24'h0;
                staging_conflict_q   <= 1'b0;
            end

            if (begin_i) begin
                if ((begin_session_id_i == 32'h0) ||
                    (begin_direction_i != DIRECTION_TX) ||
                    (begin_total_len_i != CONTEXT_BYTES)) begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_KEY_COMMIT;
                end else begin
                    // Beginning a replacement session invalidates the previous
                    // active key immediately; partial staging never becomes
                    // usable cryptographic state.
                    key_loading_o        <= 1'b1;
                    key_valid_o          <= 1'b0;
                    session_active_o     <= 1'b0;
                    session_id_o         <= 32'h0;
                    traffic_key_o        <= 128'h0;
                    nonce_prefix_o       <= 64'h0;
                    tx_sequence_o        <= 64'h0;
                    staging_session_id_q <= begin_session_id_i;
                    staging_key_q        <= 128'h0;
                    staging_prefix_q     <= 64'h0;
                    coverage_q           <= 24'h0;
                    staging_conflict_q   <= 1'b0;
                end
            end

            if (chunk_valid_i) begin
                if (!key_loading_o || (chunk_offset_i >= CONTEXT_BYTES)) begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_INVALID_STATE;
                end else if (chunk_offset_i < 16) begin
                    if (coverage_q[chunk_offset_i] &&
                        (staging_key_q[8*chunk_offset_i +: 8] != chunk_data_i)) begin
                        staging_conflict_q <= 1'b1;
                        error_valid_o      <= 1'b1;
                        error_code_o       <= ERR_KEY_COMMIT;
                    end else begin
                        staging_key_q[8*chunk_offset_i +: 8] <= chunk_data_i;
                        coverage_q[chunk_offset_i] <= 1'b1;
                    end
                end else begin
                    if (coverage_q[chunk_offset_i] &&
                        (staging_prefix_q[8*(chunk_offset_i-16) +: 8] != chunk_data_i)) begin
                        staging_conflict_q <= 1'b1;
                        error_valid_o      <= 1'b1;
                        error_code_o       <= ERR_KEY_COMMIT;
                    end else begin
                        staging_prefix_q[8*(chunk_offset_i-16) +: 8] <= chunk_data_i;
                        coverage_q[chunk_offset_i] <= 1'b1;
                    end
                end
            end

            if (commit_i) begin
                if (!key_loading_o ||
                    (commit_session_id_i != staging_session_id_q)) begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_INVALID_STATE;
                end else if (!staging_complete_o) begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_KEY_LOAD_INCOMPLETE;
                end else begin
                    session_id_o         <= staging_session_id_q;
                    traffic_key_o        <= staging_key_q;
                    nonce_prefix_o       <= staging_prefix_q;
                    tx_sequence_o        <= 64'h0;
                    key_valid_o          <= 1'b1;
                    session_active_o     <= 1'b0;
                    key_loading_o        <= 1'b0;
                    staging_session_id_q <= 32'h0;
                    staging_key_q        <= 128'h0;
                    staging_prefix_q     <= 64'h0;
                    coverage_q           <= 24'h0;
                    staging_conflict_q   <= 1'b0;
                end
            end

            if (activate_i) begin
                if (!key_valid_o || (activate_session_id_i != session_id_o)) begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_INVALID_STATE;
                end else begin
                    session_active_o <= 1'b1;
                    tx_sequence_o    <= 64'h0;
                end
            end

            if (sequence_commit_i) begin
                if (session_active_o && key_valid_o)
                    tx_sequence_o <= tx_sequence_o + 1'b1;
                else begin
                    error_valid_o <= 1'b1;
                    error_code_o  <= ERR_INVALID_STATE;
                end
            end
        end
    end
endmodule
