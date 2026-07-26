module inverse_ntt_core (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_i,
    output logic        busy_o,
    output logic        done_o,

    input  logic        host_re_i,
    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_ready_o,
    output logic        host_rvalid_o,
    output logic [15:0] host_rdata_o,

    output logic [2:0]  stage_o
);
    /*
     * Standard-domain inverse of forward_ntt_core.
     *
     * k = 127
     * for (len = 2; len <= 128; len <<= 1)
     *   for each group {
     *     zeta = zetas[k--]
     *     for j in group:
     *       t = a
     *       a = a + b mod q
     *       b = (b - t) * zeta mod q
     *   }
     * output[i] *= 128^-1 mod 3329 = 3303
     *
     * The twiddle generator in this repository explicitly locks the inverse
     * schedule to addresses 127..1. A true-dual-port BRAM stores coefficients;
     * one butterfly is retired at a time to keep the implementation compact.
     */

    localparam logic [15:0] INV_128 = 16'd3303;

    typedef enum logic [3:0] {
        S_IDLE,
        S_READ,
        S_WAIT_TWIDDLE,
        S_WAIT_MUL,
        S_WRITE,
        S_SCALE_READ,
        S_SCALE_LAUNCH,
        S_SCALE_WAIT,
        S_SCALE_WRITE,
        S_DONE
    } state_t;

    state_t state_q;

    logic [7:0] length_q;
    logic [7:0] group_start_q;
    logic [7:0] left_addr_q;
    logic [6:0] zeta_addr_q;
    logic [2:0] stage_q;
    logic [7:0] scale_addr_q;

    logic [15:0] left_q, right_q;
    logic [15:0] sum_q;
    logic [15:0] product_q;
    logic        host_read_pending_q;

    logic ram_a_en, ram_a_we;
    logic [7:0] ram_a_addr;
    logic [15:0] ram_a_wdata, ram_a_rdata;
    logic ram_b_en, ram_b_we;
    logic [7:0] ram_b_addr;
    logic [15:0] ram_b_wdata, ram_b_rdata;

    logic twiddle_valid_i;
    logic twiddle_valid_o;
    logic [15:0] twiddle_data;

    logic mul_valid_i;
    logic mul_valid_o;
    logic [15:0] mul_a, mul_b, mul_y;

    logic [15:0] add_y;
    logic [15:0] sub_y;

    wire [8:0] group_end = {1'b0, group_start_q} +
                           ({1'b0, length_q} << 1);
    wire [8:0] next_group_start = group_end;
    wire [8:0] right_addr_ext = {1'b0, left_addr_q} + {1'b0, length_q};
    wire current_group_last =
        ({1'b0, left_addr_q} + 9'd1) ==
        ({1'b0, group_start_q} + {1'b0, length_q});

    assign busy_o = (state_q != S_IDLE) && (state_q != S_DONE);
    assign host_ready_o = (state_q == S_IDLE);
    assign stage_o = stage_q;

    true_dual_port_ram_256x16 u_coeff_ram (
        .clk_i      (clk_i),
        .a_en_i     (ram_a_en),
        .a_we_i     (ram_a_we),
        .a_addr_i   (ram_a_addr),
        .a_wdata_i  (ram_a_wdata),
        .a_rdata_o  (ram_a_rdata),
        .b_en_i     (ram_b_en),
        .b_we_i     (ram_b_we),
        .b_addr_i   (ram_b_addr),
        .b_wdata_i  (ram_b_wdata),
        .b_rdata_o  (ram_b_rdata)
    );

    twiddle_rom_3329 u_twiddle (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (twiddle_valid_i),
        .addr_i  (zeta_addr_q),
        .valid_o (twiddle_valid_o),
        .zeta_o  (twiddle_data)
    );

    mod_add #(.WIDTH(16), .MODULUS(3329)) u_add (
        .a_i(left_q), .b_i(right_q), .y_o(add_y)
    );

    mod_sub #(.WIDTH(16), .MODULUS(3329)) u_sub (
        .a_i(right_q), .b_i(left_q), .y_o(sub_y)
    );

    mod_mul_3329_pipe u_mul (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (mul_valid_i),
        .a_i     (mul_a),
        .b_i     (mul_b),
        .valid_o (mul_valid_o),
        .y_o     (mul_y)
    );

    always_comb begin
        ram_a_en    = 1'b0;
        ram_a_we    = 1'b0;
        ram_a_addr  = 8'h00;
        ram_a_wdata = 16'h0000;
        ram_b_en    = 1'b0;
        ram_b_we    = 1'b0;
        ram_b_addr  = 8'h00;
        ram_b_wdata = 16'h0000;

        twiddle_valid_i = 1'b0;
        mul_valid_i     = 1'b0;
        mul_a           = 16'h0000;
        mul_b           = 16'h0000;

        if (state_q == S_IDLE) begin
            ram_a_en    = host_re_i || host_we_i;
            ram_a_we    = host_we_i;
            ram_a_addr  = host_addr_i;
            ram_a_wdata = host_wdata_i;
        end else if (state_q == S_READ) begin
            ram_a_en   = 1'b1;
            ram_a_addr = left_addr_q;
            ram_b_en   = 1'b1;
            ram_b_addr = right_addr_ext[7:0];
            twiddle_valid_i = 1'b1;
        end else if (state_q == S_WAIT_TWIDDLE && twiddle_valid_o) begin
            mul_valid_i = 1'b1;
            mul_a       = sub_y;
            mul_b       = twiddle_data;
        end else if (state_q == S_WRITE) begin
            ram_a_en    = 1'b1;
            ram_a_we    = 1'b1;
            ram_a_addr  = left_addr_q;
            ram_a_wdata = sum_q;
            ram_b_en    = 1'b1;
            ram_b_we    = 1'b1;
            ram_b_addr  = right_addr_ext[7:0];
            ram_b_wdata = product_q;
        end else if (state_q == S_SCALE_READ) begin
            ram_a_en   = 1'b1;
            ram_a_addr = scale_addr_q;
        end else if (state_q == S_SCALE_LAUNCH) begin
            /* ram_a_rdata is the synchronous result of S_SCALE_READ. */
            mul_valid_i = 1'b1;
            mul_a       = ram_a_rdata;
            mul_b       = INV_128;
        end else if (state_q == S_SCALE_WRITE) begin
            ram_a_en    = 1'b1;
            ram_a_we    = 1'b1;
            ram_a_addr  = scale_addr_q;
            ram_a_wdata = product_q;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q             <= S_IDLE;
            length_q            <= 8'd2;
            group_start_q       <= 8'd0;
            left_addr_q         <= 8'd0;
            zeta_addr_q         <= 7'd127;
            stage_q             <= 3'd0;
            scale_addr_q        <= 8'd0;
            left_q              <= 16'd0;
            right_q             <= 16'd0;
            sum_q               <= 16'd0;
            product_q           <= 16'd0;
            host_read_pending_q <= 1'b0;
            host_rvalid_o       <= 1'b0;
            host_rdata_o        <= 16'd0;
            done_o              <= 1'b0;
        end else begin
            host_rvalid_o <= 1'b0;
            done_o        <= 1'b0;

            if (host_read_pending_q) begin
                host_rdata_o        <= ram_a_rdata;
                host_rvalid_o       <= 1'b1;
                host_read_pending_q <= 1'b0;
            end
            if ((state_q == S_IDLE) && host_re_i)
                host_read_pending_q <= 1'b1;

            case (state_q)
                S_IDLE: begin
                    if (start_i && !host_re_i && !host_we_i &&
                        !host_read_pending_q) begin
                        length_q      <= 8'd2;
                        group_start_q <= 8'd0;
                        left_addr_q   <= 8'd0;
                        zeta_addr_q   <= 7'd127;
                        stage_q       <= 3'd0;
                        state_q       <= S_READ;
                    end
                end

                S_READ: begin
                    state_q <= S_WAIT_TWIDDLE;
                end

                S_WAIT_TWIDDLE: begin
                    /* Capture synchronous BRAM outputs while the ROM completes. */
                    left_q  <= ram_a_rdata;
                    right_q <= ram_b_rdata;
                    if (twiddle_valid_o) begin
                        sum_q   <= add_y;
                        state_q <= S_WAIT_MUL;
                    end
                end

                S_WAIT_MUL: begin
                    if (mul_valid_o) begin
                        product_q <= mul_y;
                        state_q   <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (!current_group_last) begin
                        left_addr_q <= left_addr_q + 8'd1;
                        state_q <= S_READ;
                    end else if (next_group_start < 9'd256) begin
                        group_start_q <= next_group_start[7:0];
                        left_addr_q   <= next_group_start[7:0];
                        zeta_addr_q   <= zeta_addr_q - 7'd1;
                        state_q       <= S_READ;
                    end else if (length_q != 8'd128) begin
                        length_q      <= length_q << 1;
                        group_start_q <= 8'd0;
                        left_addr_q   <= 8'd0;
                        zeta_addr_q   <= zeta_addr_q - 7'd1;
                        stage_q       <= stage_q + 3'd1;
                        state_q       <= S_READ;
                    end else begin
                        scale_addr_q <= 8'd0;
                        state_q      <= S_SCALE_READ;
                    end
                end

                S_SCALE_READ: begin
                    state_q <= S_SCALE_LAUNCH;
                end

                S_SCALE_LAUNCH: begin
                    state_q <= S_SCALE_WAIT;
                end

                S_SCALE_WAIT: begin
                    if (mul_valid_o) begin
                        product_q <= mul_y;
                        state_q   <= S_SCALE_WRITE;
                    end
                end

                S_SCALE_WRITE: begin
                    if (scale_addr_q == 8'hFF) begin
                        state_q <= S_DONE;
                    end else begin
                        scale_addr_q <= scale_addr_q + 8'd1;
                        state_q <= S_SCALE_READ;
                    end
                end

                S_DONE: begin
                    done_o  <= 1'b1;
                    state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && busy_o) begin
            assert (length_q == 8'd2 || length_q == 8'd4 ||
                    length_q == 8'd8 || length_q == 8'd16 ||
                    length_q == 8'd32 || length_q == 8'd64 ||
                    length_q == 8'd128)
                else $error("inverse_ntt_core: invalid length %0d", length_q);
            if (state_q == S_READ)
                assert (right_addr_ext < 9'd256)
                    else $error("inverse_ntt_core: address overflow");
        end
    end
`endif
endmodule
