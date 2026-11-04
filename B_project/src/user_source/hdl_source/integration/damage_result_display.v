// Three-class temporal confirmation and acknowledged bundled-data CDC.
// Confirm N consecutive NEW inferences, not N clocks or display frames.
// Published payload is immutable until the video domain acknowledges receipt.
module damage_result_display #(
 parameter CONFIRM_RESULTS=3
)(
 input clk,input rst_n,input result_done,input [1:0] result_class,
 input video_clk,input video_rst_n,input frame_commit,
 output reg display_valid,output reg [1:0] display_class
);
 reg [1:0] candidate,filtered_class;
 reg [7:0] consecutive;
 reg filtered_valid;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin candidate<=0;consecutive<=0;filtered_class<=0;filtered_valid<=0;end
   else if(result_done) begin
     if(result_class>2) consecutive<=0;
     else if(CONFIRM_RESULTS<=1) begin filtered_class<=result_class;filtered_valid<=1;end
     else if(consecutive==0 || result_class!=candidate) begin
       candidate<=result_class;consecutive<=1;
     end else begin
       if(consecutive<CONFIRM_RESULTS) consecutive<=consecutive+1'b1;
       if(consecutive>=CONFIRM_RESULTS-1) begin filtered_class<=result_class;filtered_valid<=1;end
     end
   end
 end
 reg publish_toggle,published_valid;
 reg [1:0] published_class;
 reg acknowledge;
 (* async_reg="true" *) reg [1:0] ack_sync,publish_sync;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin ack_sync<=0;publish_toggle<=0;published_valid<=0;published_class<=0;end
   else begin
     ack_sync<={ack_sync[0],acknowledge};
     if(ack_sync[1]==publish_toggle && filtered_valid &&
        (!published_valid || filtered_class!=published_class)) begin
       published_class<=filtered_class;published_valid<=1;publish_toggle<=~publish_toggle;
     end
   end
 end
 reg pending_valid;
 reg [1:0] pending_class;
 always @(posedge video_clk or negedge video_rst_n) begin
   if(!video_rst_n) begin
     publish_sync<=0;acknowledge<=0;pending_valid<=0;pending_class<=0;
     display_valid<=0;display_class<=0;
   end else begin
     publish_sync<={publish_sync[0],publish_toggle};
     if(publish_sync[1]!=acknowledge) begin
       // Source holds this bus throughout synchronization and until ack returns.
       pending_class<=published_class;pending_valid<=1;acknowledge<=publish_sync[1];
     end
     if(frame_commit) begin display_class<=pending_class;display_valid<=pending_valid;end
   end
 end
endmodule
