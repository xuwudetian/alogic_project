`timescale 1ns/1ps
// Publish a sector only after its byte count and the driver's CRC check pass.
module sd_sector_guard #(
    parameter integer CLK_FREQ_HZ=50000000
) (
    input clk,input rst,
    input request,input [31:0] requested_lba,
    output reg busy,output reg valid,output reg [7:0] data,
    output reg [8:0] byte_index,output reg done,output reg [7:0] error,
    output reg raw_request,output reg [31:0] raw_lba,output slow_read,
    input raw_valid,input [7:0] raw_data,input raw_done,input [7:0] raw_error,
    output reg [59:0] debug_status,output reg debug_toggle,
    input emit_ready
);
    localparam IDLE=0,RECEIVE=1,CHECK=2,EMIT=3,FINISH=4,BACKOFF=5;
    reg [2:0] state;
    reg [7:0] buffer[0:511];
    reg [9:0] received;
    reg [15:0] tail_bytes;
    reg [1:0] attempts,phase;
    reg [5:0] retry_wait;
    reg [25:0] timeout_count;
    reg slow_latched;
    assign slow_read=slow_latched;

    always @(posedge clk) begin
        if(state==RECEIVE && raw_valid && received<512)
            buffer[received[8:0]]<=raw_data;
        if(state==EMIT && phase==0)
            data<=buffer[byte_index];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;busy<=0;valid<=0;byte_index<=0;done<=0;error<=0;
            raw_request<=0;raw_lba<=0;received<=0;tail_bytes<=0;
            attempts<=0;phase<=0;retry_wait<=0;timeout_count<=0;
            debug_status<=0;debug_toggle<=0;
            slow_latched<=0;
        end else begin
            valid<=0;done<=0;
            case(state)
                IDLE: if(request) begin
                    busy<=1;error<=0;raw_request<=1;raw_lba<=requested_lba;
                    received<=0;tail_bytes<=0;attempts<=0;timeout_count<=0;
                    state<=RECEIVE;
                end
                RECEIVE: begin
                    if(raw_valid) begin
                        if(received<513) received<=received+1'b1;
                        if(received==510) tail_bytes[15:8]<=raw_data;
                        if(received==511) tail_bytes[7:0]<=raw_data;
                    end
                    if(raw_done) begin raw_request<=0;state<=CHECK;end
                    else if(timeout_count==CLK_FREQ_HZ-1) begin
                        raw_request<=0;error<=8'h10;state<=FINISH;
                        debug_status<={raw_lba,received,tail_bytes,attempts};
                        debug_toggle<=!debug_toggle;
                    end else timeout_count<=timeout_count+1'b1;
                end
                CHECK: begin
                    debug_status<={raw_lba,received,tail_bytes,attempts};
                    debug_toggle<=!debug_toggle;
                    if(raw_error!=0 || received!=512) begin
                        if(attempts<2) begin
                            attempts<=attempts+1'b1;retry_wait<=0;state<=BACKOFF;
                            slow_latched<=1;
                        end else begin
                            error<=raw_error!=0 ? raw_error : 8'h16;
                            state<=FINISH;
                        end
                    end else begin byte_index<=0;phase<=0;state<=EMIT;end
                end
                BACKOFF: begin
                    if(retry_wait==31 && !raw_done) begin
                        received<=0;tail_bytes<=0;timeout_count<=0;
                        raw_request<=1;state<=RECEIVE;
                    end else if(retry_wait<31) retry_wait<=retry_wait+1'b1;
                end
                EMIT: case(phase)
                    0:phase<=1;
                    1:if(emit_ready) begin valid<=1;phase<=2;end
                    2:begin
                        if(byte_index==511) state<=FINISH;
                        else begin byte_index<=byte_index+1'b1;phase<=0;end
                    end
                    default:phase<=0;
                endcase
                FINISH:begin done<=1;busy<=0;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
