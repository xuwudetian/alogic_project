`timescale 1ns/1ps
module tb_damage_debounce;
 reg clk=0,rst=1,camera_good=0,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(500))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 initial begin
  $dumpfile("tb_damage_debounce.vcd");
  $dumpvars(0,tb_damage_debounce);
  
  #100; rst=0; camera_good=1;
  $display("Test start");
  
  // Class 0/1 should not trigger
  #200; result_done=1; result_class=0; #20; result_done=0;
  #5000;
  if(alarm) begin $display("FAIL: alarm on class 0"); $finish; end
  
  #200; result_done=1; result_class=1; #20; result_done=0;
  #5000;
  if(alarm) begin $display("FAIL: alarm on class 1"); $finish; end
  $display("Pass: class 0/1 no alarm");
  
  // Class 2 < 1s should not trigger
  #200; result_done=1; result_class=2; #20; result_done=0;
  #500000; // 500ms
  if(alarm) begin $display("FAIL: alarm before 1s threshold"); $finish; end
  $display("Pass: class 2 < 1s no alarm");
  
  // Switch to class 0 before threshold
  result_done=1; result_class=0; #20; result_done=0;
  #5000;
  if(alarm) begin $display("FAIL: alarm after interrupted class 2"); $finish; end
  $display("Pass: interrupted class 2");
  
  // Sustained class 2 >= 1s should trigger
  #200; result_done=1; result_class=2; #20; result_done=0;
  #1010000; // 1010ms
  if(!alarm) begin $display("FAIL: no alarm after 1s class 2"); $finish; end
  if(last_class!=2) begin $display("FAIL: last_class not 2"); $finish; end
  $display("Pass: 1s sustained class 2 triggers alarm");
  
  // Continue class 2 keeps alarm
  #200; result_done=1; result_class=2; #20; result_done=0;
  #100000;
  if(!alarm) begin $display("FAIL: alarm cleared during continued class 2"); $finish; end
  $display("Pass: continued class 2 keeps alarm");
  
  // Switch to class 1, alarm should clear after 3s
  #200; result_done=1; result_class=1; #20; result_done=0;
  
  // Before 3s
  #2999000;
  if(!alarm) begin $display("FAIL: alarm cleared before 3s"); $finish; end
  $display("Pass: alarm held < 3s");
  
  // After 3s
  #2000;
  if(alarm) begin $display("FAIL: alarm not cleared after 3s"); $finish; end
  $display("Pass: alarm cleared after 3s non-damage");
  
  // Interrupt clear timer with class 2
  #200; result_done=1; result_class=2; #20; result_done=0;
  #1010000;
  if(!alarm) begin $display("FAIL: second class 2 no alarm"); $finish; end
  
  #200; result_done=1; result_class=0; #20; result_done=0;
  #1500000; // 1.5s
  if(!alarm) begin $display("FAIL: alarm cleared too early"); $finish; end
  
  // Interrupt clear with class 2 again
  result_done=1; result_class=2; #20; result_done=0;
  #500;
  if(!alarm) begin $display("FAIL: alarm cleared during new class 2"); $finish; end
  $display("Pass: clear timer interrupted by new class 2");
  
  $display("PASS: All debounce tests");
  $finish;
 end
 
 initial #10000000 begin
  $display("TIMEOUT");
  $finish;
 end
endmodule
