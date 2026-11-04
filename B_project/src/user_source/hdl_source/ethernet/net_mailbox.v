`timescale 1ns/1ps
// One-entry acknowledged bundled-data mailbox. No pulse or multi-bit bus is
// sampled without its token. Resets assert together and release locally.
module net_mailbox #(parameter WIDTH=24)(
 input source_clk,input target_clk,input source_rst,input target_rst,
 input send,input [WIDTH-1:0] data,output ready,
 output reg received,output reg [WIDTH-1:0] received_data);
 reg [WIDTH-1:0] held;
 reg request,acknowledge;
 (* async_reg="true" *) reg [1:0] ack_sync,req_sync;
 assign ready=request==ack_sync[1];
 always @(posedge source_clk or posedge source_rst) begin
  if(source_rst) begin held<=0;request<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],acknowledge};
   if(send && ready) begin held<=data;request<=~request;end
  end
 end
 always @(posedge target_clk or posedge target_rst) begin
  if(target_rst) begin req_sync<=0;acknowledge<=0;received<=0;received_data<=0;end
  else begin
   req_sync<={req_sync[0],request};received<=0;
   if(req_sync[1]!=acknowledge) begin
    received_data<=held;received<=1;acknowledge<=req_sync[1];
   end
  end
 end
endmodule
