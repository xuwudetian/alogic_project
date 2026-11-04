`timescale 1ns/1ps
module tb_roi_capture;
 reg camera_clk=0,clk=0;
 always #17 camera_clk=~camera_clk;
 always #10 clk=~clk;
 reg camera_rst_n=0,rst_n=0,frame_start=0,pixel_valid=0;
 reg [15:0] pixel_rgb565=0;reg [9:0] pixel_x=0;reg [8:0] pixel_y=0;
 reg cnn_busy=1,load_ready=0;
 wire load_valid,start;wire [11:0] load_addr;wire [23:0] load_rgb;
 wire [31:0] frames_loaded;
 roi_capture dut(camera_clk,camera_rst_n,frame_start,pixel_valid,pixel_rgb565,pixel_x,pixel_y,
   clk,rst_n,cnn_busy,load_ready,load_valid,load_addr,load_rgb,start,frames_loaded);
 integer i,j,count=0,cycles=0,starts=0;
 integer ex,ey;reg [15:0] expect565;reg [23:0] expectrgb;
 task frame;
   input integer tag;
   begin
     @(negedge camera_clk);frame_start=1;pixel_valid=0;
     @(negedge camera_clk);frame_start=0;
     for(j=0;j<480;j=j+1) begin
       for(i=0;i<640;i=i+1) begin
         pixel_valid=1;pixel_x=i;pixel_y=j;
         pixel_rgb565={i[4:0],j[5:0],tag[4:0]};
         @(negedge camera_clk);
       end
       pixel_valid=0;repeat(2) @(negedge camera_clk);
     end
     pixel_valid=0;
   end
 endtask
 always @(negedge clk) begin
   cycles=cycles+1;
   load_ready=(cycles%7!=0 && cycles%7!=1);
 end
 always @(posedge clk) if(rst_n) begin
   if(load_valid && load_ready) begin
     if(load_addr!==count[11:0]) $fatal(1,"address mismatch: %d %d",load_addr,count);
     ex=80+((count%64)*15+7)/2;ey=((count/64)*15+7)/2;
     expect565={ex[4:0],ey[5:0],5'd3};
     expectrgb={expect565[15:11],3'b0,expect565[10:5],2'b0,expect565[4:0],3'b0};
     if(load_rgb!==expectrgb) $fatal(1,"ROI data mismatch addr=%d actual=%h expected=%h",load_addr,load_rgb,expectrgb);
     count=count+1;
   end
   if(start) begin
     if(count!=4096) $fatal(1,"start before complete image");
     starts=starts+1;
   end
 end
 initial begin
   repeat(5) @(negedge clk);rst_n=1;camera_rst_n=1;
   frame(3);
   // A completed mailbox must survive later camera frames until consumer ready.
   frame(9);
   if(count!=0) $fatal(1,"wrote while CNN busy");
   cnn_busy=0;
   wait(starts==1);repeat(8) @(posedge clk);
   if(frames_loaded!=1) $fatal(1,"frame counter mismatch");
   $display("PASS roi_capture: all4096 samples, backpressure, stable CDC ownership");$finish;
 end
 initial begin #50000000;$fatal(1,"timeout");end
endmodule
