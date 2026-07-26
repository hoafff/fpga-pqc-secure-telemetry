`timescale 1ns/1ps

module tb_primer1_request_semantic_guard;
    import fpst_btp_pkg::*;

    logic clk;
    logic rst_n;
    logic zeroize;
    logic raw_valid;
    logic raw_accept;
    logic [7:0] raw_opcode;
    logic [15:0] raw_payload_len;
    logic raw_error;
    logic [15:0] raw_error_code;
    logic [9:0] payload_rd_addr;
    logic [7:0] payload_rd_data;
    logic [9:0] endpoint_payload_rd_addr;
    logic guarded_valid;
    logic guarded_accept;
    logic guarded_error;
    logic [15:0] guarded_error_code;
    logic [7:0] payload [0:1];

    primer1_request_semantic_guard dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .zeroize_i(zeroize),
        .raw_valid_i(raw_valid),
        .raw_accept_o(raw_accept),
        .raw_opcode_i(raw_opcode),
        .raw_payload_len_i(raw_payload_len),
        .raw_error_i(raw_error),
        .raw_error_code_i(raw_error_code),
        .payload_rd_addr_o(payload_rd_addr),
        .payload_rd_data_i(payload_rd_data),
        .endpoint_payload_rd_addr_i(endpoint_payload_rd_addr),
        .guarded_valid_o(guarded_valid),
        .guarded_accept_i(guarded_accept),
        .guarded_error_o(guarded_error),
        .guarded_error_code_o(guarded_error_code)
    );

    always #5 clk = ~clk;
    always_comb payload_rd_data = payload[payload_rd_addr[0]];

    task automatic present_poly(
        input logic [15:0] count,
        input logic [15:0] payload_len
    );
        begin
            payload[0] = count[15:8];
            payload[1] = count[7:0];
            raw_opcode = OP_PQC_LOAD_POLY;
            raw_payload_len = payload_len;
            raw_error = 1'b0;
            raw_error_code = ERR_OK;
            raw_valid = 1'b1;
            while (!guarded_valid)
                @(posedge clk);
            #1;
        end
    endtask

    task automatic accept_and_idle;
        begin
            guarded_accept = 1'b1;
            @(posedge clk);
            guarded_accept = 1'b0;
            raw_valid = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        zeroize = 1'b0;
        raw_valid = 1'b0;
        raw_opcode = 8'h00;
        raw_payload_len = 16'h0000;
        raw_error = 1'b0;
        raw_error_code = ERR_OK;
        endpoint_payload_rd_addr = 10'd0;
        guarded_accept = 1'b0;
        payload[0] = 8'h00;
        payload[1] = 8'h00;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        /* Valid maximum: count=256, payload=2 + 2*256 = 514. */
        present_poly(16'd256, 16'd514);
        if (guarded_error)
            $fatal(1, "Valid 256-coefficient load was rejected: %04x",
                   guarded_error_code);
        accept_and_idle();

        /* Regression: high byte 0x03 must not alias to 256. */
        present_poly(16'h0300, 16'd514);
        if (!guarded_error || guarded_error_code !== ERR_PQC_LENGTH)
            $fatal(1, "Malformed 0x0300 polynomial count was not rejected");
        accept_and_idle();

        present_poly(16'd0, 16'd2);
        if (!guarded_error || guarded_error_code !== ERR_PQC_LENGTH)
            $fatal(1, "Zero polynomial count was not rejected");
        accept_and_idle();

        present_poly(16'd3, 16'd10); /* should be 8 bytes total */
        if (!guarded_error || guarded_error_code !== ERR_PQC_LENGTH)
            $fatal(1, "Mismatched polynomial payload length was not rejected");
        accept_and_idle();

        $display("PASS: Primer #1 semantic guard validates full BE16 polynomial count");
        $finish;
    end
endmodule
