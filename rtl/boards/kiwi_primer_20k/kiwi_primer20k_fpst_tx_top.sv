// Kiwi Primer 20K #1 deployment top for FPST v1.1.
// Target: GW2A-LV18PG256C8/I7, SYS_CLK=27 MHz.
module kiwi_primer20k_fpst_tx_top (
    input  logic sys_clk_i,
    input  logic rst_ni,

    // MCU BTP SPI bus, Mode 0, MSB first.
    input  logic spi_sclk_i,
    input  logic spi_mosi_i,
    output logic spi_miso_o,
    input  logic spi_cs_ni,
    output logic irq_no,
    output logic busy_o,
    output logic fault_o,
    input  logic link_reset_ni,

    // Independent Tiny-1P5 security sideband.
    input  logic secure_enable_i,
    input  logic zeroize_ni,
    output logic heartbeat_o,

    // On-board active-low debug LEDs; not part of the BTP contract.
    output logic led1_no,
    output logic led2_no,
    output logic led3_no,
    output logic led4_no,
    output logic led5_no,
    output logic led6_no,
    output logic led7_no
);
    logic [1:0] reset_sync_q;
    logic [1:0] secure_enable_sync_q;
    logic [1:0] zeroize_sync_q;
    logic internal_rst_n;
    logic zeroize;

    logic request_txn_start;
    logic request_byte_valid;
    logic [7:0] request_byte;
    logic request_txn_end;
    logic response_pending;
    logic [10:0] response_length;
    logic [10:0] response_addr;
    logic [7:0] response_data;
    logic response_read_done;
    logic spi_selected;
    logic spi_response_txn;

    logic endpoint_busy;
    logic endpoint_fault;
    logic key_valid;
    logic session_active;
    logic [15:0] last_error;
    logic [31:0] protocol_error_count;

    logic [23:0] heartbeat_counter_q;

    wire reset_async_n = rst_ni && link_reset_ni;

    // Asynchronous assertion, synchronous release in the 27 MHz domain.
    always_ff @(posedge sys_clk_i or negedge reset_async_n) begin
        if (!reset_async_n)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end
    assign internal_rst_n = reset_sync_q[1];

    // secure_enable is fail-safe low until it has crossed the synchronizer.
    always_ff @(posedge sys_clk_i or negedge internal_rst_n) begin
        if (!internal_rst_n)
            secure_enable_sync_q <= 2'b00;
        else
            secure_enable_sync_q <= {secure_enable_sync_q[0], secure_enable_i};
    end

    // zeroize_n has asynchronous assertion so key_valid can fall within the
    // required bounded number of system clocks. Release is synchronized.
    always_ff @(posedge sys_clk_i or negedge zeroize_ni) begin
        if (!zeroize_ni)
            zeroize_sync_q <= 2'b00;
        else
            zeroize_sync_q <= {zeroize_sync_q[0], 1'b1};
    end
    assign zeroize = !zeroize_sync_q[1];

    // Heartbeat is independent of the functional/BTP FSM progress.
    always_ff @(posedge sys_clk_i or negedge internal_rst_n) begin
        if (!internal_rst_n)
            heartbeat_counter_q <= 24'h0;
        else
            heartbeat_counter_q <= heartbeat_counter_q + 1'b1;
    end
    assign heartbeat_o = heartbeat_counter_q[22];

    btp_spi_slave #(
        .MAX_FRAME_BYTES(1038)
    ) u_btp_spi (
        .clk_i                   (sys_clk_i),
        .rst_ni                  (internal_rst_n),
        .spi_sclk_i              (spi_sclk_i),
        .spi_mosi_i              (spi_mosi_i),
        .spi_miso_o              (spi_miso_o),
        .spi_cs_ni               (spi_cs_ni),
        .request_txn_start_o     (request_txn_start),
        .request_byte_valid_o    (request_byte_valid),
        .request_byte_o          (request_byte),
        .request_txn_end_o       (request_txn_end),
        .response_pending_i      (response_pending),
        .response_length_i       (response_length),
        .response_addr_o         (response_addr),
        .response_data_i         (response_data),
        .response_read_done_o    (response_read_done),
        .selected_o              (spi_selected),
        .response_txn_o          (spi_response_txn)
    );

    primer1_btp_endpoint u_endpoint (
        .clk_i                   (sys_clk_i),
        .rst_ni                  (internal_rst_n),
        .zeroize_i               (zeroize),
        .secure_enable_i         (secure_enable_sync_q[1]),
        .request_txn_start_i     (request_txn_start),
        .request_byte_valid_i    (request_byte_valid),
        .request_byte_i          (request_byte),
        .request_txn_end_i       (request_txn_end),
        .response_pending_o      (response_pending),
        .response_length_o       (response_length),
        .response_addr_i         (response_addr),
        .response_data_o         (response_data),
        .response_read_done_i    (response_read_done),
        .busy_o                  (endpoint_busy),
        .fault_o                 (endpoint_fault),
        .key_valid_o             (key_valid),
        .session_active_o        (session_active),
        .last_error_o            (last_error),
        .protocol_error_count_o  (protocol_error_count)
    );

    // BTP sidebands: IRQ is active-low; busy/fault are active-high.
    assign irq_no  = ~response_pending;
    assign busy_o  = endpoint_busy;
    assign fault_o = endpoint_fault;

    // LED meanings for bring-up:
    // 1 heartbeat, 2 BTP/operation busy, 3 key valid, 4 session active,
    // 5 IRQ asserted, 6 fault, 7 any protocol/endpoint error observed.
    assign led1_no = ~heartbeat_o;
    assign led2_no = ~endpoint_busy;
    assign led3_no = ~key_valid;
    assign led4_no = ~session_active;
    assign led5_no = irq_no;
    assign led6_no = ~endpoint_fault;
    assign led7_no = ~((last_error != 16'h0000) ||
                       (protocol_error_count != 32'h0000_0000));

`ifndef SYNTHESIS
    logic unused_debug;
    always_comb begin
        unused_debug = spi_selected ^ spi_response_txn ^ (^last_error) ^
                       (^protocol_error_count);
    end
`endif
endmodule
