`timescale 1ns/1ps
// Hold alarm display for HOLD_MS after the upstream alarm clears. Any new alarm
// asserts immediately. This adds user-facing stability without affecting the
// state-machine layer or B's detection threshold.
module net_alarm_hold #(
 parameter MS_CYCLES=50000, HOLD_MS=3000
)(input clk,input rst,input upstream_alarm,output reg display_alarm);
 localparam T_BITS=MS_CYCLES>1?$clog2(MS_CYCLES):1;
 localparam H_BITS=$clog2(HOLD_MS+1);
 reg [T_BITS-1:0] tick_count;
 reg [H_BITS-1:0] hold_elapsed;
 reg holding;
 wire tick=tick_count==MS_CYCLES-1;
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   tick_count<=0;hold_elapsed<=0;holding<=0;display_alarm<=0;
  end else begin
   if(tick) tick_count<=0;else tick_count<=tick_count+1'b1;
   if(tick && holding && hold_elapsed<HOLD_MS) hold_elapsed<=hold_elapsed+1'b1;
   if(upstream_alarm) begin
    display_alarm<=1;holding<=0;hold_elapsed<=0;
   end else if(!holding) begin
    if(display_alarm) begin
     holding<=1;hold_elapsed<=0;tick_count<=0;
    end
   end else if(hold_elapsed>=HOLD_MS) begin
    display_alarm<=0;holding<=0;
   end
  end
 end
endmodule
