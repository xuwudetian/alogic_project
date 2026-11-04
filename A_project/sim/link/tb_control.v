`timescale 1ns/1ps
module tb_control;
 reg clk=0,rst=1,frame=0,network=0,rv=0,sound=0,clear_sound=0;
 reg [7:0] cmd=0;reg [23:0] arg=0;
 wire alarm,dir,status;wire [1:0] mode;wire [2:0] result;
 always #10 clk=~clk;
 player_control #(.NETWORK_ENABLE(1),.REMOTE_ENABLE(1),.SENSOR_ENABLE(1)) dut(
 .clk(clk),.rst(rst),.frame_tick(frame),.key_next(1'b1),.key_auto(1'b1),.key_menu(1'b1),.switches(4'b0),
 .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b1),.sensor_alarm(sound),.sensor_alarm_clear(clear_sound),
 .network_alarm(network),.playback_fault(1'b0),.remote_valid(rv),.remote_command(cmd),.remote_argument(arg),
 .alarm(alarm),.directory(dir),.status_panel(status),.run_mode(mode),.remote_result(result));
 task commit;begin @(negedge clk);frame=1;@(negedge clk);frame=0;end endtask
 task command;input [7:0] c;input [23:0] a;begin @(negedge clk);cmd=c;arg=a;rv=1;@(negedge clk);rv=0;end endtask
 initial begin
  repeat(3) @(negedge clk);rst=0;
  command(8'h12,3);commit;if(!status) $fatal(1,"settings precondition");
  network=1;repeat(5) @(negedge clk);if(alarm) $fatal(1,"mid-frame alarm change");
  commit;if(!alarm || !status) $fatal(1,"network enter lost old view");
  clear_sound=1;command(8'h14,0);commit;
  if(!alarm) $fatal(1,"local clear overrode network hazard");
  command(8'h12,0);if(result!=4) $fatal(1,"navigation allowed during network alarm");
  network=0;clear_sound=0;commit;if(alarm || !status || mode!=2) $fatal(1,"network clear lost settings/mode");
  command(8'h14,1);network=1;commit;network=0;commit;
  if(!alarm) $fatal(1,"network clear erased independent manual source");
  command(8'h14,0);commit;if(alarm) $fatal(1,"manual clear failed");
  sound=1;@(negedge clk);sound=0;commit;if(!alarm) $fatal(1,"local sensor regression");
  clear_sound=1;@(negedge clk);clear_sound=0;commit;if(alarm) $fatal(1,"local quiet clear regression");
  $display("PASS control: frame-boundary priority, preserve settings/mode, source isolation, local alarm regression");$finish;
 end
endmodule
