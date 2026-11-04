`timescale 1ns/1ps
module tb_sustain;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 // Use 2000ms stale threshold so 1 result can sustain 1s alarm countdown
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(2000))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 initial begin
  #100; rst=0;
  $display("Test: sustained class 2 alarm");
  
  #500; result_done=1; result_class=2; #20; result_done=0;
  $display("Sent class 2");
  
  #1020000; // Wait 1020ms
  
  $display("After 1020ms: alarm=%0d, alarm_ms=%0d", alarm, dut.alarm_ms);
  if(!alarm) begin $display("FAIL: no alarm"); $finish; end
  $display("PASS: alarm after 1s class 2");
  
  // Test clear after 3s
  #500; result_done=1; result_class=0; #20; result_done=0;
  $display("Sent class 0");
  
  #3010000;
  $display("After 3010ms clear: alarm=%0d", alarm);
  if(alarm) begin $display("FAIL: alarm not cleared"); $finish; end
  $display("PASS: alarm cleared after 3s");
  
  $finish;
 end
 
 initial #6000000 begin $display("TIMEOUT"); $finish; end
endmodule
