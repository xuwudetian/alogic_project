`timescale 1ns/1ps
// 1024 x 32 dual-clock FIFO. Each pointer crosses only as Gray code; the RAM
// payload is read only after the synchronized write pointer advertises it.
// Two explicit M32K blocks avoid consuming the CNN's M9K allocation.
module preview_async_fifo(
    input write_clk,input write_rst_n,input write_enable,input [31:0] write_data,
    output full,
    input read_clk,input read_rst_n,input read_enable,
    output [31:0] read_data,output reg read_valid,
    output empty,output [10:0] read_count);
    reg [10:0] write_binary,write_gray,read_binary,read_gray;
    (* async_reg="true" *) reg [10:0] read_gray_w1,read_gray_w2;
    (* async_reg="true" *) reg [10:0] write_gray_r1,write_gray_r2;
    function [10:0] gray_to_binary;
        input [10:0] value;
        integer i;
        begin
            gray_to_binary[10]=value[10];
            for(i=9;i>=0;i=i-1) gray_to_binary[i]=gray_to_binary[i+1]^value[i];
        end
    endfunction
    assign full=(write_gray=={~read_gray_w2[10:9],read_gray_w2[8:0]});
    assign empty=(read_gray==write_gray_r2);
    assign read_count=gray_to_binary(write_gray_r2)-read_binary;
    wire push=write_enable && !full;
    wire pop=read_enable && !empty;
    wire [10:0] write_next=write_binary+1'b1;
    wire [10:0] read_next=read_binary+1'b1;
    always @(posedge write_clk or negedge write_rst_n) begin
        if(!write_rst_n) begin
            write_binary<=0;write_gray<=0;read_gray_w1<=0;read_gray_w2<=0;
        end else begin
            read_gray_w1<=read_gray;read_gray_w2<=read_gray_w1;
            if(push) begin write_binary<=write_next;write_gray<=(write_next>>1)^write_next;end
        end
    end
    always @(posedge read_clk or negedge read_rst_n) begin
        if(!read_rst_n) begin
            read_binary<=0;read_gray<=0;write_gray_r1<=0;write_gray_r2<=0;read_valid<=0;
        end else begin
            write_gray_r1<=write_gray;write_gray_r2<=write_gray_r1;read_valid<=pop;
            if(pop) begin read_binary<=read_next;read_gray<=(read_next>>1)^read_next;end
        end
    end
    video_frame_ram #(.WORDS(1024),.BANKS(1)) low_ram(
        .write_clk(write_clk),.write_enable(push),.write_address({5'd0,write_binary[9:0]}),
        .write_data(write_data[15:0]),.read_clk(read_clk),.read_enable(pop),
        .read_address({5'd0,read_binary[9:0]}),.read_data(read_data[15:0]));
    video_frame_ram #(.WORDS(1024),.BANKS(1)) high_ram(
        .write_clk(write_clk),.write_enable(push),.write_address({5'd0,write_binary[9:0]}),
        .write_data(write_data[31:16]),.read_clk(read_clk),.read_enable(pop),
        .read_address({5'd0,read_binary[9:0]}),.read_data(read_data[31:16]));
endmodule
