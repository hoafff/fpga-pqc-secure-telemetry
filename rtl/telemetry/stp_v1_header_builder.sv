module stp_v1_header_builder (
    input  logic [15:0]  flags_i,
    input  logic [31:0]  session_id_i,
    input  logic [63:0]  sequence_i,
    output logic [191:0] header_o
);
    /*
     * External packet order is big-endian. Byte 0 is carried in header_o[7:0]
     * so a byte-stream wrapper can index header_o[8*index +: 8].
     *
     * 50 51 | 01 | 03 | flags[2] | 00 18 | session_id[4] |
     * sequence[8] | 00 18 | 01 | 00
     */
    always_comb begin
        header_o = '0;
        header_o[8*0  +: 8] = 8'h50;
        header_o[8*1  +: 8] = 8'h51;
        header_o[8*2  +: 8] = 8'h01;
        header_o[8*3  +: 8] = 8'h03;
        header_o[8*4  +: 8] = flags_i[15:8];
        header_o[8*5  +: 8] = flags_i[7:0];
        header_o[8*6  +: 8] = 8'h00;
        header_o[8*7  +: 8] = 8'h18;
        header_o[8*8  +: 8] = session_id_i[31:24];
        header_o[8*9  +: 8] = session_id_i[23:16];
        header_o[8*10 +: 8] = session_id_i[15:8];
        header_o[8*11 +: 8] = session_id_i[7:0];
        header_o[8*12 +: 8] = sequence_i[63:56];
        header_o[8*13 +: 8] = sequence_i[55:48];
        header_o[8*14 +: 8] = sequence_i[47:40];
        header_o[8*15 +: 8] = sequence_i[39:32];
        header_o[8*16 +: 8] = sequence_i[31:24];
        header_o[8*17 +: 8] = sequence_i[23:16];
        header_o[8*18 +: 8] = sequence_i[15:8];
        header_o[8*19 +: 8] = sequence_i[7:0];
        header_o[8*20 +: 8] = 8'h00;
        header_o[8*21 +: 8] = 8'h18;
        header_o[8*22 +: 8] = 8'h01;
        header_o[8*23 +: 8] = 8'h00;
    end
endmodule
