package fpst_btp_pkg;
    localparam logic [15:0] BTP_SOF = 16'hA55A;
    localparam logic [7:0]  BTP_VERSION = 8'h01;
    localparam integer BTP_MAX_PAYLOAD = 1024;
    localparam integer BTP_HEADER_BYTES = 10;
    localparam integer BTP_CRC_BYTES = 4;
    localparam integer BTP_MAX_FRAME_BYTES = BTP_HEADER_BYTES + BTP_MAX_PAYLOAD + BTP_CRC_BYTES;

    localparam logic [7:0] BTP_FLAG_RESPONSE = 8'h01;
    localparam logic [7:0] BTP_FLAG_ERROR    = 8'h02;
    localparam logic [7:0] BTP_FLAG_MORE     = 8'h04;

    localparam logic [7:0] OP_GET_DEVICE_ID       = 8'h01;
    localparam logic [7:0] OP_GET_STATUS          = 8'h02;
    localparam logic [7:0] OP_GET_ERROR           = 8'h03;
    localparam logic [7:0] OP_CLEAR_ERROR         = 8'h04;
    localparam logic [7:0] OP_SOFT_RESET          = 8'h05;
    localparam logic [7:0] OP_SELF_TEST           = 8'h06;
    localparam logic [7:0] OP_PQC_WRITE_COEFF     = 8'h20;
    localparam logic [7:0] OP_PQC_READ_COEFF      = 8'h21;
    localparam logic [7:0] OP_PQC_START_NTT       = 8'h24;
    localparam logic [7:0] OP_PQC_START_INTT      = 8'h25;
    localparam logic [7:0] OP_PQC_GET_RESULT      = 8'h28;
    localparam logic [7:0] OP_KEY_LOAD_BEGIN      = 8'h40;
    localparam logic [7:0] OP_KEY_LOAD_CHUNK      = 8'h41;
    localparam logic [7:0] OP_KEY_LOAD_COMMIT     = 8'h42;
    localparam logic [7:0] OP_KEY_LOAD_ABORT      = 8'h43;
    localparam logic [7:0] OP_KEY_STATUS          = 8'h44;
    localparam logic [7:0] OP_ZEROIZE             = 8'h45;
    localparam logic [7:0] OP_SESSION_ACTIVATE    = 8'h46;
    localparam logic [7:0] OP_ASCON_KAT           = 8'h50;
    localparam logic [7:0] OP_TELEMETRY_TX_SAMPLE = 8'h60;

    localparam logic [15:0] ERR_OK                 = 16'h0000;
    localparam logic [15:0] ERR_BTP_SOF            = 16'h0101;
    localparam logic [15:0] ERR_BTP_VERSION        = 16'h0102;
    localparam logic [15:0] ERR_BTP_LENGTH         = 16'h0103;
    localparam logic [15:0] ERR_BTP_CRC            = 16'h0104;
    localparam logic [15:0] ERR_BTP_TRANSACTION    = 16'h0105;
    localparam logic [15:0] ERR_UNSUPPORTED_OPCODE = 16'h0201;
    localparam logic [15:0] ERR_RESERVED_FIELD     = 16'h0202;
    localparam logic [15:0] ERR_ARGUMENT           = 16'h0203;
    localparam logic [15:0] ERR_PERMISSION         = 16'h0204;
    localparam logic [15:0] ERR_BUSY               = 16'h0301;
    localparam logic [15:0] ERR_INVALID_STATE      = 16'h0302;
    localparam logic [15:0] ERR_NO_KEY              = 16'h0303;
    localparam logic [15:0] ERR_SECURE_DISABLED     = 16'h0304;
    localparam logic [15:0] ERR_SAFE_LOCKED         = 16'h0305;
    localparam logic [15:0] ERR_KEY_LOAD_INCOMPLETE = 16'h0504;
    localparam logic [15:0] ERR_KEY_COMMIT          = 16'h0505;
    localparam logic [15:0] ERR_ZEROIZE             = 16'h0506;

    function automatic logic [31:0] crc32_update_byte(
        input logic [31:0] crc_i,
        input logic [7:0] data_i
    );
        logic [31:0] crc;
        integer i;
        begin
            crc = crc_i ^ {24'h0, data_i};
            for (i = 0; i < 8; i = i + 1)
                crc = crc[0] ? ((crc >> 1) ^ 32'hEDB88320) : (crc >> 1);
            crc32_update_byte = crc;
        end
    endfunction

    function automatic logic [31:0] crc32_finalize(input logic [31:0] crc_i);
        crc32_finalize = crc_i ^ 32'hFFFFFFFF;
    endfunction
endpackage
