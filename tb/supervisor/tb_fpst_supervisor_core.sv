`timescale 1ns/1ps
module tb_fpst_supervisor_core;
localparam [15:0] E_MCU=16'h0701,E_PQC=16'h0702,E_CRY=16'h0703,E_TAMPER=16'h0704,E_MAN=16'h0705,E_ILLEGAL=16'h0706,E_AUTH=16'h0608;
localparam [2:0] ST_MONITOR=3'd2,ST_SAFE=3'd5,ST_RECOVERY=3'd6;
logic clk=0,rst_n=0,hb_mcu=0,hb_pqc=0,hb_crypto=0,crypto_fault=0,tamper=0,clear_pulse=0,manual_fault=0;
logic secure,zeroize,reset_n,fault; logic [15:0] code; logic [31:0] fault_time; logic [2:0] state,hb_timeout,hb_seen; logic all_healthy;
integer reset_pulse_seen;
fpst_supervisor_core #(.HB_TIMEOUT_MS(8),.STARTUP_ZEROIZE_MS(2),.STARTUP_GRACE_MS(4),.QUALIFY_MS(6),.ZEROIZE_HOLD_MS(2),.RESET_PULSE_MS(2),.RECOVERY_QUALIFY_MS(6),.RESET_ON_FATAL(1'b1)) dut(
 .clk_i(clk),.rst_ni(rst_n),.tick_ms_i(1'b1),.hb_mcu_i(hb_mcu),.hb_pqc_i(hb_pqc),.hb_crypto_i(hb_crypto),.crypto_fault_i(crypto_fault),
 .tamper_active_i(tamper),.clear_fault_pulse_i(clear_pulse),.manual_fault_i(manual_fault),
 .secure_enable_o(secure),.key_zeroize_o(zeroize),.system_reset_no(reset_n),.fault_latched_o(fault),
 .error_code_o(code),.first_fault_time_ms_o(fault_time),.state_o(state),.hb_timeout_o(hb_timeout),.hb_seen_o(hb_seen),.all_heartbeats_healthy_o(all_healthy));
always #5 clk=~clk;

task automatic reset_dut; begin
 rst_n=0; hb_mcu=0; hb_pqc=0; hb_crypto=0; crypto_fault=0; tamper=0; clear_pulse=0; manual_fault=0; reset_pulse_seen=0;
 repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
 if(secure!==0||zeroize!==1) $fatal(1,"reset is not fail-safe");
end endtask

task automatic healthy(input integer n); integer i; begin
 for(i=0;i<n;i=i+1) begin
  if((i%3)==0) begin hb_mcu=~hb_mcu; hb_pqc=~hb_pqc; hb_crypto=~hb_crypto; end
  @(posedge clk); if(!reset_n) reset_pulse_seen=1;
 end
end endtask

task automatic boot; begin
 healthy(24); if(state!==ST_MONITOR||!secure||zeroize) $fatal(1,"failed to enter MONITOR state=%0d",state);
end endtask

task automatic timeout_case(input integer which,input [15:0] expected); integer i; begin
 reset_dut(); boot(); reset_pulse_seen=0;
 for(i=0;i<14;i=i+1) begin
  if((i%3)==0) begin if(which!=0)hb_mcu=~hb_mcu; if(which!=1)hb_pqc=~hb_pqc; if(which!=2)hb_crypto=~hb_crypto; end
  @(posedge clk); if(!reset_n) reset_pulse_seen=1;
 end
 if(!fault||code!==expected) $fatal(1,"timeout code got=%04h expected=%04h",code,expected);
 healthy(8); if(state!==ST_SAFE||!fault||secure||!zeroize) $fatal(1,"not SAFE_LOCKED after fatal");
 if(!reset_pulse_seen) $fatal(1,"reset pulse missing after zeroize");
end endtask

initial begin
 reset_dut(); boot();
 timeout_case(0,E_MCU); timeout_case(1,E_PQC); timeout_case(2,E_CRY);

 reset_dut(); boot(); reset_pulse_seen=0; tamper=1; repeat(2) @(posedge clk);
 if(secure||!zeroize||!fault||code!==E_TAMPER) $fatal(1,"tamper response failed");
 healthy(8); if(state!==ST_SAFE) $fatal(1,"tamper did not reach SAFE_LOCKED");
 clear_pulse=1; @(posedge clk); clear_pulse=0; healthy(10);
 if(!fault||state!==ST_SAFE) $fatal(1,"clear accepted while tamper active");
 tamper=0; healthy(6); clear_pulse=1; @(posedge clk); clear_pulse=0; healthy(10);
 if(fault) $fatal(1,"qualified recovery did not clear latch");
 healthy(20); if(state!==ST_MONITOR||!secure) $fatal(1,"did not re-enter MONITOR");

 reset_dut(); boot(); manual_fault=1; repeat(4) @(posedge clk); manual_fault=0;
 if(!fault||code!==E_MAN) $fatal(1,"manual fault classification failed");
 tamper=1; repeat(3) @(posedge clk); if(code!==E_MAN) $fatal(1,"first fatal code overwritten"); tamper=0;

 /* Direct P2 crypto cause is distinct from HB_CRYPTO timeout and blocks clear while active. */
 reset_dut(); boot(); crypto_fault=1; repeat(4) @(posedge clk);
 if(!fault||code!==E_AUTH||secure||!zeroize) $fatal(1,"crypto fault arbitration failed code=%04h",code);
 healthy(8); if(state!==ST_SAFE) $fatal(1,"crypto fault did not reach SAFE_LOCKED");
 clear_pulse=1; @(posedge clk); clear_pulse=0; healthy(8);
 if(state!==ST_SAFE||!fault) $fatal(1,"clear accepted while crypto cause active");
 crypto_fault=0; healthy(5); clear_pulse=1; @(posedge clk); clear_pulse=0; healthy(2);
 if(state!==ST_RECOVERY) $fatal(1,"crypto fault recovery did not enter qualification");
 healthy(10); if(fault) $fatal(1,"crypto fault qualified recovery did not clear");

 reset_dut(); boot(); force dut.state_q=3'b111; @(posedge clk); release dut.state_q; repeat(2) @(posedge clk);
 if(!fault||code!==E_ILLEGAL||secure) $fatal(1,"illegal-state fail-safe failed");

 $display("PASS: tb_fpst_supervisor_core"); $finish;
end
endmodule
