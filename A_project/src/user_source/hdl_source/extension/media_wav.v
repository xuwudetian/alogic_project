`timescale 1ns/1ps
module media_wav #(parameter integer AUDIO_SELECT_ENABLE=0)(
    input clk,input rst,input enable,input found,input [31:0] cluster,input [31:0] size,
    input [7:0] spc,input [31:0] fat_lba,input [31:0] data_lba,input [31:0] max_cluster,
    output sector_req,output [31:0] sector_lba,input sector_busy,
    input sector_valid,input [7:0] sector_byte,input [8:0] byte_index,
    input sector_done,input [7:0] sector_error,
    output replay_ready,output urgent,
    input audio_clk,input audio_rst,input tick,input [23:0] tone,
    input [3:0] volume,input mute,
    output reg valid,output reg [23:0] pcm,output [7:0] status,
    output reg wav_sample_valid,
    input [1:0] audio_select,output reg [1:0] active_select
);
    localparam SWITCH_RUN=2'd0,SWITCH_DRAIN=2'd1,SWITCH_RESET=2'd2,SWITCH_SETTLE=2'd3;
    reg [1:0] switch_state;
    reg [2:0] switch_count;
    reg switch_reset,audio_outstanding;
    wire switch_block=AUDIO_SELECT_ENABLE!=0 &&
        (switch_state!=SWITCH_RUN || audio_select!=active_select);
    wire wav_reset=rst || switch_reset;
    // A request remains outstanding while queued in the shared arbiter as well
    // as while physically reading SD. Finish that sector before local reset;
    // main image/probe transactions and the card controller are never reset.
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            switch_state<=SWITCH_RUN;switch_count<=0;switch_reset<=0;
            audio_outstanding<=0;active_select<=0;
        end else if(AUDIO_SELECT_ENABLE!=0) begin
            if(sector_req) audio_outstanding<=1;
            if(sector_done) audio_outstanding<=0;
            case(switch_state)
                SWITCH_RUN: if(audio_select!=active_select) switch_state<=SWITCH_DRAIN;
                SWITCH_DRAIN: if(!audio_outstanding && !sector_req) begin
                    switch_reset<=1;active_select<=audio_select;
                    switch_count<=7;switch_state<=SWITCH_RESET;
                end
                SWITCH_RESET: begin
                    // Coalesce quick KEY changes while the local path is held.
                    if(audio_select!=active_select) begin
                        active_select<=audio_select;switch_count<=7;
                    end else if(switch_count!=0) switch_count<=switch_count-1'b1;
                    else begin switch_reset<=0;switch_count<=3;switch_state<=SWITCH_SETTLE;end
                end
                SWITCH_SETTLE: begin
                    if(audio_select!=active_select) switch_state<=SWITCH_DRAIN;
                    else if(switch_count!=0) switch_count<=switch_count-1'b1;
                    else switch_state<=SWITCH_RUN;
                end
            endcase
        end
    end
    reg start,started,ended,disabled,accepted_once;
    wire file_done,file_valid,file_busy,accepted,parse_done,sample_valid;
    wire [7:0] file_byte,file_error,parse_error;
    wire [31:0] offset;
    wire [15:0] sample,fifo_sample;
    wire full,empty;
    wire [9:0] wrused,rdused;
    reg [7:0] error_latched;
    reg [1:0] accept_sync,end_sync,disable_sync;
    reg playing,underflow;
    // 热插拔重建文件/FIFO时，读时钟域的播放状态也同步重置。
    (* async_reg="true" *) reg [1:0] read_reset_sync;
    wire read_reset_async=wav_reset || audio_rst;
    wire read_reset=read_reset_sync[1];
    always @(posedge audio_clk or posedge read_reset_async)
        if(read_reset_async) read_reset_sync<=2'b11;
        else read_reset_sync<={read_reset_sync[0],1'b0};
    wire pop=tick && playing && !empty && !disable_sync[1];
    wire signed [20:0] product=$signed(fifo_sample)*$signed({1'b0,volume});
    wire [15:0] adjusted=product>>>3;
    // Discard pending old-sector bytes without FIFO backpressure on a switch.
    assign replay_ready=switch_block || wrused<1000 || disabled;
    assign urgent=wrused<512 && !disabled && !switch_block;
    // status is in the SD clock domain; the top snapshots it before OSD use.
    reg [1:0] under_sync;
    assign status=error_latched!=0 ? error_latched :
                  under_sync[1] ? 8'h55 : accepted_once ? 8'h01 : 8'h00;
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(1048576)) file_reader(
        .clk(clk),.rst_n(!wav_reset),.file_start(start),.first_cluster(cluster),.file_size(size),
        .sectors_per_cluster(spc),.fat_start_lba(fat_lba),.data_start_lba(data_lba),
        .max_cluster(max_cluster),.file_busy(file_busy),.file_done(file_done),
        .file_valid(file_valid),.file_byte(file_byte),.file_byte_offset(offset),.fs_error(file_error),
        .sector_req(sector_req),.sector_lba(sector_lba),
        .sector_busy(sector_busy || switch_block || (wrused>=640 && !disabled)),
        .sector_valid(sector_valid),.sector_byte(sector_byte),.sector_byte_index(byte_index),
        .sector_done(sector_done),.sector_error(sector_error),.error_detail());
    wav_pcm_parser parser(clk,wav_reset,start,size,file_valid,file_byte,offset,file_done,
                          sample_valid,sample,accepted,parse_done,parse_error);
    wfifo_32_32_512 #(.DATA_WIDTH_W(16),.DATA_WIDTH_R(16),
        .ADDR_WIDTH_W(10),.ADDR_WIDTH_R(10),.AL_FULL_NUM(1000)) audio_fifo(
        .rst(wav_reset || audio_rst),.clkw(clk),.clkr(audio_clk),
        .we(sample_valid && !disabled && !full && !switch_block),.di(sample),.re(pop),.dout(fifo_sample),
        .valid(),.full_flag(full),.empty_flag(empty),.afull(),.aempty(),.wrusedw(wrused),.rdusedw(rdused));
    always @(posedge clk or posedge wav_reset) begin
        if(wav_reset) begin
            start<=0;started<=0;ended<=0;disabled<=0;accepted_once<=0;error_latched<=0;under_sync<=0;
        end else begin
            start<=0;under_sync<={under_sync[0],underflow};
            if(accepted) accepted_once<=1;
            if(enable && found && !started && !disabled && !switch_block) begin start<=1;started<=1;end
            if(AUDIO_SELECT_ENABLE!=0 && enable && !found && !switch_block) begin
                error_latched<=8'h50;disabled<=1;
            end
            if(file_done) begin
                ended<=1;
            end
            // A transport failure can produce a later truncated-EOF parser error.
            // Preserve the root cause instead of replacing W54 with W53.
            if(file_done && file_error!=0) begin error_latched<=8'h54;disabled<=1;end
            else if(!disabled) begin
                if(parse_error!=0) begin error_latched<=parse_error;disabled<=1;end
                else if(sample_valid && full) begin error_latched<=8'h56;disabled<=1;end
            end
            // Restart only after the final FAT check and read-domain draining.
            if(ended && !file_busy && wrused==0 && !disabled && parse_error==0 && !switch_block) begin
                ended<=0;start<=1;
            end
        end
    end
    always @(posedge audio_clk or posedge read_reset) begin
        if(read_reset) begin
            accept_sync<=0;end_sync<=0;disable_sync<=0;playing<=0;
            underflow<=0;valid<=0;pcm<=0;wav_sample_valid<=0;
        end else begin
            accept_sync<={accept_sync[0],accepted_once};
            end_sync<={end_sync[0],ended};
            disable_sync<={disable_sync[0],disabled};
            valid<=tick;
            // Provenance for read-only visuals, aligned with pcm/valid. Never
            // tag the fallback oscillator, an empty FIFO, or a disabled file.
            wav_sample_valid<=tick && accept_sync[1] && !disable_sync[1] && pop;
            if(!accept_sync[1] || disable_sync[1] || (end_sync[1] && empty)) playing<=0;
            else if(rdused>=512 || (end_sync[1] && !empty)) playing<=1;
            if(tick) begin
                if(!accept_sync[1] || disable_sync[1]) pcm<=tone;
                else if(pop) pcm<=mute ? 24'd0 : {adjusted,8'd0};
                else begin
                    pcm<=0;
                    if(playing && empty && !end_sync[1]) underflow<=1;
                end
            end
        end
    end
endmodule
