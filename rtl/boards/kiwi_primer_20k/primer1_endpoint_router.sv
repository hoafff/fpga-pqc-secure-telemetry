module primer1_endpoint_router #(
    parameter integer CLOCK_HZ = 27_000_000,
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1)
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic transport_zeroize_i,
    input  logic secure_enable_i,
    input  logic fatal_latched_i,

    input  logic request_valid_i,
    output logic request_accept_o,
    input  logic [7:0] request_opcode_i,
    input  logic [7:0] request_flags_i,
    input  logic [15:0] request_transaction_id_i,
    input  logic [15:0] request_payload_len_i,
    input  logic [31:0] request_crc32_i,
    input  logic request_error_i,
    input  logic [15:0] request_error_code_i,
    output logic [9:0] request_payload_rd_addr_o,
    input  logic [7:0] request_payload_rd_data_i,

    input  logic tx_frame_ready_i,
    input  logic tx_frame_consumed_i,
    output logic tx_frame_commit_o,
    output logic [COUNT_W-1:0] tx_frame_len_o,
    output logic tx_wr_en_o,
    output logic [COUNT_W-1:0] tx_wr_addr_o,
    output logic [7:0] tx_wr_data_o,

    output logic irq_pending_o,
    output logic busy_o,
    output logic key_valid_o,
    output logic session_active_o,
    output logic retained_packet_o,
    output logic pqc_busy_o,
    output logic [1:0] pqc_domain_o,
    output logic pqc_complete_o,
    output logic [15:0] last_error_code_o
);
    import fpst_btp_pkg::*;

    localparam integer LAST_CYCLES = CLOCK_HZ;
    localparam integer LAST_COUNT_W = $clog2(LAST_CYCLES + 1);

    logic active_q;
    logic select_pqc_q;
    logic active_collision_q;
    logic active_duplicate_q;
    logic [15:0] active_transaction_id_q;
    logic [7:0] active_opcode_q;
    logic [15:0] active_payload_len_q;
    logic [31:0] active_crc32_q;

    logic last_valid_q;
    logic last_select_pqc_q;
    logic [15:0] last_transaction_id_q;
    logic [7:0] last_opcode_q;
    logic [15:0] last_payload_len_q;
    logic [31:0] last_crc32_q;
    logic [LAST_COUNT_W-1:0] last_age_q;

    logic current_is_pqc;
    logic current_same_signature;
    logic current_collision;
    logic current_duplicate;
    logic route_pqc;
    logic routed_request_error;
    logic [15:0] routed_request_error_code;

    logic control_request_valid;
    logic control_request_accept;
    logic [9:0] control_payload_addr;
    logic control_tx_commit;
    logic [COUNT_W-1:0] control_tx_len;
    logic control_tx_wr_en;
    logic [COUNT_W-1:0] control_tx_wr_addr;
    logic [7:0] control_tx_wr_data;
    logic control_irq;
    logic control_busy;
    logic control_key_valid;
    logic control_session_active;
    logic control_retained;
    logic control_ntt_busy_unused;
    logic [15:0] control_last_error;

    logic pqc_request_valid;
    logic pqc_request_accept;
    logic [9:0] pqc_payload_addr;
    logic pqc_tx_commit;
    logic [COUNT_W-1:0] pqc_tx_len;
    logic pqc_tx_wr_en;
    logic [COUNT_W-1:0] pqc_tx_wr_addr;
    logic [7:0] pqc_tx_wr_data;
    logic pqc_endpoint_busy;
    logic [15:0] pqc_last_error;

    assign current_is_pqc = (request_opcode_i >= OP_PQC_WRITE_COEFF) &&
                            (request_opcode_i <= OP_PQC_GET_RESULT);
    assign current_same_signature = last_valid_q &&
                                    (request_transaction_id_i == last_transaction_id_q) &&
                                    (request_opcode_i == last_opcode_q) &&
                                    (request_payload_len_i == last_payload_len_q) &&
                                    (request_crc32_i == last_crc32_q);
    assign current_collision = last_valid_q &&
                               (request_transaction_id_i == last_transaction_id_q) &&
                               !current_same_signature;
    assign current_duplicate = current_same_signature;

    // An exact retry must return to the endpoint that owns the cached response.
    // A transaction-ID collision is routed by opcode but converted to an error
    // before either endpoint can cause a side effect.
    assign route_pqc = active_q
                     ? select_pqc_q
                     : (current_duplicate ? last_select_pqc_q : current_is_pqc);

    assign routed_request_error = request_error_i ||
                                  ((!active_q && request_valid_i) ? current_collision
                                                                 : active_collision_q);
    assign routed_request_error_code = request_error_i
                                     ? request_error_code_i
                                     : (routed_request_error ? ERR_BTP_TRANSACTION : ERR_OK);

    assign control_request_valid = request_valid_i && !route_pqc;
    assign pqc_request_valid = request_valid_i && route_pqc;

    assign request_accept_o = route_pqc ? pqc_request_accept : control_request_accept;
    assign request_payload_rd_addr_o = route_pqc ? pqc_payload_addr : control_payload_addr;

    always_comb begin
        if (active_q && select_pqc_q) begin
            tx_frame_commit_o = pqc_tx_commit;
            tx_frame_len_o = pqc_tx_len;
            tx_wr_en_o = pqc_tx_wr_en;
            tx_wr_addr_o = pqc_tx_wr_addr;
            tx_wr_data_o = pqc_tx_wr_data;
        end else begin
            tx_frame_commit_o = control_tx_commit;
            tx_frame_len_o = control_tx_len;
            tx_wr_en_o = control_tx_wr_en;
            tx_wr_addr_o = control_tx_wr_addr;
            tx_wr_data_o = control_tx_wr_data;
        end
    end

    primer1_btp_endpoint_deploy #(
        .CLOCK_HZ(CLOCK_HZ),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_control_endpoint (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .transport_zeroize_i(transport_zeroize_i),
        .secure_enable_i(secure_enable_i),
        .fatal_latched_i(fatal_latched_i),
        .request_valid_i(control_request_valid),
        .request_accept_o(control_request_accept),
        // Make PQC opcodes unreachable inside the legacy control endpoint.
        .request_opcode_i(route_pqc ? OP_GET_STATUS : request_opcode_i),
        .request_flags_i(request_flags_i),
        .request_transaction_id_i(request_transaction_id_i),
        .request_payload_len_i(request_payload_len_i),
        .request_crc32_i(request_crc32_i),
        .request_error_i(routed_request_error),
        .request_error_code_i(routed_request_error_code),
        .request_payload_rd_addr_o(control_payload_addr),
        .request_payload_rd_data_i(request_payload_rd_data_i),
        .tx_frame_ready_i(tx_frame_ready_i),
        .tx_frame_consumed_i(tx_frame_consumed_i),
        .tx_frame_commit_o(control_tx_commit),
        .tx_frame_len_o(control_tx_len),
        .tx_wr_en_o(control_tx_wr_en),
        .tx_wr_addr_o(control_tx_wr_addr),
        .tx_wr_data_o(control_tx_wr_data),
        .irq_pending_o(control_irq),
        .busy_o(control_busy),
        .key_valid_o(control_key_valid),
        .session_active_o(control_session_active),
        .retained_packet_o(control_retained),
        .ntt_busy_o(control_ntt_busy_unused),
        .last_error_code_o(control_last_error)
    );

    primer1_pqc_btp_endpoint #(
        .CLOCK_HZ(CLOCK_HZ),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_pqc_endpoint (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(transport_zeroize_i || fatal_latched_i),
        .request_valid_i(pqc_request_valid),
        .request_accept_o(pqc_request_accept),
        .request_opcode_i(request_opcode_i),
        .request_transaction_id_i(request_transaction_id_i),
        .request_payload_len_i(request_payload_len_i),
        .request_crc32_i(request_crc32_i),
        .request_error_i(routed_request_error),
        .request_error_code_i(routed_request_error_code),
        .request_payload_rd_addr_o(pqc_payload_addr),
        .request_payload_rd_data_i(request_payload_rd_data_i),
        .tx_frame_ready_i(tx_frame_ready_i),
        .tx_frame_commit_o(pqc_tx_commit),
        .tx_frame_len_o(pqc_tx_len),
        .tx_wr_en_o(pqc_tx_wr_en),
        .tx_wr_addr_o(pqc_tx_wr_addr),
        .tx_wr_data_o(pqc_tx_wr_data),
        .busy_o(pqc_endpoint_busy),
        .accelerator_busy_o(pqc_busy_o),
        .polynomial_domain_o(pqc_domain_o),
        .polynomial_complete_o(pqc_complete_o),
        .last_error_code_o(pqc_last_error)
    );

    assign irq_pending_o = tx_frame_ready_i;
    assign busy_o = control_busy || pqc_endpoint_busy;
    assign key_valid_o = control_key_valid;
    assign session_active_o = control_session_active;
    assign retained_packet_o = control_retained;
    assign last_error_code_o = (pqc_last_error != ERR_OK) ? pqc_last_error
                                                          : control_last_error;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            active_q <= 1'b0;
            select_pqc_q <= 1'b0;
            active_collision_q <= 1'b0;
            active_duplicate_q <= 1'b0;
            active_transaction_id_q <= '0;
            active_opcode_q <= '0;
            active_payload_len_q <= '0;
            active_crc32_q <= '0;
            last_valid_q <= 1'b0;
            last_select_pqc_q <= 1'b0;
            last_transaction_id_q <= '0;
            last_opcode_q <= '0;
            last_payload_len_q <= '0;
            last_crc32_q <= '0;
            last_age_q <= '0;
        end else begin
            if (!active_q && request_valid_i) begin
                active_q <= 1'b1;
                select_pqc_q <= current_duplicate ? last_select_pqc_q : current_is_pqc;
                active_collision_q <= current_collision;
                active_duplicate_q <= current_duplicate;
                active_transaction_id_q <= request_transaction_id_i;
                active_opcode_q <= request_opcode_i;
                active_payload_len_q <= request_payload_len_i;
                active_crc32_q <= request_crc32_i;
            end

            if (active_q && tx_frame_commit_o && !active_collision_q) begin
                last_valid_q <= 1'b1;
                last_select_pqc_q <= select_pqc_q;
                last_transaction_id_q <= active_transaction_id_q;
                last_opcode_q <= active_opcode_q;
                last_payload_len_q <= active_payload_len_q;
                last_crc32_q <= active_crc32_q;
                last_age_q <= '0;
            end else if (last_valid_q) begin
                if (last_age_q >= LAST_CYCLES-1) begin
                    last_valid_q <= 1'b0;
                    last_age_q <= '0;
                end else
                    last_age_q <= last_age_q + 1'b1;
            end else
                last_age_q <= '0;

            if (active_q && tx_frame_consumed_i) begin
                active_q <= 1'b0;
                active_collision_q <= 1'b0;
                active_duplicate_q <= 1'b0;
            end

            if (transport_zeroize_i) begin
                active_q <= 1'b0;
                active_collision_q <= 1'b0;
                active_duplicate_q <= 1'b0;
                last_valid_q <= 1'b0;
                last_age_q <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(control_tx_wr_en && pqc_tx_wr_en))
                else $error("primer1_endpoint_router: simultaneous TX writers");
            assert (!(control_tx_commit && pqc_tx_commit))
                else $error("primer1_endpoint_router: simultaneous TX commits");
            if (active_q && select_pqc_q)
                assert (!control_request_valid)
                    else $error("primer1_endpoint_router: control endpoint saw PQC request");
            if (active_q && !select_pqc_q)
                assert (!pqc_request_valid)
                    else $error("primer1_endpoint_router: PQC endpoint saw control request");
        end
    end
`endif

    logic unused_control_outputs;
    always_comb unused_control_outputs = ^{control_irq,control_ntt_busy_unused,
                                           active_duplicate_q};
endmodule
