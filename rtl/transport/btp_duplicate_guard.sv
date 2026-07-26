module btp_duplicate_guard #(
    parameter integer MAX_FRAME_BYTES = 1038,
    parameter integer CACHE_CYCLES = 27_000_000
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        zeroize_i,

    input  logic        check_i,
    input  logic [10:0] frame_len_i,
    input  logic [15:0] transaction_id_i,
    input  logic [7:0]  opcode_i,
    output logic [10:0] req_raddr_o,
    input  logic [7:0]  req_rdata_i,

    /* Assert after the corresponding response has been fully committed to the
     * SPI response cache. This starts the 1000 ms cache lifetime. */
    input  logic        response_ready_i,

    output logic        busy_o,
    output logic        decision_valid_o,
    output logic        new_request_o,
    output logic        duplicate_o,
    output logic        collision_o,
    output logic        cache_valid_o
);
    typedef enum logic [2:0] {
        D_IDLE,
        D_CHECK_READ,
        D_CHECK_COMPARE,
        D_COPY,
        D_DECIDE
    } state_t;

    state_t state_q;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [7:0] cached_request_mem [0:MAX_FRAME_BYTES-1];

    logic [10:0] index_q;
    logic [7:0] cached_byte_q;
    logic [10:0] cached_len_q;
    logic [15:0] cached_txid_q;
    logic [7:0] cached_opcode_q;
    logic cache_valid_q;
    logic cache_pending_q;
    logic [31:0] age_q;

    logic decision_new_q;
    logic decision_duplicate_q;
    logic decision_collision_q;

    assign req_raddr_o = index_q;
    assign busy_o = (state_q != D_IDLE);
    assign cache_valid_o = cache_valid_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni || zeroize_i) begin
            state_q                <= D_IDLE;
            index_q                <= '0;
            cached_byte_q          <= '0;
            cached_len_q           <= '0;
            cached_txid_q          <= '0;
            cached_opcode_q        <= '0;
            cache_valid_q          <= 1'b0;
            cache_pending_q        <= 1'b0;
            age_q                  <= '0;
            decision_new_q         <= 1'b0;
            decision_duplicate_q   <= 1'b0;
            decision_collision_q   <= 1'b0;
            decision_valid_o       <= 1'b0;
            new_request_o          <= 1'b0;
            duplicate_o            <= 1'b0;
            collision_o            <= 1'b0;
        end else begin
            /* Decision values are held stable after decision_valid_o pulses.
             * Consumers MUST qualify them with decision_valid_o. Holding the
             * values avoids a one-cycle diagnostic race with registered actions
             * taken from the decision on the following edge. */
            decision_valid_o <= 1'b0;

            if (cache_valid_q) begin
                if (age_q >= CACHE_CYCLES-1) begin
                    cache_valid_q <= 1'b0;
                    age_q <= '0;
                end else begin
                    age_q <= age_q + 32'd1;
                end
            end

            if (response_ready_i && cache_pending_q) begin
                cache_valid_q   <= 1'b1;
                cache_pending_q <= 1'b0;
                age_q           <= '0;
            end

            case (state_q)
                D_IDLE: begin
                    if (check_i) begin
                        decision_new_q       <= 1'b0;
                        decision_duplicate_q <= 1'b0;
                        decision_collision_q <= 1'b0;
                        index_q <= 11'd0;

                        if (cache_valid_q &&
                            transaction_id_i == cached_txid_q) begin
                            if ((frame_len_i != cached_len_q) ||
                                (opcode_i != cached_opcode_q)) begin
                                /* Replace the one-entry cache with this colliding
                                 * request once its collision response is built. */
                                decision_collision_q <= 1'b1;
                                cache_valid_q <= 1'b0;
                                state_q <= D_COPY;
                            end else begin
                                state_q <= D_CHECK_READ;
                            end
                        end else begin
                            decision_new_q <= 1'b1;
                            cache_valid_q <= 1'b0;
                            state_q <= D_COPY;
                        end
                    end
                end

                D_CHECK_READ: begin
                    cached_byte_q <= cached_request_mem[index_q];
                    state_q <= D_CHECK_COMPARE;
                end

                D_CHECK_COMPARE: begin
                    if (cached_byte_q != req_rdata_i) begin
                        decision_collision_q <= 1'b1;
                        cache_valid_q <= 1'b0;
                        index_q <= 11'd0;
                        state_q <= D_COPY;
                    end else if (index_q == frame_len_i - 11'd1) begin
                        decision_duplicate_q <= 1'b1;
                        state_q <= D_DECIDE;
                    end else begin
                        index_q <= index_q + 11'd1;
                        state_q <= D_CHECK_READ;
                    end
                end

                D_COPY: begin
                    cached_request_mem[index_q] <= req_rdata_i;
                    if (index_q == frame_len_i - 11'd1) begin
                        cached_len_q    <= frame_len_i;
                        cached_txid_q   <= transaction_id_i;
                        cached_opcode_q <= opcode_i;
                        cache_pending_q <= 1'b1;
                        state_q <= D_DECIDE;
                    end else begin
                        index_q <= index_q + 11'd1;
                    end
                end

                D_DECIDE: begin
                    decision_valid_o <= 1'b1;
                    new_request_o    <= decision_new_q;
                    duplicate_o      <= decision_duplicate_q;
                    collision_o      <= decision_collision_q;
                    state_q <= D_IDLE;
                end

                default: state_q <= D_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (MAX_FRAME_BYTES > 0 && MAX_FRAME_BYTES <= 2048)
            else $error("btp_duplicate_guard: invalid frame size");
        assert (CACHE_CYCLES > 0)
            else $error("btp_duplicate_guard: invalid cache lifetime");
    end
`endif
endmodule
