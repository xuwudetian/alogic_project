`timescale 1ns/1ps
// Video-only DVI TMDS carried by HDMI A; no encrypted core, audio or HDCP.
// LVDS33 pin assignment causes the EG4 differential companion pads to be used.
module hdmi_dvi_tx(input pixel_clk,input serial_clk,input rst_n,
    input [23:0] rgb,input hs,input vs,input de,
    output HDMI_CLK_P,output HDMI_D2_P,output HDMI_D1_P,output HDMI_D0_P);
    wire [9:0] red_symbol,green_symbol,blue_symbol;
    tmds_encoder red(.clk(pixel_clk),.rst_n(rst_n),.data(rgb[23:16]),.de(de),.control(2'd0),.symbol(red_symbol));
    tmds_encoder green(.clk(pixel_clk),.rst_n(rst_n),.data(rgb[15:8]),.de(de),.control(2'd0),.symbol(green_symbol));
    tmds_encoder blue(.clk(pixel_clk),.rst_n(rst_n),.data(rgb[7:0]),.de(de),.control({vs,hs}),.symbol(blue_symbol));
    tmds_serializer sr(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),.symbol(red_symbol),.serial_out(HDMI_D2_P));
    tmds_serializer sg(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),.symbol(green_symbol),.serial_out(HDMI_D1_P));
    tmds_serializer sb(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),.symbol(blue_symbol),.serial_out(HDMI_D0_P));
    tmds_serializer sc(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.rst_n(rst_n),.symbol(10'b0000011111),.serial_out(HDMI_CLK_P));
endmodule
