`timescale 1ns/1ps
// PHY management model independently decodes MDC/MDIO and only reports link
// after the requested advertisement/restart writes. RGMII wires join two real
// endpoints. RX path deliberately has different clock phase from system clock.
module mdio_phy #(parameter integer EXPECT_MDIX=-1,RESET_READS=2)(
 input rst,input mdc,inout mdio,input cable,output configured);
 integer bit_count=0;reg [31:0] shift=0;reg reading=0;
 reg [4:0] addr=0;reg adv=0,giga_off=0,restarted=0;
 reg [15:0] bmcr=16'h1140,phycr=16'h016e;
 integer reset_left=0,resets=0,force_writes=0,expected_mdix=EXPECT_MDIX;
 reg fail_reads=0,wrong_speed=0,reset_seen=0;
 wire manual_mode=reset_seen && (bmcr & 16'hff40)==16'h2100 && !phycr[6] && !phycr[10] &&
                   (expected_mdix<0 || phycr[5]==expected_mdix);
 wire legacy_mode=adv && giga_off && restarted && bmcr[12];
 wire [15:0] status=(configured && cable)?(wrong_speed?16'ha400:manual_mode?16'h6400:16'h6c00):16'h0000;
 wire [15:0] readback=addr==0?bmcr:addr==16?phycr:addr==17?status:16'd0;
 assign configured=manual_mode || legacy_mode;
 assign mdio=reading && !fail_reads && bit_count==47 ? 1'b0 :
             reading && !fail_reads && bit_count>=48 ? readback[63-bit_count] : 1'bz;
 always @(posedge mdc or posedge rst) begin
  if(rst) begin
   bit_count<=0;shift<=0;reading<=0;addr<=0;adv<=0;giga_off<=0;restarted<=0;
   bmcr<=16'h1140;phycr<=16'h016e;reset_left<=0;resets<=0;force_writes<=0;reset_seen<=0;
  end
  else begin
   shift<={shift[30:0],mdio};
   if(bit_count==35) reading<={shift[0],mdio}==2'b10;
   if(bit_count==45) addr<={shift[3:0],mdio};
   if(bit_count==63) begin
    bit_count<=0;reading<=0;
    if(!reading) case(addr)
     4:adv<={shift[14:0],mdio}==16'h0101;
     9:giga_off<={shift[14:0],mdio}==0;
     0:begin
      restarted<={shift[14:0],mdio}==16'h1200;
      if(shift[14]) begin // data bit 15: model reset restores BMCR defaults
       bmcr<=16'h9140;reset_left<=RESET_READS;resets<=resets+1;reset_seen<=1;
      end else begin
       if(reset_left!=0) $fatal(1,"BMCR configured before software reset completed");
       bmcr<={shift[14:0],mdio} & 16'hfdff;
       if({shift[14:0],mdio}==16'h2300) force_writes<=force_writes+1;
      end
     end
     16:begin
      if(({shift[14:0],mdio} & 16'hfb9f)!=(phycr & 16'hfb9f))
       $fatal(1,"PHYCR unrelated/reserved fields changed");
      phycr<={shift[14:0],mdio};
     end
    endcase
    if(reading && addr==0 && reset_left!=0 && !fail_reads) begin
     reset_left<=reset_left-1;
     if(reset_left==1) bmcr<=16'h1140;
    end
   end else bit_count<=bit_count+1;
  end
 end
endmodule

module tb_end_to_end;
 reg clk=0,rst=1,cable=1,drop_b=0,drop_a=0,camera_good=1,done=0;
 reg [1:0] classification=2;
 always #10 clk=~clk;
 wire damage,valid;wire [1:0] last_class;
 net_damage_filter #(.MS_CYCLES(50),.ALARM_MS(100),.CLEAR_MS(3000),.STALE_MS(3000)) filter(clk,rst,camera_good,done,classification,damage,valid,last_class);
 wire atxc,atxen,btxc,btxen,amdc,bmdc;wire [3:0] atxd,btxd;
 tri1 amdio,bmdio;
 wire warning,aonline,avalid,alink,bonline,bvalid,blink,unused;
 wire aconfig,bconfig;
 mdio_phy pa(rst,amdc,amdio,cable,aconfig),pb(rst,bmdc,bmdio,cable,bconfig);
 net_endpoint #(.IS_B(0)) a(clk,rst,8'd0,btxc,btxen && cable && !drop_b,btxd,
  atxc,atxen,atxd,amdc,amdio,warning,aonline,avalid,alink);
 net_endpoint #(.IS_B(1)) b(clk,rst,{3'b0,last_class,camera_good,valid,damage},atxc,atxen && cable && !drop_a,atxd,
  btxc,btxen,btxd,bmdc,bmdio,unused,bonline,bvalid,blink);
 defparam a.phy.BOOT_CYCLES=1000,a.phy.POLL_CYCLES=1000,a.phy.HALF_CYCLES=5;
 defparam b.phy.BOOT_CYCLES=1000,b.phy.POLL_CYCLES=1000,b.phy.HALF_CYCLES=5;
 defparam a.session.MS_CYCLES=50,b.session.MS_CYCLES=50;
 reg [5:0] frame_div=0;
 wire frame_tick=frame_div==49;
 always @(posedge clk) if(rst || frame_tick) frame_div<=0;else frame_div<=frame_div+1'b1;
 wire ui_alarm;wire [1:0] run_mode;
 player_control #(.NETWORK_ENABLE(1)) ui(.clk(clk),.rst(rst),.frame_tick(frame_tick),
  .key_next(1'b1),.key_auto(1'b1),.key_menu(1'b1),.switches(4'b0),
  .available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b1),.sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),
  .network_alarm(warning),.playback_fault(1'b0),.remote_valid(1'b0),.remote_command(8'd0),.remote_argument(24'd0),
  .alarm(ui_alarm),.run_mode(run_mode));
 task observe;input [1:0] c;input integer frames;integer i;begin
  for(i=0;i<frames;i=i+1) begin
   @(negedge clk);classification=c;done=1;@(negedge clk);done=0;repeat(998) @(negedge clk);
  end
 end endtask
 initial begin
  #1;rst=1;repeat(5) @(negedge clk);rst=0;
  observe(0,154);if(warning) $fatal(1,"healthy startup warning");
  if(!aconfig || !bconfig || !alink || !blink) $fatal(1,"MDIO negotiation not configured");
  // One observation, followed by only 20 us, shorter than the accelerated
  // 100 us heartbeat. This includes the real RGMII serializer and UI commit.
  observe(2,6);
  if(!warning || !ui_alarm || !aonline || !bonline) $fatal(1,"full chain enter failed");
  observe(1,149);if(!warning) $fatal(1,"early physical clear");
  observe(0,5);if(warning || ui_alarm || run_mode!=2) $fatal(1,"full chain clear/resume failed");
  // Alarm delivery cannot depend on A's acknowledgement reaching B.
  drop_a=1;observe(2,6);if(!warning || !ui_alarm) $fatal(1,"sustained damage enter waited for ACK");
  drop_a=0;
  // Stop inference but continue healthy link heartbeats: must never clear.
  repeat(180000) @(negedge clk);
  if(!warning || avalid || !aonline) $fatal(1,"stale camera incorrectly cleared/alive status");
  // Drop every B packet for longer than watchdog; active alarm holds.
  drop_b=1;observe(0,154);
  if(!warning || aonline) $fatal(1,"lost clear or cable fault released alarm");
  drop_b=0;observe(0,10);
  if(warning || ui_alarm || !aonline || !bonline) $fatal(1,"periodic retransmission failed to recover clear");
  drop_a=1;observe(0,60);
  if(!aonline || bonline || warning) $fatal(1,"lost ACK handling");
  drop_a=0;observe(0,10);if(!bonline) $fatal(1,"ACK recovery");
  cable=0;observe(0,60);if(alink || blink || aonline || bonline) $fatal(1,"PHY cable-down status");
  cable=1;observe(0,30);if(!aonline || !bonline) $fatal(1,"reconnect");
  $display("PASS end-to-end: MDIO, RGMII, UDP, sustained damage assert without ACK, 3s clear, UI resume, stop inference, packet loss, reconnect");$finish;
 end
 initial begin #30000000;$fatal(1,"end-to-end timeout");end
endmodule
