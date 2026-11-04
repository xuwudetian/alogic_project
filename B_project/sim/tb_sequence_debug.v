`timescale 1ns/1ps
module tb_sequence_debug;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(10000))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 task send_result(input [1:0] cls);
  begin
   @(posedge clk); result_done=1; result_class=cls;
   @(posedge clk); result_done=0;
   @(posedge clk);
  end
 endtask
 
 task wait_ms(input integer ms);
  repeat(ms*50) @(posedge clk);
 endtask
 
 integer cycle=0;
 always @(posedge clk) if(!rst) cycle=cycle+1;
 
 initial begin
  #100; rst=0;
  
  $display("Test 1: class 0/1");
  send_result(0); wait_ms(100);
  send_result(1); wait_ms(100);
  $display("After test 1: counting=%0d alarm_ms=%0d alarm=%0d", 
           dut.alarm_counting, dut.alarm_ms, alarm);
  
  $display("\nTest 2: class 2 < 1s");
  send_result(2); 
  $display("After send class 2: counting=%0d alarm_ms=%0d", 
           dut.alarm_counting, dut.alarm_ms);
  wait_ms(500);
  $display("After 500ms: counting=%0d alarm_ms=%0d alarm=%0d", 
           dut.alarm_counting, dut.alarm_ms, alarm);
  
  $display("\nTest 3: interrupted class 2");
  send_result(2);
  $display("After send class 2: counting=%0d alarm_ms=%0d", 
           dut.alarm_counting, dut.alarm_ms);
  wait_ms(800);
  $display("After 800ms: counting=%0d alarm_ms=%0d alarm=%0d", 
           dut.alarm_counting, dut.alarm_ms, alarm);
  send_result(1);
  $display("After send class 1: counting=%0d alarm_ms=%0d", 
           dut.alarm_counting, dut.alarm_ms);
  wait_ms(300);
  $display("After 300ms: alarm_ms=%0d alarm=%0d", dut.alarm_ms, alarm);
  
  if(alarm) $display("FAIL");
  else $display("PASS");
  $finish;
 end
 
 initial #5000000 $finish;
endmodule
