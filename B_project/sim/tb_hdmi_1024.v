`timescale 1ns/1ps
// Independent receiver checks dynamic RGB and every control code at the actual
// 66.667/333.333 MHz clock ratio. Also checks a complete 1344x806 video raster.
module tb_hdmi_1024;
 reg pclk=0,sclk=0,rst_n=0,serial_running=1;
 always #7.5 pclk=~pclk;
 always #1.5 if(serial_running) sclk=~sclk;
 wire hs,vs,de,sof;
 wire [9:0] x,y;
 video_timing_640x480 #(.H_ACTIVE(1024),.H_FP(24),.H_SYNC(136),.H_BP(160),
   .V_ACTIVE(768),.V_FP(3),.V_SYNC(6),.V_BP(29)) timing(pclk,rst_n,hs,vs,de,x,y,sof);
 reg [23:0] rgb=0;
 reg vde=0,vhs=1,vvs=1;
 wire c,r,g,b;
 hdmi_dvi_tx tx(pclk,sclk,rst_n,rgb,vhs,vvs,vde,c,r,g,b);
 function [23:0] pattern;
   input integer index;
   begin pattern=(index*24'h13579)^24'h4135f0;end
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
 function [9:0] control_code;
   input [1:0] code;
   begin case(code)
     0:control_code=10'b1101010100;1:control_code=10'b0010101011;
     2:control_code=10'b0101010100;3:control_code=10'b1010101011;
   endcase end
 endfunction
 reg old_clock=0,word_locked=0,stream_locked=0,stream_pass=0;
 reg [9:0] red_word=0,green_word=0,blue_word=0,clock_word=0;
 integer bit_index=0,received=0,i;
 always @(sclk) begin
   #0.1;
   if(rst_n) begin
     if(c && !old_clock) begin bit_index=0;word_locked=1;end
     if(word_locked) begin
       red_word[bit_index]=r;green_word[bit_index]=g;blue_word[bit_index]=b;clock_word[bit_index]=c;
       if(bit_index==9) begin
         if(clock_word!==10'b0000011111) $fatal(1,"TMDS clock word misaligned");
         if(!stream_locked && {decode(red_word),decode(green_word),decode(blue_word)}===pattern(0)) stream_locked=1;
         if(stream_locked && !stream_pass) begin
           if(received%17<13) begin
             if({decode(red_word),decode(green_word),decode(blue_word)}!==pattern(received))
               $fatal(1,"TMDS pixel %0d got=%h expected=%h",received,{decode(red_word),decode(green_word),decode(blue_word)},pattern(received));
           end else if(red_word!==control_code(0) || green_word!==control_code(0) || blue_word!==control_code(received%4))
             $fatal(1,"TMDS control mismatch %0d",received);
           received=received+1;
           if(received==8192) begin stream_pass=1;serial_running=0;end
         end
       end
       bit_index=(bit_index+1)%10;
     end
     old_clock=c;
   end
 end
 integer h_ref=0,v_ref=0,pixels=0,lines=0,hs_pixels=0,vs_pixels=0,clocks=0;
 reg raster_pass=0;
 always @(posedge pclk) begin
   if(!rst_n) begin h_ref=0;v_ref=0;end
   else if(!raster_pass) begin
     if(h_ref==1343) begin h_ref=0;v_ref=v_ref==805?0:v_ref+1;end
     else h_ref=h_ref+1;
     #0.2;
     if(hs!==(h_ref>=136) || vs!==(v_ref>=6)) $fatal(1,"XGA sync/polarity mismatch");
     if(de!==((h_ref>=296 && h_ref<1320)&&(v_ref>=35 && v_ref<803))) $fatal(1,"XGA blanking mismatch");
     if(de) begin
       if(x!==h_ref-296 || y!==v_ref-35) $fatal(1,"XGA coordinates truncated");
       pixels=pixels+1;if(x==1023) lines=lines+1;
     end
     clocks=clocks+1;if(!hs) hs_pixels=hs_pixels+1;if(!vs) vs_pixels=vs_pixels+1;
     if(sof) begin
       if(clocks!=1083264 || pixels!=786432 || lines!=768 || hs_pixels!=136*806 || vs_pixels!=6*1344)
         $fatal(1,"XGA total count mismatch clocks=%0d pixels=%0d lines=%0d",clocks,pixels,lines);
       raster_pass=1;
     end
   end
 end
 initial begin
   #101;rst_n=1;
   repeat(16) @(negedge pclk);
   for(i=0;i<8192;i=i+1) begin
     rgb=pattern(i);vde=(i%17<13);vhs=i%2;vvs=(i/2)%2;
     @(negedge pclk);
   end
   vde=0;
   wait(stream_pass && raster_pass);
   $display("PASS HDMI_1024: 1344x806 timing, 786432 active pixels, 768 lines, 8192 serialized RGB/control words at 66.667/333.333 MHz");
   $finish;
 end
 initial begin #20000000;$fatal(1,"HDMI_1024 timeout receiver=%0d raster=%b",received,raster_pass);end
endmodule
