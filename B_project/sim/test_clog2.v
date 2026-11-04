`timescale 1ns/1ps
module test_clog2;
 localparam ALARM_MS=1000;
 localparam AL_BITS=$clog2(ALARM_MS+1);
 initial begin
  $display("ALARM_MS=%0d, AL_BITS=%0d, max_value=%0d", ALARM_MS, AL_BITS, (1<<AL_BITS)-1);
  if(AL_BITS<10) $display("ERROR: AL_BITS too small!");
  $finish;
 end
endmodule
