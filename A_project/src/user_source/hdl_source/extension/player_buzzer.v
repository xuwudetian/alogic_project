`timescale 1ns/1ps
// 板载蜂鸣器 H11，低电平导通；SW5 拨下接通、拨上断开。
// 复用 48kHz 样本使能，250ms 响/250ms 停；SW3 静音同样有效。
module player_buzzer #(
    parameter integer HALF_TICKS=12000
)(
    input clk,input rst,input enable,input mute,input tick,
    output buzzer_n
);
    localparam integer COUNT_WIDTH=(HALF_TICKS>1) ? $clog2(HALF_TICKS) : 1;
    reg [COUNT_WIDTH-1:0] count;
    reg pause;
    // 复位、静音、退出报警立即关闭，不等待下一次音频样本。
    assign buzzer_n=rst || !enable || mute || pause;
    always @(posedge clk or posedge rst) begin
        if(rst) begin count<=0;pause<=0;end
        else if(!enable || mute) begin count<=0;pause<=0;end
        else if(tick) begin
            if(count==HALF_TICKS-1) begin count<=0;pause<=!pause;end
            else count<=count+1'b1;
        end
    end
endmodule
