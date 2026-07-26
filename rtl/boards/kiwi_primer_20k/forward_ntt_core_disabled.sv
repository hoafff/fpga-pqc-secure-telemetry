// Deployment-only fail-closed replacement for the legacy forward_ntt_core that
// remains instantiated inside primer1_btp_endpoint_deploy. All PQC opcodes are
// routed to primer1_pqc_btp_endpoint before they can reach that legacy path.
// Keeping the interface unavailable (host_ready_o=0) ensures any routing fault
// returns ERR_BUSY rather than executing against a second coefficient store.
module forward_ntt_core (
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
    always_comb begin
        busy_o = 1'b0;
        done_o = 1'b0;
        host_ready_o = 1'b0;
        host_rvalid_o = 1'b0;
        host_rdata_o = 16'h0000;
        stage_o = 3'd0;
        stage_barrier_o = 1'b0;
        active_bank_o = 1'b0;
    end

    logic unused_inputs;
    always_comb unused_inputs = ^{clk_i,rst_ni,start_i,host_re_i,host_we_i,
                                  host_addr_i,host_wdata_i};
endmodule
