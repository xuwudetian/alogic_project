`timescale 1ns/1ps
// 中文状态层与五拍 RGB 流水对齐：字格选择、同步字库、位选、对齐。
// 固定 8 像素字格；汉字占两格，不在像素输出末端做大字模动态选择。
module player_status_osd #(parameter integer PANEL_ALPHA_ENABLE=0,MODE_576=0)(
    input clk,input rst,input [9:0] x,input [9:0] y,
    input signed [8:0] brightness,input [11:0] bright_digits,contrast_digits,
    input [3:0] picture,input scaled,input auto_play,input [1:0] run_mode,
    input [7:0] error_code,audio_status,input [3:0] state_code,volume,interval_seconds,
    input [2:0] menu,input [3:0] modes,input directory,status_panel,alarm,browse,image_valid,
    input [39:0] source_resolution,input [59:0] debug_status,
    input [23:0] time_digits,
    output cover_on,output [23:0] color,
    // 接收主图第3拍像素，在字层第4拍混合，输出延迟保持五拍。
    input [23:0] background_rgb,input [3:0] transition_mode,input [1:0] audio_select
);
    wire [9:0] ux=x-(MODE_576 ? 40 : 0);
    wire [9:0] uy=y-(MODE_576 ? 48 : 0);
    localparam [23:0] BG=24'h606060,FG=24'hffffff,LABEL=24'hdce2e2,
        ACCENT=24'hc0c8c8,SELECTED=24'ha5dfd9,VALUE=24'hffe080,
        SELECT_INK=24'h123f43;
    wire panel_active=(status_panel || modes[3]) && !directory && !alarm;
    wire top_active=!modes[0] && !directory && !alarm;
    // 640x480 中心面板：320x224，边界 [160,480) ux [128,352)。
    // 底边恰好在频谱上方；沿用五拍字库流水，不改 HDMI 时序。
    localparam [9:0] PANEL_LEFT=160,PANEL_RIGHT=480,TEXT_LEFT=184;
    localparam [8:0] PANEL_TOP=128,PANEL_BOTTOM=352,TEXT_TOP=144;
    wire [9:0] px=ux-TEXT_LEFT;
    reg [7:0] code;
    reg [3:0] column,row;
    reg text_on,cover0,blend0;
    reg [23:0] base,ink;
    reg [6:0] slot;
    reg [3:0] line;
    reg [8:0] row_offset;
    reg [3:0] resolution_position;
    reg resolution_on;
    // ASCII 直接减 32，汉字编号与 player_ui_font 的已生成表一致。
    function [7:0] digit;input [3:0] n;begin digit=n<10 ? 8'd16+n : 8'd33+n-10;end endfunction
    function [7:0] playback_glyph;input [1:0] position;begin
        if(run_mode==1) case(position)
            0:playback_glyph=0;1:playback_glyph=45;2:playback_glyph=33;3:playback_glyph=46;
        endcase
        else case(position)
            0:playback_glyph=33;1:playback_glyph=53;2:playback_glyph=52;3:playback_glyph=47;
        endcase
    end endfunction
    function [7:0] parameter_glyph;input [1:0] field;input second;begin
        case(field)
            0:parameter_glyph=second ? 97 : 96;
            1:parameter_glyph=second ? 99 : 98;
            2:parameter_glyph=second ? 112 : 111;
            default:parameter_glyph=second ? 114 : 113;
        endcase
    end endfunction
    // Fixed five-character value field, right aligned in slots 24..33.
    function [7:0] transition_glyph;input [3:0] mode;input [2:0] position;begin
        transition_glyph=0;
        case(mode)
            0:case(position) // 淡入淡出
                1:transition_glyph=8'd170;
                2:transition_glyph=8'd171;
                3:transition_glyph=8'd170;
                4:transition_glyph=8'd172;
                default:transition_glyph=0;
            endcase
            1:case(position) // 特效轮换
                1:transition_glyph=8'd173;
                2:transition_glyph=8'd174;
                3:transition_glyph=8'd175;
                4:transition_glyph=8'd149;
                default:transition_glyph=0;
            endcase
            2:case(position) // 向上滑动
                1:transition_glyph=8'd176;
                2:transition_glyph=8'd177;
                3:transition_glyph=8'd178;
                4:transition_glyph=8'd107;
                default:transition_glyph=0;
            endcase
            3:case(position) // 横向擦除
                1:transition_glyph=8'd179;
                2:transition_glyph=8'd176;
                3:transition_glyph=8'd180;
                4:transition_glyph=8'd181;
                default:transition_glyph=0;
            endcase
            4:case(position) // 对开帘
                2:transition_glyph=8'd98;
                3:transition_glyph=8'd122;
                4:transition_glyph=8'd182;
                default:transition_glyph=0;
            endcase
            5:case(position) // 水平百叶窗
                0:transition_glyph=8'd183;
                1:transition_glyph=8'd184;
                2:transition_glyph=8'd185;
                3:transition_glyph=8'd186;
                4:transition_glyph=8'd187;
                default:transition_glyph=0;
            endcase
            6:case(position) // 方块溶解
                1:transition_glyph=8'd169;
                2:transition_glyph=8'd188;
                3:transition_glyph=8'd189;
                4:transition_glyph=8'd190;
                default:transition_glyph=0;
            endcase
            7:case(position) // 旋转
                3:transition_glyph=8'd191;
                4:transition_glyph=8'd167;
                default:transition_glyph=0;
            endcase
            8:case(position) // 随机散点
                1:transition_glyph=8'd192;
                2:transition_glyph=8'd193;
                3:transition_glyph=8'd194;
                4:transition_glyph=8'd195;
                default:transition_glyph=0;
            endcase
            default:transition_glyph=0;
        endcase
    end endfunction
    always @* begin
        code=0;column={1'b0,ux[2:0]};row=0;text_on=0;cover0=0;blend0=0;
        base=BG;ink=FG;slot=ux[9:3];line=15;row_offset=0;resolution_on=0;resolution_position=0;
        // The header stays at the raster top; only the settings panel uses
        // centered 640x480 coordinates. Otherwise y=48..71 repeats the header.
        if(top_active && y<24) begin
            cover0=1;blend0=1;row=y-10'd4;text_on=y>=4 && y<20;
            if(MODE_576 && (x<40 || x>=680)) text_on=0;
            if(y==23) begin base=24'h404848;blend0=0;end
            // 原图分辨率标签占五个汉字；数值仍保留五位宽高，不改变缩放。
            case(slot)
                // 左侧只显示自动/手动，不重复参数或播放模式标签。
                1,2:code=run_mode==1 ? 106 : 108;
                3,4:code=107;
                53,54:code=102;55,56:code=103;57,58:code=159;
                59,60:code=160;61,62:code=161;
                default:code=0;
            endcase
            if(slot>=64 && slot<=74) begin resolution_on=1;resolution_position=slot-64;end
            if(slot>=53 && slot<=62) ink=LABEL;
            if(code>=96) column={~slot[0],ux[2:0]};
            // 两个汉字字段都从奇数字格开始。
        end else if(panel_active && ux>=PANEL_LEFT && ux<PANEL_RIGHT &&
                    uy>=PANEL_TOP && uy<PANEL_BOTTOM) begin
            cover0=1;blend0=1;slot=px[8:3];column={1'b0,px[2:0]};
            // 八行正文，每行20像素：16像素字高，上下各2像素留白。
            // 固定区间比较避免像素路径上引入除法器。
            if(uy>=174 && uy<334) begin
                if(uy<194) begin line=0;row_offset=uy-9'd176;end
                else if(uy<214) begin line=1;row_offset=uy-9'd196;end
                else if(uy<234) begin line=2;row_offset=uy-9'd216;end
                else if(uy<254) begin line=3;row_offset=uy-9'd236;end
                else if(uy<274) begin line=4;row_offset=uy-9'd256;end
                else if(uy<294) begin line=5;row_offset=uy-9'd276;end
                else if(uy<314) begin line=6;row_offset=uy-9'd296;end
                else begin line=7;row_offset=uy-9'd316;end
            end
            row=row_offset[3:0];
            text_on=ux>=TEXT_LEFT && ux<456 && line<8 && row_offset<16;
            if(ux==PANEL_LEFT || ux==PANEL_RIGHT-1 || uy==PANEL_TOP || uy==PANEL_BOTTOM-1) begin base=ACCENT;blend0=0;end
            if(uy==167 && ux>=176 && ux<464) begin base=ACCENT;blend0=0;end
            // 七个编辑项；末行合并图片序号与缩放，面板仍在频谱上方。
            if(modes[3] && line<7 && line==menu && ux>=176 && ux<464) base=SELECTED;
            ink=slot>=23 ? VALUE : FG;
            if(line==7) ink=((slot>=9 && slot<=11) || slot>=32) ? VALUE : FG;
            if(uy>=TEXT_TOP && uy<TEXT_TOP+16) begin
                row=uy-TEXT_TOP;text_on=ux>=TEXT_LEFT && ux<456;
                case(slot)
                    0,1:code=165;2,3:code=166;
                    default:code=0;
                endcase
            end else case(line)
                0,1,2,3:begin
                    if(slot<4) code=parameter_glyph(line,slot[1]);
                    if(line==1 && (slot==4 || slot==5)) code=97;
                    if(line==0) case(slot)
                        30:code=brightness[8] ? 13 : 11;31:code=digit(bright_digits[11:8]);
                        32:code=digit(bright_digits[7:4]);33:code=digit(bright_digits[3:0]);
                    endcase
                    if(line==1) case(slot)
                        31:code=digit(contrast_digits[11:8]);32:code=digit(contrast_digits[7:4]);33:code=digit(contrast_digits[3:0]);
                    endcase
                    if(line==2 && slot==33) code=digit(volume);
                    if(line==3 && slot==30) code=digit(interval_seconds);
                    if(line==3 && (slot==32 || slot==33)) code=115;
                end
                4:begin
                    case(slot)
                        0,1:code=8'd167;
                        2,3:code=8'd168;
                        4,5:code=8'd169;
                        6,7:code=8'd101;
                    endcase
                    if(slot>=24 && slot<=33) code=transition_glyph(transition_mode,(slot-24)>>1);
                end
                5:case(slot)
                    0,1:code=196;2,3:code=121;4,5:code=100;6,7:code=101;
                    30,31,32,33:code=playback_glyph(slot-30);
                endcase
                6:case(slot)
                    0,1:code=111;2,3:code=158; // 音频
                    // Explicit glyph choices also give old standalone benches
                    // with an unconnected new port the default "1/4" label.
                    31:case(audio_select)
                        1:code=18;2:code=19;3:code=20;default:code=17;
                    endcase
                    32:code=15;33:code=20;
                endcase
                7:case(slot)
                    0,1:code=103;2,3:code=162;4,5:code=163;6,7:code=164;
                    9:code=digit(picture+4'd1);10:code=15;11:code=25;
                    20,21:code=120;22,23:code=121;32,33:code=scaled ? 122 : 123;
                endcase
                default:code=0;
            endcase
            if(code>=96) column={slot[0],px[2:0]};
            if(base==SELECTED) ink=SELECT_INK;
            // 面板不再绘制原图分辨率或状态码；底层诊断与重试保持原有接口。
        end
        if(resolution_on) begin
            case(resolution_position)
                0:code=source_resolution[39:36]==0 ? 0 : digit(source_resolution[39:36]);
                1:code=source_resolution[39:32]==0 ? 0 : digit(source_resolution[35:32]);
                2:code=source_resolution[39:28]==0 ? 0 : digit(source_resolution[31:28]);
                3:code=source_resolution[39:24]==0 ? 0 : digit(source_resolution[27:24]);
                4:code=digit(source_resolution[23:20]);5:code=56;
                6:code=source_resolution[19:16]==0 ? 0 : digit(source_resolution[19:16]);
                7:code=source_resolution[19:12]==0 ? 0 : digit(source_resolution[15:12]);
                8:code=source_resolution[19:8]==0 ? 0 : digit(source_resolution[11:8]);
                9:code=source_resolution[19:4]==0 ? 0 : digit(source_resolution[7:4]);
                10:code=digit(source_resolution[3:0]);default:code=0;
            endcase
            if(!image_valid && resolution_position!=5) code=13;
        end
    end
    reg [7:0] code0;reg [3:0] row0,col0,col1;
    wire [15:0] font_row;
    reg [4:0] covers,texts,blends;reg [23:0] bases[0:4],inks[0:4];
    function [7:0] half_blend;input [7:0] a,b;reg [8:0] sum;begin
        sum={1'b0,a}+{1'b0,b};half_blend=sum[8:1];
    end endfunction
    reg hit2,hit3,hit4;integer i;
    player_ui_font font(.clk(clk),.code(code0),.y(row0),.row(font_row));
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            code0<=0;row0<=0;col0<=0;col1<=0;covers<=0;texts<=0;blends<=0;hit2<=0;hit3<=0;hit4<=0;
            for(i=0;i<5;i=i+1) begin bases[i]<=0;inks[i]<=0;end
        end else begin
            code0<=code;row0<=row;col0<=column;col1<=col0;
            covers<={covers[3:0],cover0};texts<={texts[3:0],text_on};blends<={blends[3:0],blend0};
            bases[0]<=base;inks[0]<=ink;
            for(i=1;i<5;i=i+1) begin bases[i]<=bases[i-1];inks[i]<=inks[i-1];end
            // 面板、选择行、顶栏背景各50%混合图片；字、分隔线和边框不透明。
            // 不混入波形/频谱，设置数值后面不会有跳动的音频线条。
            if(PANEL_ALPHA_ENABLE!=0 && blends[3]) bases[4]<=
                {half_blend(bases[3][23:16],background_rgb[23:16]),
                 half_blend(bases[3][15:8],background_rgb[15:8]),
                 half_blend(bases[3][7:0],background_rgb[7:0])};
            hit2<=texts[1] && font_row[15-col1];hit3<=hit2;hit4<=hit3;
        end
    end
    assign cover_on=covers[4];
    assign color=hit4 ? inks[4] : bases[4];
endmodule
