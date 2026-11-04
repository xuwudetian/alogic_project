`timescale 1ns/1ps
// Native XGA simulation boundaries only (65/325 MHz). These are not models of vendor IP internals.
module sys_pll(input refclk,input reset,output clk0_out,output reg clk1_out=0,output clk2_out,output reg locked=0);
assign clk0_out=refclk;always #12.5 clk1_out=~clk1_out;assign #12 clk2_out=clk1_out;
initial begin #200;locked=1;end
endmodule
module video_pll(input refclk,input reset,output reg clk0_out=0,output reg clk1_out=0,output reg clk2_out=0,output reg locked=0);
always #7.6923075 clk0_out=~clk0_out;always #1.5384615 clk1_out=~clk1_out;always #7.6923075 clk2_out=~clk2_out;
initial begin #300;locked=1;end
endmodule
module sdram(input Clk,input Clk_sft,input Rst,output Sdr_init_done,output Sdr_init_ref_vld,output Sdr_busy,
input App_wr_en,input [20:0] App_wr_addr,input [3:0] App_wr_dm,input [31:0] App_wr_din,
input App_rd_en,input [20:0] App_rd_addr,output reg Sdr_rd_en=0,output [31:0] Sdr_rd_dout);
assign Sdr_init_done=!Rst;assign Sdr_init_ref_vld=0;assign Sdr_busy=0;assign Sdr_rd_dout=32'h10203000;
always @(posedge Clk) Sdr_rd_en<=App_rd_en && !Rst;
endmodule

module hdmi_1_4b_transmitter_core_wrapper#(
    parameter DEVICE            = "EG", //"EF2","EF3","EF4","SF1","SF2","EG","PH1A","PH1P","DR1","PH2A"

    parameter HTOTAL            = 2200,
    parameter HSA               = 44,
    parameter HFP               = 88,
    parameter HBP               = 148,
    parameter HACTIVE           = 1920,
    parameter VTOTAL            = 1125,
    parameter VSA               = 5,
    parameter VFP               = 4,
    parameter VBP               = 36,
    parameter VACTIVE           = 1080,

    parameter VIDEO_TPG         = "Enable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter VIDEO_VIC         = 16,

    parameter AUDIO_SAMPLE_RATE = "48K",

    parameter IIC_SCL_DIV       = 125
)(
    input wire       I_pixel_clk,
    input wire       I_rst,

    /*
        edid read interface 
    */
    input wire       I_edid_read_trig,
    output wire      O_edid_read_valid,
    output wire[7:0] O_edid_read_data,

    /*
        video interface 
    */
    input wire       I_axis_s_user,
    input wire       I_axis_s_valid,
    input wire       I_axis_s_last,
    input wire[23:0] I_axis_s_data,
    output wire      O_axis_s_ready,

    /*
        audio interface 
    */
    input wire       I_audio_valid,     
    input wire[23:0] I_audio_left_data, 
    input wire[23:0] I_audio_right_data,

    /*
        audio regenaration interface
    */
    input wire       I_acr_valid,
    input wire[19:0] I_acr_cts,
    input wire[19:0] I_acr_n,

    /*
        status signal
    */
    output wire      O_video_locked,

    /*
        DDC channel interface
    */
    output wire      O_ddc_scl,
    inout wire       IO_ddc_sda,

    /*
        tmds data interface 
    */
    output wire[9:0] O_ch0_tmds_data,
    output wire[9:0] O_ch1_tmds_data,
    output wire[9:0] O_ch2_tmds_data,
    output wire[9:0] O_clk_tmds_data
);


assign O_axis_s_ready=!I_rst;assign O_video_locked=!I_rst;assign O_edid_read_valid=0;assign O_edid_read_data=0;
assign O_ddc_scl=1;assign IO_ddc_sda=1'bz;
assign O_ch0_tmds_data=0;assign O_ch1_tmds_data=0;assign O_ch2_tmds_data=0;assign O_clk_tmds_data=0;
endmodule


module hdmi_phy_wrapper#(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_tmds_channel_0,
    input wire[9:0] I_tmds_channel_1,
    input wire[9:0] I_tmds_channel_2,
    input wire[9:0] I_tmds_channel_clk,
    
    output wire     O_tmds_ch0_p,
    output wire     O_tmds_ch1_p,
    output wire     O_tmds_ch2_p,
    output wire     O_tmds_clk_p
);
assign O_tmds_ch0_p=0;assign O_tmds_ch1_p=0;assign O_tmds_ch2_p=0;assign O_tmds_clk_p=I_pixel_clk;
endmodule
