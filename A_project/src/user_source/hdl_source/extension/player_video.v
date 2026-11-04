`timescale 1ns/1ps
module player_video #(
    parameter integer MODE_576=0,
    parameter integer MODE_XGA=0,
    parameter integer CLK_HZ=25000000,
    parameter integer WAVE_TRIGGER_ENABLE=1,
    parameter integer WAVE_HALF_RATE=1,
    parameter integer WAVE_SMOOTH_ENABLE=1,
    // 8 点分组平均：48 kHz 下 128 点覆盖 21.33 ms，为旧版 4 倍。
    parameter integer WAVE_DECIMATE_LOG2=3,
    parameter integer WAVE_GAIN_BOOST=1,
    // 默认每四帧更新；保留 WAVE_HALF_RATE=0 的逐帧测试入口。
    parameter integer WAVE_UPDATE_FRAMES=(WAVE_HALF_RATE!=0 ? 4 : 1),
    parameter integer UI_ENABLE=0,
    // 0=旧示波器，1=音乐包络，2=256点真实波形；正式顶层选择2。
    parameter integer WAVE_MUSIC_ENABLE=0,
    parameter integer PANEL_ALPHA_ENABLE=0,
    parameter integer IMAGE_EFFECTS_ENABLE=0,
    parameter integer AMBIENT_ENABLE=0,
    parameter integer AMBIENT_ZOOM_ENABLE=0
)(
    input clk,input rst,input hs,input vs,input de,input [23:0] rgb,
    input signed [8:0] brightness,input [8:0] contrast,input [8:0] gain,
    input display_valid,input [3:0] picture,input scaled,
    input auto_play,input [7:0] error_code,input [3:0] state_code,
    input [3:0] volume,input [3:0] interval_seconds,input [2:0] menu,input [3:0] modes,
    input audio_valid,input signed [23:0] audio_sample,
    output out_hs,output out_vs,output out_de,output reg [23:0] out_rgb,
    input [59:0] debug_status,input [7:0] audio_status,
    input image_valid,
    input ui_directory,input ui_status,input ui_alarm,input ui_browse,
    input [39:0] source_resolution,input [1:0] run_mode,
    input effect_mask_active,input [2:0] effect_mask_style,input [5:0] effect_mask_level,
    input [3:0] transition_mode,input [1:0] audio_select,
    input [23:0] ambient_color,input picture_layout,
    input [7:0] layout_size,input [9:0] layout_left,input [9:0] layout_top,
    input [9:0] layout_width,input [9:0] layout_height
);
    // E37 carries a three-bit image slot; SD/FAT diagnostics retain their
    // original sector count, header and response layout.
    wire [9:0] diagnostic_n=error_code==8'h37 ? {1'b0,debug_status[27:19]} : debug_status[27:18];
    wire [15:0] diagnostic_h=error_code==8'h37 ? debug_status[18:3] : debug_status[17:2];
    wire [3:0] diagnostic_r=error_code==8'h37 ? {1'b0,debug_status[2:0]} : {2'b0,debug_status[1:0]};
    reg last_de,last_vs;
    reg [9:0] raster_x,raster_y;
    wire [9:0] logical_x,logical_y;
    generate if(MODE_XGA) begin: registered_coordinates
        player_xga_logical_coordinates coordinates(.clk(clk),.rst(rst),.de(de),
            .frame_tick(last_vs && !vs),.row_tick(last_de && !de),
            .native_x_phase(raster_x[2:0]),.native_y_phase(raster_y[2:0]),.x(logical_x),.y(logical_y));
    end else begin assign logical_x=0;assign logical_y=0;end endgenerate
    wire [9:0] x=MODE_XGA ? logical_x : raster_x;
    wire [9:0] y=MODE_XGA ? logical_y : raster_y;
    reg [9:0] xp[0:4];
    reg [9:0] yp[0:4];
    reg [4:0] dp,hp,vp;
    // (RGB-128)*contrast 范围 -65408..64897，17 位足够；加亮度后 11 位足够。
    reg signed [16:0] cr,cg,cb;
    reg signed [10:0] br,bg,bb;
    reg [23:0] adjusted;
    reg [16:0] fr,fg,fb;
    reg [23:0] faded;
    reg [8:0] scroll;
    reg [$clog2(CLK_HZ)-1:0] second_count;
    reg [3:0] su,st,mu,mt,hu,ht;
    reg [3:0] ssu,sst,smu,smt,shu,sht;
    // 波形仅在视频末端叠加，不回写 SDRAM，也不混合历史帧。
    // 双缓存各保存 128 个采样点，横向每 5 个像素对应一个点，覆盖 640 像素。
    localparam [23:0] WAVE_COLOR = 24'h1040b0; // 深蓝色，RGB(16,64,176)
    localparam [23:0] UI_BACKGROUND = 24'h606060;
    // 显示高度恢复到 128 行，同一音频的峰峰值比 64 行版本增大两倍。
    // 频谱从 352 开始，中间保留 8 行原图；不改变音量和 FFT 输入。
    localparam [8:0] WAVE_TOP = 9'd216;
    localparam [8:0] WAVE_END = 9'd344;
    localparam integer AUDIO_IDLE_MAX = (CLK_HZ/20-1); // 25 MHz 下无有效样本 50 ms
    // 每个地址保存 {前一点, 当前点}，一次同步读取得到线段两端。
    // 避免双读口将小波形 RAM 复制成两块，给同时启用的 FFT 留出资源。
    reg [13:0] wave[0:255];
    reg [6:0] previous_point;
    reg capture_bank,display_bank,wave_ready,wave_valid;
    // 提交后倒数三个帧边界，归零后才采集，下一边界提交完整块。
    // 滤波仍连续工作，不把已采好的旧音频块保持三帧后才显示。
    localparam integer WAVE_FRAME_BITS=WAVE_UPDATE_FRAMES>1 ? $clog2(WAVE_UPDATE_FRAMES) : 1;
    // 扩窗后为采集预留两帧，仍以四帧为目标提交周期。
    localparam integer CAPTURE_FRAMES=WAVE_DECIMATE_LOG2>=3 ? 2 : 1;
    localparam integer HOLD_FRAMES=WAVE_UPDATE_FRAMES>CAPTURE_FRAMES ? WAVE_UPDATE_FRAMES-CAPTURE_FRAMES : 0;
    localparam integer TRIGGER_GROUPS=384 >> WAVE_DECIMATE_LOG2;
    reg [WAVE_FRAME_BITS-1:0] wave_frame_wait;
    wire wave_hold_frame=(wave_frame_wait!=0);
    reg [6:0] sample_index;
    reg [WAVE_DECIMATE_LOG2-1:0] decimation;
    reg signed [15+WAVE_DECIMATE_LOG2:0] group_sum;
    // 显示支路一阶低通：y += (x-y)/4，16 位 PCM 保留两位小数。
    // 每个有效音频样本都更新，包括等待帧提交期间；不反馈到声音或 FFT。
    reg signed [17:0] smooth_state;
    reg signed [15:0] visual_pcm;
    reg visual_valid;
    wire signed [18:0] smooth_input={audio_sample[23],audio_sample[23:8],2'b00};
    wire signed [18:0] smooth_delta=smooth_input-$signed({smooth_state[17],smooth_state});
    wire signed [18:0] smooth_next=$signed({smooth_state[17],smooth_state})+(smooth_delta>>>2);
    reg [$clog2(CLK_HZ/20+1)-1:0] audio_idle;
    // 周期音频从负半周后的上升过零点开始采集，减少帧间相位跳动造成的叠影感。
    // 触发等待保持 384 个原始样本（48 kHz 下约 8 ms），不随扩窗倍数增加。
    reg trigger_armed,trigger_active;
    // 上一完整块的负峰决定滞回宽度（1..4 个显示码）。连续两对负样本
    // 才允许上升过零触发，抑制零点附近孤立毛刺；不平均不同音乐周期。
    reg trigger_below;
    reg [5:0] capture_negative_peak;
    reg [2:0] trigger_margin;
    wire [6:0] trigger_low_y=7'd64+{4'd0,trigger_margin};
    reg [7:0] trigger_wait;
    wire frame_tick=last_vs && !vs;
    // 先分组平均再抽取；归一化为旧接口的两倍均值，无新增乘法器和 RAM。
    wire signed [15+WAVE_DECIMATE_LOG2:0] group_total=group_sum+
        $signed({{WAVE_DECIMATE_LOG2{visual_pcm[15]}},visual_pcm});
    wire signed [16:0] pair_sum=group_total >>> (WAVE_DECIMATE_LOG2-1);
    wire trigger_crossing=trigger_armed && !pair_sum[16];
    // 默认显示增益 10/7，约提高 43%；大信号在区域边缘饱和，不覆盖频谱。
    wire signed [20:0] pair_extended={{4{pair_sum[16]}},pair_sum};
    wire signed [20:0] height_scaled=WAVE_GAIN_BOOST!=0 ?
        (pair_extended<<<3)+(pair_extended<<<1) : (pair_extended<<<3)-pair_extended;
    wire signed [20:0] height_rounded=height_scaled+21'sd4096;
    wire signed [16:0] sample_height = 17'sd64 - (height_rounded >>> 13);
    wire [6:0] wave_y = sample_height<0 ? 7'd0 : sample_height>127 ? 7'd127 : sample_height[6:0];
    wire below_trigger=(wave_y>=trigger_low_y);

    // 滤波与采样分拍，数据和有效脉冲同时延迟一拍，缩短反馈组合路径。
    always @(posedge clk or posedge rst) begin
        if(rst) begin smooth_state<=0;visual_pcm<=0;visual_valid<=0;end
        else begin
            visual_valid<=audio_valid && WAVE_MUSIC_ENABLE==0;
            if(audio_valid) begin
                smooth_state<=smooth_next[17:0];
                visual_pcm<=WAVE_SMOOTH_ENABLE!=0 ? smooth_next[17:2] : audio_sample[23:8];
            end else if(audio_idle==AUDIO_IDLE_MAX) begin smooth_state<=0;visual_pcm<=0;end
        end
    end

    // 波形流水线与原来的五级 RGB/坐标流水对齐，不改变 HDMI 输出延迟。
    // S0：读取当前点和下一点；S1：计算每一像素的线段端点（五分之一像素精度）；
    // S2：四舍五入；S3：判断曲线覆盖；S4：对齐 faded，输出时只覆盖本帧曲线。
    // 行消隐期间归零；每五个有效像素推进一次地址，避免坐标除法。
    reg [6:0] read_index;
    reg [2:0] wave_phase,phase0;
    wire [6:0] next_index = read_index==7'd127 ? 7'd127 : read_index+7'd1;
    reg [13:0] wave_pair0;
    reg last_point0;
    wire [6:0] wave_point0=last_point0 ? wave_pair0[6:0] : wave_pair0[13:7];
    wire [6:0] wave_next0=wave_pair0[6:0];
    reg [9:0] line_a1,line_b1;
    reg [6:0] line_a2,line_b2;
    reg line_hit3,line_hit4;
    wire [8:0] wave_y2 = yp[2] - WAVE_TOP;
    wire [9:0] rounded_a1 = (line_a1 + 10'd2) / 10'd5;
    wire [9:0] rounded_b1 = (line_b1 + 10'd2) / 10'd5;
    always @(posedge clk or posedge rst) begin
        if(rst) begin read_index<=0;wave_phase<=0;phase0<=0;end
        else begin
            phase0<=wave_phase;
            if(!de) begin read_index<=0;wave_phase<=0;end
            else if(wave_phase==4) begin
                wave_phase<=0;
                if(read_index!=127) read_index<=read_index+1'b1;
            end else wave_phase<=wave_phase+1'b1;
        end
    end
    // RAM 内容不复位；wave_valid 确保完整采集前不会显示未初始化的数据。
    always @(posedge clk) begin
        wave_pair0 <= wave[{display_bank,next_index}];
        last_point0 <= (read_index==127);
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            line_a1<=0;line_b1<=0;line_a2<=0;line_b2<=0;line_hit3<=0;line_hit4<=0;
        end else begin
            // (5-k)*当前点+k*下一点；10 位中间值容纳最大值 5*127。
            case(phase0)
                3'd0: begin
                    line_a1<=({3'b0,wave_point0}<<2)+{3'b0,wave_point0};
                    line_b1<=({3'b0,wave_point0}<<2)+{3'b0,wave_next0};
                end
                3'd1: begin
                    line_a1<=({3'b0,wave_point0}<<2)+{3'b0,wave_next0};
                    line_b1<=({3'b0,wave_point0}<<1)+{3'b0,wave_point0}+({3'b0,wave_next0}<<1);
                end
                3'd2: begin
                    line_a1<=({3'b0,wave_point0}<<1)+{3'b0,wave_point0}+({3'b0,wave_next0}<<1);
                    line_b1<=({3'b0,wave_point0}<<1)+({3'b0,wave_next0}<<1)+{3'b0,wave_next0};
                end
                3'd3: begin
                    line_a1<=({3'b0,wave_point0}<<1)+({3'b0,wave_next0}<<1)+{3'b0,wave_next0};
                    line_b1<={3'b0,wave_point0}+({3'b0,wave_next0}<<2);
                end
                default: begin
                    line_a1<={3'b0,wave_point0}+({3'b0,wave_next0}<<2);
                    line_b1<=({3'b0,wave_next0}<<2)+{3'b0,wave_next0};
                end
            endcase
            line_a2<=rounded_a1[6:0];line_b2<=rounded_b1[6:0];
            // 每列仅连接本像素与下一像素的高度，避免四像素整块填充造成粗线重影感。
            line_hit3<=wave_valid && xp[2]>=8 && xp[2]<632 && yp[2]>=WAVE_TOP && yp[2]<WAVE_END &&
                ((wave_y2>=line_a2 && wave_y2<={2'b0,line_b2}+9'd1) ||
                 (wave_y2>=line_b2 && wave_y2<={2'b0,line_a2}+9'd1));
            line_hit4<=line_hit3;
        end
    end
    integer i;
    function [7:0] clamp;
        input signed [10:0] a;
        begin
            if(a<0) clamp=0;
            else if(a>255) clamp=255;
            else clamp=a[7:0];
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            last_de<=0;last_vs<=1;raster_x<=0;raster_y<=0;dp<=0;hp<=0;vp<=0;
            cr<=0;cg<=0;cb<=0;br<=0;bg<=0;bb<=0;adjusted<=0;
            fr<=0;fg<=0;fb<=0;faded<=0;scroll<=0;second_count<=0;
            su<=0;st<=0;mu<=0;mt<=0;hu<=0;ht<=0;
            ssu<=0;sst<=0;smu<=0;smt<=0;shu<=0;sht<=0;
            capture_bank<=0;display_bank<=1;wave_ready<=0;wave_valid<=0;
            wave_frame_wait<=0;
            previous_point<=0;
            sample_index<=0;decimation<=0;group_sum<=0;audio_idle<=0;
            trigger_armed<=0;trigger_active<=0;trigger_wait<=0;
            trigger_below<=0;capture_negative_peak<=0;trigger_margin<=1;
            for(i=0;i<5;i=i+1) begin xp[i]<=0;yp[i]<=0;end
        end else begin
            last_de<=de;last_vs<=vs;
            if(de) raster_x<=raster_x+1'b1;else raster_x<=0;
            if(frame_tick) raster_y<=0;
            else if(last_de && !de) raster_y<=raster_y+1'b1;
            xp[0]<=x;yp[0]<=y;
            for(i=1;i<5;i=i+1) begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];end
            dp<={dp[3:0],de};hp<={hp[3:0],hs};vp<={vp[3:0],vs};
            cr<=($signed({1'b0,rgb[23:16]})-17'sd128)*$signed({1'b0,contrast});
            cg<=($signed({1'b0,rgb[15:8]})-17'sd128)*$signed({1'b0,contrast});
            cb<=($signed({1'b0,rgb[7:0]})-17'sd128)*$signed({1'b0,contrast});
            br<=(cr>>>7)+17'sd128+brightness;
            bg<=(cg>>>7)+17'sd128+brightness;
            bb<=(cb>>>7)+17'sd128+brightness;
            // 亮度端点强制图片全白/全黑，不受对比度影响；上层 OSD 保留。
            adjusted<=brightness==9'sd255 ? 24'hffffff : brightness== -9'sd255 ? 24'd0 :
                      {clamp(br),clamp(bg),clamp(bb)};
            fr<=adjusted[23:16]*gain;fg<=adjusted[15:8]*gain;fb<=adjusted[7:0]*gain;
            faded<=display_valid ? {fr[15:8],fg[15:8],fb[15:8]} : 24'd0;
            if(second_count==CLK_HZ-1) begin
                second_count<=0;
                if(su!=9) su<=su+1'b1;
                else begin su<=0;
                    if(st!=5) st<=st+1'b1;
                    else begin st<=0;
                        if(mu!=9) mu<=mu+1'b1;
                        else begin mu<=0;
                            if(mt!=5) mt<=mt+1'b1;
                            else begin mt<=0;
                                if(hu!=9) hu<=hu+1'b1;
                                else begin hu<=0;ht<=ht==9 ? 0 : ht+1'b1;end
                            end
                        end
                    end
                end
            end else second_count<=second_count+1'b1;
            if(frame_tick) begin
                scroll<=scroll+1'b1;
                ssu<=su;sst<=st;smu<=mu;smt<=mt;shu<=hu;sht<=ht;
            end
            if(audio_valid) audio_idle<=0;
            else if(audio_idle!=AUDIO_IDLE_MAX) audio_idle<=audio_idle+1'b1;
            if(frame_tick && wave_hold_frame) wave_frame_wait<=wave_frame_wait-1'b1;
            // 音频有效脉冲停止时，不无限保留最后一帧旧曲线；重新来音频后整块重采。
            if(!audio_valid && !visual_valid && audio_idle==AUDIO_IDLE_MAX) begin
                wave_valid<=0;wave_ready<=0;sample_index<=0;decimation<=0;
                wave_frame_wait<=0;
                trigger_armed<=0;trigger_active<=0;trigger_wait<=0;
                trigger_below<=0;capture_negative_peak<=0;trigger_margin<=1;
            end else if(frame_tick && wave_ready && !wave_hold_frame) begin
                display_bank<=capture_bank;capture_bank<=!capture_bank;
                wave_frame_wait<=HOLD_FRAMES;
                sample_index<=0;wave_ready<=0;wave_valid<=1;decimation<=0;
                trigger_armed<=0;trigger_active<=0;trigger_wait<=0;
                trigger_below<=0;capture_negative_peak<=0;
                trigger_margin<={1'b0,capture_negative_peak[5:4]}+3'd1;
            end else if(WAVE_MUSIC_ENABLE==0 && visual_valid && !wave_ready && !wave_hold_frame) begin
                decimation<=decimation+1'b1;
                if(decimation==0) group_sum<={{WAVE_DECIMATE_LOG2{visual_pcm[15]}},visual_pcm};
                else group_sum<=group_total;
                if(&decimation) begin
                    if(trigger_active || WAVE_TRIGGER_ENABLE==0 || trigger_crossing || trigger_wait==TRIGGER_GROUPS-1) begin
                        trigger_active<=1;
                        wave[{capture_bank,sample_index}]<={sample_index==0 ? wave_y : previous_point,wave_y};
                        previous_point<=wave_y;
                        if(wave_y[6] && wave_y[5:0]>capture_negative_peak)
                            capture_negative_peak<=wave_y[5:0];
                        if(sample_index==127) wave_ready<=1;
                        else sample_index<=sample_index+1'b1;
                    end else begin
                        trigger_wait<=trigger_wait+1'b1;
                        trigger_below<=below_trigger;
                        if(below_trigger && trigger_below) trigger_armed<=1;
                    end
                end
            end
        end
    end
    assign out_hs=hp[4];
    assign out_vs=vp[4];
    assign out_de=dp[4];
    // 遮罩只作用于图片，字幕/波形/频谱/Logo 不随转场消失。
    wire [4:0] image_mask;
    wire [23:0] picture_rgb=image_mask[4] ? 24'd0 : faded;
    wire [23:0] picture_rgb3=display_valid && !image_mask[3] ? {fr[15:8],fg[15:8],fb[15:8]} : 24'd0;
    generate if(IMAGE_EFFECTS_ENABLE!=0) begin:image_effects
        if(MODE_XGA) begin: pipelined_mask
            // These are the only mask taps consumed by the XGA video path.
            assign image_mask[2:0]=0;
            player_image_mask_pipeline #(.MODE_576(MODE_576)) mask(.clk(clk),.rst(rst),.x(x),.y(y),
                .active(effect_mask_active),.style(effect_mask_style),.level(effect_mask_level),
                .tap3(image_mask[3]),.tap4(image_mask[4]));
        end else begin: legacy_mask
            player_image_mask #(.MODE_576(MODE_576)) mask(.clk(clk),.rst(rst),.x(x),.y(y),.active(effect_mask_active),
                .style(effect_mask_style),.level(effect_mask_level),.mask_pipe(image_mask));
        end
    end else begin:no_image_effects
        assign image_mask=5'd0;
    end endgenerate
    wire [1:0] music_ink;
    wire visual_hit=WAVE_MUSIC_ENABLE!=0 ? |music_ink : wave_valid && line_hit4;
    wire [23:0] visual_color=WAVE_MUSIC_ENABLE!=0 && music_ink==1 ? 24'h3c94dc : WAVE_COLOR;
    wire [23:0] alarm_wave_color=WAVE_MUSIC_ENABLE!=0 && music_ink==1 ? 24'hb01010 : 24'hff2020;
    generate if(WAVE_MUSIC_ENABLE==2) begin:triggered_visual
        player_triggered_wave #(.MODE_576(MODE_576),.MODE_XGA(MODE_XGA),.IDLE_CYCLES(CLK_HZ/20)) scope(.clk(clk),.rst(rst),.de(de),.frame_tick(frame_tick),
            .x(x),.y(y),.audio_valid(audio_valid),.audio_sample(audio_sample),.ink(music_ink),
            .compact_layout(AMBIENT_ENABLE!=0 && picture_layout && !ui_alarm));
    end else if(WAVE_MUSIC_ENABLE!=0) begin:music_visual
        player_music_envelope envelope(.clk(clk),.rst(rst),.de(de),.frame_tick(frame_tick),
            .x(x),.y(y),.audio_valid(audio_valid),.audio_sample(audio_sample),.ink(music_ink));
    end else begin:scope_visual
        assign music_ink=2'd0;
    end endgenerate

    // The SDRAM reader supplies the compact picture below the 24-pixel header:
    // 640x480 at (40,32) for 576p, or the legacy 544x408 at (48,32).
    // Paint only the margins here; the picture itself keeps its tone/effects.
    wire ambient_layout=AMBIENT_ENABLE!=0 && picture_layout && !ui_alarm;
    // Precompute rectangle edges off the pixel path. The animation controller
    // publishes in blanking, well before the next frame-read handshake.
    wire [9:0] image_left,image_right,frame_left,frame_right,glow_left,glow_right;
    wire [9:0] image_top,image_bottom,frame_top,frame_bottom,glow_top,glow_bottom;
    generate if(AMBIENT_ZOOM_ENABLE!=0) begin: moving_bounds
        reg [9:0] il,ir,fl,fr,gl,gr;
        reg [9:0] it,ib,ft,fb,gt,gb;
        assign {image_left,image_right,frame_left,frame_right,glow_left,glow_right}={il,ir,fl,fr,gl,gr};
        assign {image_top,image_bottom,frame_top,frame_bottom,glow_top,glow_bottom}={it,ib,ft,fb,gt,gb};
        always @(posedge clk or posedge rst) begin
            if(rst) begin
                il<=MODE_576 ? 40 : 48;ir<=MODE_576 ? 680 : 592;it<=32;ib<=MODE_576 ? 512 : 440;
                fl<=MODE_576 ? 38 : 46;fr<=MODE_576 ? 682 : 594;ft<=30;fb<=MODE_576 ? 514 : 442;
                gl<=MODE_576 ? 34 : 42;gr<=MODE_576 ? 686 : 598;gt<=26;gb<=MODE_576 ? 518 : 446;
            end else begin
                il<=layout_left;ir<=layout_left+(MODE_576 ? layout_width : {layout_size,2'b00});
                it<=layout_top;ib<=layout_top+(MODE_576 ? layout_height : {layout_size,1'b0}+layout_size);
                fl<=MODE_576 && il<2 ? 0 : il-2;fr<=ir+2;
                ft<=MODE_576 && it<2 ? 0 : it-2;fb<=ib+2;
                gl<=MODE_576 && il<6 ? 0 : il-6;gr<=ir+6;
                gt<=MODE_576 && it<6 ? 0 : it-6;gb<=ib+6;
            end
        end
    end else begin: fixed_bounds
        assign {image_left,image_right,image_top,image_bottom}=MODE_576 ?
            {10'd40,10'd680,10'd32,10'd512} : {10'd48,10'd592,10'd32,10'd440};
        assign {frame_left,frame_right,frame_top,frame_bottom}=MODE_576 ?
            {10'd38,10'd682,10'd30,10'd514} : {10'd46,10'd594,10'd30,10'd442};
        assign {glow_left,glow_right,glow_top,glow_bottom}=MODE_576 ?
            {10'd34,10'd686,10'd26,10'd518} : {10'd42,10'd598,10'd26,10'd446};
    end endgenerate
    wire in_picture,in_frame,in_glow;
    generate if(MODE_XGA) begin: native_bounds
        reg [49:0] xpipe,ypipe;
        always @(posedge clk or posedge rst)
            if(rst) begin xpipe<=0;ypipe<=0;end
            else begin xpipe<={xpipe[39:0],raster_x};ypipe<={ypipe[39:0],raster_y};end
        function [10:0] scale_edge(input [9:0] logical_edge);
            scale_edge=(logical_edge*8+4)/5;
        endfunction
        wire [10:0] nx={1'b0,xpipe[49:40]},ny={1'b0,ypipe[49:40]};
        wire [10:0] scaled_width=((image_right-image_left)*8)/5;
        reg [10:0] il,it,iw,ih,ir,ib,fl,fr,ft,fb,gl,gr,gt,gb;
        // Geometry is stable throughout a frame; register conversion and
        // edge addition before it reaches the per-pixel compare/mix path.
        always @(posedge clk or posedge rst) begin
            if(rst) begin
                il<=0;it<=0;iw<=0;ih<=0;ir<=0;ib<=0;
                fl<=0;fr<=0;ft<=0;fb<=0;gl<=0;gr<=0;gt<=0;gb<=0;
            end else begin
                il<=scale_edge(image_left);it<=scale_edge(image_top);
                iw<={scaled_width[10:2],2'b00};ih<=((image_bottom-image_top)*8)/5;
                ir<=il+iw;ib<=it+ih;
                fl<=scale_edge(frame_left);fr<=scale_edge(frame_right);
                ft<=scale_edge(frame_top);fb<=scale_edge(frame_bottom);
                gl<=scale_edge(glow_left);gr<=scale_edge(glow_right);
                gt<=scale_edge(glow_top);gb<=scale_edge(glow_bottom);
            end
        end
        reg [4:0] picture_pipe,frame_pipe,glow_pipe;
        // Compare before the existing five pixel stages, so the final
        // ambient blend receives registered region flags alongside faded RGB.
        always @(posedge clk or posedge rst) begin
            if(rst) begin picture_pipe<=0;frame_pipe<=0;glow_pipe<=0;end
            else begin
                picture_pipe<={picture_pipe[3:0],{1'b0,raster_x}>=il && {1'b0,raster_x}<ir && {1'b0,raster_y}>=it && {1'b0,raster_y}<ib};
                frame_pipe<={frame_pipe[3:0],{1'b0,raster_x}>=fl && {1'b0,raster_x}<fr && {1'b0,raster_y}>=ft && {1'b0,raster_y}<fb};
                glow_pipe<={glow_pipe[3:0],{1'b0,raster_x}>=gl && {1'b0,raster_x}<gr && {1'b0,raster_y}>=gt && {1'b0,raster_y}<gb};
            end
        end
        assign in_picture=picture_pipe[4];
        assign in_frame=frame_pipe[4];
        assign in_glow=glow_pipe[4];
    end else begin: legacy_bounds
        assign in_picture=xp[4]>=image_left && xp[4]<image_right && yp[4]>=image_top && yp[4]<image_bottom;
        assign in_frame=xp[4]>=frame_left && xp[4]<frame_right && yp[4]>=frame_top && yp[4]<frame_bottom;
        assign in_glow=xp[4]>=glow_left && xp[4]<glow_right && yp[4]>=glow_top && yp[4]<glow_bottom;
    end endgenerate
    wire [23:0] ambient_base=in_picture ? picture_rgb : 24'h081014;
    wire frame_line=in_frame && !in_picture;
    wire frame_glow=in_glow && !in_frame;
    wire [1:0] ambient_alpha=visual_hit ? (music_ink==1 ? 2'd1 : 2'd2) :
        frame_line ? 2'd2 : 2'd0;
    // 1/2 main ink, 1/4 antialias, 1/8 outer glow. Identical tint and
    // 1/2 opacity are also used by both side spectra.
    function [7:0] ambient_mix;
        input [7:0] bg,fg;input [1:0] alpha;
        reg [10:0] total;
        begin
            case(alpha)
                2:total=({3'd0,bg}+fg)<<2;
                1:total=({3'd0,bg}<<2)+({3'd0,bg}<<1)+({3'd0,fg}<<1);
                default:total=({3'd0,bg}<<3)-bg+fg;
            endcase
            ambient_mix=total[10:3];
        end
    endfunction
    wire [23:0] ambient_ink={ambient_mix(ambient_base[23:16],ambient_color[23:16],ambient_alpha),
        ambient_mix(ambient_base[15:8],ambient_color[15:8],ambient_alpha),
        ambient_mix(ambient_base[7:0],ambient_color[7:0],ambient_alpha)};
    wire [23:0] ambient_rgb=!modes[1] && (visual_hit || frame_line || frame_glow) ? ambient_ink : ambient_base;

    function [34:0] glyph;
        input [7:0] c;
        begin
            case(c)
                "0":glyph=35'b01110_10001_10011_10101_11001_10001_01110;
                "1":glyph=35'b00100_01100_00100_00100_00100_00100_01110;
                "2":glyph=35'b01110_10001_00001_00010_00100_01000_11111;
                "3":glyph=35'b11110_00001_00001_01110_00001_00001_11110;
                "4":glyph=35'b00010_00110_01010_10010_11111_00010_00010;
                "5":glyph=35'b11111_10000_10000_11110_00001_00001_11110;
                "6":glyph=35'b01110_10000_10000_11110_10001_10001_01110;
                "7":glyph=35'b11111_00001_00010_00100_01000_01000_01000;
                "8":glyph=35'b01110_10001_10001_01110_10001_10001_01110;
                "9":glyph=35'b01110_10001_10001_01111_00001_00001_01110;
                "A":glyph=35'b01110_10001_10001_11111_10001_10001_10001;
                "B":glyph=35'b11110_10001_10001_11110_10001_10001_11110;
                "C":glyph=35'b01111_10000_10000_10000_10000_10000_01111;
                "D":glyph=35'b11110_10001_10001_10001_10001_10001_11110;
                "E":glyph=35'b11111_10000_10000_11110_10000_10000_11111;
                "F":glyph=35'b11111_10000_10000_11110_10000_10000_10000;
                "G":glyph=35'b01110_10001_10000_10111_10001_10001_01110;
                "H":glyph=35'b10001_10001_10001_11111_10001_10001_10001;
                "I":glyph=35'b01110_00100_00100_00100_00100_00100_01110;
                "K":glyph=35'b10001_10010_10100_11000_10100_10010_10001;
                "L":glyph=35'b10000_10000_10000_10000_10000_10000_11111;
                "M":glyph=35'b10001_11011_10101_10101_10001_10001_10001;
                "N":glyph=35'b10001_11001_11001_10101_10011_10011_10001;
                "O":glyph=35'b01110_10001_10001_10001_10001_10001_01110;
                "P":glyph=35'b11110_10001_10001_11110_10000_10000_10000;
                "R":glyph=35'b11110_10001_10001_11110_10100_10010_10001;
                "S":glyph=35'b01111_10000_10000_01110_00001_00001_11110;
                "T":glyph=35'b11111_00100_00100_00100_00100_00100_00100;
                "U":glyph=35'b10001_10001_10001_10001_10001_10001_01110;
                "V":glyph=35'b10001_10001_10001_10001_10001_01010_00100;
                "W":glyph=35'b10001_10001_10001_10101_10101_10101_01010;
                "X":glyph=35'b10001_10001_01010_00100_01010_10001_10001;
                "Y":glyph=35'b10001_10001_01010_00100_00100_00100_00100;
                ":":glyph=35'b00000_00100_00100_00000_00100_00100_00000;
                "+":glyph=35'b00000_00100_00100_11111_00100_00100_00000;
                "-":glyph=35'b00000_00000_00000_11111_00000_00000_00000;
                "/":glyph=35'b00001_00010_00010_00100_01000_01000_10000;
                default:glyph=0;
            endcase
        end
    endfunction
    function [7:0] hexchar;
        input [3:0] n;
        begin hexchar=n<10 ? "0"+n : "A"+n-10;end
    endfunction
    function [7:0] banner;
        input [5:0] n;
        reg [511:0] text;
        begin
            text="ANLOGIC FPGA LAB EX6  TF BMP + HDMI AUDIO  48K PCM                 ";
            banner=text[511-n*8 -: 8];
        end
    endfunction
    reg [7:0] character;
    // 顶栏和侧栏共用一个固定字格选择器，避免复制宽高动态位选逻辑。
    function [7:0] resolution_char;
        input [3:0] position;
        begin
            case(position)
                0:resolution_char="S";1:resolution_char="R";2:resolution_char="C";
                4:resolution_char=source_resolution[39:36]==0 ? " " : {4'h3,source_resolution[39:36]};
                5:resolution_char=source_resolution[39:32]==0 ? " " : {4'h3,source_resolution[35:32]};
                6:resolution_char=source_resolution[39:28]==0 ? " " : {4'h3,source_resolution[31:28]};
                7:resolution_char=source_resolution[39:24]==0 ? " " : {4'h3,source_resolution[27:24]};
                8:resolution_char={4'h3,source_resolution[23:20]};
                9:resolution_char="X";
                10:resolution_char=source_resolution[19:16]==0 ? " " : {4'h3,source_resolution[19:16]};
                11:resolution_char=source_resolution[19:12]==0 ? " " : {4'h3,source_resolution[15:12]};
                12:resolution_char=source_resolution[19:8]==0 ? " " : {4'h3,source_resolution[11:8]};
                13:resolution_char=source_resolution[19:4]==0 ? " " : {4'h3,source_resolution[7:4]};
                14:resolution_char={4'h3,source_resolution[3:0]};
                default:resolution_char=" ";
            endcase
            if(!image_valid && (position>=4 && position<=8 || position>=10 && position<=14)) resolution_char="-";
        end
    endfunction
    reg source_text;
    reg [3:0] resolution_index;
    reg [34:0] dots;
    reg [9:0] text_x;
    reg [3:0] text_y;
    reg text_area;
    reg [23:0] text_color;
    wire [7:0] bright_abs=brightness[8] ? -brightness : brightness;
    wire [11:0] bright_digits,contrast_digits;
    // 慢速参数共用减法转十进制，不在每个像素路径中复制 /10 和 /100。
    player_parameter_digits parameter_digits(.clk(clk),.rst(rst),.brightness(bright_abs),
        .contrast(contrast),.bright_digits(bright_digits),.contrast_digits(contrast_digits));
    reg [6:0] status_index;
    wire [9:0] panel_x=xp[4]-10'd8;
    wire [8:0] panel_y=yp[4]-9'd40;
    // Editing always exposes the selected field and all values, even with SW1 up.
    wire panel_active=UI_ENABLE!=0 && (ui_status || modes[3]) && !ui_alarm && !ui_directory;
    wire alarm_active=UI_ENABLE!=0 && ui_alarm;
    wire top_bar=UI_ENABLE!=0 && !modes[0] && !ui_alarm && !ui_directory && yp[4]<24;
    wire panel_text=panel_active && xp[4]>=8 && xp[4]<136 && yp[4]>=40 && yp[4]<120;
    wire resolution_text=UI_ENABLE!=0 ? panel_active && yp[4]>=136 && yp[4]<152 && xp[4]>=8 && xp[4]<128 :
        yp[4]>=40 && yp[4]<56 && xp[4]<96;
    localparam [8*34-1:0] PREVIEW_HINT="RED FAILED: REENTER PREVIEW TO RETRY";
    wire preview_hint=UI_ENABLE!=0 && ui_browse && !ui_alarm && !ui_directory &&
                      yp[4]>=400 && yp[4]<416 && xp[4]>=144 && xp[4]<416;
    wire status_cover;
    wire [23:0] status_color;
    generate if(UI_ENABLE!=0) begin:chinese_osd
        player_status_osd #(.PANEL_ALPHA_ENABLE(PANEL_ALPHA_ENABLE),.MODE_576(MODE_576)) status(.clk(clk),.rst(rst),.x(x),.y(y),
            .brightness(brightness),.bright_digits(bright_digits),.contrast_digits(contrast_digits),
            .picture(picture),.scaled(scaled),.auto_play(auto_play),.run_mode(run_mode),
            .error_code(error_code),.audio_status(audio_status),.state_code(state_code),
            .volume(volume),.interval_seconds(interval_seconds),.menu(menu),.modes(modes),.transition_mode(transition_mode),.audio_select(audio_select),
            .directory(ui_directory),.status_panel(ui_status),.alarm(ui_alarm),.browse(ui_browse),
            .image_valid(image_valid),.source_resolution(source_resolution),.debug_status(debug_status),
            .time_digits({sht,shu,smt,smu,sst,ssu}),.cover_on(status_cover),.color(status_color),
            .background_rgb(picture_rgb3));
    end else begin:no_chinese_osd
        assign status_cover=1'b0;assign status_color=24'd0;
    end endgenerate
    always @* begin
        out_rgb=alarm_active ? 24'd0 : picture_rgb;
        status_index=xp[4][9:3];
        if(UI_ENABLE!=0) begin
            // 每行从完整字段开始，不把错误码、地址和计时值拆到两行。
            case(panel_y[6:4])
                0:status_index={3'd0,panel_x[6:3]};
                1:status_index=panel_x[6:3]<13 ? 7'd17+panel_x[6:3] : 7'd127;
                2:status_index=7'd31+panel_x[6:3];
                3:status_index=panel_x[6:3]<14 ? 7'd48+panel_x[6:3] : 7'd127;
                4:status_index=panel_x[6:3]<13 ? 7'd63+panel_x[6:3] : 7'd127;
                default:status_index=127;
            endcase
        end
        text_area=0;text_x=0;text_y=0;character=" ";dots=0;
        text_color=error_code!=0 ? 24'hff7070 : 24'hf0f8ff;
        source_text=0;resolution_index=0;
        if(!modes[1] && visual_hit) out_rgb=alarm_active ? alarm_wave_color : visual_color;
        if(top_bar) out_rgb=yp[4]==23 ? 24'h404848 : UI_BACKGROUND;
        if(panel_active && xp[4]<144 && yp[4]>=32 && yp[4]<168) begin
            out_rgb=UI_BACKGROUND;
            if(xp[4]<2 || xp[4]>=142 || yp[4]<34 || yp[4]>=166) out_rgb=24'h40c8c0;
        end
        if(!alarm_active && !(UI_ENABLE!=0 && ui_directory) && (!modes[0] || panel_active)) begin
            if(top_bar) begin
                // 24px 灰底、上下 4px 留白；字段固定对齐，模式使用现有 ASCII 字库。
                text_area=yp[4]>=4 && yp[4]<20;text_x=xp[4];text_y=yp[4]-9'd4;
                text_color=24'hffffff;
                if(xp[4]<16 || (xp[4]>=104 && xp[4]<112) ||
                   (xp[4]>=200 && xp[4]<232) || (xp[4]>=512 && xp[4]<536)) text_color=24'hc0c8c8;
                case(xp[4][9:3])
                    1:character="B";2:character=brightness[8] ? "-" : "+";
                    3:character="0"+bright_digits[11:8];
                    4:character="0"+bright_digits[7:4];5:character="0"+bright_digits[3:0];
                    13:character="C";14:character="0"+contrast_digits[11:8];
                    15:character="0"+contrast_digits[7:4];16:character="0"+contrast_digits[3:0];
                    25:character="P";26:character="L";27:character="A";28:character="Y";
                    30:character=run_mode==1 ? "M" : "A";
                    31:character=run_mode==1 ? "A" : "U";
                    32:character=run_mode==1 ? "N" : "T";
                    33:character=run_mode==1 ? " " : "O";
                    default:character=" ";
                endcase
                if(xp[4]>=512 && xp[4]<632) begin source_text=1;resolution_index=xp[4][6:3];end
            end else if(UI_ENABLE==0 && yp[4]<16) begin
                text_area=1;text_x={1'b0,(xp[4][8:0]+scroll)};text_y=yp[4][3:0];
                character=banner(text_x[8:3]);
            end else if((UI_ENABLE==0 && yp[4]>=20 && yp[4]<36) || panel_text) begin
                text_area=1;text_x=xp[4];text_y=yp[4]-20;
                if(UI_ENABLE!=0) begin text_x=panel_x;text_y=panel_y[3:0];end
                case(status_index)
                    0:character="P";1:character="I";2:character="C";4:character="1"+picture;
                    6:character="S";7:character=scaled ? "1" : "0";
                    9:character="A";10:character=auto_play ? "1" : "0";
                    // 三位亮度完整放入状态框第一行，不覆盖下一行对比度。
                    11:character="B";12:character=brightness[8] ? "-" : "+";
                    13:character="0"+bright_digits[11:8];
                    14:character="0"+bright_digits[7:4];15:character="0"+bright_digits[3:0];
                    17:character="C";18:character="0"+contrast_digits[11:8];
                    19:character="0"+contrast_digits[7:4];20:character="0"+contrast_digits[3:0];
                    22:character="V";23:character="0"+volume;
                    25:character="T";26:character="0"+interval_seconds;
                    28:character="M";29:case(menu) 0:character="B";1:character="C";2:character="V";3:character="T";endcase
                    31:character="E";32:character=hexchar(error_code[7:4]);33:character=hexchar(error_code[3:0]);
                    35:character="S";36:character=hexchar(state_code);
                    39:character="0"+sht;40:character="0"+shu;41:character=":";
                    42:character="0"+smt;43:character="0"+smu;44:character=":";
                    45:character="0"+sst;46:character="0"+ssu;
                    48:character="L";
                    49:character=hexchar(debug_status[59:56]);
                    50:character=hexchar(debug_status[55:52]);
                    51:character=hexchar(debug_status[51:48]);
                    52:character=hexchar(debug_status[47:44]);
                    53:character=hexchar(debug_status[43:40]);
                    54:character=hexchar(debug_status[39:36]);
                    55:character=hexchar(debug_status[35:32]);
                    56:character=hexchar(debug_status[31:28]);
                    58:character="N";
                    59:character=hexchar({2'b0,diagnostic_n[9:8]});
                    60:character=hexchar(diagnostic_n[7:4]);
                    61:character=hexchar(diagnostic_n[3:0]);
                    63:character="H";
                    64:character=hexchar(diagnostic_h[15:12]);
                    65:character=hexchar(diagnostic_h[11:8]);
                    66:character=hexchar(diagnostic_h[7:4]);
                    67:character=hexchar(diagnostic_h[3:0]);
                    69:character="R";
                    70:character=hexchar(diagnostic_r);
                    73:character="W";74:character=hexchar(audio_status[7:4]);
                    75:character=hexchar(audio_status[3:0]);
                    default:character=" ";
                endcase
            end else if(resolution_text) begin
                // Metadata belongs to the committed full-screen image, not a pending load.
                text_area=1;text_x=xp[4];text_y=yp[4]-40;
                if(UI_ENABLE!=0) begin text_y=yp[4]-136;text_x=panel_x;end
                case(text_x[9:3])
                    0:character="O";1:character="U";2:character="T";
                    4:character=!image_valid ? "-" : " ";
                    5:character=!image_valid ? "-" : "6";
                    6:character=!image_valid ? "-" : "4";
                    7:character=image_valid ? "0" : "-";
                    8:character="X";
                    9:character=!image_valid ? "-" : "4";
                    10:character=!image_valid ? "-" : "8";
                    11:character=image_valid ? "0" : "-";
                    default:character=" ";
                endcase
                if(UI_ENABLE!=0) begin source_text=1;resolution_index=panel_x[6:3];end
            end
        end
        if(preview_hint) begin
            text_area=1;text_x=xp[4]-144;text_y=yp[4]-400;
            character=PREVIEW_HINT >> ((33-text_x[9:3])*8);
        end
        if(source_text) character=resolution_char(resolution_index);
        dots=glyph(character);
        if(text_area) begin
            out_rgb={1'b0,faded[23:17],1'b0,faded[15:9],1'b0,faded[7:1]};
            if(UI_ENABLE!=0 && (panel_text || resolution_text || top_bar)) out_rgb=UI_BACKGROUND;
            if(text_x[2:0]<5 && text_y[3:1]<7 && dots[34-text_y[3:1]*5-text_x[2:0]])
                out_rgb=text_color;
        end
        // 正式工程使用提前五拍准备好的中文字层；旧 ASCII 仅供兼容测试入口。
        // 末级只剩像素覆盖选择，不再串联字符选择和字形位选。
        if(UI_ENABLE!=0) begin
            out_rgb=alarm_active ? 24'd0 : picture_rgb;
            if(!modes[1] && visual_hit) out_rgb=alarm_active ? alarm_wave_color : visual_color;
            if(ambient_layout) out_rgb=ambient_rgb;
            if(status_cover) out_rgb=status_color;
        end
        if(UI_ENABLE==0 && ambient_layout) out_rgb=ambient_rgb;
        if(!out_de) out_rgb=0;
    end
endmodule

// 空间遮罩只生成覆盖标记，五拍对齐主图，不增加帧缓存或DSP。
// level=0完整图片，level=32全黑；中间先遮住旧图，再反向展开新图。
module player_image_mask #(parameter integer MODE_576=0)(input clk,input rst,input [9:0] x,input [9:0] y,
    input active,input [2:0] style,input [5:0] level,output reg [4:0] mask_pipe);
    wire [10:0] horizontal=MODE_576 ? (level*45)>>1 : ({5'd0,level}<<4)+({5'd0,level}<<2);
    wire [9:0] curtain=MODE_576 ? (level*45)>>2 : ({4'd0,level}<<3)+({4'd0,level}<<1);
    localparam integer CX=MODE_576 ? 360 : 320, CY=MODE_576 ? 288 : 240;
    wire [9:0] distance=x<CX ? CX-1-x : x-CX;
    // Coordinate-only pseudo-random order: stable while paused and monotonic
    // across progress levels. Block mode uses one rank per 16x16 tile;
    // scatter mode uses one rank per pixel. Shift/add/XOR only, no DSP/RAM.
    function [4:0] dissolve_rank;
        input [9:0] px;
        input [9:0] py;
        reg [15:0] a,b,c;
        begin
            a={px[7:0],py[7:0]} ^ {py[3:0],px[9:0],py[8:7]} ^
                {15'd0,(MODE_576!=0 && py[9])} ^ 16'h9e37;
            b=a+(a<<3);b=b^(b>>7);
            c=b+(b<<5);c=c^(c>>9);
            dissolve_rank=c[4:0]^c[12:8];
        end
    endfunction
    wire [4:0] block_rank=dissolve_rank({4'd0,x[9:4]},{4'd0,y[9:4]});
    wire [4:0] scatter_rank=dissolve_rank(x,y);
    // Clockwise rotating shutter around the screen centre, 32 angular sectors.
    // Approximate tan(11.25/22.5/33.75 degrees) with 1/5, 2/5 and 2/3.
    wire right_half=x>=CX,bottom_half=y>=CY;
    wire [9:0] dx=right_half ? x-CX : CX-1-x;
    wire [9:0] dy=bottom_half ? y-CY : CY-1-y;
    wire vertical=dy>=dx;
    wire [12:0] major={3'd0,(vertical ? dy : dx)};
    wire [12:0] minor={3'd0,(vertical ? dx : dy)};
    wire [12:0] minor5=(minor<<2)+minor,minor3=(minor<<1)+minor;
    wire [1:0] sector=minor5<major ? 2'd0 : minor5<(major<<1) ? 2'd1 :
        minor3<(major<<1) ? 2'd2 : 2'd3;
    wire [4:0] sector_wide={3'd0,sector};
    reg [4:0] angle_rank;
    always @* begin
        case({bottom_half,right_half})
            2'b01:angle_rank=vertical ? sector_wide : 5'd7-sector_wide;
            2'b11:angle_rank=vertical ? 5'd15-sector_wide : 5'd8+sector_wide;
            2'b10:angle_rank=vertical ? 5'd16+sector_wide : 5'd23-sector_wide;
            default:angle_rank=vertical ? 5'd31-sector_wide : 5'd24+sector_wide;
        endcase
    end
    reg mask;
    always @* begin
        mask=0;
        if(active) case(style)
            1:mask={1'b0,x}<horizontal;
            2:mask=distance>=CX-curtain;
            3:mask={1'b0,y[5:0]}<{level,1'b0};
            4:mask={1'b0,block_rank}<level;
            5:mask={1'b0,angle_rank}<level;
            6:mask={1'b0,scatter_rank}<level;
            default:mask=0;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) mask_pipe<=0;else mask_pipe<={mask_pipe[3:0],mask};
    end
endmodule

// 真实波形：256 点 / 48 kHz = 5.33 ms；只平滑本次样本，不叠加历史画面。
// 双缓存完整采集后在消隐切换，约每三帧更新，旧两种显示算法保留。
module player_triggered_wave #(parameter integer IDLE_CYCLES=1250000,parameter integer MODE_576=0,parameter integer MODE_XGA=0)(
    input clk,input rst,input de,input frame_tick,input [9:0] x,input [9:0] y,
    input audio_valid,input signed [23:0] audio_sample,output reg [1:0] ink,
    input compact_layout
);
    reg signed [15:0] previous_pcm;
    // 两点均值轻滤波：仅一个加法器，不需要反馈乘法或跨帧平均。
    wire signed [16:0] sample_sum=$signed({audio_sample[23],audio_sample[23:8]})+
        $signed({previous_pcm[15],previous_pcm});
    reg signed [15:0] pcm;
    reg pcm_valid;
    reg [$clog2(IDLE_CYCLES+1)-1:0] idle_count;
    reg [13:0] points[0:511];
    reg capture_bank,display_bank,ready,valid,armed,capturing;
    reg [7:0] count;
    reg [8:0] trigger_wait;
    reg [1:0] hold_frames;
    reg [6:0] previous;
    // 仅显示放大 1.5 倍，不改 HDMI/FFT 音频；先扩位，再限幅，防止溢出折返。
    wire signed [17:0] pcm_wide={{2{pcm[15]}},pcm};
    wire signed [17:0] display_pcm=pcm_wide+(pcm_wide>>>1);
    wire signed [9:0] height=10'sd64-$signed({display_pcm[17],display_pcm[17:9]});
    wire [6:0] point=height<8 ? 7'd8 : height>120 ? 7'd120 : height[6:0];
    wire timeout_idle=idle_count>=IDLE_CYCLES-1 && !audio_valid;
    wire take=pcm_valid && !ready && hold_frames==0 &&
        (capturing || (armed && !pcm[15]) || trigger_wait==383);
    always @(posedge clk) if(!rst && !timeout_idle && take)
        points[{capture_bank,count}]<={count==0 ? point : previous,point};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            previous_pcm<=0;pcm<=0;pcm_valid<=0;idle_count<=0;
            capture_bank<=0;display_bank<=1;ready<=0;valid<=0;armed<=0;capturing<=0;
            count<=0;trigger_wait<=0;hold_frames<=0;previous<=64;
        end else begin
            pcm_valid<=audio_valid;
            if(audio_valid) begin previous_pcm<=audio_sample[23:8];pcm<=sample_sum[16:1];idle_count<=0;end
            else if(!timeout_idle) idle_count<=idle_count+1'b1;
            if(timeout_idle) begin
                previous_pcm<=0;pcm<=0;pcm_valid<=0;ready<=0;valid<=0;armed<=0;capturing<=0;
                count<=0;trigger_wait<=0;hold_frames<=0;
            end else if(frame_tick && !de && ready) begin
                display_bank<=capture_bank;capture_bank<=!capture_bank;valid<=1;ready<=0;
                count<=0;armed<=0;capturing<=0;trigger_wait<=0;hold_frames<=2;
            end else begin
                if(frame_tick && !de && hold_frames!=0) hold_frames<=hold_frames-1'b1;
                if(pcm_valid && !ready && hold_frames==0) begin
                    if(take) begin
                        capturing<=1;previous<=point;
                        if(count==255) ready<=1;else count<=count+1'b1;
                    end else begin
                        if(pcm< -16'sd256) armed<=1;
                        if(trigger_wait<383) trigger_wait<=trigger_wait+1'b1;
                    end
                end
            end
        end
    end
    // 256 点铺满 640 像素：相位每像素加 2、模 5，无坐标乘法或可变除法。
    reg [7:0] index;
    reg [2:0] phase,phase0;
    reg [13:0] pair0;
    reg last0;
    wire [7:0] next_index=index==255 ? 8'd255 : index+1'b1;
    wire [6:0] p0=last0 ? pair0[6:0] : pair0[13:7];
    wire [6:0] p1=pair0[6:0];
    reg [9:0] interpolated;
    wire [9:0] rounded=(interpolated+10'd2)/10'd5;
    reg [6:0] a2,b2;
    reg [9:0] xs[0:2];
    reg [9:0] ys[0:2];
    reg [2:0] ds;
    reg [1:0] ink3;
    wire [8:0] compact_a={1'b0,a2,1'b0}+{2'd0,a2};
    wire [8:0] compact_b={1'b0,b2,1'b0}+{2'd0,b2};
    wire [6:0] draw_a=compact_layout ? (MODE_576 ? {1'b0,compact_a[8:3]} : {2'd0,a2[6:2]}) : a2;
    wire [6:0] draw_b=compact_layout ? (MODE_576 ? {1'b0,compact_b[8:3]} : {2'd0,b2[6:2]}) : b2;
    wire [6:0] lo=draw_a<draw_b ? draw_a : draw_b,hi=draw_a>draw_b ? draw_a : draw_b;
    wire [9:0] row=ys[2]-(compact_layout ? (MODE_576 ? 10'd522 : 10'd446) : (MODE_576 ? 10'd264 : 10'd216));
    wire wave_region=MODE_576 ? (compact_layout ? xs[2]>=40 && xs[2]<680 && ys[2]>=520 && ys[2]<574 :
        xs[2]>=48 && xs[2]<672 && ys[2]>=264 && ys[2]<392) :
        (compact_layout ? xs[2]>=40 && xs[2]<600 && ys[2]>=448 && ys[2]<478 :
        xs[2]>=8 && xs[2]<632 && ys[2]>=216 && ys[2]<344);
    integer j;
    always @(posedge clk) pair0<=points[{display_bank,next_index}];
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            index<=0;phase<=0;phase0<=0;last0<=0;interpolated<=320;
            a2<=64;b2<=64;ds<=0;ink3<=0;ink<=0;
            for(j=0;j<3;j=j+1) begin xs[j]<=0;ys[j]<=0;end
        end else begin
            if(!de || (MODE_576 && x<40)) begin index<=0;phase<=0;end
            else if(MODE_XGA) begin
                if(phase==3) begin phase<=0;if(index!=255) index<=index+1'b1;end
                else phase<=phase+1'b1;
            end else if(phase>=3) begin phase<=phase-3;if(index!=255) index<=index+1'b1;end
            else phase<=phase+2;
            phase0<=MODE_XGA ? (phase==0 ? 0 : phase==1 ? 1 : phase==2 ? 3 : 4) : phase;last0<=index==255;
            xs[0]<=x;ys[0]<=y;ds<={ds[1:0],de};
            for(j=1;j<3;j=j+1) begin xs[j]<=xs[j-1];ys[j]<=ys[j-1];end
            case(phase0)
                0:interpolated<=({3'd0,p0}<<2)+p0;
                1:interpolated<=({3'd0,p0}<<2)+p1;
                2:interpolated<=({3'd0,p0}<<1)+p0+({3'd0,p1}<<1);
                3:interpolated<=({3'd0,p0}<<1)+({3'd0,p1}<<1)+p1;
                default:interpolated<=p0+({3'd0,p1}<<2);
            endcase
            a2<=rounded[6:0];b2<=a2;ink3<=0;
            if(valid && ds[2] && wave_region) begin
                if(row>=lo && row<=hi) ink3<=2;
                else if(row+9'd1==lo || row=={2'd0,hi}+9'd1) ink3<=1;
            end
            ink<=ink3;
        end
    end
endmodule

// 音乐播放器显示支路：帧峰值 -> 快升慢降包络 -> 二次平滑 -> 环形历史。
// 128 点约覆盖 2.1 秒；只在消隐更新一个点，绝不混合或回写旧视频帧。
// 使用移位、加减和小 RAM，不占用音频/FFT 数据通道或新增乘法器。
module player_music_envelope(
    input clk,input rst,input de,input frame_tick,input [9:0] x,input [9:0] y,
    input audio_valid,input signed [23:0] audio_sample,output reg [1:0] ink
);
    wire [15:0] pcm=audio_sample[23:8];
    // 无符号绝对值可正确表示 -32768，不能用有符号 16 位保存。
    wire [15:0] magnitude=pcm[15] ? (~pcm+16'd1) : pcm;
    reg [15:0] frame_peak;
    wire [15:0] peak_now=audio_valid && magnitude>frame_peak ? magnitude : frame_peak;
    wire [5:0] target_height=peak_now>=16'd14336 ? 6'd56 : peak_now[13:8];
    wire [11:0] target={target_height,6'd0};
    reg [11:0] envelope,shape;
    wire [11:0] rise=target-envelope;
    wire [11:0] fall=envelope-target;
    // Q6 小数避免小音量卡在量化台阶；下降取整可最终回到零。
    wire [11:0] envelope_next=target>envelope ? envelope+((rise+12'd1)>>1) :
        envelope-((fall+12'd7)>>3);
    wire [11:0] shape_rise=envelope_next-shape;
    wire [11:0] shape_fall=shape-envelope_next;
    wire [11:0] shape_next=envelope_next>shape ? shape+((shape_rise+12'd1)>>1) :
        shape-((shape_fall+12'd1)>>1);
    wire [11:0] rounded_shape=shape_next+12'd32;
    wire [5:0] new_height=rounded_shape[11:6];
    reg [5:0] previous_height;
    reg [6:0] head;
    reg [7:0] history_count;
    reg [11:0] history[0:127];
    wire commit=frame_tick && !de;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            frame_peak<=0;envelope<=0;shape<=0;previous_height<=0;head<=0;history_count<=0;
        end else begin
            if(commit) begin
                frame_peak<=0;envelope<=envelope_next;shape<=shape_next;
                previous_height<=new_height;head<=head+1'b1;
                if(history_count!=128) history_count<=history_count+1'b1;
            end else frame_peak<=peak_now;
        end
    end
    // 不复位 RAM；读取侧对尚未写入的历史显式补零，复位后没有随机线条。
    always @(posedge clk) if(!rst && commit) history[head]<={previous_height,new_height};

    reg [6:0] read_index;
    reg [2:0] phase,phase0;
    wire [6:0] next_index=read_index==127 ? 7'd127 : read_index+7'd1;
    wire [6:0] read_address=head+next_index;
    wire [7:0] oldest_valid=8'd128-history_count;
    reg [11:0] pair0;
    reg current_valid0,next_valid0,last0;
    wire [5:0] point0=current_valid0 ? (last0 ? pair0[5:0] : pair0[11:6]) : 6'd0;
    wire [5:0] point1=next_valid0 ? pair0[5:0] : 6'd0;
    reg [9:0] xs[0:2];
    reg [9:0] ys[0:2];
    reg [2:0] active;
    reg [8:0] a1,b1;
    wire [8:0] rounded_a=(a1+9'd2)/9'd5;
    wire [8:0] rounded_b=(b1+9'd2)/9'd5;
    reg [5:0] a2,b2;
    wire [5:0] low2=a2<b2 ? a2 : b2;
    wire [5:0] high2=a2>b2 ? a2 : b2;
    wire [8:0] distance2=ys[2]>=280 ? ys[2]-9'd280 : 9'd280-ys[2];
    reg [1:0] ink3;
    integer k;
    always @(posedge clk) pair0<=history[read_address];
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            read_index<=0;phase<=0;phase0<=0;current_valid0<=0;next_valid0<=0;last0<=0;
            a1<=0;b1<=0;a2<=0;b2<=0;ink3<=0;ink<=0;active<=0;
            for(k=0;k<3;k=k+1) begin xs[k]<=0;ys[k]<=0;end
        end else begin
            if(!de) begin read_index<=0;phase<=0;end
            else if(phase==4) begin phase<=0;if(read_index!=127) read_index<=read_index+1'b1;end
            else phase<=phase+1'b1;
            phase0<=phase;last0<=read_index==127;
            current_valid0<={1'b0,read_index}>=oldest_valid;
            next_valid0<={1'b0,next_index}>=oldest_valid;
            xs[0]<=x;ys[0]<=y;active<={active[1:0],de};
            for(k=1;k<3;k=k+1) begin xs[k]<=xs[k-1];ys[k]<=ys[k-1];end
            // 五像素线性连接；运算分拍，保持既有五拍 RGB/同步延迟。
            case(phase0)
                0:begin a1<=({3'd0,point0}<<2)+point0;b1<=({3'd0,point0}<<2)+point1;end
                1:begin a1<=({3'd0,point0}<<2)+point1;b1<=({3'd0,point0}<<1)+point0+({3'd0,point1}<<1);end
                2:begin a1<=({3'd0,point0}<<1)+point0+({3'd0,point1}<<1);b1<=({3'd0,point0}<<1)+({3'd0,point1}<<1)+point1;end
                3:begin a1<=({3'd0,point0}<<1)+({3'd0,point1}<<1)+point1;b1<=point0+({3'd0,point1}<<2);end
                default:begin a1<=point0+({3'd0,point1}<<2);b1<=({3'd0,point1}<<2)+point1;end
            endcase
            a2<=rounded_a[5:0];b2<=rounded_b[5:0];
            ink3<=0;
            if(active[2] && xs[2]>=8 && xs[2]<632 && ys[2]>=216 && ys[2]<344) begin
                if(distance2>=low2 && distance2<={3'd0,high2}+9'd1) ink3<=2;
                else if(distance2+9'd1>=low2 && distance2<={3'd0,high2}+9'd2) ink3<=1;
            end
            ink<=ink3;
        end
    end
endmodule

// 两个慢变参数轮流换算，每个字段在换算结束时整体发布，最迟 30 拍稳定。
module player_parameter_digits(input clk,input rst,input [7:0] brightness,input [8:0] contrast,
    output reg [11:0] bright_digits,output reg [11:0] contrast_digits);
    reg field,load;
    reg [8:0] remaining;
    reg [3:0] hundreds,tens;
    always @(posedge clk or posedge rst) begin
        if(rst) begin field<=0;load<=1;remaining<=0;hundreds<=0;tens<=0;bright_digits<=0;contrast_digits<=12'h128;end
        else if(load) begin
            remaining<=field ? contrast : {1'b0,brightness};hundreds<=0;tens<=0;load<=0;
        end else if(remaining>=100) begin remaining<=remaining-9'd100;hundreds<=hundreds+1'b1;end
        else if(remaining>=10) begin remaining<=remaining-9'd10;tens<=tens+1'b1;end
        else begin
            if(field) contrast_digits<={hundreds,tens,remaining[3:0]};
            else bright_digits<={hundreds,tens,remaining[3:0]};
            field<=!field;load<=1;
        end
    end
endmodule

// XGA consumer uses the fourth and fifth mask taps. Compute the same mask
// across the otherwise idle delay stages, retaining those exact pixel clocks.
module player_image_mask_pipeline #(parameter integer MODE_576=0)(
    input clk,input rst,input [9:0] x,y,input active,input [2:0] style,
    input [5:0] level,output reg tap3,tap4);
    localparam integer CX=MODE_576 ? 360 : 320,CY=MODE_576 ? 288 : 240;
    wire [10:0] horizontal=MODE_576 ? (level*45)>>1 : ({5'd0,level}<<4)+({5'd0,level}<<2);
    wire [9:0] curtain=MODE_576 ? (level*45)>>2 : ({4'd0,level}<<3)+({4'd0,level}<<1);
    wire [9:0] distance=x<CX ? CX-1-x : x-CX;
    reg simple;
    always @* begin
        case(style)
            1:simple={1'b0,x}<horizontal;
            2:simple=distance>=CX-curtain;
            3:simple={1'b0,y[5:0]}<{level,1'b0};
            default:simple=0;
        endcase
    end
    function [15:0] rank_first;
        input [9:0] px,py;
        reg [15:0] a,b;
        begin
            a={px[7:0],py[7:0]} ^ {py[3:0],px[9:0],py[8:7]} ^
                {15'd0,(MODE_576!=0 && py[9])} ^ 16'h9e37;
            b=a+(a<<3);
            rank_first=b^(b>>7);
        end
    endfunction
    function [4:0] rank_last;
        input [15:0] b;
        reg [15:0] c;
        begin
            c=b+(b<<5);c=c^(c>>9);
            rank_last=c[4:0]^c[12:8];
        end
    endfunction
    reg [9:0] dx1,dy1;
    reg [1:0] quadrant1,quadrant2;
    reg [15:0] block1,scatter1;
    reg [4:0] block2,scatter2;
    reg [12:0] major2,minor5_2,minor3_2;
    reg vertical2;
    reg active1,active2,simple1,simple2;
    reg [2:0] style1,style2;
    reg [5:0] level1,level2;
    wire vertical1=dy1>=dx1;
    wire [12:0] minor1={3'd0,(vertical1 ? dx1 : dy1)};
    wire [1:0] sector2=minor5_2<major2 ? 2'd0 : minor5_2<(major2<<1) ? 2'd1 :
        minor3_2<(major2<<1) ? 2'd2 : 2'd3;
    reg [4:0] angle2;
    always @* begin
        case(quadrant2)
            2'b01:angle2=vertical2 ? {3'b000,sector2} : {3'b001,~sector2};
            2'b11:angle2=vertical2 ? {3'b011,~sector2} : {3'b010,sector2};
            2'b10:angle2=vertical2 ? {3'b100,sector2} : {3'b101,~sector2};
            default:angle2=vertical2 ? {3'b111,~sector2} : {3'b110,sector2};
        endcase
    end
    reg mask2,mask3;
    always @* begin
        mask2=0;
        if(active2) case(style2)
            1,2,3:mask2=simple2;
            4:mask2={1'b0,block2}<level2;
            5:mask2={1'b0,angle2}<level2;
            6:mask2={1'b0,scatter2}<level2;
            default:mask2=0;
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            dx1<=0;dy1<=0;quadrant1<=0;quadrant2<=0;
            block1<=0;scatter1<=0;block2<=0;scatter2<=0;
            major2<=0;minor5_2<=0;minor3_2<=0;vertical2<=0;
            active1<=0;active2<=0;simple1<=0;simple2<=0;
            style1<=0;style2<=0;level1<=0;level2<=0;
            mask3<=0;tap3<=0;tap4<=0;
        end else begin
            dx1<=x>=CX ? x-CX : CX-1-x;
            dy1<=y>=CY ? y-CY : CY-1-y;
            quadrant1<={y>=CY,x>=CX};
            block1<=rank_first({4'd0,x[9:4]},{4'd0,y[9:4]});
            scatter1<=rank_first(x,y);
            active1<=active;style1<=style;level1<=level;simple1<=simple;
            major2<={3'd0,(vertical1 ? dy1 : dx1)};
            minor5_2<=(minor1<<2)+minor1;minor3_2<=(minor1<<1)+minor1;
            vertical2<=vertical1;quadrant2<=quadrant1;
            block2<=rank_last(block1);scatter2<=rank_last(scatter1);
            active2<=active1;style2<=style1;level2<=level1;simple2<=simple1;
            mask3<=mask2;tap3<=mask3;tap4<=tap3;
        end
    end
endmodule
