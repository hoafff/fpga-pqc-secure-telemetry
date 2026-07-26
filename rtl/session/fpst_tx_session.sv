module fpst_tx_session (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    input  logic         stage_valid_i,
    output logic         stage_ready_o,
    input  logic [31:0]  stage_session_id_i,
    input  logic [127:0] stage_key_i,
    input  logic [63:0]  stage_nonce_prefix_i,
    input  logic [63:0]  stage_initial_sequence_i,
    input  logic [31:0]  stage_policy_flags_i,

    input  logic         commit_valid_i,
    output logic         commit_ready_o,
    input  logic [31:0]  commit_session_id_i,

    input  logic         activate_valid_i,
    output logic         activate_ready_o,
    input  logic [31:0]  activate_session_id_i,

    input  logic         tx_commit_valid_i,
    input  logic [63:0]  tx_commit_sequence_i,

    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [31:0]  session_id_o,
    output logic [127:0] key_o,
    output logic [63:0]  nonce_prefix_o,
    output logic [63:0]  sequence_o,
    output logic [31:0]  policy_flags_o,

    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    localparam logic [15:0] ERR_INVALID_STATE       = 16'h0302;
    localparam logic [15:0] ERR_SECURE_DISABLED     = 16'h0304;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT           = 16'h0505;

    logic staging_valid_q;
    logic [31:0]  staging_session_id_q;
    logic [127:0] staging_key_q;
    logic [63:0]  staging_nonce_prefix_q;
    logic [63:0]  staging_initial_sequence_q;
    logic [31:0]  staging_policy_flags_q;

    assign stage_ready_o = !session_active_o;
    assign commit_ready_o = staging_valid_q && !session_active_o;
    assign activate_ready_o = key_valid_o && !session_active_o && secure_enable_i;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            staging_valid_q            <= 1'b0;
            staging_session_id_q       <= '0;
            staging_key_q              <= '0;
            staging_nonce_prefix_q     <= '0;
            staging_initial_sequence_q <= '0;
            staging_policy_flags_q     <= '0;
            key_valid_o                <= 1'b0;
            session_active_o           <= 1'b0;
            session_id_o               <= '0;
            key_o                      <= '0;
            nonce_prefix_o             <= '0;
            sequence_o                 <= '0;
            policy_flags_o             <= '0;
            error_valid_o              <= 1'b0;
            error_code_o               <= 16'h0000;
        end else if (zeroize_i) begin
            staging_valid_q            <= 1'b0;
            staging_session_id_q       <= '0;
            staging_key_q              <= '0;
            staging_nonce_prefix_q     <= '0;
            staging_initial_sequence_q <= '0;
            staging_policy_flags_q     <= '0;
            key_valid_o                <= 1'b0;
            session_active_o           <= 1'b0;
            session_id_o               <= '0;
            key_o                      <= '0;
            nonce_prefix_o             <= '0;
            sequence_o                 <= '0;
            policy_flags_o             <= '0;
            error_valid_o              <= 1'b0;
            error_code_o               <= 16'h0000;
        end else begin
            error_valid_o <= 1'b0;
            error_code_o <= 16'h0000;

            if (!secure_enable_i && session_active_o) begin
                /* secure_enable loss invalidates use immediately; supervisor
                 * zeroize remains the mechanism that wipes the key material. */
                session_active_o <= 1'b0;
            end

            if (stage_valid_i) begin
                if (!stage_ready_o || stage_session_id_i == 32'h00000000) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_INVALID_STATE;
                end else begin
                    staging_session_id_q       <= stage_session_id_i;
                    staging_key_q              <= stage_key_i;
                    staging_nonce_prefix_q     <= stage_nonce_prefix_i;
                    staging_initial_sequence_q <= stage_initial_sequence_i;
                    staging_policy_flags_q     <= stage_policy_flags_i;
                    staging_valid_q            <= 1'b1;
                end
            end

            if (commit_valid_i) begin
                if (!staging_valid_q) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_KEY_LOAD_INCOMPLETE;
                end else if (!commit_ready_o ||
                             commit_session_id_i != staging_session_id_q) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_KEY_COMMIT;
                end else begin
                    session_id_o     <= staging_session_id_q;
                    key_o            <= staging_key_q;
                    nonce_prefix_o   <= staging_nonce_prefix_q;
                    sequence_o       <= staging_initial_sequence_q;
                    policy_flags_o   <= staging_policy_flags_q;
                    key_valid_o      <= 1'b1;
                    session_active_o <= 1'b0;

                    staging_valid_q            <= 1'b0;
                    staging_session_id_q       <= '0;
                    staging_key_q              <= '0;
                    staging_nonce_prefix_q     <= '0;
                    staging_initial_sequence_q <= '0;
                    staging_policy_flags_q     <= '0;
                end
            end

            if (activate_valid_i) begin
                if (!secure_enable_i) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_SECURE_DISABLED;
                end else if (!activate_ready_o ||
                             activate_session_id_i != session_id_o) begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_INVALID_STATE;
                end else begin
                    session_active_o <= 1'b1;
                end
            end

            /* Sequence ownership belongs to the TX endpoint. It advances only
             * after a matching receiver commit acknowledgement. */
            if (tx_commit_valid_i && session_active_o) begin
                if (tx_commit_sequence_i == sequence_o)
                    sequence_o <= sequence_o + 1'b1;
                else begin
                    error_valid_o <= 1'b1;
                    error_code_o <= ERR_INVALID_STATE;
                end
            end
        end
    end
endmodule
