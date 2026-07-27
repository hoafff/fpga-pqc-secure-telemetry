`timescale 1ns/1ps
module tb_fpst_heartbeat_watchdog;
logic clk=0,rst_n=0,hb=0; logic seen,timeout,healthy,transition_pulse;
fpst_heartbeat_watchdog #(.TIMEOUT_MS(5)) dut(
 .clk_i(clk),.rst_ni(rst_n),.tick_ms_i(1'b1),.heartbeat_async_i(hb),.armed_i(1'b1),
 .seen_o(seen),.timeout_o(timeout),.healthy_o(healthy),.transition_pulse_o(transition_pulse));
always #5 clk=~clk;
initial begin
 repeat(3) @(posedge clk); rst_n=1; repeat(3) @(posedge clk);
 if(seen) $fatal(1,"static initial heartbeat incorrectly marked seen");
 hb=1; repeat(4) @(posedge clk);
 if(!seen||!healthy||timeout) $fatal(1,"heartbeat transition not accepted");
 repeat(6) @(posedge clk);
 if(!timeout||healthy) $fatal(1,"timeout did not assert");
 hb=0; repeat(4) @(posedge clk);
 if(timeout||!healthy) $fatal(1,"heartbeat did not recover");
 $display("PASS: tb_fpst_heartbeat_watchdog"); $finish;
end
endmodule
