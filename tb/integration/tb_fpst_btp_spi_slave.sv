`timescale 1ns/1ps
module tb_fpst_btp_spi_slave;
    logic clk=0,rst_n=0,zeroize=0;
    logic sclk=0,mosi=0,miso,cs_n=1,irq_n,busy,fault;
    logic cmd_valid,cmd_ready;
    logic [7:0] cmd_opcode,cmd_flags;
    logic [15:0] cmd_txid,cmd_len;
    logic [9:0] cmd_addr;
    logic [7:0] cmd_data;
    logic rsp_we,rsp_valid,rsp_ready;
    logic [9:0] rsp_addr;
    logic [7:0] rsp_data,rsp_opcode,rsp_flags;
    logic [15:0] rsp_txid,rsp_len;
    logic link_err_v; logic [15:0] link_err;
    reg [7:0] req[0:31]; reg [7:0] rsp[0:31];
    integer i;
    localparam [7:0] OP_PING = 8'h7F;
    always #18.5 clk=~clk; // approximately 27 MHz

    fpst_btp_spi_slave dut(
        .sys_clk_i(clk),.rst_ni(rst_n),.zeroize_i(zeroize),
        .spi_sclk_i(sclk),.spi_mosi_i(mosi),.spi_miso_o(miso),.spi_cs_ni(cs_n),
        .irq_no(irq_n),.busy_o(busy),.fault_o(fault),
        .cmd_valid_o(cmd_valid),.cmd_ready_i(cmd_ready),.cmd_opcode_o(cmd_opcode),
        .cmd_flags_o(cmd_flags),.cmd_transaction_id_o(cmd_txid),.cmd_payload_len_o(cmd_len),
        .cmd_payload_addr_i(cmd_addr),.cmd_payload_data_o(cmd_data),
        .rsp_payload_we_i(rsp_we),.rsp_payload_addr_i(rsp_addr),.rsp_payload_data_i(rsp_data),
        .rsp_valid_i(rsp_valid),.rsp_ready_o(rsp_ready),.rsp_opcode_i(rsp_opcode),
        .rsp_flags_i(rsp_flags),.rsp_transaction_id_i(rsp_txid),.rsp_payload_len_i(rsp_len),
        .link_error_valid_o(link_err_v),.link_error_code_o(link_err));

    function automatic [31:0] crc_byte(input [31:0] ci,input [7:0] d);
        reg [31:0] c; integer k;
        begin c=ci^d; for(k=0;k<8;k=k+1) c=c[0]?((c>>1)^32'hEDB88320):(c>>1); crc_byte=c; end
    endfunction

    task spi_tx_byte(input [7:0] b);
        integer k;
        begin
            for(k=7;k>=0;k=k-1) begin
                mosi=b[k]; #500; sclk=1; #500; sclk=0;
            end
        end
    endtask

    task spi_rx_byte(output [7:0] b);
        integer k; reg [7:0] t;
        begin
            t=0;
            for(k=7;k>=0;k=k-1) begin
                mosi=0; #500; sclk=1; #100; t[k]=miso; #400; sclk=0;
            end
            b=t;
        end
    endtask

    task build_ping(input [15:0] txid);
        reg [31:0] c;
        begin
            req[0]=8'hA5; req[1]=8'h5A; req[2]=8'h01; req[3]=OP_PING;
            req[4]=8'h00; req[5]=8'h00;
            req[6]=txid[15:8]; req[7]=txid[7:0]; req[8]=0; req[9]=0;
            c=32'hFFFFFFFF;
            for(i=2;i<10;i=i+1) c=crc_byte(c,req[i]);
            c=~c;
            req[10]=c[31:24]; req[11]=c[23:16]; req[12]=c[15:8]; req[13]=c[7:0];
        end
    endtask

    initial begin
        cmd_ready=0;cmd_addr=0;rsp_we=0;rsp_valid=0;rsp_addr=0;rsp_data=0;
        rsp_opcode=0;rsp_flags=0;rsp_txid=0;rsp_len=0;
        repeat(5) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);

        build_ping(16'h1234);
        cs_n=0; #300; for(i=0;i<14;i=i+1) spi_tx_byte(req[i]); #300; cs_n=1;
        fork begin wait(cmd_valid); end begin #200000; $fatal(1,"no decoded request"); end join_any disable fork;
        if(cmd_opcode!==OP_PING||cmd_txid!==16'h1234||cmd_len!==0)
            $fatal(1,"decoded request mismatch");

        // Stage generic success payload 0000, then release command.
        rsp_we=1;rsp_addr=0;rsp_data=0;@(posedge clk);rsp_addr=1;@(posedge clk);rsp_we=0;
        cmd_ready=1;@(posedge clk);cmd_ready=0;

        // Wait until response builder can accept a response. valid is held for
        // one complete ready/valid transfer only; waiting for ready AFTER that
        // transfer would deadlock because ready correctly falls while cached.
        wait(rsp_ready);
        rsp_opcode=OP_PING;rsp_flags=0;rsp_txid=16'h1234;rsp_len=2;rsp_valid=1;
        @(posedge clk); #1;
        rsp_valid=0;

        fork begin wait(!irq_n); end begin #200000;$fatal(1,"irq not asserted");end join_any disable fork;

        cs_n=0; #300; for(i=0;i<16;i=i+1) spi_rx_byte(rsp[i]); #300; cs_n=1;
        if(rsp[0]!==8'hA5||rsp[1]!==8'h5A||rsp[2]!==8'h01||rsp[3]!==OP_PING||
           rsp[4]!==8'h01||rsp[5]!==8'h00||rsp[6]!==8'h12||rsp[7]!==8'h34||
           rsp[8]!==0||rsp[9]!==2||rsp[10]!==0||rsp[11]!==0)
            $fatal(1,"response header/payload mismatch");
        begin reg [31:0] c,got; c=32'hFFFFFFFF;
            for(i=2;i<12;i=i+1)c=crc_byte(c,rsp[i]); c=~c;
            got={rsp[12],rsp[13],rsp[14],rsp[15]};
            if(got!==c) $fatal(1,"response CRC mismatch");
        end
        repeat(10) @(posedge clk);
        if(!irq_n) $fatal(1,"irq did not clear after response transaction");

        // Bad CRC must be rejected before dispatcher publication.
        build_ping(16'h1235);
        req[13] = req[13] ^ 8'h01;
        cs_n=0; #300; for(i=0;i<14;i=i+1) spi_tx_byte(req[i]); #300; cs_n=1;
        repeat(30) @(posedge clk);
        if(cmd_valid) $fatal(1,"bad CRC request reached dispatcher");
        fork begin wait(!irq_n); end begin #200000;$fatal(1,"CRC error response missing");end join_any disable fork;

        $display("PASS: fpst_btp_spi_slave two-transaction CRC32 BTP @1MHz");
        $finish;
    end
endmodule
