`timescale 1ns/1ps
// Drive a pixel-varying DVP frame through the production top, SDRAM and HDMI A.
// Independently check the 640x480 normalizer and decode the physical TMDS pins.
module tb_hdmi_native_top;
 reg clk=0,cam_pclk=0,rst_n=0,cam_vsync=0,cam_href=0;
 reg [7:0] cam_data=0;
 always #10 clk=~clk;
 always #11 cam_pclk=~cam_pclk;
 wire hc,hr,hg,hb;
 tri1 cam_sda;
 top dut(.clk(clk),.rst_n(rst_n),.cam_pclk(cam_pclk),.cam_vsync(cam_vsync),
   .cam_href(cam_href),.cam_data(cam_data),.cam_sda(cam_sda),
   .HDMI_CLK_P(hc),.HDMI_D2_P(hr),.HDMI_D1_P(hg),.HDMI_D0_P(hb),
   .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'b0));
 defparam dut.camera.capture.WAIT_FRAMES=0;

 function [15:0] pattern;
   input integer x,y;
   reg [4:0] r,b;
   reg [5:0] g;
   begin r=x+y*3;g=x*3+y*5;b=x*7+y;pattern={r,g,b};end
 endfunction
 function [23:0] expand;
   input [15:0] p;
   begin expand={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};end
 endfunction
 function [23:0] normalize_rgb;
   input [15:0] p;
   begin normalize_rgb={p[15:11],3'b0,p[10:5],2'b0,p[4:0],3'b0};end
 endfunction
 function [23:0] screen_rgb;
   input integer x,y;
   begin
     screen_rgb=expand(pattern(x,y));
     if((x>=128 && x<896 && (y<2 || y>=766)) ||
        (y>=2 && y<766 && ((x>=128 && x<130)||(x>=894 && x<896))))
       screen_rgb=24'h40c0e0;
   end
 endfunction
 function [7:0] decode;
   input [9:0] symbol;
   reg [7:0] q;
   integer k;
   begin
     q=symbol[9]?~symbol[7:0]:symbol[7:0];decode[0]=q[0];
     for(k=1;k<8;k=k+1) decode[k]=symbol[8]?(q[k]^q[k-1]):~(q[k]^q[k-1]);
   end
 endfunction
 function control;
   input [9:0] symbol;
   begin case(symbol)
     10'b1101010100,10'b0010101011,10'b0101010100,10'b1010101011:control=1;
     default:control=0;
   endcase end
 endfunction

 integer sx,sy,normalized_pixels=0,native_pixels=0,preview_pixels=0;
 integer roi_pixels=0,source_x,source_y,roi_x,roi_y;
 reg [15:0] sent;
 initial begin
   #120;rst_n=1;
   wait(dut.sys_rst_n);
   #300000;
   // SCCB ACK/error handling is covered by tb_camera_config.
   force dut.camera.config_done=1;
   force dut.camera.config_error=0;
   repeat(12) @(negedge cam_pclk);
   cam_vsync=1;repeat(4) @(negedge cam_pclk);cam_vsync=0;
   repeat(5) @(negedge cam_pclk);
   for(sy=0;sy<768;sy=sy+1) begin
     for(sx=0;sx<1024;sx=sx+1) begin
       sent=pattern(sx,sy);
       cam_href=1;cam_data=sent[15:8];@(negedge cam_pclk);
       cam_data=sent[7:0];@(negedge cam_pclk);
     end
     cam_href=0;repeat(4) @(negedge cam_pclk);
   end
   wait(serial_pass);
   if(native_pixels!=786432 || normalized_pixels!=307200 || roi_pixels!=4096 || preview_pixels<786432)
     $fatal(1,"counts native=%0d normalized=%0d ROI=%0d preview=%0d",native_pixels,normalized_pixels,roi_pixels,preview_pixels);
   $display("PASS HDMI_NATIVE_TOP: actual HDMI A pins decoded 1024x768 (786432 pixels), native per-pixel detail preserved; unchanged 640x480 normalizer (307200 pixels), 4096 exact ROI inputs");
   $finish;
 end
 always @(posedge cam_pclk) begin
   if(dut.native_valid) begin
     if(dut.native_rgb565!==pattern(dut.native_x,dut.native_y)) $fatal(1,"native capture mismatch");
     native_pixels=native_pixels+1;
   end
   if(dut.pixel_valid) begin
     source_x=(8*dut.pixel_x+4)/5;source_y=(8*dut.pixel_y+4)/5;
     if(dut.pixel_rgb565!==pattern(source_x,source_y)) $fatal(1,"normalizer changed");
     normalized_pixels=normalized_pixels+1;
   end
 end
 always @(posedge clk) if(dut.load_valid && dut.load_ready) begin
   if(dut.load_addr!==roi_pixels[11:0]) $fatal(1,"ROI order changed");
   roi_x=80+(15*(roi_pixels%64)+7)/2;roi_y=(15*(roi_pixels/64)+7)/2;
   source_x=(8*roi_x+4)/5;source_y=(8*roi_y+4)/5;
   if(dut.load_rgb!==normalize_rgb(pattern(source_x,source_y))) $fatal(1,"ROI pixel changed at %0d",roi_pixels);
   roi_pixels=roi_pixels+1;
 end
 always @(posedge dut.video_clk) begin
   #0.2;
   if(dut.de && dut.frame_valid) begin
     if(dut.preview_rgb!==expand(pattern(dut.vx,dut.vy)))
       $fatal(1,"preview is not native at x=%0d y=%0d",dut.vx,dut.vy);
     preview_pixels=preview_pixels+1;
   end
 end

 reg old_clock=0,word_locked=0,armed=0,serial_pass=0;
 reg [9:0] red_word=0,green_word=0,blue_word=0,clock_word=0;
 reg [23:0] received_rgb;
 integer bit_index=0,line_pixels=0,screen_y=0,serial_pixels=0;
 always @(dut.serial_clk) begin
   #0.1;
   if(rst_n) begin
     if(hc && !old_clock) begin bit_index=0;word_locked=1;end
     if(word_locked && !serial_pass) begin
       red_word[bit_index]=hr;green_word[bit_index]=hg;
       blue_word[bit_index]=hb;clock_word[bit_index]=hc;
       if(bit_index==9) begin
         if(clock_word!==10'b0000011111) $fatal(1,"HDMI A clock word misaligned");
         // frame_valid changes only at the start of vertical blanking.
         if(!armed && dut.frame_valid && control(blue_word)) armed=1;
         if(armed) begin
           if(control(blue_word)) begin
             if(red_word!==10'b1101010100 || green_word!==10'b1101010100)
               $fatal(1,"HDMI A blanking/control mismatch");
             if(line_pixels!=0) begin
               if(line_pixels!=1024) $fatal(1,"HDMI A active width=%0d",line_pixels);
               line_pixels=0;screen_y=screen_y+1;
               if(screen_y==768) begin
                 if(serial_pixels!=786432) $fatal(1,"HDMI A pixel count=%0d",serial_pixels);
                 serial_pass=1;
               end
             end
           end else begin
             if(line_pixels>=1024 || screen_y>=768) $fatal(1,"HDMI A image exceeds 1024x768");
             received_rgb={decode(red_word),decode(green_word),decode(blue_word)};
             // Preserve the existing classification text panel; compare all
             // remaining camera pixels and the existing ROI border exactly.
             if(!(line_pixels>=40 && line_pixels<280 && screen_y>=32 && screen_y<72) &&
                received_rgb!==screen_rgb(line_pixels,screen_y))
               $fatal(1,"HDMI A native detail mismatch x=%0d y=%0d got=%h expected=%h",line_pixels,screen_y,received_rgb,screen_rgb(line_pixels,screen_y));
             line_pixels=line_pixels+1;serial_pixels=serial_pixels+1;
           end
         end
       end
       bit_index=(bit_index+1)%10;
     end
     old_clock=hc;
   end
 end
 initial begin #100000000;$fatal(1,"HDMI native integration timeout rows=%0d pixels=%0d",screen_y,serial_pixels);end
endmodule
