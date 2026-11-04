`timescale 1ns/1ps
// 轻量传感控制：原始门限+连续确认，不增加 FFT、BRAM 或 DSP。
// 声音门限是 ADC 峰峰值，不是校准后的 dB SPL。
module player_sensor_policy #(
    parameter [15:0] DARK_RAW=160,LIGHT_RAW=320,
    parameter signed [8:0] NIGHT_BRIGHTNESS=64,
    parameter integer WINDOW_LOG2=13,
    parameter [11:0] SOUND_HIGH=700,SOUND_LOW=350,
    parameter integer QUIET_WINDOWS=24,COOLDOWN_WINDOWS=120,
    parameter integer EXIT_QUIET_WINDOWS=72,SAMPLE_TIMEOUT_CYCLES=256
)(input clk,input rst,input frame_tick,
  input light_valid,input light_online,input [15:0] light_raw,
  input signed [8:0] manual_brightness,input edit_mode,input alarm,
  input sample_valid,input [11:0] sample,
  output reg signed [8:0] brightness,output reg alarm_request,
  output reg dark,output reg [11:0] sound_level,output reg alarm_clear_request);
    reg [1:0] light_count;
    reg [WINDOW_LOG2-1:0] window_count;
    reg [11:0] minimum,maximum;
    reg window_bad,window_ready,level_bad;
    reg armed;
    reg [1:0] loud_count;
    reg [6:0] quiet_count,cooldown;
    localparam EXIT_BITS=EXIT_QUIET_WINDOWS>1 ? $clog2(EXIT_QUIET_WINDOWS) : 1;
    localparam GAP_BITS=SAMPLE_TIMEOUT_CYCLES>1 ? $clog2(SAMPLE_TIMEOUT_CYCLES) : 1;
    reg [EXIT_BITS-1:0] exit_quiet_count;
    reg [GAP_BITS-1:0] sample_gap;
    reg alarm_previous,exit_sent;
    wire alarm_enter=alarm && !alarm_previous;
    wire sample_timeout=!sample_valid && sample_gap==SAMPLE_TIMEOUT_CYCLES-1;
    wire [11:0] next_min=sample<minimum ? sample : minimum;
    wire [11:0] next_max=sample>maximum ? sample : maximum;
    wire invalid_sample=sample<12'd410 || sample>12'd3685;
    // 暗处补亮：原始照度每下降 4 级补 1 级亮度，最多补 64 级。
    // 只锁存有效读数；断线后清零，重新上线必须等待一次新读数。
    localparam [8:0] MAX_BOOST=NIGHT_BRIGHTNESS>0 ? NIGHT_BRIGHTNESS : 9'd0;
    wire [15:0] light_deficit=light_raw<LIGHT_RAW ? LIGHT_RAW-light_raw : 16'd0;
    wire [13:0] requested_boost=light_deficit[15:2];
    reg [8:0] light_boost;
    reg signed [8:0] frame_manual;
    wire signed [9:0] boosted_target=$signed({manual_brightness[8],manual_brightness})+
        $signed({1'b0,light_boost});
    wire signed [8:0] target=!light_online ? manual_brightness :
        boosted_target>10'sd255 ? 9'sd255 : boosted_target[8:0];
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            brightness<=0;dark<=0;light_count<=0;light_boost<=0;frame_manual<=0;alarm_request<=0;
            window_count<=0;minimum<=4095;maximum<=0;window_bad<=0;window_ready<=0;level_bad<=1;
            sound_level<=0;armed<=0;loud_count<=0;quiet_count<=0;cooldown<=0;
            alarm_clear_request<=0;exit_quiet_count<=0;sample_gap<=0;alarm_previous<=0;exit_sent<=0;
        end else begin
            alarm_request<=0;alarm_clear_request<=0;window_ready<=0;alarm_previous<=alarm;
            if(sample_valid) sample_gap<=0;
            else if(!sample_timeout) sample_gap<=sample_gap+1'b1;
            if(!light_online) begin dark<=0;light_count<=0;light_boost<=0;end
            else if(light_valid) begin
                light_boost<=requested_boost>MAX_BOOST ? MAX_BOOST : requested_boost[8:0];
                if((!dark && light_raw<DARK_RAW) || (dark && light_raw>LIGHT_RAW)) begin
                    if(light_count==2) begin dark<=!dark;light_count<=0;end
                    else light_count<=light_count+1'b1;
                end else light_count<=0;
            end
            // 设置窗口继续光感补亮；仅手动值改变时即时应用合成目标。
            // 自动控制仍每帧一步，打开窗口不会清除已生效的补亮。
            if(frame_tick) begin
                frame_manual<=manual_brightness;
                if(edit_mode && manual_brightness!=frame_manual) brightness<=target;
                else if(brightness<target) brightness<=brightness+1'b1;
                else if(brightness>target) brightness<=brightness-1'b1;
            end
            // 报警前的半窗不计入退出时间；ADC停采也丢弃半窗，禁止把旧数据当安静。
            if(alarm_enter || sample_timeout) begin
                window_count<=0;minimum<=4095;maximum<=0;window_bad<=0;level_bad<=1;
            end else if(sample_valid) begin
                window_count<=window_count+1'b1;
                if(&window_count) begin
                    sound_level<=next_max-next_min;level_bad<=window_bad || invalid_sample;
                    window_ready<=1;minimum<=4095;maximum<=0;window_bad<=0;
                end else begin
                    minimum<=next_min;maximum<=next_max;window_bad<=window_bad || invalid_sample;
                end
            end
            // 默认72个完整安静窗约3.02秒。非安静、越界或停采均重新计时。
            // 仅发退出请求，是否为声音报警由界面控制器判断；手动报警不自动关闭。
            if(!alarm || alarm_enter) begin exit_quiet_count<=0;exit_sent<=0;end
            else if(sample_timeout) exit_quiet_count<=0;
            else if(window_ready && !exit_sent) begin
                if(level_bad || sound_level>=SOUND_LOW) exit_quiet_count<=0;
                else if(exit_quiet_count==EXIT_QUIET_WINDOWS-1) begin
                    alarm_clear_request<=1;exit_sent<=1;
                end else exit_quiet_count<=exit_quiet_count+1'b1;
            end
            // 任意退出后先冷却且持续安静再重启，避免本机报警声立即反复触发。
            if(alarm) begin cooldown<=COOLDOWN_WINDOWS;armed<=0;loud_count<=0;quiet_count<=0;end
            else if(sample_timeout) begin armed<=0;quiet_count<=0;loud_count<=0;end
            else if(window_ready) begin
                if(cooldown!=0) begin cooldown<=cooldown-1'b1;armed<=0;quiet_count<=0;loud_count<=0;end
                else if(level_bad) begin armed<=0;quiet_count<=0;loud_count<=0;end
                else if(!armed) begin
                    if(sound_level<SOUND_LOW) begin
                        if(quiet_count==QUIET_WINDOWS-1) begin armed<=1;quiet_count<=0;end
                        else quiet_count<=quiet_count+1'b1;
                    end else quiet_count<=0;
                end else if(sound_level>SOUND_HIGH) begin
                    if(loud_count==2) begin alarm_request<=1;armed<=0;loud_count<=0;end
                    else loud_count<=loud_count+1'b1;
                end else loud_count<=0;
            end
        end
    end
endmodule
