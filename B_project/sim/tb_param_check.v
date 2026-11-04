`timescale 1ns/1ps
module tb_param_check;
 reg clk=0,rst=1,camera_good=1,result_done=0;
 reg [1:0] result_class=0;
 wire alarm,valid;
 wire [1:0] last_class;
 
 always #10 clk=~clk;
 
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(1000),.CLEAR_MS(3000),.STALE_MS(500))
  dut(.clk(clk),.rst(rst),.camera_good(camera_good),.result_done(result_done),
      .result_class(result_class),.alarm(alarm),.valid(valid),.last_class(last_class));
 
 initial begin
  $display("Parameters: MS_CYCLES=%0d, ALARM_MS=%0d, AL_BITS=%0d", 
           dut.MS_CYCLES, dut.ALARM_MS, dut.AL_BITS);
  #100; rst=0;
  #200; result_done=1; result_class=2; #20; result_done=0;
  
  repeat(600) begin
   @(posedge clk);
   if(dut.tick) begin
    $display("tick: alarm_ms=%0d, counting=%0d, alarm=%0d, check_limit=%0d", 
             dut.alarm_ms, dut.alarm_counting, alarm, dut.alarm_ms<dut.ALARM_MS);
    if(dut.alarm_ms>=550) $finish;
   end
  end
  $finish;
 end
endmodule
