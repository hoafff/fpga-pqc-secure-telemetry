module primer1_request_semantic_guard (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic zeroize_i,

    /* Raw request held by btp_request_parser until raw_accept_o. */
    input  logic raw_valid_i,
    output logic raw_accept_o,
    input  logic [7:0] raw_opcode_i,
    input  logic [15:0] raw_payload_len_i,
    input  logic raw_error_i,
    input  logic [15:0] raw_error_code_i,

    /* Shared immutable request payload RAM read port. */
    output logic [9:0] payload_rd_addr_o,
    input  logic [7:0] payload_rd_data_i,
    input  logic [9:0] endpoint_payload_rd_addr_i,

    /* Guarded request presented to the Primer #1 command endpoint. */
    output logic guarded_valid_o,
    input  logic guarded_accept_i,
    output logic guarded_error_o,
    output logic [15:0] guarded_error_code_o
);
    import fpst_btp_pkg::*;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_POLY_COUNT_HI,
        ST_POLY_COUNT_LO,
        ST_HOLD
    } state_t;

    state_t state_q;
    logic [7:0] poly_count_hi_q;
    logic semantic_error_q;
    logic [15:0] semantic_error_code_q;
    logic [15:0] observed_poly_count;
    logic [17:0] expected_poly_payload_len;

    assign observed_poly_count = {poly_count_hi_q, payload_rd_data_i};
    assign expected_poly_payload_len = 18'd2 +
                                       ({2'b00, observed_poly_count} << 1);

    assign guarded_valid_o = (state_q == ST_HOLD) && raw_valid_i;
    assign guarded_error_o = raw_error_i || semantic_error_q;
    assign guarded_error_code_o = raw_error_i
                                ? raw_error_code_i
                                : semantic_error_code_q;

    always_comb begin
        raw_accept_o = 1'b0;
        payload_rd_addr_o = endpoint_payload_rd_addr_i;

        case (state_q)
            ST_POLY_COUNT_HI:
                payload_rd_addr_o = 10'd0;
            ST_POLY_COUNT_LO:
                payload_rd_addr_o = 10'd1;
            ST_HOLD: begin
                if (guarded_accept_i)
                    raw_accept_o = 1'b1;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            poly_count_hi_q <= 8'h00;
            semantic_error_q <= 1'b0;
            semantic_error_code_q <= ERR_OK;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    semantic_error_q <= 1'b0;
                    semantic_error_code_q <= ERR_OK;
                    if (raw_valid_i) begin
                        /*
                         * The command endpoint's forward-NTT RAM has exactly
                         * 256 coefficients. Validate the full BE16 count here
                         * before that endpoint is allowed to see the request.
                         */
                        if (!raw_error_i && raw_opcode_i == OP_PQC_LOAD_POLY)
                            state_q <= ST_POLY_COUNT_HI;
                        else
                            state_q <= ST_HOLD;
                    end
                end

                ST_POLY_COUNT_HI: begin
                    poly_count_hi_q <= payload_rd_data_i;
                    state_q <= ST_POLY_COUNT_LO;
                end

                ST_POLY_COUNT_LO: begin
                    if (observed_poly_count == 16'd0 ||
                        observed_poly_count > 16'd256 ||
                        raw_payload_len_i < 16'd4 ||
                        expected_poly_payload_len != {2'b00, raw_payload_len_i}) begin
                        semantic_error_q <= 1'b1;
                        semantic_error_code_q <= ERR_PQC_LENGTH;
                    end
                    state_q <= ST_HOLD;
                end

                ST_HOLD: begin
                    if (guarded_accept_i) begin
                        poly_count_hi_q <= 8'h00;
                        semantic_error_q <= 1'b0;
                        semantic_error_code_q <= ERR_OK;
                        state_q <= ST_IDLE;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase

            if (zeroize_i) begin
                state_q <= ST_IDLE;
                poly_count_hi_q <= 8'h00;
                semantic_error_q <= 1'b0;
                semantic_error_code_q <= ERR_OK;
            end
        end
    end
endmodule
