`timescale 1ns/1ps
// State replication: B retransmits every 100 ms and immediately on a change.
// A acknowledges accepted/duplicate packets but only advancing sequence numbers
// refresh its watchdog. Explicit healthy clear is the ONLY automatic release.
module net_session #(parameter IS_B=0,MS_CYCLES=50000,HEARTBEAT_MS=100,TIMEOUT_MS=1000)(
 input clk,input rst,input link_ok,input [7:0] local_flags,
 input received,input [23:0] rx_payload,
 input tx_ready,output reg send,output reg [23:0] tx_payload,
 output reg remote_alarm,output wire online,output reg remote_valid);
 localparam T_BITS=MS_CYCLES>1?$clog2(MS_CYCLES):1;
 localparam W_BITS=$clog2(TIMEOUT_MS+1),H_BITS=$clog2(HEARTBEAT_MS+1);
 reg [T_BITS-1:0] ticks;
 reg [W_BITS-1:0] age;
 reg [H_BITS-1:0] heartbeat;
 reg [15:0] next_seq,last_rx,last_tx;
 reg [7:0] sent_flags;
 reg pending,have_rx;
 reg [23:0] reply;
 wire [15:0] delta=rx_payload[23:8]-last_rx;
 wire new_sequence=!have_rx || (delta!=0 && (!online || !delta[15]));
 wire tick=ticks==MS_CYCLES-1;
 assign online=link_ok && age<TIMEOUT_MS;
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   ticks<=0;age<=TIMEOUT_MS;heartbeat<=HEARTBEAT_MS;next_seq<=0;
   last_rx<=0;last_tx<=0;sent_flags<=0;pending<=0;reply<=0;have_rx<=0;
   send<=0;tx_payload<=0;remote_alarm<=0;remote_valid<=0;
  end else begin
   send<=0;
   if(tick) begin
    ticks<=0;
    if(age<TIMEOUT_MS) age<=age+1'b1;
    if(heartbeat<HEARTBEAT_MS) heartbeat<=heartbeat+1'b1;
   end else ticks<=ticks+1'b1;
   if(!online) remote_valid<=0;
   if(!link_ok) age<=TIMEOUT_MS;
   if(IS_B) begin
    if(link_ok && tx_ready && !send && (heartbeat>=HEARTBEAT_MS || local_flags!=sent_flags)) begin
     send<=1;tx_payload<={next_seq,local_flags};last_tx<=next_seq;
     next_seq<=next_seq+1'b1;sent_flags<=local_flags;heartbeat<=0;
    end
    if(received && link_ok && rx_payload[23:8]==last_tx && rx_payload[7:0]==sent_flags) begin
     age<=0;remote_valid<=1;
    end
   end else begin
    if(pending && tx_ready && !send && link_ok) begin send<=1;tx_payload<=reply;pending<=0;end
    if(received && link_ok && (new_sequence || delta==0)) begin
     reply<=rx_payload;pending<=1;
     if(new_sequence) begin
      last_rx<=rx_payload[23:8];age<=0;have_rx<=1;
      remote_valid<=rx_payload[1] && rx_payload[2];
      if(rx_payload[1] && rx_payload[2]) remote_alarm<=rx_payload[0];
     end
    end
   end
  end
 end
endmodule
