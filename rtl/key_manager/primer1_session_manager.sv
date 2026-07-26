module primer1_session_manager (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    /* KEY_LOAD_BEGIN (0x40): session_id + dir + total material length. */
    input  logic         load_begin_i,
    input  logic [31:0]  load_session_id_i,
    input  logic [7:0]   load_direction_i,
    input  logic [15:0]  load_total_len_i,

    /* KEY_LOAD_CHUNK (0x41): dispatcher presents one byte per cycle. */
    input  logic         load_byte_i,
    input  logic [15:0]  load_offset_i,
    input  logic [7:0]   load_data_i,

    /* KEY_LOAD_COMMIT / ABORT / SESSION_ACTIVATE. */
    input  logic         load_commit_i,
    input  logic [31:0]  commit_session_id_i,
    input  logic [31:0]  commit_policy_flags_i,
    input  logic         load_abort_i,
    input  logic         session_activate_i,
    input  logic [31:0]  activate_session_id_i,

    /* Receiver commit / lost-ack reconciliation for retained TX packets. */
    input  logic         tx_commit_i,
    input  logic [63:0]  tx_commit_sequence_i,
    input  logic         tx_reconcile_i,
    input  logic [63:0]  rx_expected_sequence_i,

    output logic         staging_valid_o,
    output logic [23:0]  staging_write_mask_o,
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
    /* Primer #1 owns TX material only.  Profile value 0x01 means TX. */
    localparam logic [7:0]  KEY_DIRECTION_TX = 8'h01;
    localparam logic [15:0] TX_MATERIAL_BYTES = 16'd24;

    localparam logic [15:0] ERR_ARGUMENT            = 16'h0203;
    localparam logic [15:0] ERR_INVALID_STATE       = 16'h0302;
    localparam logic [15:0] ERR_SECURE_DISABLED     = 16'h0304;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT          = 16'h0505;
    localparam logic [15:0] ERR_SEQUENCE_DESYNC     = 16'h0610;

    logic [31:0]  staging_session_id_q;
    logic [127:0] staging_key_q;
    logic [63:0]  staging_nonce_prefix_q;
    logic [23:0]  staging_write_mask_q;
    logic         staging_valid_q;

    logic [31:0]  session_id_q;
    logic [127:0] traffic_key_q;
    logic [63:0]  nonce_prefix_q;
    logic [63:0]  tx_sequence_q;
    logic [31:0]  policy_flags_q;
    logic         key_valid_q;
    logic         session_active_q;

    assign staging_valid_o      = staging_valid_q;
    assign staging_write_mask_o = staging_write_mask_q;
    assign key_valid_o          = key_valid_q;
    assign session_active_o     = session_active_q;
    assign session_id_o         = session_id_q;
    assign traffic_key_o        = traffic_key_q;
    assign nonce_prefix_o       = nonce_prefix_q;
    assign tx_sequence_o        = tx_sequence_q;
    assign policy_flags_o       = policy_flags_q;

    task automatic clear_staging;
        begin
            staging_session_id_q   <= '0;
            staging_key_q          <= '0;
            staging_nonce_prefix_q <= '0;
            staging_write_mask_q   <= '0;
            staging_valid_q        <= 1'b0;
        end
    endtask

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            staging_session_id_q   <= '0;
            staging_key_q          <= '0;
            staging_nonce_prefix_q <= '0;
            staging_write_mask_q   <= '0;
            staging_valid_q        <= 1'b0;
            session_id_q           <= '0;
            traffic_key_q          <= '0;
            nonce_prefix_q         <= '0;
            tx_sequence_q          <= '0;
            policy_flags_q         <= '0;
            key_valid_q            <= 1'b0;
            session_active_q       <= 1'b0;
            event_valid_o          <= 1'b0;
            event_code_o           <= 16'h0000;
        end else begin
            event_valid_o <= 1'b0;
            event_code_o  <= 16'h0000;

            /* Removing the supervisor gate requires explicit re-activation. */
            if (!secure_enable_i)
                session_active_q <= 1'b0;

            if (load_abort_i)
                clear_staging();

            if (load_begin_i) begin
                if ((load_session_id_i == 32'h0000_0000) ||
                    (load_direction_i != KEY_DIRECTION_TX) ||
                    (load_total_len_i != TX_MATERIAL_BYTES)) begin
                    clear_staging();
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_ARGUMENT;
                end else begin
                    /* Starting a new staging transaction never changes active key. */
                    staging_session_id_q   <= load_session_id_i;
                    staging_key_q          <= '0;
                    staging_nonce_prefix_q <= '0;
                    staging_write_mask_q   <= '0;
                    staging_valid_q        <= 1'b1;
                end
            end

            if (load_byte_i) begin
                if (!staging_valid_q || load_offset_i >= TX_MATERIAL_BYTES) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_ARGUMENT;
                end else if (load_offset_i < 16) begin
                    staging_key_q[8*load_offset_i +: 8] <= load_data_i;
                    staging_write_mask_q[load_offset_i] <= 1'b1;
                end else begin
                    staging_nonce_prefix_q[8*(load_offset_i-16) +: 8] <= load_data_i;
                    staging_write_mask_q[load_offset_i] <= 1'b1;
                end
            end

            if (load_commit_i) begin
                if (!staging_valid_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_KEY_COMMIT;
                end else if (staging_write_mask_q != 24'hFF_FFFF) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_KEY_LOAD_INCOMPLETE;
                end else if ((commit_session_id_i == 32'h0000_0000) ||
                             (commit_session_id_i != staging_session_id_q)) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_KEY_COMMIT;
                end else begin
                    /* Atomic transition into KEY_VALID. Activation is separate 0x46. */
                    session_id_q      <= staging_session_id_q;
                    traffic_key_q     <= staging_key_q;
                    nonce_prefix_q    <= staging_nonce_prefix_q;
                    tx_sequence_q     <= 64'd0;
                    policy_flags_q    <= commit_policy_flags_i;
                    key_valid_q       <= 1'b1;
                    session_active_q  <= 1'b0;
                    clear_staging();
                end
            end

            if (session_activate_i) begin
                if (!secure_enable_i) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_SECURE_DISABLED;
                end else if (!key_valid_q ||
                             activate_session_id_i == 32'h0000_0000 ||
                             activate_session_id_i != session_id_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_INVALID_STATE;
                end else begin
                    session_active_q <= 1'b1;
                end
            end

            /* Commit only the exact retained sequence once receiver accepted it. */
            if (tx_commit_i) begin
                if (!key_valid_q || !session_active_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_INVALID_STATE;
                end else if (tx_commit_sequence_i != tx_sequence_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_SEQUENCE_DESYNC;
                    session_active_q <= 1'b0;
                end else begin
                    tx_sequence_q <= tx_sequence_q + 64'd1;
                end
            end

            /* Lost-ack reconciliation:
             * expected == sent     : receiver has not committed, keep packet.
             * expected == sent + 1 : prior packet committed; advance locally.
             * otherwise            : desync and require a new activation/session.
             */
            if (tx_reconcile_i) begin
                if (!key_valid_q || !session_active_q) begin
                    event_valid_o <= 1'b1;
                    event_code_o  <= ERR_INVALID_STATE;
                end else if (rx_expected_sequence_i == tx_sequence_q + 64'd1) begin
                    tx_sequence_q <= tx_sequence_q + 64'd1;
                end else if (rx_expected_sequence_i != tx_sequence_q) begin
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
            assert (!staging_valid_q || (staging_session_id_q != 32'h0))
                else $error("primer1_session_manager: staging with zero session id");
        end
    end
`endif
endmodule
