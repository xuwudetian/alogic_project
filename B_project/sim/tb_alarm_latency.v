`timescale 1ns/1ps
// Actual B top -> RGMII wires -> A endpoint -> current A controller/overlay.
// Inject at the CNN result boundary (CNN arithmetic/DVP covered separately).
// Real 50/25 MHz clocks, real 640x480 timing and production session/filter timers.
// Only PHY negotiation boot/poll waits are accelerated; analog PHY is not modeled.
module tb_alarm_latency;
 reg clk=0,cam_clk=0,avclk=0,rst=1;
 always #10 clk=~clk;
 always #10.1 cam_clk=~cam_clk;
 initial begin #7;forever #20 avclk=~avclk;end
 reg injected_done=0;reg [1:0] injected_class=0;
 wire atxc,atxen,btxc,btxen,amdc,bmdc;wire [3:0] atxd,btxd;
 tri1 amdio,bmdio,cam_sda;
 wire warning,aonline,avalid,alink,aconfig,bconfig;
 reg drop_ack=0,drop_frame=0;integer drop_target=0,dropped=0;
 mdio_phy pa(rst,amdc,amdio,1'b1,aconfig),pb(rst,bmdc,bmdio,1'b1,bconfig);
 top b(.clk(clk),.rst_n(!rst),.cam_pclk(cam_clk),.cam_vsync(1'b0),
   .cam_href(1'b0),.cam_data(8'd0),.cam_sda(cam_sda),
   .eth_rx_clk(atxc),.eth_rx_ctl(atxen && !drop_ack),.eth_rxd(atxd),
   .eth_tx_clk(btxc),.eth_tx_ctl(btxen),.eth_txd(btxd),.eth_mdc(bmdc),.eth_mdio(bmdio));
 net_endpoint #(.IS_B(0)) a(.clk(clk),.rst(rst),.local_flags(8'd0),
   .eth_rx_clk(btxc),.eth_rx_ctl(btxen && !drop_frame),.eth_rxd(btxd),
   .eth_tx_clk(atxc),.eth_tx_ctl(atxen),.eth_txd(atxd),.eth_mdc(amdc),.eth_mdio(amdio),
   .remote_alarm(warning),.online(aonline),.remote_valid(avalid),.link_ok(alink));
 defparam a.phy.BOOT_CYCLES=1000,a.phy.POLL_CYCLES=1000,a.phy.HALF_CYCLES=5;
 defparam b.network.phy.BOOT_CYCLES=1000,b.network.phy.POLL_CYCLES=1000,b.network.phy.HALF_CYCLES=5;
 wire ahs,avs,ade;reg last_vs=1;reg [1:0] alarm_sync=0;
 wire frame_tick=last_vs && !avs;
 color_bar timing(.clk(avclk),.rst(rst),.hs(ahs),.vs(avs),.de(ade));
 always @(posedge avclk or posedge rst)
   if(rst) begin last_vs<=1;alarm_sync<=0;end
   else begin last_vs<=avs;alarm_sync<={alarm_sync[0],warning};end
 wire ui_alarm,out_de;wire [23:0] out_rgb;
 player_control #(.NETWORK_ENABLE(1),.REMOTE_ENABLE(1),.SENSOR_ENABLE(1)) ui(
   .clk(avclk),.rst(rst),.frame_tick(frame_tick),.key_next(1'b1),.key_auto(1'b1),.key_menu(1'b1),
   .switches(4'b0),.available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b1),
   .sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),.network_alarm(alarm_sync[1]),
   .playback_fault(1'b0),.remote_valid(1'b0),.remote_command(8'd0),.remote_argument(24'd0),.alarm(ui_alarm));
 // Keep A's 3.5-second boot screen enabled: warning must preempt it immediately.
 player_ui_overlay #(.BOOT_ENABLE(1)) overlay(.clk(avclk),.rst(rst),.hs(ahs),.vs(avs),.de(ade),
   .rgb(24'd0),.directory(1'b0),.selection(2'd0),.alarm(ui_alarm),.out_de(out_de),.out_rgb(out_rgb),
   .directory_run(1'b0),.no_signal(1'b1),.boot_ready(1'b0));
 reg armed=0,glyph_pending=0;
 time start_at,net_at,ui_at,glyph_at,label_at;
 always @(posedge warning) if(armed && !net_at) net_at=$time;
 always @(posedge ui_alarm) if(armed && !ui_at) ui_at=$time;
 always @(posedge b.video_clk) begin
   #1;
   if(armed && !label_at && b.display_valid && b.display_class==2) label_at=$time;
 end
 always @(posedge avclk) begin
   glyph_pending=overlay.warning1 && overlay.warning_row[7-overlay.warning_index];
   #1;
   if(armed && !glyph_at && glyph_pending && out_de && out_rgb[23:16]>=8'hc0 && out_rgb[15:8]!=0)
     glyph_at=$time;
 end
 // Drop complete alarm frames, never splice or alter an accepted payload.
 always @(posedge btxen) begin
   drop_frame=0;
   if(armed && b.network.mac.held[1:0]==2'b11 && dropped<drop_target) begin
     drop_frame=1;dropped=dropped+1;
   end
 end
 always @(negedge btxen) drop_frame=0;
 task result;input [1:0] value;begin
   @(negedge clk);injected_class=value;injected_done=1;
   @(negedge clk);injected_done=0;
 end endtask
 task run_case;input integer id,losses;begin
   armed=0;rst=1;drop_target=losses;dropped=0;drop_ack=1;injected_done=0;
   repeat(20) @(negedge clk);rst=0;
   wait(alink && b.network_link);
   // Just missed A's frame boundary; healthy packet occupies the MAC when
   // damage arrives. This covers a queued alarm and absent ACK simultaneously.
   @(posedge frame_tick);repeat(20) @(negedge clk);
   result(1);wait(b.network.mac.state==2);
   @(negedge clk);armed=1;start_at=$time;net_at=0;ui_at=0;glyph_at=0;label_at=0;
   injected_class=2;injected_done=1;
   @(negedge clk);injected_done=0;
   #1000000;result(2);#1000000;result(2);
   wait(net_at!=0 && ui_at!=0 && glyph_at!=0 && label_at!=0);
   if(!warning || !ui_alarm || !aonline || !avalid) $fatal(1,"alarm chain unavailable");
   if(dropped!=losses) $fatal(1,"packet loss injection not exercised");
   if(net_at-start_at>losses*10000000+30000) $fatal(1,"network exceeded immediate/retry bound");
   if(ui_at-start_at>losses*10000000+16830000) $fatal(1,"UI waited beyond next frame");
   if(glyph_at-start_at>losses*10000000+22000000) $fatal(1,"WARNING glyph delayed/boot masked alarm");
   $display("LATENCY case=%0d drops=%0d network_ns=%0d ui_ns=%0d warning_glyph_ns=%0d b_label_ns=%0d",
     id,losses,net_at-start_at,ui_at-start_at,glyph_at-start_at,label_at-start_at);
   armed=0;
 end endtask
 initial begin
   force b.camera.config_done=1'b1;force b.camera.config_error=1'b0;
   force b.done=injected_done;force b.class_id=injected_class;
   #1;
   if(b.network.session.MS_CYCLES!=50000 || b.network.session.HEARTBEAT_MS!=10 ||
      b.detection_timer.MS_CYCLES!=50000 || b.detection_timer.CLEAR_MS!=3000 ||
      timing.H_TOTAL!=800 || timing.V_TOTAL!=525) $fatal(1,"test must use production timing");
   run_case(1,0);
   run_case(2,2);
   $display("PASS ALARM_LATENCY: B top, busy MAC, missing ACK, 2 lost frames, real A frame/CDC/WARNING pixels, boot preemption");
   $finish;
 end
 initial begin #100000000;$fatal(1,"ALARM_LATENCY timeout");end
endmodule
