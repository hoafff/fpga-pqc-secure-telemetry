module primer1_session_manager (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    input  logic         stage_i,
    input  logic [31:0]  stage_session_id_i,
    input  logic [127:0] stage_key_i,
    input  logic [63:0]  stage_nonce_prefix_i,
    input  logic [63:0]  stage_sequence_i,
    input  logic [31:0]  stage_policy_flags_i,

    input  logic         commit_i,
    input  logic [31:0]  commit_session_id_i,

    input  logic         tx_commit_i,
    input  logic [63:0]  tx_commit_sequence_i,
    input  logic         tx_prove_committed_i,
    input  logic [63:0]  tx_expected_sequence_i,

    output logic         staging_valid_o,
    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [31:0]  session_id_o,
    output logic [127:0] traffic_key_o,
    output logic [63:0]  nonce_prefix_o,
    output logic [63:0]  tx_sequence_o,
    output logic [31:0]  policy_flags_o,

    output logic         event_valid_o,
    output logic [15:0]  event_code_o
);
    localparam logic [15:0] ERR_ARGUMENT        = 16'h0203;
    localparam logic [15:0] ERR_INVALID_STATE   = 16'h0302;
    localparam logic [15:0] ERR_SECURE_DISABLED = 16'h0304;
    localparam logic [15:0] ERR_KEY_COMMIT      = 16'h0505;
    localparam logic [15:0] ERR_SEQUENCE_DESYNC = 16'h0610;

    logic [31:0]  staging_session_id_q;
    logic [127:0] staging_key_q;
    logic [63:0]  staging_nonce_prefix_q;
    logic [63:0]  staging_sequence_q;
    logic [31:0]  staging_policy_flags_q;
    logic         staging_valid_q;

    logic [31:0]  session_id_q;
    logic [127:0] traffic_key_q;
    logic [63:0]  nonce_prefix_q;
    logic [63:0]  tx_sequence_q;
    logic [31:0]  policy_flags_q;
    logic         key_valid_q;
    logic         session_active_q;

    assign staging_valid_o  = staging_valid_q;
    assign key_valid_o      = key_valid_q;
    assign session_active_o = session_active_q;
    assign session_id_o     = session_id_q;
    assign traffic_key_o    = traffic_key_q;
    assign nonce_prefix_o   = nonce_prefix_q;
    assign tx_sequence_o    = tx_sequence_q;
    assign policy_flags_o   = policy_flags_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            staging_session_id_q     <= '0;
            staging_key_q            <= '0;
            staging_nonce_prefix_q   <= '0;
            staging_sequence_q       <= '0;
            staging_policy_flags_q   <= '0;
            staging_valid_q          <= 1'b0;
            session_id_q             <= '0;
            traffic_key_q            <= '0;
            nonce_prefix_q           <= '0;
            tx_sequence_q            <= '0;
            policy_flags_q           <= '0;
            key_valid_q              <= 1'b0;
            session_active_q         <= 1'b0;
            event_valid_o            <= 1'b0;
            event_code_o             <= 16'h0000;
        end else begin
            event_valid_o <= 1'b0;
            event_code_o  <= 16'h0000;

            /* secure_enable is an independent supervisor gate.  Loss of the
             * gate disables use immediately but does not itself erase context;
             * the supervisor's zeroize path performs the erase. */
            if (!secure_enable_i)
                session_active_q <= 1'b0;

            if (stage_i) begin
                if (stage_session_id_i == 32'h0000_0000) begin
                    staging_valid_q <= 1'b0;
                    event_valid_o   <= 1'b1;
                    event_code_o    <= ERR_ARGUMENT;
                end else begin
                    staging_session_id_q   <= stage_session_id_i;
                    staging_key_q          <= stage_key_i;
                    staging_nonce_prefix_q <= stage_nonce_prefix_i;
                    staging_sequence_q     <= stage_sequence_i;
                    staging_policy_flags_q <= stage_policy_flags_i;
                    staging_valid_q        <= 1'b1;
                end
            end

            if (commit_i) begin
                if (!secure_enable_i) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_SECURE_DISABLED;
                end else if (!staging_valid_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_KEY_COMMIT;
                end else if ((commit_session_id_i == 32'h0000_0000) ||
                             (commit_session_id_i != staging_session_id_q)) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_KEY_COMMIT;
                end else begin
                    /* One edge changes the complete active context. */
                    session_id_q      <= staging_session_id_q;
                    traffic_key_q     <= staging_key_q;
                    nonce_prefix_q    <= staging_nonce_prefix_q;
                    tx_sequence_q     <= staging_sequence_q;
                    policy_flags_q    <= staging_policy_flags_q;
                    key_valid_q       <= 1'b1;
                    session_active_q  <= 1'b1;

                    staging_session_id_q   <= '0;
                    staging_key_q          <= '0;
                    staging_nonce_prefix_q <= '0;
                    staging_sequence_q     <= '0;
                    staging_policy_flags_q <= '0;
                    staging_valid_q        <= 1'b0;
                end
            end

            /* Normal receiver commit: only the retained packet using the
             * current sequence may advance the counter, exactly once. */
            if (tx_commit_i) begin
                if (!key_valid_q || !session_active_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_INVALID_STATE;
                end else if (tx_commit_sequence_i != tx_sequence_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_SEQUENCE_DESYNC;
                end else begin
                    tx_sequence_q <= tx_sequence_q + 64'd1;
                end
            end

            /* Lost-ack recovery from Primer #2.  Only expected=sent+1 is proof
             * of the previous commit.  expected=sent means "retry retained
             * bytes" and therefore does not change the counter. */
            if (tx_prove_committed_i) begin
                if (!key_valid_q || !session_active_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_INVALID_STATE;
                end else if (tx_expected_sequence_i == tx_sequence_q + 64'd1) begin
                    tx_sequence_q <= tx_sequence_q + 64'd1;
                end else if (tx_expected_sequence_i != tx_sequence_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_SEQUENCE_DESYNC;
                    session_active_q <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && !zeroize_i) begin
            assert (!session_active_q || key_valid_q)
                else $error("primer1_session_manager: active session without valid key");
            assert (!key_valid_q || (session_id_q != 32'h0))
                else $error("primer1_session_manager: valid key with zero session id");
        end
    end
`endif
endmodule
