`timescale 1ns/1ps
// The board module supplies its own XCLK, as in the supplied OV5640 demo.
// RGB565 arrives MSB first, two PCLK cycles per pixel. No data-clock CDC.
module ov5640_rgb565_capture #(
    parameter integer WAIT_FRAMES=10,
    parameter integer WIDTH=640,HEIGHT=480
)(input cam_pclk,input rst_n,input enable,
    input cam_vsync,input cam_href,input [7:0] cam_data,
    output reg pixel_valid,output reg [15:0] pixel_rgb565,
    output reg [$clog2(WIDTH)-1:0] pixel_x,
    output reg [$clog2(HEIGHT)-1:0] pixel_y,
    output reg frame_start);
    reg vs_d, href_d, byte_phase;
    reg [7:0] msb;
    // Include the terminal count: 1024 must not wrap back to x=0 on a long
    // line. Saturation also prevents extra lines from re-entering the image.
    reg [$clog2(WIDTH+1)-1:0] next_x;
    reg [$clog2(HEIGHT+1)-1:0] next_y;
    reg [7:0] stable_frames;
    reg active;
    // Sample the complete DVP bus into input registers before byte/control logic.
    // All three signals acquire the same one-cycle delay.
    reg [7:0] data_q;
    reg href_q,vsync_q;
    always @(posedge cam_pclk) begin data_q<=cam_data;href_q<=cam_href;vsync_q<=cam_vsync;end
    always @(posedge cam_pclk or negedge rst_n) begin
        if(!rst_n) begin
            vs_d<=0; href_d<=0; byte_phase<=0; msb<=0;
            next_x<=0;next_y<=0;pixel_valid<=0;pixel_rgb565<=0;
            pixel_x<=0;pixel_y<=0;frame_start<=0;stable_frames<=0;active<=0;
        end else begin
            vs_d<=vsync_q;href_d<=href_q;
            pixel_valid<=0; frame_start<=0;
            if(!enable) begin
                stable_frames<=0;active<=0;byte_phase<=0;next_x<=0;next_y<=0;
            end else if(vsync_q && !vs_d) begin
                next_x<=0; next_y<=0; byte_phase<=0;
                if(stable_frames<WAIT_FRAMES) stable_frames<=stable_frames+1'b1;
                else begin active<=1;frame_start<=1;end
            end else if(!vsync_q) begin
                if(href_q) begin
                    byte_phase<=~byte_phase;
                    if(!byte_phase) msb<=data_q;
                    else begin
                        if(active && next_x<WIDTH && next_y<HEIGHT) begin
                            pixel_valid<=1;pixel_rgb565<={msb,data_q};
                            pixel_x<=next_x;pixel_y<=next_y;
                        end
                        if(next_x<WIDTH) next_x<=next_x+1'b1;
                    end
                end else begin
                    byte_phase<=0;next_x<=0;
                    if(href_d && next_y<HEIGHT) next_y<=next_y+1'b1;
                end
            end
        end
    end
endmodule
