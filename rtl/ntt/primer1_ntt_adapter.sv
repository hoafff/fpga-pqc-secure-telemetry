module primer1_ntt_adapter (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        forward_load_i,
    input  logic        forward_read_i,
    input  logic        forward_start_i,
    input  logic        inverse_load_i,
    input  logic        inverse_read_i,
    input  logic        inverse_start_i,
    input  logic [7:0]  addr_i,
    input  logic [15:0] coeff_i,

    output logic        command_ready_o,
    output logic        read_valid_o,
    output logic [15:0] read_data_o,
    output logic        operation_done_o,
    output logic        forward_busy_o,
    output logic        inverse_busy_o,
    output logic [15:0] error_code_o,
    output logic        error_valid_o
);
    localparam logic [15:0] ERR_BUSY        = 16'h0301;
    localparam logic [15:0] ERR_COEFF_RANGE = 16'h0401;

    logic f_host_re, f_host_we, f_host_ready, f_host_rvalid;
    logic [15:0] f_host_rdata;
    logic f_start, f_done;
    logic [2:0] f_stage;
    logic f_barrier, f_bank;

    logic i_host_re, i_host_we, i_host_ready, i_host_rvalid;
    logic [15:0] i_host_rdata;
    logic i_start, i_done;
    logic [2:0] i_stage;

    assign f_host_re = forward_read_i && !forward_busy_o;
    assign f_host_we = forward_load_i && !forward_busy_o && (coeff_i < 16'd3329);
    assign f_start   = forward_start_i && !forward_busy_o && !inverse_busy_o;

    assign i_host_re = inverse_read_i && !inverse_busy_o;
    assign i_host_we = inverse_load_i && !inverse_busy_o && (coeff_i < 16'd3329);
    assign i_start   = inverse_start_i && !inverse_busy_o && !forward_busy_o;

    assign command_ready_o = !forward_busy_o && !inverse_busy_o;
    assign read_valid_o = f_host_rvalid || i_host_rvalid;
    assign read_data_o = f_host_rvalid ? f_host_rdata : i_host_rdata;
    assign operation_done_o = f_done || i_done;

    forward_ntt_core u_forward (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .start_i          (f_start),
        .busy_o           (forward_busy_o),
        .done_o           (f_done),
        .host_re_i        (f_host_re),
        .host_we_i        (f_host_we),
        .host_addr_i      (addr_i),
        .host_wdata_i     (coeff_i),
        .host_ready_o     (f_host_ready),
        .host_rvalid_o    (f_host_rvalid),
        .host_rdata_o     (f_host_rdata),
        .stage_o          (f_stage),
        .stage_barrier_o  (f_barrier),
        .active_bank_o    (f_bank)
    );

    inverse_ntt_core u_inverse (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .start_i       (i_start),
        .busy_o        (inverse_busy_o),
        .done_o        (i_done),
        .host_re_i     (i_host_re),
        .host_we_i     (i_host_we),
        .host_addr_i   (addr_i),
        .host_wdata_i  (coeff_i),
        .host_ready_o  (i_host_ready),
        .host_rvalid_o (i_host_rvalid),
        .host_rdata_o  (i_host_rdata),
        .stage_o       (i_stage)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;
        end else begin
            error_valid_o <= 1'b0;
            error_code_o  <= 16'h0000;

            if ((forward_load_i || inverse_load_i) && (coeff_i >= 16'd3329)) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_COEFF_RANGE;
            end else if ((forward_load_i || forward_read_i || forward_start_i) &&
                         forward_busy_o) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_BUSY;
            end else if ((inverse_load_i || inverse_read_i || inverse_start_i) &&
                         inverse_busy_o) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_BUSY;
            end else if ((forward_start_i && inverse_busy_o) ||
                         (inverse_start_i && forward_busy_o)) begin
                error_valid_o <= 1'b1;
                error_code_o  <= ERR_BUSY;
            end
        end
    end

`ifndef SYNTHESIS
    logic unused_status;
    always_comb begin
        unused_status = f_host_ready ^ i_host_ready ^ (^f_stage) ^ f_barrier ^
                        f_bank ^ (^i_stage);
    end
`endif
endmodule
