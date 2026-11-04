`timescale 1ns/1ps
// 目录和报警层：只覆盖像素，不读写 SDRAM。字形选择、位选择分两级流水。
module player_ui_overlay #(
    parameter integer MODE_576=0,
    parameter integer MODE_XGA=0,
    parameter integer LOGO_ENABLE=0,
    parameter integer NO_SIGNAL_ENABLE=0,
    parameter integer BOOT_ENABLE=0,
    // 25 MHz / (800*525): 209 frames = 3.5112 s, rounded up to a whole frame.
    parameter integer BOOT_FRAMES=209,
    parameter integer DIRECTORY_ANIMATION_ENABLE=0,
    parameter integer DIRECTORY_EXTERNAL_DIM=0,
    parameter integer SOUND_SCENE_ENABLE=0
)(
    input clk,input rst,input hs,input vs,input de,input [23:0] rgb,
    input directory,input [1:0] selection,input alarm,
    output reg out_hs,output reg out_vs,output reg out_de,output reg [23:0] out_rgb,
    input directory_run, // Reserved compatibility port; the second-level menu is removed.
    input no_signal,input boot_ready, // Compatibility input; startup duration is fixed.
    output directory_active, // Hold the picture until the last exit frame has cleared.
    output [2:0] background_dim, // 0=full, then 7/8, 3/4, 5/8 and 1/2 gain.
    input sound_alarm
);
    reg last_de,last_vs;
    reg [9:0] raster_x,raster_y,scroll;
    // Center the existing native-size text, icons and menus in the larger raster.
    wire [9:0] logical_x,logical_y;
    generate if(MODE_XGA) begin: registered_coordinates
        player_xga_logical_coordinates coordinates(.clk(clk),.rst(rst),.de(de),
            .frame_tick(last_vs && !vs),.row_tick(last_de && !de),
            .native_x_phase(raster_x[2:0]),.native_y_phase(raster_y[2:0]),.x(logical_x),.y(logical_y));
    end else begin assign logical_x=0;assign logical_y=0;end endgenerate
    wire [9:0] x=MODE_XGA ? logical_x : raster_x-(MODE_576 ? 40 : 0);
    wire [9:0] y=MODE_XGA ? logical_y : raster_y-(MODE_576 ? 48 : 0);
    wire content_pixel=MODE_576==0 ||
        (raster_x>=40 && raster_x<680 && raster_y>=48 && raster_y<528);
    reg [8:0] hint_scroll;
    reg hint_div;
    wire frame_tick=last_vs && !vs;
    wire sound_visible=SOUND_SCENE_ENABLE!=0 && alarm && sound_alarm;
    wire [23:0] sound_rgb;
    generate if(SOUND_SCENE_ENABLE!=0) begin:sound_scene
        player_sound_scene scene(.clk(clk),.rst(rst),.frame_tick(frame_tick),
            .enable(sound_visible),.x(x),.y(y),.rgb(sound_rgb));
    end else begin:no_sound_scene
        assign sound_rgb=24'hffffff;
    end endgenerate
    // 13 frames at 25 MHz/(800*525) = 218.4 ms. The quadratic lookup
    // decelerates on entry; walking backwards gives a continuous reverse exit.
    // Only a frame boundary may change the position, including rapid reversals.
    reg [3:0] directory_phase;
    reg [9:0] directory_offset;
    // Compute the animation offset at the frame commit. Registering the
    // same next-phase value removes the phase-ROM from every pixel's path.
    function [9:0] offset_for_phase;
        input [3:0] phase;
        begin case(phase)
            0:offset_for_phase=640; 1:offset_for_phase=545;
            2:offset_for_phase=458; 3:offset_for_phase=379;
            4:offset_for_phase=307; 5:offset_for_phase=242;
            6:offset_for_phase=186; 7:offset_for_phase=136;
            8:offset_for_phase=95; 9:offset_for_phase=61;
            10:offset_for_phase=34; 11:offset_for_phase=15;
            12:offset_for_phase=4; default:offset_for_phase=0;
        endcase end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            directory_phase<=0;
            directory_offset<=DIRECTORY_ANIMATION_ENABLE!=0 ? 640 : 0;
        end else if(frame_tick && DIRECTORY_ANIMATION_ENABLE!=0) begin
            if(alarm) begin
                directory_phase<=directory ? 4'd13 : 4'd0;
                directory_offset<=directory ? 0 : 640;
            end else if(directory && directory_phase<13) begin
                directory_phase<=directory_phase+1'b1;
                directory_offset<=offset_for_phase(directory_phase+1'b1);
            end else if(!directory && directory_phase!=0) begin
                directory_phase<=directory_phase-1'b1;
                directory_offset<=offset_for_phase(directory_phase-1'b1);
            end
        end
    end
    assign directory_active=directory || (DIRECTORY_ANIMATION_ENABLE!=0 && directory_phase!=0);
    wire directory_visible=DIRECTORY_ANIMATION_ENABLE!=0 ? directory_phase!=0 : directory;
    assign background_dim=DIRECTORY_ANIMATION_ENABLE!=0 && directory_visible && !alarm ?
        {1'b0,directory_phase[3:2]}+3'd1 : 3'd0;
    wire directory_settled=DIRECTORY_ANIMATION_ENABLE==0 || directory_phase==13;
    wire [9:0] directory_x=x-directory_offset;
    wire directory_pixel=directory_visible && content_pixel && x>=directory_offset;
    wire [8:0] hint_x=directory_x[8:0]+hint_scroll;
    function [7:0] dim_directory_background;
        input [7:0] channel;
        input [1:0] level;
        begin case(level)
            0:dim_directory_background=channel-(channel>>3);
            1:dim_directory_background=channel-(channel>>2);
            2:dim_directory_background=(channel>>1)+(channel>>3);
            default:dim_directory_background=channel>>1;
        endcase end
    endfunction
    wire [23:0] directory_background={
        dim_directory_background(rgb[23:16],directory_phase[3:2]),
        dim_directory_background(rgb[15:8],directory_phase[3:2]),
        dim_directory_background(rgb[7:0],directory_phase[3:2])};
    localparam integer BOOT_BITS=BOOT_FRAMES<128 ? 7 : $clog2(BOOT_FRAMES+1);
    reg [BOOT_BITS-1:0] boot_frames;
    reg boot_active;
    // 固定约3.5秒，在消隐边界退场；读卡就绪/错误/无卡不改变时长。
    // 后台继续加载；报警和用户目录优先，退场后热插拔不会重启加载页。
    wire boot_visible=BOOT_ENABLE!=0 && boot_active && !alarm && !directory_active;
    // Replace only the unavailable playback page. Startup, the menu and the
    // alarm keep their existing priority and timing; storage keeps remounting.
    wire no_signal_visible=NO_SIGNAL_ENABLE!=0 && no_signal &&
                           !boot_visible && !directory_active && !alarm;
    reg [2:0] no_signal_column;
    reg [23:0] no_signal_rgb;
    reg [7:0] rainbow_offset;
    wire [10:0] rainbow_level_wide={rainbow_offset,2'b00}+{3'd0,rainbow_offset};
    wire [7:0] rainbow_level=rainbow_level_wide[7:0];
    // x * 171 / 256 maps the 384-pixel grayscale strip to 0..255 using
    // constant shifts/adds, without a divider or another frame buffer.
    wire [9:0] pattern_x=MODE_576 ? (raster_x<40 ? 0 : raster_x>=680 ? 639 : x) : x;
    wire [9:0] pattern_y=MODE_576 ? (raster_y<48 ? 0 : raster_y>=528 ? 479 : y) : y;
    wire [16:0] gray_position={pattern_x,7'd0}+{2'd0,pattern_x,5'd0}+{4'd0,pattern_x,3'd0}+
                              {6'd0,pattern_x,1'b0}+{7'd0,pattern_x};
    wire [7:0] gray_level=8'd255-gray_position[15:8];
    always @* begin
        if(pattern_x<92) no_signal_column=0;
        else if(pattern_x<183) no_signal_column=1;
        else if(pattern_x<275) no_signal_column=2;
        else if(pattern_x<366) no_signal_column=3;
        else if(pattern_x<458) no_signal_column=4;
        else if(pattern_x<549) no_signal_column=5;
        else no_signal_column=6;
        rainbow_offset=0;no_signal_rgb=0;
        if(pattern_y<360) begin
            case(no_signal_column)
                0:no_signal_rgb=24'hffffff;
                1:no_signal_rgb=24'hffff00;
                2:no_signal_rgb=24'h00ffff;
                3:no_signal_rgb=24'h00ff00;
                4:no_signal_rgb=24'hff00ff;
                5:no_signal_rgb=24'hff0000;
                default:no_signal_rgb=24'h0000ff;
            endcase
        end else if(pattern_y<408) begin
            case(no_signal_column)
                0:no_signal_rgb=24'h0000ff;
                1:no_signal_rgb=24'hff00ff;
                2:no_signal_rgb=24'hffff00;
                3:no_signal_rgb=24'hff0000;
                4:no_signal_rgb=24'h00ffff;
                5:no_signal_rgb=24'h000000;
                default:no_signal_rgb=24'hffffff;
            endcase
        end else if(pattern_x<384) no_signal_rgb={gray_level,gray_level,gray_level};
        else if(pattern_x<435) begin rainbow_offset=pattern_x-384;no_signal_rgb={8'hff,rainbow_level,8'h00};end
        else if(pattern_x<486) begin rainbow_offset=pattern_x-435;no_signal_rgb={8'hff-rainbow_level,8'hff,8'h00};end
        else if(pattern_x<537) begin rainbow_offset=pattern_x-486;no_signal_rgb={8'h00,8'hff,rainbow_level};end
        else if(pattern_x<588) begin rainbow_offset=pattern_x-537;no_signal_rgb={8'h00,8'hff-rainbow_level,8'hff};end
        else begin rainbow_offset=pattern_x-588;no_signal_rgb={rainbow_level,8'h00,8'hff};end
    end
    wire [7:0] boot_bar_phase={boot_frames[6:0],1'b0};
    wire [7:0] boot_bar_delta=x[7:0]-8'd192-boot_bar_phase;
    // 连续ROM字格229..239组成整行标题；FP/GA各合成一个16x16字格。
    // x=144起，round(x/32)=5..15，仅需4位加法，省去逐字符译码。
    wire [3:0] boot_title_slot=x[8:5]+{3'd0,x[4]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin boot_frames<=0;boot_active<=BOOT_ENABLE!=0;end
        else if(frame_tick && boot_active) begin
            if(alarm || directory || boot_frames>=BOOT_FRAMES-1) boot_active<=0;
            else boot_frames<=boot_frames+1'b1;
        end
    end
    // 64 帧一个明暗周期，约 1.08 秒；帧边界更新，避免行内闪变。
    reg [5:0] alarm_phase;
    wire [4:0] alarm_pulse=alarm_phase[5] ? ~alarm_phase[4:0] : alarm_phase[4:0];
    wire [23:0] alarm_background={{1'b0,alarm_pulse,2'b00},16'd0};
    wire [23:0] alarm_ink={{2'b11,alarm_pulse,1'b1},{3'b000,alarm_pulse},{3'b000,alarm_pulse}};
    wire [23:0] alarm_edge={{2'b10,alarm_pulse,1'b0},8'd8,8'd8};
    wire logo_pixel;
    wire [23:0] logo_color;
    reg [23:0] logo_color1;
    reg logo1;
    generate if(LOGO_ENABLE!=0) begin:logo_layer
        player_logo_sprite sprite(.clk(clk),.rst(rst),.frame_tick(frame_tick),.x(x),.y(y[8:0]),
            .pixel_on(logo_pixel),.pixel_color(logo_color),.centered(boot_visible));
    end else begin:no_logo
        assign logo_pixel=1'b0;
        assign logo_color=24'd0;
    end endgenerate
    wire [9:0] rolling_x=x+scroll;
    wire [8:0] warning_y=y-9'd96;
    reg [7:0] glyph_id;
    reg [3:0] glyph_x,glyph_y;
    reg text_on;
    reg [23:0] base,text_color;
    reg [1:0] tile;
    reg [9:0] local_x;
    reg [8:0] local_y;
    wire [15:0] glyph_row;
    reg [3:0] bit_index;
    reg text1,h1,v1,d1;
    reg [23:0] base1,color1;
    // Keep the sound scene on its own first-stage register. Its geometry
    // must not pass through the menu/background priority mux before capture.
    // The final selection uses the same two pixel-clock latency as the font.
    reg sound1;
    reg [23:0] sound_color1;
    wire [4:0] stripe=x[4:0]+y[4:0];

    // 16x16 黑体字模：目、录、预、览、模、式、运、行、状、态。
    function [255:0] chinese;
        input [4:0] id;
        begin case(id)
            0:chinese=256'h3FF0201020103FF03FF0201020103FF02010201020103FF02010000000000000;
            1:chinese=256'h7FF000103FF000300030FFFC4310333813E00FC03360C31C0708040000000000;
            2:chinese=256'hFBFC0840504021F82108FD68256825482148214820C020B8630C020000000000;
            3:chinese=256'h488049FC49404B30481000003FE03420322037A035801984F1FC000000000000;
            4:chinese=256'h27FC21B0F80023F8220873F86A08EBF8A04027FC20A021902E0E000400000000;
            5:chinese=256'h01B00190FFFC0180008000807E8018C0184018401F64F834401C000000000000;
            6:chinese=256'h67F8200000000000FFFCF10031203210323837C83000780087FC000000000000;
            7:chinese=256'h23F86000C000980037FC20206020E020A02020202020202020E0204000000000;
            8:chinese=256'h18509858D84858401FFC18C038C078E0D8A099A019101B181E0C180000000000;
            9:chinese=256'h0200FFFC04800CC00C403630621C400001004918480CC8248FE0000000000000;
            10:chinese=256'h00004FC042404240F24042404240544064400840118000000000000000000000;
            11:chinese=256'h440044004B00F1004EC06A40CA405FE043004480D84000000000000000000000;
            12:chinese=256'h0200F7804900490047C0F54057C0554077C0594059C000000000000000000000;
            13:chinese=256'h4200620022000200C20042004500550069804880304000000000000000000000;
            14:chinese=256'h00004FC048000F80C8804E804B005180564068009FC000000000000000000000;
            15:chinese=256'h0000FFC080409E409240924092408C408040FFC0804000000000000000000000;
            16:chinese=256'h300c300c3030303030c030c03f003f0030c030c030303030300c300c00000000;
            17:chinese=256'h3ffc3ffc30003000300030003ff03ff030003000300030003ffc3ffc00000000;
            18:chinese=256'h300c300c300c300c0c300c3003c003c003c003c003c003c003c003c000000000;
            19:chinese=256'h0ff00ff0300c300c000c000c00f000f00f000f00300030003ffc3ffc00000000;
            20:chinese=256'h0ff00ff0300c300c000c000c03f003f0000c000c300c300c0ff00ff000000000;
            21:chinese=256'h0030003000f000f0033003300c300c30303030303ffc3ffc0030003000000000;
            // 手、动、自、切、换：二级目录沿用 16x16 字模和两级流水。
            22:chinese=256'h3f00010001003ff8010001000100fffe01000100010001000500020000000000;
            23:chinese=256'h7c40004001fc0044fe4420442044208448844484fd0445040228041000000000;
            24:chinese=256'h04001ff01010101010101ff0101010101ff01010101010101ff0101000000000;
            25:chinese=256'h11fc104410441e44f04410441044124414441884108401040228041000000000;
            26:chinese=256'h10f81108fa1015fc112419243124d12417fe1050105010885104260200000000;
            default:chinese=0;
        endcase end
    endfunction
    // 顶行循环字幕：道路千万条，安全第一条。行车不规范，亲人两行泪。
    // 沿用32个字格、原有速度与循环；句尾8个空格。
    function [7:0] hint_glyph;
        input [4:0] glyph_slot;
        begin case(glyph_slot)
            0:hint_glyph=217; // 道
            1:hint_glyph=218; // 路
            2:hint_glyph=219; // 千
            3:hint_glyph=220; // 万
            4:hint_glyph=221; // 条
            5:hint_glyph=222; // ，
            6:hint_glyph=223; // 安
            7:hint_glyph=240; // 全
            8:hint_glyph=241; // 第
            9:hint_glyph=242; // 一
            10:hint_glyph=221; // 条
            11:hint_glyph=243; // 。
            12:hint_glyph=147; // 行
            13:hint_glyph=244; // 车
            14:hint_glyph=245; // 不
            15:hint_glyph=246; // 规
            16:hint_glyph=247; // 范
            17:hint_glyph=222; // ，
            18:hint_glyph=248; // 亲
            19:hint_glyph=249; // 人
            20:hint_glyph=250; // 两
            21:hint_glyph=147; // 行
            22:hint_glyph=251; // 泪
            23:hint_glyph=243; // 。
            default:hint_glyph=0;
        endcase end
    endfunction
    // 前方发生车辆碰撞！！：十个64像素字格，沿用原56像素高字幕区和滚动节奏。
    // 字库208..216使用14像素高字形，放大四倍；两个全角叹号共用字形216。
    function [7:0] warning_glyph;
        input [3:0] id;
        begin case(id)
            0:warning_glyph=208;1:warning_glyph=209;
            2:warning_glyph=210;3:warning_glyph=211;
            4:warning_glyph=212;5:warning_glyph=213;
            6:warning_glyph=214;7:warning_glyph=215;
            8,9:warning_glyph=216;
            default:warning_glyph=0;
        endcase end
    endfunction
    // 只锁存当前行，避免每像素寄存整幅字模及 256:1 位选择器。
    player_ui_font font(.clk(clk),.code(glyph_id),.y(glyph_y),.row(glyph_row));
    always @* begin
        base=rgb;text_color=24'hffffff;text_on=0;glyph_id=0;
        glyph_x=0;glyph_y=0;tile=3;local_x=0;local_y=0;
        if(directory_visible && !alarm) base=DIRECTORY_EXTERNAL_DIM!=0 ? rgb : directory_background;
        if(directory_pixel && !alarm) begin
            base=24'h101418;
            if(y>=8 && y<24) begin
                glyph_id=hint_glyph(hint_x[8:4]);glyph_x=hint_x[3:0];
                glyph_y=y-9'd8;text_on=1;text_color=24'hc0e8ff;
                if(glyph_id<96) glyph_x={1'b0,hint_x[3:1]};
            end
            if(directory_x>=224 && directory_x<416 && y>=40 && y<72) begin
                local_x=directory_x-224;local_y=y-40;
                // 紧急通知系统：六个固定字格，只做小位宽查表。
                case(local_x[7:5])
                    0:glyph_id=138;1:glyph_id=139;2:glyph_id=140;
                    3:glyph_id=141;4:glyph_id=142;5:glyph_id=143;
                    default:glyph_id=0;
                endcase
                glyph_x=local_x[4:1];glyph_y=local_y[4:1];text_on=1;
            end
            if(directory_x>=112 && directory_x<528 && y==88) base=24'h52606c;
            if(directory_x>=288 && directory_x<352 && y>=104 && y<136) begin
                local_x=directory_x-288;local_y=y-104;
                glyph_id=local_x[5] ? 145 : 144;
                glyph_x=local_x[4:1];glyph_y=local_y[4:1];text_on=1;
            end
            if(y>=160 && y<240) tile=0;
            else if(y>=256 && y<336) tile=1;
            else if(y>=352 && y<432) tile=2;
            if(tile!=3 && directory_x>=112 && directory_x<528) begin
                case(tile) 0:local_y=y-160;1:local_y=y-256;default:local_y=y-352;endcase
                base=selection==tile && directory_settled ? 24'h203c48 : 24'h22282e;
                if(directory_x<115 || directory_x>=525 ||
                   (y>=160 && y<163) || (y>=237 && y<240) ||
                   (y>=256 && y<259) || (y>=333 && y<336) ||
                   (y>=352 && y<355) || (y>=429 && y<432))
                    base=selection==tile && directory_settled ? 24'h40e0d0 : 24'h52606c;
                // 实心光标不依赖文字颜色，明确表示当前选择。
                if(selection==tile && directory_settled && directory_x>=144 && directory_x<156 &&
                   ((y>=192 && y<208) || (y>=288 && y<304) || (y>=384 && y<400))) base=24'h40e0d0;
                if(directory_x>=256 && directory_x<384 &&
                   ((y>=184 && y<216) || (y>=280 && y<312) || (y>=376 && y<408))) begin
                    local_x=directory_x-256;local_y=local_y-24;
                    // 图片预览 / 继续播放 / 参数设置. Playback mode is edited only in settings.
                    case(local_x[6:5])
                        0:glyph_id=tile==0 ? 103 : tile==1 ? 197 : 116;
                        1:glyph_id=tile==0 ? 162 : tile==1 ? 198 : 117;
                        2:glyph_id=tile==0 ? 109 : tile==1 ? 196 : 165;
                        3:glyph_id=tile==0 ? 110 : tile==1 ? 121 : 166;
                    endcase
                    // All three tile origins are multiples of 32; their
                    // label baseline is +24. Use one small common slice.
                    glyph_x=directory_x[4:1];glyph_y=y[4:1]-4'd12;text_on=1;
                end
            end
        end else if(alarm) begin
            // 保留红色主线/暗边两级，整屏闪烁时不把边缘重新染成主线。
            base=rgb==24'hff2020 ? alarm_ink : rgb==24'hb01010 ? alarm_edge : alarm_background;
            text_color=alarm_ink;
            // 两组横线夹红色斜杠，均位于波形上方，不覆盖音频可视化。
            if((y>=56 && y<76) || (y>=176 && y<196)) begin
                if(y<59 || (y>=73 && y<76) || (y>=176 && y<179) || y>=193 || !stripe[4])
                    base=alarm_ink;
            end
            if(content_pixel && y>=96 && y<152 && rolling_x<640) begin
                glyph_id=warning_glyph(rolling_x[9:6]);
                glyph_x=rolling_x[5:2];glyph_y=warning_y[5:2];text_on=1;
            end
        end
        if(boot_visible) begin
            base=24'hffffff;text_on=0;text_color=24'h1c2c4e;
            if(x>=144 && x<496 && y>=224 && y<256) begin
                // 基于FPGA的紧急通知系统：中文32px、ASCII16px，共352px居中。
                glyph_id={4'he,boot_title_slot};
                glyph_x={~x[4],x[3:1]};
                glyph_y=y[4:1];text_on=1;
            end
            // 不伪造百分比：循环亮段表示后台仍在初始化/加载首张图片。
            if(x>=192 && x<448 && y>=304 && y<312)
                base=boot_bar_delta<32 ? 24'h40e0d0 : 24'h303c48;
        end
        if(no_signal_visible) begin
            base=no_signal_rgb;text_on=0;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            last_de<=0;last_vs<=1;raster_x<=0;raster_y<=0;scroll<=0;
            hint_scroll<=0;hint_div<=0;
            alarm_phase<=31;
            h1<=1;v1<=1;d1<=0;text1<=0;base1<=0;color1<=0;
            sound1<=0;sound_color1<=0;
            bit_index<=0;logo1<=0;logo_color1<=0;
            out_hs<=1;out_vs<=1;out_de<=0;out_rgb<=0;
        end else begin
            last_de<=de;last_vs<=vs;
            if(!alarm) alarm_phase<=31;
            else if(frame_tick) alarm_phase<=alarm_phase+1'b1;
            // 每两帧移动一像素；离开目录复位，避免每次打开从句子中途开始。
            if(!directory || !directory_settled) begin hint_scroll<=0;hint_div<=0;end
            else if(frame_tick) begin
                hint_div<=!hint_div;
                if(hint_div) hint_scroll<=hint_scroll+1'b1;
            end
            if(de) raster_x<=raster_x+1'b1;else raster_x<=0;
            if(frame_tick) begin raster_y<=0;if(alarm) scroll<=scroll+2;else scroll<=0;end
            else if(last_de && !de) raster_y<=raster_y+1'b1;
            h1<=hs;v1<=vs;d1<=de;base1<=base;color1<=text_color;text1<=text_on;
            sound1<=sound_visible;sound_color1<=sound_rgb;
            // The sprite has a legacy 9-bit Y port; clip before its wrapped
            // coordinates can draw a second logo below the centered viewport.
            logo1<=logo_pixel && content_pixel && !no_signal_visible && !sound_visible;
            logo_color1<=logo_color;
            bit_index<=glyph_x;
            out_hs<=h1;out_vs<=v1;out_de<=d1;
            // Logo 最后覆盖，目录文字与报警字幕都位于它下面；消隐仍输出黑色。
            out_rgb<=!d1 ? 24'd0 : sound1 ? sound_color1 : logo1 ? logo_color1 : text1 && glyph_row[15-bit_index] ? color1 : base1;
        end
    end
endmodule

// BEGIN GENERATED SOUND SCENE
// Resource-light vector scene for the sound-threshold alarm.
// Pure-white background, a red no-horn mark, a dark speaker and three
// breathing sound strokes. Geometry is intentionally LUT-light for EG4S20.
module player_sound_scene(input clk,input rst,input frame_tick,input enable,
    input [9:0] x,input [9:0] y,output reg [23:0] rgb);
    reg [6:0] phase;
    wire [5:0] pulse=phase[6] ? ~phase[5:0] : phase[5:0];
    wire [4:0] strength=pulse[5:1];
    wire [7:0] wave_r=8'd255-{strength,2'b00}-{1'b0,strength,1'b0};
    wire [7:0] wave_g=8'd255-{2'b00,strength,1'b0}-{3'b000,strength};
    wire [7:0] wave_b=8'd255-{2'b00,strength,1'b0};
    reg [8:0] sx,sy,slash_delta,cone_half;
    reg outer_shape,inner_shape,ring_pixel,slash_pixel,horn_pixel,wave_pixel;
    always @* begin
        // Work on a 320x240 coarse grid; each logical pixel is a 2x2 block.
        sx=x[9:1]; sy=y[8:1];
        // Exact interval form of abs(sx-160)/abs(sy-120): remove the
        // subtract/absolute-value mux chain without changing any pixel.
        outer_shape=sx>=9'd76 && sx<=9'd244 && sy>=9'd36 && sy<=9'd204 &&
                    !((sx<9'd90 || sx>9'd230) && (sy<9'd50 || sy>9'd190));
        inner_shape=sx>=9'd90 && sx<=9'd230 && sy>=9'd50 && sy<=9'd190 &&
                    !((sx<9'd102 || sx>9'd218) && (sy<9'd62 || sy>9'd178));
        ring_pixel=outer_shape && !inner_shape;
        // sy is at most 255. A negative sx-sy wraps to 257..511,
        // disjoint from 35..45, so one subtractor is sufficient.
        slash_delta=sx-sy;
        slash_pixel=outer_shape && slash_delta>=9'd35 && slash_delta<=9'd45;
        cone_half=(sx>=9'd138 && sx<9'd174) ? ((sx-9'd138)>>1) : 0;
        horn_pixel=((sx>=9'd173 && sx<9'd230 && sy>=9'd111 && sy<9'd129) ||
              (sx>=9'd194 && sx<9'd222 && sy>=9'd130 && sy<9'd145) ||
              (sx>=9'd164 && sx<9'd184 && sy>=9'd112 && sy<9'd128) ||
              (sx>=9'd138 && sx<9'd174 && sy>=9'd120-cone_half && sy<=9'd120+cone_half));
        // Three compact left-facing sound strokes; color breathes with phase.
        wave_pixel=((sx>=9'd128 && sx<9'd133 && sy>=9'd106 && sy<9'd134) ||
                    (sx>=9'd112 && sx<9'd117 && sy>=9'd98 && sy<9'd142) ||
                    (sx>=9'd96  && sx<9'd101 && sy>=9'd90  && sy<9'd150));
        rgb=24'hffffff;
        if(wave_pixel) rgb={wave_r,wave_g,wave_b};
        if(horn_pixel) rgb=24'h17191d;
        if(ring_pixel || slash_pixel) rgb=24'he5232e;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) phase<=7'd63;
        else if(!enable) phase<=7'd63;
        else if(frame_tick) phase<=phase+1'b1;
    end
endmodule
