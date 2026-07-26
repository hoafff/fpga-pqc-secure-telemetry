`timescale 1ns/1ps
module tb_fpst_debounce_active_low;
logic clk=0,rst_n=0,async_n=1; logic active,pulse; integer pulse_count=0;
fpst_debounce_active_low #(.STABLE_MS(3)) dut(
 .clk_i(clk),.rst_ni(rst_n),.tick_ms_i(1'b1),.async_ni(async_n),.active_o(active),.assert_pulse_o(pulse));
always #5 clk=~clk;
always @(posedge clk) if(pulse) pulse_count=pulse_count+1;
initial begin
 repeat(3) @(posedge clk); rst_n=1; repeat(3) @(posedge clk);
 async_n=0; @(posedge clk); async_n=1; repeat(4) @(posedge clk);
 if(active||pulse_count!=0) $fatal(1,"short bounce accepted");
 async_n=0; repeat(7) @(posedge clk);
 if(!active||pulse_count!=1) $fatal(1,"stable assertion failed");
 async_n=1; repeat(7) @(posedge clk);
 if(active||pulse_count!=1) $fatal(1,"release behavior wrong");
 $display("PASS: tb_fpst_debounce_active_low"); $finish;
end
endmodule
