`timescale 1ns/1ps
module tb_clean;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(500))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 integer cycle=0;
 always @(posedge clk) if(!rst) cycle=cycle+1;
 
 initial begin
  #100; rst=0;
  $display("START: MS_CYCLES=%0d, ALARM_MS=%0d", dut.MS_CYCLES, dut.ALARM_MS);
  
  #500; result_done=1; result_class=2; #20; result_done=0;
  $display("cycle %0d: Sent class 2", cycle);
  
  fork
   begin: monitor
    integer last_ms=-1;
    forever @(posedge clk) begin
     if(dut.tick && (dut.alarm_ms!=last_ms || dut.alarm_ms>=995)) begin
      $display("cycle %0d: alarm_ms=%0d alarm=%0d", cycle, dut.alarm_ms, alarm);
      last_ms=dut.alarm_ms;
      if(alarm) disable monitor;
     end
    end
   end
   begin
    repeat(1100*50) @(posedge clk);
    $display("cycle %0d: Timeout", cycle);
    $finish;
   end
  join_any
  
  $display("cycle %0d: FINAL alarm=%0d", cycle, alarm);
  if(alarm) $display("PASS");
  else $display("FAIL");
  $finish;
 end
endmodule
