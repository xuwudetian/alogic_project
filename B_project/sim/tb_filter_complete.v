`timescale 1ns/1ps
module tb_filter_complete;
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
  end
 endtask
 
 task wait_ms(input integer ms);
  repeat(ms) repeat(50) @(posedge clk);
 endtask
 
 initial begin
  #100; rst=0;
  $display("Test 1: class 0/1 no alarm");
  send_result(0); wait_ms(100);
  send_result(1); wait_ms(100);
  if(alarm) begin $display("FAIL: alarm on non-damage"); $finish; end
  $display("PASS");
  
  $display("\nTest 2: class 2 < 1s no alarm");
  send_result(2); wait_ms(500);
  if(alarm) begin $display("FAIL: early alarm"); $finish; end
  send_result(0); wait_ms(10);  // Reset for next test
  $display("PASS");
  
  $display("\nTest 3: interrupted class 2");
  send_result(2); wait_ms(800);
  send_result(1);  // Interrupt before 1s
  wait_ms(300);
  if(alarm) begin $display("FAIL: alarm after interrupt"); $finish; end
  $display("PASS");
  
  $display("\nTest 4: sustained class 2 >= 1s triggers alarm");
  send_result(2); wait_ms(1010);
  if(!alarm) begin $display("FAIL: no alarm after 1s"); $finish; end
  if(last_class!=2) begin $display("FAIL: last_class=%0d", last_class); $finish; end
  $display("PASS: alarm=%0d at %0d ms", alarm, dut.alarm_ms);
  
  $display("\nTest 5: continued class 2 keeps alarm");
  send_result(2); wait_ms(200);
  if(!alarm) begin $display("FAIL: alarm cleared"); $finish; end
  $display("PASS");
  
  $display("\nTest 6: class 1 starts clear, held < 3s");
  send_result(1); wait_ms(2900);
  if(!alarm) begin $display("FAIL: alarm cleared too early"); $finish; end
  $display("PASS: clear_ms=%0d", dut.clear_ms);
  
  $display("\nTest 7: alarm clears after >= 3s non-damage");
  wait_ms(200);
  if(alarm) begin $display("FAIL: alarm not cleared, clear_ms=%0d", dut.clear_ms); $finish; end
  $display("PASS");
  
  $display("\nTest 8: clear interrupted by class 2");
  send_result(2); wait_ms(1010);
  if(!alarm) begin $display("FAIL: second alarm failed"); $finish; end
  send_result(0); wait_ms(1500);  // Start clear
  if(!alarm) begin $display("FAIL: cleared too early"); $finish; end
  send_result(2);  // Interrupt clear
  wait_ms(10);
  if(!alarm) begin $display("FAIL: alarm dropped on interrupt"); $finish; end
  if(dut.clear_counting) begin $display("FAIL: clear not stopped"); $finish; end
  $display("PASS");
  
  $display("\nTest 9: final clear after interruption");
  send_result(1); wait_ms(3050);
  if(alarm) begin $display("FAIL: final clear failed"); $finish; end
  $display("PASS");
  
  $display("\n=== ALL TESTS PASSED ===");
  $finish;
 end
 
 initial #20000000 begin
  $display("TIMEOUT");
  $finish;
 end
endmodule
