`timescale 1ns/1ps
module net_endpoint #(parameter IS_B=0,DIRECT_LINK=1)(
 input clk,input rst,input [7:0] local_flags,
 input eth_rx_clk,input eth_rx_ctl,input [3:0] eth_rxd,
 output eth_tx_clk,output eth_tx_ctl,output [3:0] eth_txd,
 output eth_mdc,inout eth_mdio,
 output remote_alarm,output online,output remote_valid,output link_ok);
 wire mac_clk,shifted_clk,locked;
 net_clock clocks(clk,rst,mac_clk,shifted_clk,locked);
 wire reset_all=rst || !locked;
 // Assert in all domains together, release only after three local edges.
 // Falling-edge release gives the rising-edge state machines half a cycle
 // for recovery/removal and keeps a stopped RX clock in reset.
 (* async_reg="true" *) reg [2:0] sys_reset_sync=3'b111;
 (* async_reg="true" *) reg [2:0] tx_reset_sync=3'b111;
 (* async_reg="true" *) reg [2:0] rx_reset_sync=3'b111;
 always @(negedge clk or posedge reset_all)
  if(reset_all) sys_reset_sync<=3'b111;else sys_reset_sync<={sys_reset_sync[1:0],1'b0};
 always @(negedge mac_clk or posedge reset_all)
  if(reset_all) tx_reset_sync<=3'b111;else tx_reset_sync<={tx_reset_sync[1:0],1'b0};
 always @(negedge eth_rx_clk or posedge reset_all)
  if(reset_all) rx_reset_sync<=3'b111;else rx_reset_sync<={rx_reset_sync[1:0],1'b0};
 wire sys_reset=sys_reset_sync[2],tx_reset=tx_reset_sync[2],rx_reset=rx_reset_sync[2];
 net_mdio #(.IS_B(IS_B),.DIRECT_LINK(DIRECT_LINK)) phy(clk,sys_reset,eth_mdc,eth_mdio,link_ok);
 // At 100 Mb/s both edges carry the same nibble. Sample RX on its falling
 // edge, away from the PHY rising-edge data transition, then consume on rising.
 // This tolerates both 0 ns and 2 ns RX clock strap delay at 100 Mb/s.
 reg [3:0] rx_sample;reg rx_ctl_sample;
 // Input pipeline is flushed while the RX parser is held in reset.
 always @(negedge eth_rx_clk) begin
  rx_sample<=eth_rxd;rx_ctl_sample<=eth_rx_ctl;
 end
 (* async_reg="true" *) reg [1:0] link_sync;
 always @(posedge mac_clk or posedge tx_reset)
  if(tx_reset) link_sync<=0;else link_sync<={link_sync[0],link_ok};
 wire [3:0] tx_nibble;wire tx_enable,mac_ready,mac_received;
 wire [23:0] mac_payload;
 wire outbound,outbound_ready,inbound;wire [23:0] outbound_payload,inbound_payload;
 net_session #(.IS_B(IS_B)) session(
  .clk(clk),.rst(sys_reset),.link_ok(link_ok),.local_flags(local_flags),
  .received(inbound),.rx_payload(inbound_payload),.tx_ready(outbound_ready),
  .send(outbound),.tx_payload(outbound_payload),.remote_alarm(remote_alarm),
  .online(online),.remote_valid(remote_valid));
 wire tx_message;wire [23:0] tx_message_data;
 net_mailbox tx_box(clk,mac_clk,sys_reset,tx_reset,outbound,outbound_payload,outbound_ready,tx_message,tx_message_data);
 wire rx_box_ready;
 net_mailbox rx_box(eth_rx_clk,clk,rx_reset,sys_reset,mac_received,mac_payload,rx_box_ready,inbound,inbound_payload);
 reg tx_pending,mac_send;reg [23:0] tx_held;
 always @(posedge mac_clk or posedge tx_reset) begin
  if(tx_reset) begin tx_pending<=0;mac_send<=0;tx_held<=0;end
  else begin
   mac_send<=0;
   if(tx_pending && mac_ready && !mac_send && link_sync[1]) begin mac_send<=1;tx_pending<=0;end
   if(tx_message) begin tx_held<=tx_message_data;tx_pending<=1;end
  end
 end
 net_udp_mac #(.IS_B(IS_B)) mac(
  .tx_clk(mac_clk),.rx_clk(eth_rx_clk),.tx_rst(tx_reset),.rx_rst(rx_reset),.enabled(link_sync[1]),
  .send(mac_send),.payload(tx_held),.ready(mac_ready),.txd(tx_nibble),.tx_en(tx_enable),
  .rxd(rx_sample),.rx_dv(rx_ctl_sample),.received(mac_received),.received_payload(mac_payload));
`ifdef SIMULATION
 assign eth_tx_clk=shifted_clk;
 reg [3:0] sim_txd;reg sim_tx_ctl;
 always @(posedge mac_clk) begin sim_txd<=tx_nibble;sim_tx_ctl<=tx_enable;end
 assign eth_txd=sim_txd;assign eth_tx_ctl=sim_tx_ctl;
`else
 // Same EG4 ODDR primitive and d0/d1 convention as the supplied RGMII demo.
 // The forwarded clock runs continuously. TX state drives idle during reset;
 // output DDR registers need no asynchronous reset on either sampling edge.
 EG_LOGIC_ODDR #(.ASYNCRST("DISABLE")) tx_clock(.clk(shifted_clk),.rst(1'b0),.d0(1'b1),.d1(1'b0),.q(eth_tx_clk));
 genvar i;
 generate for(i=0;i<4;i=i+1) begin:tx_pads
  EG_LOGIC_ODDR #(.ASYNCRST("DISABLE")) data_pad(.clk(mac_clk),.rst(1'b0),.d0(tx_nibble[i]),.d1(tx_nibble[i]),.q(eth_txd[i]));
 end endgenerate
 EG_LOGIC_ODDR #(.ASYNCRST("DISABLE")) ctl_pad(.clk(mac_clk),.rst(1'b0),.d0(tx_enable),.d1(tx_enable),.q(eth_tx_ctl));
`endif
endmodule
