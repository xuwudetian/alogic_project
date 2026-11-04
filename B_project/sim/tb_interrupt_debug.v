`timescale 1ns/1ps
module tb_interrupt_debug;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(10000))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 integer cycle=0;
 always @(posedge clk) if(!rst) cycle=cycle+1;
 
 initial begin
  #100; rst=0;
  $display("Test: class 2 for 800ms, then class 1");
  
  @(posedge clk); result_done=1; result_class=2;
  @(posedge clk); result_done=0;
  $display("cycle %0d: Sent class 2, counting=%0d", cycle, dut.alarm_counting);
  
  // Wait 800ms
  repeat(800*50) @(posedge clk);
  $display("cycle %0d: After 800ms, alarm_ms=%0d counting=%0d alarm=%0d", 
           cycle, dut.alarm_ms, dut.alarm_counting, alarm);
  
  // Send class 1 to interrupt
  @(posedge clk); result_done=1; result_class=1;
  @(posedge clk); result_done=0;
  @(posedge clk); @(posedge clk);
  $display("cycle %0d: Sent class 1, counting=%0d alarm_ms=%0d", 
           cycle, dut.alarm_counting, dut.alarm_ms);
  
  // Wait 300ms more
  repeat(300*50) @(posedge clk);
  $display("cycle %0d: After 300ms more, alarm_ms=%0d alarm=%0d", 
           cycle, dut.alarm_ms, alarm);
  
  if(alarm) $display("FAIL: alarm triggered");
  else $display("PASS: alarm not triggered");
  $finish;
 end
 
 initial #3000000 $finish;
endmodule
