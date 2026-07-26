module primer1_system_core (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         zeroize_i,
    input  logic         secure_enable_i,

    input  logic         spi_sclk_i,
    input  logic         spi_mosi_i,
    output logic         spi_miso_o,
    input  logic         spi_cs_ni,
    output logic         irq_no,
    output logic         busy_o,
    output logic         fault_o,

    /* Logical delivery acknowledgement from the complete system integration.
     * No private BTP opcode or physical pin is assigned by this module. */
    input  logic         tx_commit_valid_i,
    input  logic [63:0]  tx_commit_sequence_i,

    output logic         key_valid_o,
    output logic         session_active_o,
    output logic [63:0]  tx_sequence_o,
    output logic         tx_packet_retained_o,
    output logic         error_valid_o,
    output logic [15:0]  error_code_o
);
    logic cmd_valid;
    logic cmd_ready;
    logic [7:0] cmd_opcode;
    logic [7:0] cmd_flags;
    logic [15:0] cmd_transaction_id;
    logic [15:0] cmd_payload_len;
    logic [9:0] cmd_payload_addr;
    logic [7:0] cmd_payload_data;

    logic rsp_payload_we;
    logic [9:0] rsp_payload_addr;
    logic [7:0] rsp_payload_data;
    logic rsp_valid;
    logic rsp_ready;
    logic [7:0] rsp_opcode;
    logic [7:0] rsp_flags;
    logic [15:0] rsp_transaction_id;
    logic [15:0] rsp_payload_len;

    logic link_busy;
    logic link_fault;
    logic link_error_valid;
    logic [15:0] link_error_code;
    logic endpoint_busy;
    logic endpoint_error_valid;
    logic [15:0] endpoint_error_code;

    fpst_btp_spi_slave u_btp (
        .sys_clk_i              (clk_i),
        .rst_ni                 (rst_ni),
        .zeroize_i              (zeroize_i),
        .spi_sclk_i             (spi_sclk_i),
        .spi_mosi_i             (spi_mosi_i),
        .spi_miso_o             (spi_miso_o),
        .spi_cs_ni              (spi_cs_ni),
        .irq_no                 (irq_no),
        .busy_o                 (link_busy),
        .fault_o                (link_fault),
        .cmd_valid_o            (cmd_valid),
        .cmd_ready_i            (cmd_ready),
        .cmd_opcode_o           (cmd_opcode),
        .cmd_flags_o            (cmd_flags),
        .cmd_transaction_id_o   (cmd_transaction_id),
        .cmd_payload_len_o      (cmd_payload_len),
        .cmd_payload_addr_i     (cmd_payload_addr),
        .cmd_payload_data_o     (cmd_payload_data),
        .rsp_payload_we_i       (rsp_payload_we),
        .rsp_payload_addr_i     (rsp_payload_addr),
        .rsp_payload_data_i     (rsp_payload_data),
        .rsp_valid_i            (rsp_valid),
        .rsp_ready_o            (rsp_ready),
        .rsp_opcode_i           (rsp_opcode),
        .rsp_flags_i            (rsp_flags),
        .rsp_transaction_id_i   (rsp_transaction_id),
        .rsp_payload_len_i      (rsp_payload_len),
        .link_error_valid_o     (link_error_valid),
        .link_error_code_o      (link_error_code)
    );

    primer1_endpoint_core u_endpoint (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .zeroize_i              (zeroize_i),
        .secure_enable_i        (secure_enable_i),
        .cmd_valid_i            (cmd_valid),
        .cmd_ready_o            (cmd_ready),
        .cmd_opcode_i           (cmd_opcode),
        .cmd_flags_i            (cmd_flags),
        .cmd_transaction_id_i   (cmd_transaction_id),
        .cmd_payload_len_i      (cmd_payload_len),
        .cmd_payload_addr_o     (cmd_payload_addr),
        .cmd_payload_data_i     (cmd_payload_data),
        .rsp_payload_we_o       (rsp_payload_we),
        .rsp_payload_addr_o     (rsp_payload_addr),
        .rsp_payload_data_o     (rsp_payload_data),
        .rsp_valid_o            (rsp_valid),
        .rsp_ready_i            (rsp_ready),
        .rsp_opcode_o           (rsp_opcode),
        .rsp_flags_o            (rsp_flags),
        .rsp_transaction_id_o   (rsp_transaction_id),
        .rsp_payload_len_o      (rsp_payload_len),
        .tx_commit_valid_i      (tx_commit_valid_i),
        .tx_commit_sequence_i   (tx_commit_sequence_i),
        .key_valid_o            (key_valid_o),
        .session_active_o       (session_active_o),
        .tx_sequence_o          (tx_sequence_o),
        .tx_packet_retained_o   (tx_packet_retained_o),
        .endpoint_busy_o        (endpoint_busy),
        .error_valid_o          (endpoint_error_valid),
        .error_code_o           (endpoint_error_code)
    );

    assign busy_o = link_busy || endpoint_busy;
    assign fault_o = link_fault;
    assign error_valid_o = link_error_valid || endpoint_error_valid;
    assign error_code_o = link_error_valid ? link_error_code : endpoint_error_code;
endmodule
