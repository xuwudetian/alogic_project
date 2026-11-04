`timescale 1ns/1ps
module tb_damage_debounce_debug;
 reg clk=0,rst=1,camera_good=0,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(500))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 integer tick_count=0,last_alarm_ms=-1;
 always @(posedge clk) begin
  if(!rst && dut.tick) begin
   tick_count<=tick_count+1;
   if(dut.alarm_ms!=last_alarm_ms || tick_count%100==99) begin
    $display("tick=%0d alarm_ms=%0d counting=%0d alarm=%0d", 
             tick_count+1, dut.alarm_ms, dut.alarm_counting, alarm);
    last_alarm_ms<=dut.alarm_ms;
   end
  end
 end
 
 initial begin
  #100; rst=0; camera_good=1;
  
  #200; result_done=1; result_class=2; #20; result_done=0;
  
  #1010000;
  $display("Final: alarm=%0d", alarm);
  if(!alarm) $display("FAIL");
  else $display("PASS");
  $finish;
 end
 
 initial #3000000 $finish;
endmodule
