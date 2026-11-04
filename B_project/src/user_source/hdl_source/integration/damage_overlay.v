// Show only the current Chinese result, with the original three class colors.
module damage_overlay #(
 parameter MODEL_TRAINED=0,parameter MODEL_ACCEPTED=0,
 parameter WIDTH=640,parameter HEIGHT=480
)(
 input [23:0] rgb,input de,input [9:0] x,input [$clog2(HEIGHT)-1:0] y,
 input camera_ok,input camera_error,input result_valid,input [1:0] severity,
 output reg [23:0] rgb_out
);
 function [15:0] message_char;
   input [2:0] pos;
   reg [127:0] message;
   begin
     // Unicode values select the seven built-in glyphs; no numeric prefix.
     case(severity)
       0:message={16'h65e0,16'h8f66,16'h8f86,{5{16'h0020}}}; // 无车辆
       1:message={16'h8f66,16'h8f86,16'h65e0,16'h660e,16'h663e,16'h53d7,16'h635f,{1{16'h0020}}}; // 车辆无明显受损
       2:message={16'h8f66,16'h8f86,16'h53d7,16'h635f,{4{16'h0020}}}; // 车辆受损
       default:message={8{16'h0020}};
     endcase
     message_char=message[(7-pos)*16+:16];
   end
 endfunction
 // Fixed 16x16 monochrome SimSun glyphs. No external font/init file is needed.
 function [15:0] font_row;
   input [15:0] ch;input [3:0] row;
   reg [255:0] glyph;
   begin
     case(ch)
       16'h65e0:glyph=256'h0000_3ff0_0200_0200_0200_0200_7ffc_0480_0480_0480_0880_0880_1084_2084_407c_8000; // 无
       16'h8f66:glyph=256'h0200_0200_0200_7ffc_0400_0900_1100_2100_3ff8_0100_0100_fffe_0100_0100_0100_0100; // 车
       16'h8f86:glyph=256'h2000_23fe_2050_fc50_4050_53fe_9252_fe52_1252_12aa_1ea6_f302_5202_1202_120a_1204; // 辆
       16'h660e:glyph=256'h0000_00fc_7c84_4484_4484_44fc_7c84_4484_4484_44fc_7c84_4484_0104_0104_0214_0408; // 明
       16'h663e:glyph=256'h0000_1ff0_1010_1010_1ff0_1010_1010_1ff0_0440_4444_2444_1448_1450_0440_fffe_0000; // 显
       16'h53d7:glyph=256'h0008_01fc_7e10_2210_1120_7ffe_4002_8004_3ff0_1010_0820_0440_0380_0c60_3018_c006; // 受
       16'h635f:glyph=256'h1000_10f8_1088_1088_fcf8_1000_11fc_1504_1924_3124_d124_1124_1050_1048_5084_2304; // 损
       default:glyph=0;
     endcase
     font_row=glyph[(15-row)*16+:16];
   end
 endfunction
 reg [23:0] color;
 reg [9:0] tx;reg [8:0] ty;
 reg [15:0] glyph_row;
 localparam ROI_LEFT=(WIDTH-HEIGHT)/2,ROI_RIGHT=ROI_LEFT+HEIGHT;
 wire show_result=camera_ok && !camera_error && MODEL_TRAINED &&
                  result_valid && severity<=2;
 always @* begin
   case(severity)
     0:color=24'hb0b0b0;1:color=24'h20d070;2:color=24'hff8030;
     default:color=24'hffffff;
   endcase
   rgb_out=rgb;tx=0;ty=0;glyph_row=0;
   if(de) begin
     if((x>=ROI_LEFT && x<ROI_RIGHT && (y<2 || y>=HEIGHT-2)) ||
        (y>=2 && y<HEIGHT-2 && ((x>=ROI_LEFT && x<ROI_LEFT+2)||
        (x>=ROI_RIGHT-2 && x<ROI_RIGHT)))) rgb_out=24'h40c0e0;
     // Keep the ROI border, original result position and panel padding.
     // Double each font pixel to display 32x32 glyphs; expand the panel to fit.
     if(show_result && x>=40 && x<280 && y>=32 && y<72) begin
       rgb_out=24'h101b2b;
       if(x>=48 && x<272 && y>=36 && y<68) begin
         tx=x-48;ty=y-36;
         glyph_row=font_row(message_char(tx[7:5]),ty[4:1]);
         if(glyph_row[15-tx[4:1]])
           rgb_out=color;
       end
     end
   end else rgb_out=0;
 end
endmodule
