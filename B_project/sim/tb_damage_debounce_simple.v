`timescale 1ns/1ps
module tb_damage_debounce_simple;
 reg clk=0,rst=1,camera_good=0,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(500))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 integer tick_count=0;
 always @(posedge clk) if(!rst && dut.tick) tick_count<=tick_count+1;
 
 initial begin
  $dumpfile("tb_damage_debounce_simple.vcd");
  $dumpvars(0,tb_damage_debounce_simple);
  
  #100; rst=0; camera_good=1;
  $display("Test: sustained class 2");
  
  #200; result_done=1; result_class=2; #20; result_done=0;
  $display("Class 2 sent, alarm_counting=%0d, alarm_ms=%0d", dut.alarm_counting, dut.alarm_ms);
  
  // Wait exactly 1000 ticks
  tick_count=0;
  wait(tick_count>=1000);
  @(posedge clk); @(posedge clk); // Wait 2 more cycles for assignment
  
  $display("After 1000 ticks: alarm_ms=%0d, counting=%0d, alarm=%0d", 
           dut.alarm_ms, dut.alarm_counting, alarm);
  if(!alarm) begin $display("FAIL: no alarm after 1s"); $finish; end
  
  $display("PASS");
  $finish;
 end
 
 initial #3000000 begin
  $display("TIMEOUT at tick %0d", tick_count);
  $finish;
 end
endmodule
