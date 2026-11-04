`timescale 1ns/1ps
// Behavioral integration test: a synthetic DVP camera presents a real validation
// ROI through the 1024x768 capture and 640x480 normalization. SCCB configuration
// is bypassed here; its protocol has a separate test.
module tb_top_camera;
 reg clk=0,cam_pclk=0,rst_n=0,cam_vsync=0,cam_href=0;
 reg [7:0] cam_data=0;
 always #10 clk=~clk;
 always #11 cam_pclk=~cam_pclk;
 wire cam_rst_n,cam_pwdn,cam_scl,HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P;
 tri1 cam_sda;
 top dut(clk,rst_n,cam_pclk,cam_vsync,cam_href,cam_data,cam_rst_n,cam_pwdn,cam_scl,cam_sda,
   HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,1'b0,1'b0,4'b0,,,,,,);
 // Temporal confirmation is independently tested by tb_result_display.
 defparam dut.result_display.CONFIRM_RESULTS=1;
 defparam dut.camera.capture.WAIT_FRAMES=0;
 reg [23:0] pixels[0:4095];
 reg signed [31:0] expected[0:2];
 reg [23:0] rgb;reg [15:0] value;
 integer x,y,ix,iy,n,best,loaded=0,native_pixels=0,display_pixels=0;
 reg [23:0] expected_rgb;
 reg [15:0] expected_565;
 integer display_ix,display_iy;
 initial begin
   $readmemh("model/verification/input_rgb.hex",pixels);
   $readmemh("sim/generated/trained/expected_logits.hex",expected);
   #120;rst_n=1;
   wait(dut.sys_rst_n);
   // Real SCCB initialization outlasts the 200us SDRAM power-up interval.
   #300000;
   force dut.camera.config_done=1;
   force dut.camera.config_error=0;
   repeat(12) @(negedge cam_pclk);
   cam_vsync=1;repeat(4) @(negedge cam_pclk);cam_vsync=0;
   repeat(5) @(negedge cam_pclk);
   for(y=0;y<768;y=y+1) begin
     for(x=0;x<1024;x=x+1) begin
       rgb=0;
       if(x>=128 && x<896) begin
         ix=(x-128)*64/768;iy=y*64/768;rgb=pixels[iy*64+ix];
       end
       value={rgb[23:19],rgb[15:10],rgb[7:3]};
       cam_href=1;cam_data=value[15:8];@(negedge cam_pclk);
       cam_data=value[7:0];@(negedge cam_pclk);
     end
     cam_href=0;repeat(4) @(negedge cam_pclk);
   end
   wait(dut.done);#1;
   if(loaded!=4096) $fatal(1,"integration incomplete ROI: %d",loaded);
   if(dut.logits0!==expected[0] || dut.logits1!==expected[1] || dut.logits2!==expected[2])
     $fatal(1,"DVP -> ROI -> CNN logits mismatch");
   best=0;for(n=1;n<3;n=n+1) if(expected[n]>expected[best]) best=n;
   wait(dut.display_valid);#1;
   if(dut.display_class!==best[1:0]) $fatal(1,"result CDC / display mismatch");
   if(!dut.frame_valid) $fatal(1,"preview frame was not published");
   wait(display_pixels>=786432);
   if(native_pixels!=786432) $fatal(1,"native display branch lost camera pixels");
   $display("PASS TOP_CAMERA: 786432 native preview pixels; unchanged 4096 CNN inputs/logits; class %0d; native 1024x768 display verified",best);
   $finish;
 end
 always @(posedge clk) if(dut.load_valid && dut.load_ready) begin
   if(dut.load_addr!==loaded[11:0] || dut.load_rgb!==pixels[loaded]) $fatal(1,"integration pixel mismatch addr=%d",loaded);
   loaded=loaded+1;
 end
 always @(posedge cam_pclk) if(dut.native_valid) native_pixels=native_pixels+1;
 always @(posedge dut.video_clk) begin
   #0.2;
   if(dut.de && dut.frame_valid) begin
     expected_rgb=0;
     if(dut.vx>=128 && dut.vx<896) begin
       display_ix=(dut.vx-128)/12;display_iy=dut.vy/12;
       expected_rgb=pixels[display_iy*64+display_ix];
     end
     expected_565={expected_rgb[23:19],expected_rgb[15:10],expected_rgb[7:3]};
     expected_rgb={expected_565[15:11],expected_565[15:13],expected_565[10:5],expected_565[10:9],expected_565[4:0],expected_565[4:2]};
     if(dut.preview_rgb!==expected_rgb) $fatal(1,"native preview pixel mismatch x=%0d y=%0d got=%h expected=%h",dut.vx,dut.vy,dut.preview_rgb,expected_rgb);
     display_pixels=display_pixels+1;
   end
 end
 initial begin #100000000;$fatal(1,"top integration timeout");end
endmodule
