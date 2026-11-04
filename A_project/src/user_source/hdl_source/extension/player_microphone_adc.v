`timescale 1ns/1ps
// EG4S20 硬 ADC CH1=M10：由硬核占用模拟管脚，不声明普通数字输入。
// 原理图 3_Power_and_Config：L11 的 VREF 经 R103 接 3.3V，C84 滤波。
module player_microphone_adc #(parameter integer CLK_HZ=25000000)(input clk,input rst,output reg valid,output reg [11:0] sample);
    reg adc_clk;
    localparam ADC_HALF_DIV=CLK_HZ>40000000 ? 2 : 1;
    reg adc_phase;
    // Preserve the original average 25 MHz / 128 sample cadence when the
    // HDMI pixel clock changes. At 27 MHz the SOC period is 138.24 clocks.
    localparam integer SOC_NUMERATOR=(CLK_HZ/1000)*128;
    localparam integer SOC_BASE=SOC_NUMERATOR/25000;
    localparam integer SOC_REMAINDER=SOC_NUMERATOR%25000;
    reg [$clog2(SOC_BASE+2)-1:0] phase;
    reg [15:0] fraction;
    wire extra_cycle=SOC_REMAINDER!=0 && fraction>=25000-SOC_REMAINDER;
    reg previous_eoc;
    wire eoc;
    wire [11:0] data;
    // Falling-edge divide by two: 12.5 MHz legacy / 13.5 MHz at 576p.
    // Rising-edge data capture still has half a pixel clock of margin.
    always @(negedge clk or posedge rst) begin
        if(rst) begin adc_clk<=0;adc_phase<=0;end
        else if(ADC_HALF_DIV==1 || adc_phase) begin adc_clk<=!adc_clk;adc_phase<=0;end
        else adc_phase<=1;
    end
    EG_PHY_ADC #(.CH1("ENABLE"),.VREF("ENABLE")) converter(
        .clk(adc_clk),.pd(rst),.s(3'd1),.soc(phase>=8*ADC_HALF_DIV && phase<16*ADC_HALF_DIV),.eoc(eoc),.dout(data));
    always @(posedge clk or posedge rst) begin
        if(rst) begin phase<=0;fraction<=0;previous_eoc<=0;valid<=0;sample<=0;end
        else begin
            if(phase==SOC_BASE-1+extra_cycle) begin
                phase<=0;
                fraction<=extra_cycle ? fraction+SOC_REMAINDER-25000 : fraction+SOC_REMAINDER;
            end else phase<=phase+1'b1;
            previous_eoc<=eoc;valid<=eoc && !previous_eoc;
            if(eoc && !previous_eoc) sample<=data;
        end
    end
endmodule
