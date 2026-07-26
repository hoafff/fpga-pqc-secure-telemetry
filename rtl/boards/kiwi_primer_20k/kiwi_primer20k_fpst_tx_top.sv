module kiwi_primer20k_fpst_tx_top #(
    parameter integer CLOCK_HZ = 27_000_000,
    parameter integer HEARTBEAT_TOGGLE_CYCLES = 2_700_000
) (
    input  logic sys_clk_i,
    input  logic rst_ni,

    /* SN32F407 <-> Primer #1 BTP/SPI, mode 0, MSB first. */
    input  logic spi_sck_i,
    input  logic spi_cs_ni,
    input  logic spi_mosi_i,
    output logic spi_miso_o,
    output logic irq_no,
    output logic busy_o,
    output logic fault_o,

    /* Independent Tiny-1P5 security plane; asynchronous to sys_clk_i. */
    input  logic secure_enable_i,
    input  logic zeroize_ni,
    input  logic fatal_latched_i,
    output logic heartbeat_o,

    /* On-board deployment diagnostics, active low. */
    output logic led1_no,
    output logic led2_no,
    output logic led3_no,
    output logic led4_no,
    output logic led5_no,
    output logic led6_no,
    output logic led7_no
);
    localparam integer MAX_FRAME_BYTES = 1038;
    localparam integer COUNT_W = $clog2(MAX_FRAME_BYTES + 1);
    localparam integer HEARTBEAT_COUNT_W =
        (HEARTBEAT_TOGGLE_CYCLES <= 1) ? 1 : $clog2(HEARTBEAT_TOGGLE_CYCLES);

    logic [1:0] reset_sync_q;
    logic [1:0] secure_enable_sync_q;
    logic [1:0] zeroize_sync_q;
    logic [1:0] fatal_sync_q;
    logic internal_rst_n;
    logic secure_enable_sys;
    logic transport_zeroize;
    logic fatal_latched_sys;
    logic [HEARTBEAT_COUNT_W-1:0] heartbeat_counter_q;
    logic heartbeat_q;

    logic rx_frame_valid;
    logic [COUNT_W-1:0] rx_frame_len;
    logic rx_frame_accept;
    logic [COUNT_W-1:0] rx_rd_addr;
    logic [7:0] rx_rd_data;
    logic rx_overflow;

    logic tx_frame_commit;
    logic [COUNT_W-1:0] tx_frame_len;
    logic [COUNT_W-1:0] tx_wr_addr;
    logic [7:0] tx_wr_data;
    logic tx_wr_en;
    logic tx_frame_ready;
    logic tx_frame_consumed;

    logic parser_frame_accept;
    logic [COUNT_W-1:0] parser_frame_rd_addr;

    /* Raw BTP request held by parser until the semantic guard accepts it. */
    logic raw_request_valid;
    logic raw_request_accept;
    logic [7:0] request_opcode;
    logic [7:0] request_flags;
    logic [15:0] request_transaction_id;
    logic [15:0] request_payload_len;
    logic [31:0] request_crc32;
    logic raw_request_error;
    logic [15:0] raw_request_error_code;

    logic [9:0] guard_payload_rd_addr;
    logic [7:0] request_payload_rd_data;
    logic [9:0] endpoint_payload_rd_addr;
    logic guarded_request_valid;
    logic guarded_request_accept;
    logic guarded_request_error;
    logic [15:0] guarded_request_error_code;

    logic endpoint_irq_pending;
    logic endpoint_busy;
    logic key_valid;
    logic session_active;
    logic retained_packet;
    logic pqc_busy;
    logic [1:0] pqc_domain;
    logic pqc_complete;
    logic [15:0] last_error_code;

    /* Asynchronous reset assertion, synchronous release in the 27 MHz domain. */
    always_ff @(posedge sys_clk_i or negedge rst_ni) begin
        if (!rst_ni)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0],1'b1};
    end
    assign internal_rst_n = reset_sync_q[1];

    /* secure_enable is fail-safe low until two system-clock samples agree. */
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n)
            secure_enable_sync_q <= 2'b00;
        else
            secure_enable_sync_q <= {secure_enable_sync_q[0],secure_enable_i};
    end
    assign secure_enable_sys = secure_enable_sync_q[1];

    /*
     * zeroize_n asserts asynchronously so secret invalidation starts without
     * waiting for a clock edge.  Deassertion is deliberately synchronized and
     * the level remains active for two clean system clocks after release.
     */
    always_ff @(posedge sys_clk_i or negedge zeroize_ni) begin
        if (!zeroize_ni)
            zeroize_sync_q <= 2'b00;
        else if (!internal_rst_n)
            zeroize_sync_q <= 2'b00;
        else
            zeroize_sync_q <= {zeroize_sync_q[0],1'b1};
    end
    assign transport_zeroize = !zeroize_sync_q[1];

    /*
     * fatal_latched is an active-high security indication.  Assertion sets the
     * local synchronized copy asynchronously; release is shifted out only on
     * clean system clocks.  This keeps the fail-safe direction fast.
     */
    always_ff @(posedge sys_clk_i or posedge fatal_latched_i) begin
        if (fatal_latched_i)
            fatal_sync_q <= 2'b11;
        else if (!internal_rst_n)
            fatal_sync_q <= 2'b00;
        else
            fatal_sync_q <= {fatal_sync_q[0],1'b0};
    end
    assign fatal_latched_sys = fatal_sync_q[1];

    /*
     * FPST v1.1 requires a nominal heartbeat transition every 100 ms. At the
     * production 27 MHz clock this is exactly 2,700,000 cycles. Use an explicit
     * terminal-count divider because no power-of-two counter bit meets the
     * required 100 ms +/-20% transition window at 27 MHz.
     */
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n || transport_zeroize || fatal_latched_sys) begin
            heartbeat_counter_q <= '0;
            heartbeat_q <= 1'b0;
        end else if (HEARTBEAT_TOGGLE_CYCLES <= 1) begin
            heartbeat_counter_q <= '0;
            heartbeat_q <= ~heartbeat_q;
        end else if (heartbeat_counter_q == HEARTBEAT_TOGGLE_CYCLES-1) begin
            heartbeat_counter_q <= '0;
            heartbeat_q <= ~heartbeat_q;
        end else begin
            heartbeat_counter_q <= heartbeat_counter_q + 1'b1;
        end
    end
    assign heartbeat_o = heartbeat_q;

    btp_spi_slave #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_btp_spi_slave (
        .clk_i                (sys_clk_i),
        .rst_ni               (internal_rst_n),
        .zeroize_i            (transport_zeroize),
        .spi_sck_i            (spi_sck_i),
        .spi_cs_ni            (spi_cs_ni),
        .spi_mosi_i           (spi_mosi_i),
        .spi_miso_o           (spi_miso_o),
        .rx_frame_valid_o     (rx_frame_valid),
        .rx_frame_len_o       (rx_frame_len),
        .rx_frame_accept_i    (rx_frame_accept),
        .rx_rd_addr_i         (rx_rd_addr),
        .rx_rd_data_o         (rx_rd_data),
        .tx_frame_commit_i    (tx_frame_commit),
        .tx_frame_len_i       (tx_frame_len),
        .tx_wr_addr_i         (tx_wr_addr),
        .tx_wr_data_i         (tx_wr_data),
        .tx_wr_en_i           (tx_wr_en),
        .tx_frame_ready_o     (tx_frame_ready),
        .tx_frame_consumed_o  (tx_frame_consumed),
        .overflow_o           (rx_overflow)
    );

    btp_request_parser #(
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_btp_request_parser (
        .clk_i                    (sys_clk_i),
        .rst_ni                   (internal_rst_n),
        .zeroize_i                (transport_zeroize),
        .frame_valid_i            (rx_frame_valid),
        .frame_len_i              (rx_frame_len),
        .frame_overflow_i         (rx_overflow),
        .frame_accept_o           (parser_frame_accept),
        .frame_rd_addr_o          (parser_frame_rd_addr),
        .frame_rd_data_i          (rx_rd_data),
        .request_valid_o          (raw_request_valid),
        .request_accept_i         (raw_request_accept),
        .request_opcode_o         (request_opcode),
        .request_flags_o          (request_flags),
        .request_transaction_id_o (request_transaction_id),
        .request_payload_len_o    (request_payload_len),
        .request_crc32_o          (request_crc32),
        .request_error_o          (raw_request_error),
        .request_error_code_o     (raw_request_error_code),
        .payload_rd_addr_i        (guard_payload_rd_addr),
        .payload_rd_data_o        (request_payload_rd_data)
    );

    assign rx_frame_accept = parser_frame_accept;
    assign rx_rd_addr = parser_frame_rd_addr;

    primer1_request_semantic_guard u_request_guard (
        .clk_i                       (sys_clk_i),
        .rst_ni                      (internal_rst_n),
        .zeroize_i                   (transport_zeroize),
        .raw_valid_i                 (raw_request_valid),
        .raw_accept_o                (raw_request_accept),
        .raw_opcode_i                (request_opcode),
        .raw_payload_len_i           (request_payload_len),
        .raw_error_i                 (raw_request_error),
        .raw_error_code_i            (raw_request_error_code),
        .payload_rd_addr_o           (guard_payload_rd_addr),
        .payload_rd_data_i           (request_payload_rd_data),
        .endpoint_payload_rd_addr_i  (endpoint_payload_rd_addr),
        .guarded_valid_o             (guarded_request_valid),
        .guarded_accept_i            (guarded_request_accept),
        .guarded_error_o             (guarded_request_error),
        .guarded_error_code_o        (guarded_request_error_code)
    );

    primer1_endpoint_router #(
        .CLOCK_HZ(CLOCK_HZ),
        .MAX_FRAME_BYTES(MAX_FRAME_BYTES),
        .COUNT_W(COUNT_W)
    ) u_endpoint_router (
        .clk_i                     (sys_clk_i),
        .rst_ni                    (internal_rst_n),
        .transport_zeroize_i       (transport_zeroize),
        .secure_enable_i           (secure_enable_sys),
        .fatal_latched_i           (fatal_latched_sys),
        .request_valid_i           (guarded_request_valid),
        .request_accept_o          (guarded_request_accept),
        .request_opcode_i          (request_opcode),
        .request_flags_i           (request_flags),
        .request_transaction_id_i  (request_transaction_id),
        .request_payload_len_i     (request_payload_len),
        .request_crc32_i           (request_crc32),
        .request_error_i           (guarded_request_error),
        .request_error_code_i      (guarded_request_error_code),
        .request_payload_rd_addr_o (endpoint_payload_rd_addr),
        .request_payload_rd_data_i (request_payload_rd_data),
        .tx_frame_ready_i          (tx_frame_ready),
        .tx_frame_consumed_i       (tx_frame_consumed),
        .tx_frame_commit_o         (tx_frame_commit),
        .tx_frame_len_o            (tx_frame_len),
        .tx_wr_en_o                (tx_wr_en),
        .tx_wr_addr_o              (tx_wr_addr),
        .tx_wr_data_o              (tx_wr_data),
        .irq_pending_o             (endpoint_irq_pending),
        .busy_o                    (endpoint_busy),
        .key_valid_o               (key_valid),
        .session_active_o          (session_active),
        .retained_packet_o         (retained_packet),
        .pqc_busy_o                (pqc_busy),
        .pqc_domain_o              (pqc_domain),
        .pqc_complete_o            (pqc_complete),
        .last_error_code_o         (last_error_code)
    );

    assign irq_no = ~endpoint_irq_pending;
    assign busy_o = endpoint_busy;
    assign fault_o = fatal_latched_sys;

    assign led1_no = ~heartbeat_o;
    assign led2_no = ~endpoint_busy;
    assign led3_no = ~endpoint_irq_pending;
    assign led4_no = ~key_valid;
    assign led5_no = ~session_active;
    assign led6_no = ~retained_packet;
    assign led7_no = ~(fatal_latched_sys || (last_error_code != 16'h0000));

`ifndef SYNTHESIS
    initial begin
        assert (CLOCK_HZ > 0)
            else $error("kiwi_primer20k_fpst_tx_top: CLOCK_HZ must be positive");
        assert (HEARTBEAT_TOGGLE_CYCLES > 0)
            else $error("kiwi_primer20k_fpst_tx_top: HEARTBEAT_TOGGLE_CYCLES must be positive");
    end

    always_ff @(posedge sys_clk_i) begin
        if (internal_rst_n) begin
            assert (!(session_active && !key_valid))
                else $error("kiwi_primer20k_fpst_tx_top: session active without key");
            if (endpoint_irq_pending)
                assert (tx_frame_ready)
                    else $error("kiwi_primer20k_fpst_tx_top: IRQ without cached response");
        end
    end
`endif

    logic unused_pqc_status;
    always_comb unused_pqc_status = ^{pqc_busy,pqc_domain,pqc_complete};
endmodule
