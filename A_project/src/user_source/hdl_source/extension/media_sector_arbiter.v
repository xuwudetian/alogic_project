`timescale 1ns/1ps
// Both producers issue pulses. Capture both before selecting one owner.
module media_sector_arbiter #(parameter integer PROBE_ENABLE=0)(
    input clk,input rst,input main_req,input [31:0] main_lba,
    input audio_req,input [31:0] audio_lba,input audio_urgent,
    output busy,output reg request,output reg [31:0] lba,
    input backend_busy,input backend_done,input backend_valid,input [7:0] backend_error,
    output main_valid,output main_done,output [7:0] main_error,
    output audio_valid,output audio_done,output [7:0] audio_error,
    input main_ready,input audio_ready,output emit_ready,output audio_owner,
    input probe_req,output probe_done,output [7:0] probe_error
);
    reg pending_main,pending_audio,active,owner,last_audio,pending_probe,probing;
    reg [31:0] queued_main,queued_audio;
    assign busy=active || pending_main || pending_audio || pending_probe || backend_busy || request;
    assign audio_owner=active && owner;
    assign main_valid=active && !owner && !probing && backend_valid;
    assign audio_valid=active && owner && backend_valid;
    assign main_done=active && !owner && !probing && backend_done;
    assign audio_done=active && owner && backend_done;
    assign main_error=main_done ? backend_error : 8'd0;
    assign audio_error=audio_done ? backend_error : 8'd0;
    assign probe_done=active && probing && backend_done;
    assign probe_error=probe_done ? backend_error : 8'd0;
    assign emit_ready=probing ? 1'b1 : owner ? audio_ready : main_ready;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            pending_main<=0;pending_audio<=0;active<=0;owner<=0;last_audio<=0;
            pending_probe<=0;probing<=0;
            queued_main<=0;queued_audio<=0;request<=0;lba<=0;
        end else begin
            request<=0;
            if(main_req) begin pending_main<=1;queued_main<=main_lba;end
            if(audio_req) begin pending_audio<=1;queued_audio<=audio_lba;end
            if(PROBE_ENABLE!=0 && probe_req) pending_probe<=1;
            if(active) begin
                if(backend_done) begin active<=0;last_audio<=owner;end
            end else if(!backend_busy && !request) begin
                if(pending_audio && (audio_urgent || !pending_main || !last_audio)) begin
                    pending_audio<=0;owner<=1;probing<=0;active<=1;request<=1;lba<=queued_audio;
                end else if(pending_main) begin
                    pending_main<=0;owner<=0;probing<=0;active<=1;request<=1;lba<=queued_main;
                end else if(PROBE_ENABLE!=0 && pending_probe && !main_req && !audio_req) begin
                    // 最低优先级读 LBA0；数据只丢弃，不送入 BMP/WAV。
                    pending_probe<=0;owner<=0;probing<=1;active<=1;request<=1;lba<=0;
                end
            end
        end
    end
endmodule
