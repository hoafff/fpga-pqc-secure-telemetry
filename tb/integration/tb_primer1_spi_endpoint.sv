`timescale 1ns/1ps

module tb_primer1_spi_endpoint;
    logic sys_clk=0;
    always #18.5 sys_clk=~sys_clk; /* ~27.027 MHz */

    logic board_rst_n;
    logic spi_sclk, spi_mosi, spi_cs_n;
    wire spi_miso;
    logic irq_n, busy, fault;
    logic secure_enable, key_zeroize, system_reset_n;
    logic hb;

    logic [7:0] request [0:31];
    logic [7:0] response [0:63];
    logic [7:0] response_retry [0:63];
    integer request_len;

    kiwi_primer20k_primer1_top #(
        .SYS_CLK_HZ(27_000_000),
        .HEARTBEAT_TOGGLE_CYCLES(100)
    ) dut (
        .sys_clk_i(sys_clk), .board_rst_ni(board_rst_n),
        .spi_sclk_i(spi_sclk), .spi_mosi_i(spi_mosi),
        .spi_miso_o(spi_miso), .spi_cs_ni(spi_cs_n),
        .irq_no(irq_n), .busy_o(busy), .fault_o(fault),
        .secure_enable_i(secure_enable), .key_zeroize_i(key_zeroize),
        .system_reset_ni(system_reset_n), .hb_o(hb)
    );

    function automatic [31:0] crc32_byte(
        input [31:0] crc_in, input [7:0] byte_in
    );
        reg [31:0] c;
        integer b;
        begin
            c = crc_in ^ byte_in;
            for (b=0;b<8;b=b+1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    task build_zero_payload_request(input [7:0] opcode, input [15:0] txid);
        reg [31:0] crc;
        begin
            request[0]=8'hA5; request[1]=8'h5A; request[2]=8'h01;
            request[3]=opcode; request[4]=8'h00; request[5]=8'h00;
            request[6]=txid[15:8]; request[7]=txid[7:0];
            request[8]=8'h00; request[9]=8'h00;
            crc=32'hFFFFFFFF;
            for (integer k=2;k<10;k=k+1)
                crc=crc32_byte(crc,request[k]);
            crc=crc ^ 32'hFFFFFFFF;
            request[10]=crc[31:24]; request[11]=crc[23:16];
            request[12]=crc[15:8]; request[13]=crc[7:0];
            request_len=14;
        end
    endtask

    task spi_write_byte(input [7:0] value);
        integer bitn;
        begin
            for (bitn=7; bitn>=0; bitn=bitn-1) begin
                spi_mosi=value[bitn];
                #500;
                spi_sclk=1;
                #500;
                spi_sclk=0;
            end
        end
    endtask

    task spi_read_byte(output [7:0] value);
        integer bitn;
        begin
            value=0;
            for (bitn=7; bitn>=0; bitn=bitn-1) begin
                spi_mosi=0;
                #500;
                spi_sclk=1;
                #100;
                value[bitn]=spi_miso;
                #400;
                spi_sclk=0;
            end
        end
    endtask

    task send_request;
        begin
            spi_cs_n=0;
            #400;
            for (integer k=0;k<request_len;k=k+1)
                spi_write_byte(request[k]);
            #400;
            spi_cs_n=1;
            spi_mosi=0;
        end
    endtask

    task read_response(input integer count, input bit retry_copy);
        reg [7:0] value;
        begin
            wait(irq_n===1'b0);
            #500;
            spi_cs_n=0;
            #500;
            for (integer k=0;k<count;k=k+1) begin
                spi_read_byte(value);
                if (retry_copy) response_retry[k]=value;
                else response[k]=value;
            end
            #400;
            spi_cs_n=1;
            #500;
            wait(irq_n===1'b1);
        end
    endtask

    task check_response_crc(input integer count, input bit retry_copy);
        reg [31:0] crc;
        reg [31:0] observed;
        reg [7:0] value;
        begin
            crc=32'hFFFFFFFF;
            for (integer k=2;k<count-4;k=k+1) begin
                value = retry_copy ? response_retry[k] : response[k];
                crc=crc32_byte(crc,value);
            end
            crc=crc ^ 32'hFFFFFFFF;
            observed = {
                retry_copy ? response_retry[count-4] : response[count-4],
                retry_copy ? response_retry[count-3] : response[count-3],
                retry_copy ? response_retry[count-2] : response[count-2],
                retry_copy ? response_retry[count-1] : response[count-1]
            };
            if (observed !== crc)
                $fatal(1,"response CRC mismatch got=%08x expected=%08x",observed,crc);
        end
    endtask

    initial begin
        board_rst_n=0; system_reset_n=0;
        secure_enable=1; key_zeroize=0;
        spi_sclk=0; spi_mosi=0; spi_cs_n=1;
        request_len=0;
        for (integer k=0;k<64;k=k+1) begin
            response[k]=0;
            response_retry[k]=0;
        end

        #500;
        board_rst_n=1;
        system_reset_n=1;
        #1000;

        /* End-to-end PING request and second-transaction response. */
        build_zero_payload_request(8'h7F,16'h1234);
        send_request();
        wait(irq_n===1'b0);
        #200;
        if (dut.u_spi_slave.rsp_len_q !== 11'd30)
            $fatal(1,"SPI response length cache wrong: %0d",dut.u_spi_slave.rsp_len_q);
        if ({dut.u_spi_slave.rsp_mem[26],dut.u_spi_slave.rsp_mem[27],
             dut.u_spi_slave.rsp_mem[28],dut.u_spi_slave.rsp_mem[29]} !==
            32'hA9F9A8EE)
            $fatal(1,"response RAM CRC wrong: %02x%02x%02x%02x",
                   dut.u_spi_slave.rsp_mem[26],dut.u_spi_slave.rsp_mem[27],
                   dut.u_spi_slave.rsp_mem[28],dut.u_spi_slave.rsp_mem[29]);
        read_response(30,1'b0);
        check_response_crc(30,1'b0);

        if (response[0]!=8'hA5 || response[1]!=8'h5A || response[2]!=8'h01 ||
            response[3]!=8'h7F || response[4]!=8'h01 || response[5]!=8'h00 ||
            {response[6],response[7]}!=16'h1234 ||
            {response[8],response[9]}!=16'd16 ||
            {response[10],response[11]}!=16'h0000 ||
            {response[22],response[23],response[24],response[25]}!=32'h46505354)
            $fatal(1,"end-to-end PING response malformed");

        /* Exact retry must return byte-identical cached response. */
        build_zero_payload_request(8'h7F,16'h1234);
        send_request();
        read_response(30,1'b1);
        check_response_crc(30,1'b1);
        for (integer k=0;k<30;k=k+1)
            if (response_retry[k] !== response[k])
                $fatal(1,"cached response differs at byte %0d",k);

        /* Same transaction ID with a changed request => collision error. */
        build_zero_payload_request(8'h02,16'h1234);
        send_request();
        read_response(26,1'b0);
        check_response_crc(26,1'b0);
        if (response[3]!=8'h02 || response[4]!=8'h03 ||
            {response[10],response[11]}!=16'h0207)
            $fatal(1,"collision response malformed");

        if (fault)
            $fatal(1,"recoverable BTP tests unexpectedly asserted fatal sideband");

        $display("PASS: tb_primer1_spi_endpoint");
        $finish;
    end
endmodule
