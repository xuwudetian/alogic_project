`timescale 1ns/1ps
// VEML7700：固定 1x / 100ms，只读原始照度，不做浮点 lux 换算。
// SCL/SDA 只拉低或释放，必须有 3.3V 外部上拉。
module player_light_sensor #(
    parameter integer QUARTER_CYCLES=125,
    parameter integer POLL_FRAMES=16
)(input clk,input rst,input frame_tick,inout scl,inout sda,
  output reg valid,output reg online,output reg [15:0] raw);
    localparam IDLE=0,RECOVER=1,START=2,BYTE=3,ACK=4,RESTART=5,STOP=6;
    reg [2:0] state,phase_byte;
    reg [1:0] phase;
    reg [2:0] bit_index;
    reg [3:0] recovery_count;
    reg [7:0] shift,low_byte;
    reg [$clog2(QUARTER_CYCLES)-1:0] divider;
    reg [4:0] frames,stretch_wait;
    reg scl_low,sda_low,configured,failed,recovering;
    (* async_reg="true" *) reg [1:0] scl_sync,sda_sync;
    assign scl=scl_low ? 1'b0 : 1'bz;
    assign sda=sda_low ? 1'b0 : 1'bz;
    wire receiving=configured && phase_byte>=3;
    wire stretch_phase=(state==BYTE || state==ACK || state==RECOVER) ? phase==2 :
                       (state==START || state==RESTART || state==STOP) && phase==2;
    wire wait_clock=stretch_phase && !scl_sync[1];
    always @(posedge clk or posedge rst) begin
        if(rst) begin scl_sync<=3;sda_sync<=3;end
        else begin scl_sync<={scl_sync[0],scl};sda_sync<={sda_sync[0],sda};end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;phase<=0;phase_byte<=0;bit_index<=7;recovery_count<=0;
            shift<=0;low_byte<=0;divider<=0;frames<=0;stretch_wait<=0;
            scl_low<=0;sda_low<=0;configured<=0;failed<=0;recovering<=0;
            valid<=0;online<=0;raw<=0;
        end else begin
            valid<=0;
            if(frame_tick && state==IDLE) begin
                if(frames==POLL_FRAMES-1) begin
                    frames<=0;phase<=0;failed<=0;stretch_wait<=0;
                    if(configured) state<=START;
                    else begin state<=RECOVER;recovery_count<=0;recovering<=1;end
                end else frames<=frames+1'b1;
            end
            if(divider==QUARTER_CYCLES-1) begin
                divider<=0;
                if(wait_clock) begin
                    // 卡低超时后释放总线，下次自动重新初始化。
                    if(stretch_wait==31) begin
                        state<=IDLE;scl_low<=0;sda_low<=0;configured<=0;online<=0;frames<=0;
                        stretch_wait<=0;recovering<=0;
                    end else stretch_wait<=stretch_wait+1'b1;
                end else begin
                    stretch_wait<=0;
                    case(state)
                        RECOVER: case(phase)
                            0:begin scl_low<=1;sda_low<=0;phase<=1;end
                            1:begin scl_low<=0;phase<=2;end
                            2:phase<=3;
                            3:begin
                                scl_low<=1;phase<=0;
                                if(recovery_count==8) state<=STOP;
                                else recovery_count<=recovery_count+1'b1;
                            end
                        endcase
                        START,RESTART: case(phase)
                            0:begin sda_low<=0;phase<=1;end
                            1:begin scl_low<=0;phase<=2;end
                            2:begin
                                if(!sda_sync[1]) begin failed<=1;state<=STOP;phase<=0;end
                                else begin sda_low<=1;phase<=3;end
                            end
                            3:begin
                                scl_low<=1;phase<=0;bit_index<=7;state<=BYTE;
                                if(state==RESTART) begin shift<=8'h21;phase_byte<=2;end
                                else begin shift<=8'h20;phase_byte<=0;end
                            end
                        endcase
                        BYTE: case(phase)
                            0:begin sda_low<=receiving ? 1'b0 : !shift[7];phase<=1;end
                            1:begin scl_low<=0;phase<=2;end
                            2:begin if(receiving) shift<={shift[6:0],sda_sync[1]};phase<=3;end
                            3:begin
                                scl_low<=1;phase<=0;
                                if(!receiving) shift<={shift[6:0],1'b0};
                                if(bit_index==0) state<=ACK;else bit_index<=bit_index-1'b1;
                            end
                        endcase
                        ACK: case(phase)
                            0:begin sda_low<=receiving && phase_byte==3;phase<=1;end
                            1:begin scl_low<=0;phase<=2;end
                            2:begin
                                if(!receiving && sda_sync[1]) failed<=1;
                                phase<=3;
                            end
                            3:begin
                                scl_low<=1;phase<=0;bit_index<=7;
                                if(failed) state<=STOP;
                                else if(!configured) begin
                                    if(phase_byte==3) state<=STOP;
                                    else begin phase_byte<=phase_byte+1'b1;shift<=0;state<=BYTE;end
                                end else case(phase_byte)
                                    0:begin phase_byte<=1;shift<=8'h04;state<=BYTE;end
                                    1:state<=RESTART;
                                    2:begin phase_byte<=3;shift<=0;state<=BYTE;end
                                    3:begin low_byte<=shift;phase_byte<=4;shift<=0;state<=BYTE;end
                                    default:begin raw<={shift,low_byte};state<=STOP;end
                                endcase
                            end
                        endcase
                        STOP: case(phase)
                            0:begin scl_low<=1;sda_low<=1;phase<=1;end
                            1:begin scl_low<=0;phase<=2;end
                            2:begin sda_low<=0;phase<=3;end
                            3:begin
                                phase<=0;frames<=0;
                                if(recovering) begin recovering<=0;state<=START;end
                                else begin
                                    state<=IDLE;
                                    if(failed) begin online<=0;configured<=0;end
                                    else if(!configured) configured<=1;
                                    else begin online<=1;valid<=1;end
                                end
                            end
                        endcase
                        default:begin scl_low<=0;sda_low<=0;end
                    endcase
                end
            end else divider<=divider+1'b1;
        end
    end
endmodule
