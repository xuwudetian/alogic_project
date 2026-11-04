`timescale 1ns/1ps
module tb_damage_overlay #(parameter WIDTH=640,HEIGHT=480);
 localparam LEFT=(WIDTH-HEIGHT)/2,RIGHT=LEFT+HEIGHT;
 reg [23:0] rgb=24'h123456;
 reg de=0;reg [9:0] x=LEFT;reg [$clog2(HEIGHT)-1:0] y=200;
 reg camera_ok=1,camera_error=0,result_valid=1;reg [1:0] severity=0;
 wire [23:0] rgb_out;
 damage_overlay #(.MODEL_TRAINED(1),.MODEL_ACCEPTED(0),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) dut(
   rgb,de,x,y,camera_ok,camera_error,result_valid,severity,rgb_out);
 integer c,p;
 reg [127:0] expected_message;
 reg [23:0] text_color;
 // Check the entire visible frame: the former title/footer/validation bands
 // must show camera pixels again, and the original cyan ROI must remain.
 task check_frame;
   input with_result;
   integer px,py,text_pixels;
   reg [23:0] expected_pixel;
   begin
     text_pixels=0;
     for(py=0;py<HEIGHT;py=py+1) begin
       for(px=0;px<WIDTH;px=px+1) begin
         x=px;y=py;#1;
         if(with_result && px>=40 && px<280 && py>=32 && py<72) begin
           if(rgb_out===text_color) text_pixels=text_pixels+1;
           else if(rgb_out!==24'h101b2b) $fatal(1,"Unexpected result-panel pixel at %0d,%0d",px,py);
         end else begin
           expected_pixel=rgb;
           if((px>=LEFT && px<RIGHT && (py<2 || py>=HEIGHT-2)) ||
              (py>=2 && py<HEIGHT-2 && ((px>=LEFT && px<LEFT+2)||(px>=RIGHT-2 && px<RIGHT))))
             expected_pixel=24'h40c0e0;
           if(rgb_out!==expected_pixel) $fatal(1,"Preview/ROI changed at %0d,%0d",px,py);
         end
       end
     end
     if(with_result && text_pixels<400) $fatal(1,"Enlarged result text is missing");
   end
 endtask
 initial begin
   #1;de=1;#1;
   for(c=0;c<3;c=c+1) begin
     x=LEFT;y=200;severity=c;#1;
     if(rgb_out!==24'h40c0e0) $fatal(1,"ROI border depends on class");
     case(c)
       // Exact Chinese labels (Unicode), with spaces only after the last glyph.
       0:begin expected_message=128'h65e08f668f8600200020002000200020;text_color=24'hb0b0b0;end
       1:begin expected_message=128'h8f668f8665e0660e663e53d7635f0020;text_color=24'h20d070;end
       2:begin expected_message=128'h8f668f8653d7635f0020002000200020;text_color=24'hff8030;end
     endcase
     for(p=0;p<8;p=p+1)
       if(dut.message_char(p)!==expected_message[(7-p)*16+:16])
         $fatal(1,"Wrong result label: class %0d character %0d",c,p);
     check_frame(1);
   end
   result_valid=0;check_frame(0);
   result_valid=1;camera_ok=0;check_frame(0);
   camera_ok=1;camera_error=1;check_frame(0);
   camera_error=0;severity=3;check_frame(0);
   severity=0;x=LEFT;y=200;#1;
   if(rgb_out!==24'h40c0e0) $fatal(1,"Waiting causes border blink");
   x=LEFT+20;#1;if(rgb_out!==rgb) $fatal(1,"ROI interior corrupted");
   de=0;#1;if(rgb_out!==0) $fatal(1,"Blanking output nonzero");
   $display("Raster %0dx%0d",WIDTH,HEIGHT);
   $display("PASS DAMAGE_OVERLAY: enlarged 32x32 Chinese labels without numeric prefixes, original gray/green/orange colors, full-frame preview/ROI preservation, no startup/error hints and correct blanking");
   $finish;
 end
endmodule
