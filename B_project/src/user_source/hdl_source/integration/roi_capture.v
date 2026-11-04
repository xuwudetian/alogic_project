// Camera-domain stable-frame mailbox. The buffer remains immutable until all
// 4096 samples have been delivered to the CNN. No unsynchronised pulse crossing.
// ROI=(80,0,480,480), sample=floor((index+0.5)*480/64), RGB565.
module roi_capture(
 input camera_clk,input camera_rst_n,input frame_start,input pixel_valid,
 input [15:0] pixel_rgb565,input [9:0] pixel_x,input [8:0] pixel_y,
 input clk,input rst_n,input cnn_busy,input load_ready,
 output reg load_valid,output reg [11:0] load_addr,
 output [23:0] load_rgb,output reg start,
 output reg [31:0] frames_loaded
);
 reg request,acknowledge;
 (* async_reg="true" *) reg [1:0] ack_sync,req_sync;
 reg capturing;
 reg [5:0] sx,sy;
 reg [9:0] target_x;
 reg [8:0] target_y;
 wire [11:0] wr_addr={sy,sx};
 always @(posedge camera_clk or negedge camera_rst_n) begin
   if(!camera_rst_n) begin
     ack_sync<=0;request<=0;capturing<=0;sx<=0;sy<=0;
     target_x<=83;target_y<=3;
   end else begin
     ack_sync<={ack_sync[0],acknowledge};
     if(frame_start) begin
       capturing<=(request==ack_sync[1]);
       sx<=0;sy<=0;target_x<=83;target_y<=3;
     end else if(capturing && pixel_valid && pixel_x==target_x && pixel_y==target_y) begin
       if(sx==63) begin
         sx<=0;target_x<=83;
         if(sy==63) begin capturing<=0;request<=~request;end
         else begin sy<=sy+1'b1;target_y<=target_y+(sy[0]?7:8);end
       end else begin sx<=sx+1'b1;target_x<=target_x+(sx[0]?7:8);end
     end
   end
 end
 // Explicit two M32K blocks keep the complete design within the M9K budget.
 wire [15:0] rd_data;
 wire roi_we=capturing && !frame_start && pixel_valid && pixel_x==target_x && pixel_y==target_y;
 video_frame_ram #(.WORDS(4096),.BANKS(2)) roi_ram(
   .write_clk(camera_clk),.write_enable(roi_we),.write_address({3'd0,wr_addr}),.write_data(pixel_rgb565),
   .read_clk(clk),.read_enable(1'b1),.read_address({3'd0,load_addr}),.read_data(rd_data));
 assign load_rgb={rd_data[15:11],3'b000,rd_data[10:5],2'b00,rd_data[4:0],3'b000};
 reg [2:0] state;
 localparam IDLE=0,READ=1,OFFER=2,ACCEPT=3,START=4;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     req_sync<=0;acknowledge<=0;state<=IDLE;load_valid<=0;
     load_addr<=0;start<=0;frames_loaded<=0;
   end else begin
     req_sync<={req_sync[0],request};
     start<=0;
     case(state)
       IDLE: if(req_sync[1]!=acknowledge && !cnn_busy) begin load_addr<=0;state<=READ;end
       READ: state<=OFFER;
       OFFER: begin load_valid<=1;state<=ACCEPT;end
       ACCEPT: if(load_ready) begin
         load_valid<=0;
         if(load_addr==4095) begin acknowledge<=req_sync[1];state<=START;end
         else begin load_addr<=load_addr+1'b1;state<=READ;end
       end
       START: begin start<=1;frames_loaded<=frames_loaded+1'b1;state<=IDLE;end
       default: begin state<=IDLE;load_valid<=0;end
     endcase
   end
 end
endmodule
