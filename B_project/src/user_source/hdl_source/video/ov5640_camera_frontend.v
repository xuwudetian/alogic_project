`timescale 1ns/1ps
module ov5640_camera_frontend #(
    parameter integer SIMPLE_AWB=1
)(
    input clk50,input rst_n,input cam_pclk,input cam_vsync,input cam_href,input [7:0] cam_data,
    output cam_rst_n,output cam_pwdn,output cam_scl,inout cam_sda,
    output reg config_done,output reg config_error,
    output pixel_valid,output [15:0] pixel_rgb565,
    output [9:0] pixel_x,output [8:0] pixel_y,output frame_start,
    output native_valid,output [15:0] native_rgb565,
    output [9:0] native_x,output [9:0] native_y,output native_frame_start);
    localparam POWER_WAIT=0,SUBMIT=1,WAIT_DONE=2,RESET_WAIT=3,FINISHED=4;
    localparam [7:0] LAST_REGISTER=8'd254;
    reg [2:0] state;
    reg [20:0] delay_count;
    reg [7:0] reg_index;
    reg [1:0] retry_count;
    reg start;
    wire [23:0] reg_data;
    wire busy,done,nack;
    assign cam_pwdn=1'b0;
    assign cam_rst_n=rst_n && (state!=POWER_WAIT || delay_count>=250000);
    ov5640_register_table #(.SIMPLE_AWB(SIMPLE_AWB)) table_rom(.index(reg_index),.data(reg_data));
    ov5640_sccb_write bus_master(.clk(clk50),.rst_n(rst_n),.start(start),
        .register_data(reg_data),.busy(busy),.done(done),.nack(nack),.scl(cam_scl),.sda(cam_sda));
    always @(posedge clk50 or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWER_WAIT;delay_count<=0;reg_index<=2;retry_count<=0;
            start<=0;config_done<=0;config_error<=0;
        end else begin
            start<=0;
            case(state)
                POWER_WAIT: if(delay_count==1500000-1) begin
                    delay_count<=0;state<=SUBMIT;
                end else delay_count<=delay_count+1'b1;
                SUBMIT: if(!busy) begin start<=1;state<=WAIT_DONE;end
                WAIT_DONE: if(done) begin
                    if(nack) begin
                        if(retry_count==3) begin config_error<=1;state<=FINISHED;end
                        else begin retry_count<=retry_count+1'b1;state<=SUBMIT;end
                    end else begin
                        retry_count<=0;
                        if(reg_index==LAST_REGISTER) begin config_done<=1;state<=FINISHED;end
                        else begin
                            reg_index<=reg_index+1'b1;
                            if(reg_index==2) begin delay_count<=0;state<=RESET_WAIT;end
                            else state<=SUBMIT;
                        end
                    end
                end
                RESET_WAIT: if(delay_count==250000-1) state<=SUBMIT;
                            else delay_count<=delay_count+1'b1;
                default: ;
            endcase
        end
    end
    wire capture_rst_n;
    video_reset_sync capture_reset(.clk(cam_pclk),.arst_n(rst_n),.rst_n(capture_rst_n));
    (* async_reg = "true" *) reg [1:0] config_sync;
    always @(posedge cam_pclk or negedge capture_rst_n)
        if(!capture_rst_n) config_sync<=0;
        else config_sync<={config_sync[0],config_done};
    // The display receives the complete native frame. The independent CNN
    // branch retains the exact existing 640x480 normalization and ROI contract.
    wire raw_valid,raw_frame_start;
    wire [15:0] raw_rgb565;
    wire [9:0] raw_x,raw_y;
    assign native_valid=raw_valid;
    assign native_rgb565=raw_rgb565;
    assign native_x=raw_x;
    assign native_y=raw_y;
    assign native_frame_start=raw_frame_start;
    ov5640_rgb565_capture #(.WIDTH(1024),.HEIGHT(768)) capture(
        .cam_pclk(cam_pclk),.rst_n(capture_rst_n),.enable(config_sync[1]),
        .cam_vsync(cam_vsync),.cam_href(cam_href),.cam_data(cam_data),
        .pixel_valid(raw_valid),.pixel_rgb565(raw_rgb565),.pixel_x(raw_x),
        .pixel_y(raw_y),.frame_start(raw_frame_start));
    ov5640_resize_1024_to_640 normalize(
        .clk(cam_pclk),.rst_n(capture_rst_n),.input_frame_start(raw_frame_start),
        .input_valid(raw_valid),.input_rgb565(raw_rgb565),.input_x(raw_x),.input_y(raw_y),
        .frame_start(frame_start),.pixel_valid(pixel_valid),.pixel_rgb565(pixel_rgb565),
        .pixel_x(pixel_x),.pixel_y(pixel_y));
endmodule

// Fixed-ratio, centre-aligned nearest sampling over the entire sensor frame.
// Source coordinate = floor((output_coordinate + 0.5) * 8 / 5).
// Successive coordinate steps repeat 2,2,1,2,1. No frame/line memory, divider,
// DSP, colour conversion or new clock domain is needed. RGB565 bits pass intact.
// Keeping the old 640x480 raster preserves the ROI's centre-square geometry,
// 4096-sample ordering, input quantization and CNN/mailbox implementation.
module ov5640_resize_1024_to_640(
    input clk,input rst_n,input input_frame_start,input input_valid,
    input [15:0] input_rgb565,input [9:0] input_x,input [9:0] input_y,
    output reg frame_start,output reg pixel_valid,output reg [15:0] pixel_rgb565,
    output reg [9:0] pixel_x,output reg [8:0] pixel_y
);
    reg active;
    reg [9:0] target_x,target_y,out_x;
    reg [8:0] out_y;
    reg [2:0] phase_x,phase_y;
    wire [1:0] step_x=(phase_x==2 || phase_x==4) ? 2'd1 : 2'd2;
    wire [1:0] step_y=(phase_y==2 || phase_y==4) ? 2'd1 : 2'd2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            frame_start<=0;pixel_valid<=0;pixel_rgb565<=0;pixel_x<=0;pixel_y<=0;
            active<=0;target_x<=0;target_y<=0;out_x<=0;out_y<=0;phase_x<=0;phase_y<=0;
        end else begin
            frame_start<=input_frame_start;pixel_valid<=0;
            if(input_frame_start) begin
                active<=1;target_x<=0;target_y<=0;out_x<=0;out_y<=0;phase_x<=0;phase_y<=0;
            end else if(active && input_valid && input_x==target_x && input_y==target_y) begin
                pixel_valid<=1;pixel_rgb565<=input_rgb565;pixel_x<=out_x;pixel_y<=out_y;
                if(out_x==639) begin
                    out_x<=0;target_x<=0;phase_x<=0;
                    if(out_y==479) active<=0;
                    else begin
                        out_y<=out_y+1'b1;target_y<=target_y+step_y;
                        phase_y<=phase_y==4 ? 3'd0 : phase_y+1'b1;
                    end
                end else begin
                    out_x<=out_x+1'b1;target_x<=target_x+step_x;
                    phase_x<=phase_x==4 ? 3'd0 : phase_x+1'b1;
                end
            end
        end
    end
endmodule
