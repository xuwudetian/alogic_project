`timescale 1ns/1ps
module tb_clear_debug;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(5000))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 integer cycle=0;
 always @(posedge clk) if(!rst) cycle=cycle+1;
 
 initial begin
  #100; rst=0;
  
  // Trigger alarm
  #500; result_done=1; result_class=2; #20; result_done=0;
  $display("cycle %0d: Sent class 2", cycle);
  
  #1020000;
  $display("cycle %0d: alarm=%0d, alarm_ms=%0d", cycle, alarm, dut.alarm_ms);
  if(!alarm) begin $display("FAIL: no alarm"); $finish; end
  
  // Send class 0 to start clear
  #500; result_done=1; result_class=0; #20; result_done=0;
  $display("cycle %0d: Sent class 0, clear_counting=%0d", cycle, dut.clear_counting);
  
  // Monitor clear progress
  fork
   begin: mon
    integer last_clear=-1;
    forever @(posedge clk) begin
     if(dut.tick && (dut.clear_ms!=last_clear || dut.clear_ms>=2995)) begin
      $display("cycle %0d: clear_ms=%0d counting=%0d alarm=%0d", 
               cycle, dut.clear_ms, dut.clear_counting, alarm);
      last_clear=dut.clear_ms;
      if(!alarm) disable mon;
     end
    end
   end
   begin
    #3200000; $display("Clear timeout"); $finish;
   end
  join_any
  
  $display("cycle %0d: FINAL alarm=%0d", cycle, alarm);
  if(!alarm) $display("PASS");
  else $display("FAIL: alarm not cleared");
  $finish;
 end
endmodule
