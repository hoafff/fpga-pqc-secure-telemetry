module btp_crc32_iso_hdlc (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       clear_i,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    output logic [31:0] crc_o
);
    logic [31:0] crc_q;

    function automatic logic [31:0] update_byte(
        input logic [31:0] crc_in,
        input logic [7:0]  byte_in
    );
        logic [31:0] c;
        integer i;
        begin
            c = crc_in ^ {24'h0, byte_in};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
                else      c = c >> 1;
            end
            update_byte = c;
        end
    endfunction

    assign crc_o = crc_q ^ 32'hFFFF_FFFF;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            crc_q <= 32'hFFFF_FFFF;
        end else if (clear_i) begin
            crc_q <= 32'hFFFF_FFFF;
        end else if (valid_i) begin
            crc_q <= update_byte(crc_q, data_i);
        end
    end
endmodule
