module kiwi_primer20k_primer1_top #(
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer HEARTBEAT_TOGGLE_CYCLES = 2_700_000
) (
    input  logic        sys_clk_i,
    input  logic        board_rst_ni,

    /* MCU shared SPI bus. */
    input  logic        spi_sclk_i,
    input  logic        spi_mosi_i,
    output wire         spi_miso_o,
    input  logic        spi_cs_ni,

    /* MCU sideband. */
    output logic        irq_no,
    output logic        busy_o,
    output logic        fault_o,

    /* Tiny 1P5 supervisor sideband. */
    input  logic        secure_enable_i,
    input  logic        key_zeroize_i,
    input  logic        system_reset_ni,
    output logic        hb_o
);
    localparam integer HB_COUNT_WIDTH =
        (HEARTBEAT_TOGGLE_CYCLES <= 1) ? 1 : $clog2(HEARTBEAT_TOGGLE_CYCLES);

    logic [1:0] reset_sync_q;
    logic internal_rst_n;
    logic [1:0] secure_enable_sync_q;
    logic [1:0] zeroize_release_q;
    logic zeroize_sync;

    logic [HB_COUNT_WIDTH-1:0] heartbeat_count_q;

    logic spi_miso_data;
    logic spi_miso_oe;
    logic req_valid, req_take;
    logic [10:0] req_len, req_raddr;
    logic [7:0] req_rdata;
    logic rsp_we, rsp_commit, rsp_rearm, rsp_pending, rsp_consumed;
    logic [10:0] rsp_waddr, rsp_len;
    logic [7:0] rsp_wdata;
    logic transport_overflow;

    logic endpoint_busy;
    logic key_valid, session_active, retained_valid;
    logic [63:0] tx_sequence;
    logic [15:0] last_error;
    logic safe_locked_q;

    /* Reset assertion is asynchronous at the board boundary; release is
     * synchronized into the 27 MHz system domain. */
    always_ff @(posedge sys_clk_i or negedge board_rst_ni or negedge system_reset_ni) begin
        if (!board_rst_ni || !system_reset_ni)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end
    assign internal_rst_n = reset_sync_q[1];

    /* Supervisor enable is a level signal and uses a two-flop synchronizer. */
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n)
            secure_enable_sync_q <= 2'b00;
        else
            secure_enable_sync_q <= {secure_enable_sync_q[0], secure_enable_i};
    end

    /* key_zeroize_i is security critical: asynchronous assertion is captured,
     * then deassertion is stretched/synchronized for two system clocks. */
    always_ff @(posedge sys_clk_i or posedge key_zeroize_i or negedge internal_rst_n) begin
        if (!internal_rst_n)
            zeroize_release_q <= 2'b00;
        else if (key_zeroize_i)
            zeroize_release_q <= 2'b11;
        else
            zeroize_release_q <= {1'b0, zeroize_release_q[1]};
    end
    assign zeroize_sync = |zeroize_release_q;

    /* Independent ~100 ms heartbeat toggle at 27 MHz. */
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n) begin
            heartbeat_count_q <= '0;
            hb_o <= 1'b0;
        end else if (HEARTBEAT_TOGGLE_CYCLES <= 1) begin
            heartbeat_count_q <= '0;
            hb_o <= ~hb_o;
        end else if (heartbeat_count_q == HEARTBEAT_TOGGLE_CYCLES-1) begin
            heartbeat_count_q <= '0;
            hb_o <= ~hb_o;
        end else begin
            heartbeat_count_q <= heartbeat_count_q + 1'b1;
        end
    end

    btp_spi_slave #(.MAX_FRAME_BYTES(1038)) u_spi_slave (
        .clk_i              (sys_clk_i),
        .rst_ni             (internal_rst_n),
        .zeroize_i          (zeroize_sync),
        .spi_sclk_i         (spi_sclk_i),
        .spi_mosi_i         (spi_mosi_i),
        .spi_cs_ni          (spi_cs_ni),
        .spi_miso_o         (spi_miso_data),
        .spi_miso_oe_o      (spi_miso_oe),
        .req_valid_o        (req_valid),
        .req_take_i         (req_take),
        .req_len_o          (req_len),
        .req_raddr_i        (req_raddr),
        .req_rdata_o        (req_rdata),
        .rsp_we_i           (rsp_we),
        .rsp_waddr_i        (rsp_waddr),
        .rsp_wdata_i        (rsp_wdata),
        .rsp_len_i          (rsp_len),
        .rsp_commit_i       (rsp_commit),
        .rsp_rearm_i        (rsp_rearm),
        .rsp_pending_o      (rsp_pending),
        .rsp_consumed_o     (rsp_consumed),
        .irq_no             (irq_no),
        .overflow_o         (transport_overflow)
    );

    primer1_endpoint_core #(
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .RESPONSE_CACHE_CYCLES(SYS_CLK_HZ)
    ) u_endpoint (
        .clk_i              (sys_clk_i),
        .rst_ni             (internal_rst_n),
        .external_zeroize_i (zeroize_sync),
        .secure_enable_i    (secure_enable_sync_q[1]),
        .safe_locked_i      (safe_locked_q),
        .req_valid_i        (req_valid),
        .req_len_i          (req_len),
        .req_take_o         (req_take),
        .req_raddr_o        (req_raddr),
        .req_rdata_i        (req_rdata),
        .rsp_we_o           (rsp_we),
        .rsp_waddr_o        (rsp_waddr),
        .rsp_wdata_o        (rsp_wdata),
        .rsp_len_o          (rsp_len),
        .rsp_commit_o       (rsp_commit),
        .rsp_rearm_o        (rsp_rearm),
        .rsp_consumed_i     (rsp_consumed),
        .endpoint_busy_o    (endpoint_busy),
        .key_valid_o        (key_valid),
        .session_active_o   (session_active),
        .retained_valid_o   (retained_valid),
        .tx_sequence_o      (tx_sequence),
        .last_error_o       (last_error)
    );

    /* Shared MISO must be high-Z whenever this Primer is not selected. */
    assign spi_miso_o = spi_miso_oe ? spi_miso_data : 1'bz;

    assign busy_o = endpoint_busy || req_valid || rsp_pending;

    /* Self-test failure and transport-buffer overflow are treated as local
     * fatal summary conditions until reset/zeroize recovery. */
    always_ff @(posedge sys_clk_i) begin
        if (!internal_rst_n || zeroize_sync)
            safe_locked_q <= 1'b0;
        else if (transport_overflow || last_error == 16'h0801)
            safe_locked_q <= 1'b1;
    end
    assign fault_o = safe_locked_q;

`ifndef SYNTHESIS
    initial begin
        assert (SYS_CLK_HZ > 0)
            else $error("kiwi_primer20k_primer1_top: invalid system clock");
        assert (HEARTBEAT_TOGGLE_CYCLES > 0)
            else $error("kiwi_primer20k_primer1_top: invalid heartbeat period");
    end

    logic unused_debug;
    always_comb begin
        unused_debug = key_valid ^ session_active ^ retained_valid ^
                       (^tx_sequence);
    end
`endif
endmodule
