module kiwi_primer20k_primer1_top #(
    parameter integer HEARTBEAT_BIT = 23
) (
    input  logic sys_clk_i,
    input  logic rst_ni,

    input  logic spi_sclk_i,
    input  logic spi_cs_ni,
    input  logic spi_mosi_i,
    output wire  spi_miso_o,

    output logic fpga_ready_o,
    output logic fpga_irq_o,
    input  logic fpga_reset_ni,
    input  logic fpga_zeroize_ni,

    output logic led1_no,
    output logic led2_no,
    output logic led3_no,
    output logic led4_no,
    output logic led5_no,
    output logic led6_no,
    output logic led7_no
);
    logic [1:0] reset_sync_q;
    logic       internal_rst_n;
    logic [1:0] zeroize_sync_q;
    logic       zeroize_level;

    logic [HEARTBEAT_BIT:0] heartbeat_counter_q;
    logic heartbeat;

    logic endpoint_busy;
    logic endpoint_fatal;
    logic endpoint_key_valid;
    logic endpoint_retained;

    logic request_doorbell;
    logic response_ack;
    logic link_reset;
    logic [15:0] request_len;
    logic [15:0] request_id;
    logic [8:0] request_rd_addr;
    logic [7:0] request_rd_data;

    logic response_we;
    logic [8:0] response_waddr;
    logic [7:0] response_wdata;
    logic response_valid;
    logic [15:0] response_len;
    logic [15:0] response_id;
    logic [15:0] error_code;

    wire combined_reset_ni = rst_ni && fpga_reset_ni;

    always_ff @(posedge sys_clk_i or negedge combined_reset_ni) begin
        if (!combined_reset_ni)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end

    assign internal_rst_n = reset_sync_q[1];

    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n)
            zeroize_sync_q <= 2'b11;
        else
            zeroize_sync_q <= {zeroize_sync_q[0], fpga_zeroize_ni};
    end

    assign zeroize_level = !zeroize_sync_q[1];

    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n)
            heartbeat_counter_q <= '0;
        else
            heartbeat_counter_q <= heartbeat_counter_q + 1'b1;
    end

    assign heartbeat = heartbeat_counter_q[HEARTBEAT_BIT];

    fpst_spi_mem_slave u_spi_mem (
        .clk_i                 (sys_clk_i),
        .rst_ni                (internal_rst_n),
        .spi_sclk_i            (spi_sclk_i),
        .spi_cs_ni             (spi_cs_ni),
        .spi_mosi_i            (spi_mosi_i),
        .spi_miso_o            (spi_miso_o),
        .endpoint_busy_i       (endpoint_busy),
        .endpoint_fatal_i      (endpoint_fatal),
        .response_valid_i      (response_valid),
        .response_len_i        (response_len),
        .response_id_i         (response_id),
        .error_code_i          (error_code),
        .request_doorbell_o    (request_doorbell),
        .response_ack_o        (response_ack),
        .link_reset_o          (link_reset),
        .request_len_o         (request_len),
        .request_id_o          (request_id),
        .request_rd_addr_i     (request_rd_addr),
        .request_rd_data_o     (request_rd_data),
        .response_we_i         (response_we),
        .response_waddr_i      (response_waddr),
        .response_wdata_i      (response_wdata)
    );

    primer1_endpoint u_endpoint (
        .clk_i                 (sys_clk_i),
        .rst_ni                (internal_rst_n),
        .zeroize_i             (zeroize_level),
        .request_doorbell_i    (request_doorbell),
        .response_ack_i        (response_ack),
        .link_reset_i          (link_reset),
        .request_len_i         (request_len),
        .request_id_i          (request_id),
        .request_rd_addr_o     (request_rd_addr),
        .request_rd_data_i     (request_rd_data),
        .response_we_o         (response_we),
        .response_waddr_o      (response_waddr),
        .response_wdata_o      (response_wdata),
        .response_valid_o      (response_valid),
        .response_len_o        (response_len),
        .response_id_o         (response_id),
        .error_code_o          (error_code),
        .busy_o                (endpoint_busy),
        .fatal_o               (endpoint_fatal),
        .key_valid_o           (endpoint_key_valid),
        .retained_packet_o     (endpoint_retained)
    );

    assign fpga_ready_o = internal_rst_n && !zeroize_level &&
                          !endpoint_busy && !response_valid && !endpoint_fatal;
    assign fpga_irq_o   = internal_rst_n && response_valid;

    // On-board LEDs are active low.
    assign led1_no = ~heartbeat;
    assign led2_no = ~fpga_ready_o;
    assign led3_no = ~fpga_irq_o;
    assign led4_no = ~endpoint_busy;
    assign led5_no = ~endpoint_key_valid;
    assign led6_no = ~endpoint_retained;
    assign led7_no = ~(endpoint_fatal || (error_code != 16'h0000));
endmodule
