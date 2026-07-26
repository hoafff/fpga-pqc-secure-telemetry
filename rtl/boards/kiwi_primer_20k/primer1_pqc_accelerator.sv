// Primer #1 NTT/INTT deployment service.
//
// Both verified transform cores own local ping-pong coefficient memories.
// Host writes are mirrored into both memories so either transform starts from
// the same staged polynomial. After any transform starts the staged image is
// considered consumed; all 256 addresses must be written again before the next
// transform. This prevents accidentally running the opposite core on a stale
// pre-transform image.
module primer1_pqc_accelerator (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_ntt_i,
    input  logic        start_intt_i,
    output logic        start_ready_o,
    output logic        busy_o,
    output logic        done_o,
    output logic        result_is_intt_o,

    input  logic        host_re_i,
    input  logic        host_we_i,
    input  logic [7:0]  host_addr_i,
    input  logic [15:0] host_wdata_i,
    output logic        host_ready_o,
    output logic        host_rvalid_o,
    output logic [15:0] host_rdata_o,
    output logic        staged_complete_o,

    output logic [2:0]  stage_o,
    output logic        stage_barrier_o,
    output logic        active_bank_o
);
    logic fwd_start;
    logic fwd_busy;
    logic fwd_done;
    logic fwd_ready;
    logic fwd_rvalid;
    logic [15:0] fwd_rdata;
    logic [2:0] fwd_stage;
    logic fwd_barrier;
    logic fwd_bank;

    logic inv_start;
    logic inv_busy;
    logic inv_done;
    logic inv_ready;
    logic inv_rvalid;
    logic [15:0] inv_rdata;
    logic [2:0] inv_stage;
    logic inv_barrier;
    logic inv_bank;

    logic [255:0] write_coverage_q;
    logic result_is_intt_q;

    wire cores_idle = !fwd_busy && !inv_busy;
    wire mirrored_host_ready = fwd_ready && inv_ready && cores_idle;
    wire accepted_host_write = host_we_i && mirrored_host_ready;
    wire accepted_start_ntt = start_ntt_i && start_ready_o;
    wire accepted_start_intt = start_intt_i && start_ready_o;

    assign staged_complete_o = &write_coverage_q;
    assign start_ready_o = cores_idle && staged_complete_o &&
                           !host_re_i && !host_we_i;
    assign busy_o = fwd_busy || inv_busy;
    assign done_o = fwd_done || inv_done;
    assign result_is_intt_o = result_is_intt_q;

    // Writes are mirrored into both local memories. Reads come only from the
    // result owner selected by the last accepted transform command.
    assign host_ready_o = mirrored_host_ready;
    assign host_rvalid_o = result_is_intt_q ? inv_rvalid : fwd_rvalid;
    assign host_rdata_o  = result_is_intt_q ? inv_rdata  : fwd_rdata;
    assign stage_o       = result_is_intt_q ? inv_stage  : fwd_stage;
    assign stage_barrier_o = result_is_intt_q ? inv_barrier : fwd_barrier;
    assign active_bank_o = result_is_intt_q ? inv_bank : fwd_bank;

    assign fwd_start = accepted_start_ntt;
    assign inv_start = accepted_start_intt;

    forward_ntt_core u_forward (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .start_i         (fwd_start),
        .busy_o          (fwd_busy),
        .done_o          (fwd_done),
        .host_re_i       (host_re_i && !result_is_intt_q),
        .host_we_i       (accepted_host_write),
        .host_addr_i     (host_addr_i),
        .host_wdata_i    (host_wdata_i),
        .host_ready_o    (fwd_ready),
        .host_rvalid_o   (fwd_rvalid),
        .host_rdata_o    (fwd_rdata),
        .stage_o         (fwd_stage),
        .stage_barrier_o (fwd_barrier),
        .active_bank_o   (fwd_bank)
    );

    inverse_ntt_core u_inverse (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .start_i         (inv_start),
        .busy_o          (inv_busy),
        .done_o          (inv_done),
        .host_re_i       (host_re_i && result_is_intt_q),
        .host_we_i       (accepted_host_write),
        .host_addr_i     (host_addr_i),
        .host_wdata_i    (host_wdata_i),
        .host_ready_o    (inv_ready),
        .host_rvalid_o   (inv_rvalid),
        .host_rdata_o    (inv_rdata),
        .stage_o         (inv_stage),
        .stage_barrier_o (inv_barrier),
        .active_bank_o   (inv_bank)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            write_coverage_q <= 256'h0;
            result_is_intt_q <= 1'b0;
        end else begin
            if (accepted_host_write)
                write_coverage_q[host_addr_i] <= 1'b1;

            if (accepted_start_ntt) begin
                result_is_intt_q <= 1'b0;
                write_coverage_q <= 256'h0;
            end else if (accepted_start_intt) begin
                result_is_intt_q <= 1'b1;
                write_coverage_q <= 256'h0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            assert (!(start_ntt_i && start_intt_i))
                else $error("primer1_pqc_accelerator: NTT and INTT start together");
            if ((start_ntt_i || start_intt_i) && !start_ready_o)
                assert (!fwd_start && !inv_start)
                    else $error("primer1_pqc_accelerator: accepted invalid start");
            if (accepted_host_write)
                assert (host_wdata_i < 16'd3329)
                    else $error("primer1_pqc_accelerator: non-canonical coefficient %0d",
                                host_wdata_i);
        end
    end
`endif
endmodule
