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

    output logic [2:0]  stage_o,
    output logic        stage_barrier_o,
    output logic        active_bank_o
);
    // ML-KEM inverse NTT matching the repository's forward transform:
    //   forward lengths: 128,64,32,16,8,4,2 with zeta addresses 1..127
    //   inverse lengths: 2,4,8,16,32,64,128 with zeta addresses 127..1
    //   final normalization: multiply every coefficient by 128^-1 mod 3329.
    //
    // Arithmetic is canonical standard-domain arithmetic, matching
    // twiddle_rom_3329 and mod_mul_3329_pipe. 128^-1 mod 3329 = 3303.
    //
    // The implementation intentionally prioritizes BRAM-safe deployment over
    // maximum throughput. One butterfly is retired at a time and the existing
    // ping-pong coefficient memory swaps only after the last write of a stage.

    localparam logic [15:0] Q = 16'd3329;
    localparam logic [15:0] INV_128 = 16'd3303;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_BFLY_READ,
        ST_BFLY_WAIT_INPUT,
        ST_BFLY_WAIT_MUL,
        ST_NORM_READ,
        ST_NORM_WAIT_READ,
        ST_NORM_LEFT_START,
        ST_NORM_LEFT_WAIT,
        ST_NORM_RIGHT_START,
        ST_NORM_RIGHT_WAIT
    } state_t;

    state_t state_q;
    logic running_q;

    logic [7:0] length_q;
    logic [7:0] group_start_q;
    logic [7:0] offset_q;
    logic [6:0] zeta_addr_q;
    logic [2:0] stage_q;

    logic [7:0] norm_index_q;

    logic [15:0] held_left_q;
    logic [15:0] held_right_q;
    logic [15:0] held_zeta_q;
    logic        have_memory_q;
    logic        have_twiddle_q;
    logic [15:0] sum_q;
    logic [15:0] norm_left_q;

    logic memory_core_re;
    logic [7:0] memory_left_raddr;
    logic [7:0] memory_right_raddr;
    logic memory_rvalid;
    logic [15:0] memory_left_data;
    logic [15:0] memory_right_data;
    logic memory_core_we;
    logic [7:0] memory_left_waddr;
    logic [7:0] memory_right_waddr;
    logic [15:0] memory_left_wdata;
    logic [15:0] memory_right_wdata;
    logic memory_swap;
    logic memory_active_bank;

    logic twiddle_req;
    logic twiddle_valid;
    logic [15:0] twiddle_data;

    logic mul_valid_i;
    logic [15:0] mul_a_i;
    logic [15:0] mul_b_i;
    logic mul_valid_o;
    logic [15:0] mul_y_o;

    logic [15:0] selected_left;
    logic [15:0] selected_right;
    logic [15:0] selected_zeta;
    logic selected_inputs_valid;

    logic [7:0] butterfly_left_addr;
    logic [7:0] butterfly_right_addr;
    logic butterfly_group_last;
    logic butterfly_stage_last;
    logic normalization_last;

    function automatic logic [15:0] mod_add_q(
        input logic [15:0] a,
        input logic [15:0] b
    );
        logic [16:0] s;
        begin
            s = {1'b0,a} + {1'b0,b};
            if (s >= Q)
                mod_add_q = s - Q;
            else
                mod_add_q = s[15:0];
        end
    endfunction

    function automatic logic [15:0] mod_sub_q(
        input logic [15:0] a,
        input logic [15:0] b
    );
        begin
            if (a >= b)
                mod_sub_q = a - b;
            else
                mod_sub_q = a + Q - b;
        end
    endfunction

    assign butterfly_left_addr  = group_start_q + offset_q;
    assign butterfly_right_addr = butterfly_left_addr + length_q;
    assign butterfly_group_last = (offset_q == (length_q - 1'b1));
    assign butterfly_stage_last = butterfly_group_last &&
                                  ((group_start_q + (length_q << 1)) >= 9'd256);
    assign normalization_last = (norm_index_q == 8'd254);

    assign selected_left  = memory_rvalid ? memory_left_data  : held_left_q;
    assign selected_right = memory_rvalid ? memory_right_data : held_right_q;
    assign selected_zeta  = twiddle_valid ? twiddle_data      : held_zeta_q;
    assign selected_inputs_valid = (have_memory_q || memory_rvalid) &&
                                   (have_twiddle_q || twiddle_valid);

    assign busy_o = running_q;
    assign host_ready_o = !running_q;
    assign stage_o = stage_q;
    assign stage_barrier_o = memory_swap;
    assign active_bank_o = memory_active_bank;

    always_comb begin
        memory_core_re      = 1'b0;
        memory_left_raddr   = 8'h00;
        memory_right_raddr  = 8'h01;
        memory_core_we      = 1'b0;
        memory_left_waddr   = 8'h00;
        memory_right_waddr  = 8'h01;
        memory_left_wdata   = 16'h0000;
        memory_right_wdata  = 16'h0000;
        memory_swap         = 1'b0;
        twiddle_req         = 1'b0;

        mul_valid_i = 1'b0;
        mul_a_i     = 16'h0000;
        mul_b_i     = 16'h0000;

        case (state_q)
            ST_BFLY_READ: begin
                memory_core_re     = 1'b1;
                memory_left_raddr  = butterfly_left_addr;
                memory_right_raddr = butterfly_right_addr;
                twiddle_req        = 1'b1;
            end

            ST_BFLY_WAIT_INPUT: begin
                if (selected_inputs_valid) begin
                    mul_valid_i = 1'b1;
                    // Inverse butterfly:
                    // left  = a+b
                    // right = zeta*(b-a)
                    mul_a_i = mod_sub_q(selected_right, selected_left);
                    mul_b_i = selected_zeta;
                end
            end

            ST_BFLY_WAIT_MUL: begin
                if (mul_valid_o) begin
                    memory_core_we     = 1'b1;
                    memory_left_waddr  = butterfly_left_addr;
                    memory_right_waddr = butterfly_right_addr;
                    memory_left_wdata  = sum_q;
                    memory_right_wdata = mul_y_o;
                    memory_swap        = butterfly_stage_last;
                end
            end

            ST_NORM_READ: begin
                memory_core_re     = 1'b1;
                memory_left_raddr  = norm_index_q;
                memory_right_raddr = norm_index_q + 1'b1;
            end

            ST_NORM_LEFT_START: begin
                mul_valid_i = 1'b1;
                mul_a_i     = held_left_q;
                mul_b_i     = INV_128;
            end

            ST_NORM_RIGHT_START: begin
                mul_valid_i = 1'b1;
                mul_a_i     = held_right_q;
                mul_b_i     = INV_128;
            end

            ST_NORM_RIGHT_WAIT: begin
                if (mul_valid_o) begin
                    memory_core_we     = 1'b1;
                    memory_left_waddr  = norm_index_q;
                    memory_right_waddr = norm_index_q + 1'b1;
                    memory_left_wdata  = norm_left_q;
                    memory_right_wdata = mul_y_o;
                    memory_swap        = normalization_last;
                end
            end

            default: begin
            end
        endcase
    end

    coefficient_pingpong_memory_256x16 u_coefficient_memory (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .host_re_i      (host_re_i && host_ready_o),
        .host_we_i      (host_we_i && host_ready_o),
        .host_addr_i    (host_addr_i),
        .host_wdata_i   (host_wdata_i),
        .host_rvalid_o  (host_rvalid_o),
        .host_rdata_o   (host_rdata_o),
        .core_re_i      (memory_core_re),
        .left_raddr_i   (memory_left_raddr),
        .right_raddr_i  (memory_right_raddr),
        .core_rvalid_o  (memory_rvalid),
        .left_rdata_o   (memory_left_data),
        .right_rdata_o  (memory_right_data),
        .core_we_i      (memory_core_we),
        .left_waddr_i   (memory_left_waddr),
        .right_waddr_i  (memory_right_waddr),
        .left_wdata_i   (memory_left_wdata),
        .right_wdata_i  (memory_right_wdata),
        .swap_i         (memory_swap),
        .active_bank_o  (memory_active_bank)
    );

    twiddle_rom_3329 u_twiddle_rom (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (twiddle_req),
        .addr_i  (zeta_addr_q),
        .valid_o (twiddle_valid),
        .zeta_o  (twiddle_data)
    );

    mod_mul_3329_pipe u_multiplier (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .valid_i (mul_valid_i),
        .a_i     (mul_a_i),
        .b_i     (mul_b_i),
        .valid_o (mul_valid_o),
        .y_o     (mul_y_o)
    );

    wire start_accept = start_i && !running_q && !host_re_i && !host_we_i;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q          <= ST_IDLE;
            running_q        <= 1'b0;
            done_o           <= 1'b0;
            length_q         <= 8'd2;
            group_start_q    <= 8'd0;
            offset_q         <= 8'd0;
            zeta_addr_q      <= 7'd127;
            stage_q          <= 3'd0;
            norm_index_q     <= 8'd0;
            held_left_q      <= 16'h0000;
            held_right_q     <= 16'h0000;
            held_zeta_q      <= 16'h0000;
            have_memory_q    <= 1'b0;
            have_twiddle_q   <= 1'b0;
            sum_q            <= 16'h0000;
            norm_left_q      <= 16'h0000;
        end else begin
            done_o <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_accept) begin
                        running_q      <= 1'b1;
                        length_q       <= 8'd2;
                        group_start_q  <= 8'd0;
                        offset_q       <= 8'd0;
                        zeta_addr_q    <= 7'd127;
                        stage_q        <= 3'd0;
                        have_memory_q  <= 1'b0;
                        have_twiddle_q <= 1'b0;
                        state_q        <= ST_BFLY_READ;
                    end
                end

                ST_BFLY_READ: begin
                    have_memory_q  <= 1'b0;
                    have_twiddle_q <= 1'b0;
                    state_q        <= ST_BFLY_WAIT_INPUT;
                end

                ST_BFLY_WAIT_INPUT: begin
                    if (memory_rvalid) begin
                        held_left_q   <= memory_left_data;
                        held_right_q  <= memory_right_data;
                        have_memory_q <= 1'b1;
                    end
                    if (twiddle_valid) begin
                        held_zeta_q    <= twiddle_data;
                        have_twiddle_q <= 1'b1;
                    end

                    if (selected_inputs_valid) begin
                        sum_q           <= mod_add_q(selected_left, selected_right);
                        have_memory_q   <= 1'b0;
                        have_twiddle_q  <= 1'b0;
                        state_q         <= ST_BFLY_WAIT_MUL;
                    end
                end

                ST_BFLY_WAIT_MUL: begin
                    if (mul_valid_o) begin
                        if (butterfly_group_last) begin
                            zeta_addr_q <= zeta_addr_q - 1'b1;
                            offset_q    <= 8'd0;

                            if (butterfly_stage_last) begin
                                group_start_q <= 8'd0;
                                if (length_q == 8'd128) begin
                                    // Seven inverse stages are complete. The
                                    // final stage write swaps the banks here;
                                    // normalization reads that new active bank.
                                    stage_q      <= 3'd7;
                                    norm_index_q <= 8'd0;
                                    state_q      <= ST_NORM_READ;
                                end else begin
                                    length_q      <= length_q << 1;
                                    stage_q       <= stage_q + 1'b1;
                                    state_q       <= ST_BFLY_READ;
                                end
                            end else begin
                                group_start_q <= group_start_q + (length_q << 1);
                                state_q       <= ST_BFLY_READ;
                            end
                        end else begin
                            offset_q <= offset_q + 1'b1;
                            state_q  <= ST_BFLY_READ;
                        end
                    end
                end

                ST_NORM_READ: begin
                    state_q <= ST_NORM_WAIT_READ;
                end

                ST_NORM_WAIT_READ: begin
                    if (memory_rvalid) begin
                        held_left_q  <= memory_left_data;
                        held_right_q <= memory_right_data;
                        state_q      <= ST_NORM_LEFT_START;
                    end
                end

                ST_NORM_LEFT_START: begin
                    state_q <= ST_NORM_LEFT_WAIT;
                end

                ST_NORM_LEFT_WAIT: begin
                    if (mul_valid_o) begin
                        norm_left_q <= mul_y_o;
                        state_q     <= ST_NORM_RIGHT_START;
                    end
                end

                ST_NORM_RIGHT_START: begin
                    state_q <= ST_NORM_RIGHT_WAIT;
                end

                ST_NORM_RIGHT_WAIT: begin
                    if (mul_valid_o) begin
                        if (normalization_last) begin
                            running_q <= 1'b0;
                            done_o    <= 1'b1;
                            state_q   <= ST_IDLE;
                        end else begin
                            norm_index_q <= norm_index_q + 8'd2;
                            state_q      <= ST_NORM_READ;
                        end
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if (start_i && running_q)
                assert (!start_accept)
                    else $error("inverse_ntt_core: start accepted while busy");

            if (memory_core_we) begin
                assert (memory_left_wdata < Q)
                    else $error("inverse_ntt_core: non-canonical left write %0d",
                                memory_left_wdata);
                assert (memory_right_wdata < Q)
                    else $error("inverse_ntt_core: non-canonical right write %0d",
                                memory_right_wdata);
            end

            if (memory_swap)
                assert (memory_core_we)
                    else $error("inverse_ntt_core: bank swap without writeback");
        end
    end
`endif
endmodule
