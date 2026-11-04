`timescale 1ns/1ps
// Native 1024x768 RGB565 preview, independent of the CNN's normalized stream.
// Two frames live in package SDRAM. Four M32K blocks hold the asynchronous
// write FIFO and two line caches; CNN/ROI traffic stays separate.
// One camera pixel maps to one HDMI pixel, preserving the sensor's detail.
module camera_preview(
    input camera_clk,input camera_rst_n,input pixel_valid,input [15:0] pixel_rgb565,
    input [9:0] pixel_x,input [9:0] pixel_y,input frame_start,
    input mem_clk,input mem_rst_n,input mem_forward_clk,input video_clk,input video_rst_n,
    output [23:0] rgb,output reg hs,output reg vs,output reg de,
    output reg [9:0] x,output reg [9:0] y,output reg frame_valid);
    wire raw_hs,raw_vs,raw_de,video_frame_start;
    wire [9:0] raw_x;
    wire [9:0] raw_y;
    video_timing_640x480 #(.H_ACTIVE(1024),.H_FP(24),.H_SYNC(136),.H_BP(160),
        .V_ACTIVE(768),.V_FP(3),.V_SYNC(6),.V_BP(29)) timing(.clk(video_clk),.rst_n(video_rst_n),
        .hs(raw_hs),.vs(raw_vs),.de(raw_de),.x(raw_x),.y(raw_y),.frame_start(video_frame_start));
    wire published_toggle,published_bank,line_acknowledge,initialized;
    reg display_acknowledge,read_bank;
    reg line_request,line_frame_bank,line_cache;
    reg [9:0] line_row;
    (* async_reg="true" *) reg [1:0] publish_sync,line_ack_sync;
    reg [1:0] cache_valid;
    reg [9:0] cache_row0,cache_row1;
    reg prefetch_second;
    reg line_ack_seen,half_q,valid_q;
    wire [31:0] cache_write_data;
    wire [9:0] cache_write_address;
    wire cache_write_enable;
    wire [31:0] frames_committed,frames_dropped;
    preview_frame_store frame_store(.clk(mem_clk),.rst_n(mem_rst_n),.mem_forward_clk(mem_forward_clk),
        .camera_clk(camera_clk),.camera_rst_n(camera_rst_n),.pixel_valid(pixel_valid),
        .pixel_rgb565(pixel_rgb565),.pixel_x(pixel_x),.pixel_y(pixel_y),.frame_start(frame_start),
        .display_acknowledge(display_acknowledge),.published_toggle(published_toggle),.published_bank(published_bank),
        .line_request(line_request),.line_frame_bank(line_frame_bank),.line_row(line_row),.line_cache(line_cache),
        .line_acknowledge(line_acknowledge),.cache_write_enable(cache_write_enable),
        .cache_write_address(cache_write_address),.cache_write_data(cache_write_data),.initialized(initialized),
        .frames_committed(frames_committed),.frames_dropped(frames_dropped));
    wire [9:0] cache_read_address={raw_y[0],raw_x[9:1]};
    wire [31:0] cache_read_data;
    video_frame_ram #(.WORDS(1024),.BANKS(1)) cache_low(
        .write_clk(mem_clk),.write_enable(cache_write_enable),.write_address({5'd0,cache_write_address}),
        .write_data(cache_write_data[15:0]),.read_clk(video_clk),.read_enable(raw_de),
        .read_address({5'd0,cache_read_address}),.read_data(cache_read_data[15:0]));
    video_frame_ram #(.WORDS(1024),.BANKS(1)) cache_high(
        .write_clk(mem_clk),.write_enable(cache_write_enable),.write_address({5'd0,cache_write_address}),
        .write_data(cache_write_data[31:16]),.read_clk(video_clk),.read_enable(raw_de),
        .read_address({5'd0,cache_read_address}),.read_data(cache_read_data[31:16]));
    wire row_ready=cache_valid[raw_y[0]] && (raw_y[0]?cache_row1:cache_row0)==raw_y;
    wire new_frame_available=(publish_sync[1]!=display_acknowledge);
    always @(posedge video_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            publish_sync<=0;line_ack_sync<=0;display_acknowledge<=0;read_bank<=1;frame_valid<=0;
            line_request<=0;line_frame_bank<=0;line_cache<=0;line_row<=0;line_ack_seen<=0;
            cache_valid<=0;cache_row0<=0;cache_row1<=0;prefetch_second<=0;
            hs<=1;vs<=1;de<=0;x<=0;y<=0;half_q<=0;valid_q<=0;
        end else begin
            publish_sync<={publish_sync[0],published_toggle};line_ack_sync<={line_ack_sync[0],line_acknowledge};
            hs<=raw_hs;vs<=raw_vs;de<=raw_de;x<=raw_x;y<=raw_y;
            half_q<=raw_x[0];valid_q<=frame_valid && row_ready;
            if(line_ack_sync[1]!=line_ack_seen) begin
                line_ack_seen<=line_ack_sync[1];cache_valid[line_cache]<=1;
                if(line_cache) cache_row1<=line_row;else cache_row0<=line_row;
                // Complete both initial lines during the long vertical blank.
                if(prefetch_second) begin
                    line_row<=1;line_cache<=1;line_request<=~line_request;
                    prefetch_second<=0;
                end
            end
            if(video_frame_start) begin
                cache_valid<=0;
                if(new_frame_available) begin
                    read_bank<=published_bank;display_acknowledge<=publish_sync[1];frame_valid<=1;
                end
                if((frame_valid || new_frame_available) && line_ack_sync[1]==line_request) begin
                    line_frame_bank<=new_frame_available?published_bank:read_bank;
                    line_row<=0;line_cache<=0;line_request<=~line_request;
                    prefetch_second<=1;
                end
            end else if(raw_de && raw_x==0 && raw_y>=1 && raw_y<767 && frame_valid) begin
                // The previous line has finished using the opposite cache.
                // Fetch the next native line within this 20.16 us scanline.
                if(line_ack_sync[1]==line_request) begin
                    line_frame_bank<=read_bank;line_row<=raw_y+1'b1;
                    line_cache<=~raw_y[0];cache_valid[~raw_y[0]]<=0;line_request<=~line_request;
                end
            end
        end
    end
    wire [15:0] rgb565=half_q?cache_read_data[31:16]:cache_read_data[15:0];
    assign rgb=(de && valid_q) ?
        {rgb565[15:11],rgb565[15:13],rgb565[10:5],rgb565[10:9],rgb565[4:0],rgb565[4:2]}:24'd0;
endmodule
