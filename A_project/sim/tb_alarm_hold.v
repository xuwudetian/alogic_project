`timescale 1ns/1ps
module tb_alarm_hold;
 reg clk=0,rst=1,upstream_alarm=0;
 wire display_alarm;
 
 always #20 clk=~clk; // 25 MHz video clock
 
 // 1 ms = 25,000 cycles; use 25 for simulation
 net_alarm_hold #(.MS_CYCLES(25),.HOLD_MS(3000))
  dut(.clk(clk),.rst(rst),.upstream_alarm(upstream_alarm),.display_alarm(display_alarm));
 
 integer ms_count=0;
 always @(posedge clk) if(!rst && dut.tick) ms_count<=ms_count+1;
 
 initial begin
  $dumpfile("tb_alarm_hold.vcd");
  $dumpvars(0,tb_alarm_hold);
  
  #100; rst=0;
  
  // Upstream alarm asserts immediately
  #200; upstream_alarm=1;
  #100;
  if(!display_alarm) begin $display("FAIL: display not immediate"); $finish; end
  
  // Hold during upstream alarm
  #5000;
  if(!display_alarm) begin $display("FAIL: display dropped during alarm"); $finish; end
  
  // Upstream clears, display holds for 3s
  ms_count=0;
  #200; upstream_alarm=0;
  #100;
  if(!display_alarm) begin $display("FAIL: display cleared immediately"); $finish; end
  
  wait(ms_count>=2999);
  #100;
  if(!display_alarm) begin $display("FAIL: display cleared before 3s"); $finish; end
  
  wait(ms_count>=3001);
  #100;
  if(display_alarm) begin $display("FAIL: display not cleared after 3s"); $finish; end
  
  // New alarm during hold period cancels hold
  ms_count=0;
  #200; upstream_alarm=1;
  #100;
  if(!display_alarm) begin $display("FAIL: no display on new alarm"); $finish; end
  
  #1000; // wait 1s
  wait(ms_count>=1000);
  upstream_alarm=0;
  #100;
  if(!display_alarm) begin $display("FAIL: display cleared at hold start"); $finish; end
  
  // New alarm interrupts hold
  #500;
  upstream_alarm=1;
  #100;
  if(!display_alarm) begin $display("FAIL: display not re-asserted"); $finish; end
  
  $display("PASS: A alarm hold test");
  $finish;
 end
 
 initial #150000 begin
  $display("TIMEOUT");
  $finish;
 end
endmodule
