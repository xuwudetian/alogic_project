`timescale 1ns/1ps
// 2026/10/20: Sustained threshold check accounts for same-cycle tick.
module net_damage_filter #(
 parameter MS_CYCLES=50000, ALARM_MS=1000, CLEAR_MS=3000, STALE_MS=500
)(input clk,input rst,input camera_good,input result_done,input [1:0] result_class,
  output reg alarm,output wire valid,output reg [1:0] last_class);
 localparam T_BITS=MS_CYCLES>1?$clog2(MS_CYCLES):1;
 localparam A_BITS=$clog2(STALE_MS+1), M_BITS=$clog2(ALARM_MS+1), C_BITS=$clog2(CLEAR_MS+1);
 reg [T_BITS-1:0] tick_count;
 reg [A_BITS-1:0] age;
 reg [M_BITS-1:0] alarm_elapsed;
 reg [C_BITS-1:0] clear_elapsed;
 reg alarm_pending,clear_pending,known;
 wire tick=tick_count==MS_CYCLES-1;
 wire usable=camera_good && result_class<3;
 assign valid=known && camera_good && age<STALE_MS;
 
 // Compute what alarm/clear elapsed *would be* after this cycle's tick
 wire [M_BITS-1:0] alarm_after_tick = (tick && alarm_pending && alarm_elapsed<ALARM_MS) ? alarm_elapsed+1'b1 : alarm_elapsed;
 wire [C_BITS-1:0] clear_after_tick = (tick && clear_pending && clear_elapsed<CLEAR_MS) ? clear_elapsed+1'b1 : clear_elapsed;
 
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   tick_count<=0;age<=STALE_MS;alarm_elapsed<=0;clear_elapsed<=0;
   alarm_pending<=0;clear_pending<=0;known<=0;alarm<=0;last_class<=0;
  end else begin
   // Tick generation
   if(tick) tick_count<=0;else tick_count<=tick_count+1'b1;
   if(tick && age<STALE_MS) age<=age+1'b1;
   
   // Accumulate elapsed time while pending
   if(tick && alarm_pending && alarm_elapsed<ALARM_MS) alarm_elapsed<=alarm_elapsed+1'b1;
   if(tick && clear_pending && clear_elapsed<CLEAR_MS) clear_elapsed<=clear_elapsed+1'b1;
   
   // Camera loss resets all state
   if(!camera_good || age>=STALE_MS) begin
    alarm_pending<=0;clear_pending<=0;alarm_elapsed<=0;clear_elapsed<=0;known<=0;
   end
   
   if(result_done) begin
    if(!usable) begin
     alarm_pending<=0;clear_pending<=0;alarm_elapsed<=0;clear_elapsed<=0;
     known<=0;age<=STALE_MS;
    end else begin
     age<=0;
     last_class<=result_class;
     if(result_class==2) begin
      // Damage result
      if(alarm_pending && age<STALE_MS) begin
       // Check threshold including in-flight tick
       if(alarm_after_tick>=ALARM_MS) begin
        alarm<=1;
        known<=1;
       end
      end else begin
       // Start new alarm countdown
       alarm_pending<=1;
       alarm_elapsed<=0;
       tick_count<=0;
      end
      // Cancel any clear
      clear_pending<=0;
      clear_elapsed<=0;
     end else begin
      // Healthy result (class 0 or 1)
      if(clear_pending && age<STALE_MS) begin
       if(clear_after_tick>=CLEAR_MS) begin
        alarm<=0;
        known<=1;
       end
      end else begin
       // Start new clear countdown
       clear_pending<=1;
       clear_elapsed<=0;
       tick_count<=0;
      end
      // Cancel any alarm countdown
      alarm_pending<=0;
      alarm_elapsed<=0;
     end
    end
   end
  end
 end
endmodule
