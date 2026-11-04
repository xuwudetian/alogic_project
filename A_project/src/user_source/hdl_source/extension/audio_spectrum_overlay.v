`timescale 1ns/1ps
// 全部运行在像素时钟域；PCM 与送往 HDMI 的音频样本一致。
// 48 kHz / 512 点 FFT：只显示 bin 1..64，即 93.75 Hz..6 kHz。
// 每柱一个真实频点，提高常用音频频段分辨率；不制造高频活动。
// 计算期间冻结显示，结果在垂直消隐时统一提交；下降每帧最多 4 像素。
module audio_spectrum_overlay #(parameter integer AMBIENT_ENABLE=0,MODE_576=0,MODE_XGA=0)(
    input clk,input rst,input enable,
    input hs,input vs,input de,input [23:0] rgb_in,
    input audio_valid,input signed [23:0] audio_sample,
    output reg hs_out,output reg vs_out,output reg de_out,
    output reg [23:0] rgb_out,
    input alarm,input [23:0] ambient_color,input picture_layout
);
    // 即使静音或 FFT 尚未完成，每根柱保留 20 像素底高。
    // 柱高以 2px 为单位保存，64x2 组缓存各省 1bit；误差最多 1px。
    localparam [5:0] SPECTRUM_BASE_HEIGHT = 6'd10;
    localparam IDLE=0,ARM=1,CAPTURE=2,TRANSFORM=3,HOLD=4;
    reg [2:0] state;
    reg [5:0] arm_count;
    reg [8:0] sample_count,bin_count;
    reg start,window_valid;
    reg signed [20:0] window_product;
    wire [7:0] triangle=sample_count[8] ? ~sample_count[7:0] : sample_count[7:0];
    wire fft_valid,fft_busy,fft_done;
    wire [20:0] fft_re,fft_im;
    spectrum_fft_512 fft(.clk(clk),.rst(rst),.mode(1'b0),.start(start),
        .din_en(window_valid),.din_re(window_product[19:8]),.din_im(12'd0),
        .done(fft_done),.busy(fft_busy),.dout_en(fft_valid),.dout_re(fft_re),.dout_im(fft_im));

    // 分级流水线缩短 FFT 输出到柱高寄存器之间的组合路径。
    reg mag_valid,level_valid;
    reg [8:0] mag_bin,level_bin;
    wire [5:0] band_index=level_bin[5:0]-6'd1;
    reg [20:0] abs_re,abs_im;
    wire [21:0] magnitude={1'b0,abs_re}+{1'b0,abs_im};
    reg [6:0] bin_level;
    // HOLD 前 64 个频点必定全部写完，无需整组清零；使用分布式 RAM 节省触发器。
    (* ram_style="dram" *) reg [5:0] pending[0:63];
    (* ram_style="dram" *) reg [5:0] displayed[0:63];
    reg init_busy;
    reg [5:0] init_index;
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
    wire advance_x=!MODE_XGA || raster_x[2:0]==1 || raster_x[2:0]==3 || raster_x[2:0]==4 || raster_x[2:0]==6 || raster_x[2:0]==7;
    wire advance_y=!MODE_XGA || raster_y[2:0]==1 || raster_y[2:0]==3 || raster_y[2:0]==4 || raster_y[2:0]==6 || raster_y[2:0]==7;
    // 64 柱分成 16 组，每组 39px（10+10+10+9），两侧各留 8px。
    // 柱宽统一 7px；组间间距少 1px，用计数器代替坐标除法。
    reg [5:0] bar_index;
    reg [3:0] bar_phase;
    reg [5:0] side_index;
    reg [2:0] side_phase;
    wire side_layout=AMBIENT_ENABLE!=0 && picture_layout && !alarm;
    wire frame_tick=last_vs && !vs;
    reg commit_busy,commit_load,commit_phase;
    reg [5:0] commit_index;
    // Commit runs in vertical blanking, drawing in the bottom of the frame.
    // Share one asynchronous RAM read port instead of duplicating the mux.
    wire [5:0] height_address=commit_busy ? commit_index : side_layout ? side_index : bar_index;
    wire [5:0] display_height=init_busy ? SPECTRUM_BASE_HEIGHT : displayed[height_address];
    reg [5:0] old_height_q,new_height_q;
    wire [5:0] old_height=MODE_XGA ? old_height_q : display_height;
    wire [5:0] new_height=MODE_XGA ? new_height_q : pending[commit_index];
    always @(posedge clk) if(commit_busy && !commit_phase) begin
        old_height_q<=display_height;new_height_q<=pending[commit_index];
    end

    // Serial RAM initialization avoids resettable flops for all 64 entries.
    // Until it completes, the visible floor is exactly the original 20 px.
    always @(posedge clk or posedge rst) begin
        if(rst) begin init_busy<=1;init_index<=0;end
        else if(init_busy) begin
            if(init_index==63) init_busy<=0;
            else init_index<=init_index+1'b1;
        end
    end
    always @(posedge clk) begin
        if(!rst) begin
            if(init_busy) displayed[init_index]<=SPECTRUM_BASE_HEIGHT;
            else if(commit_busy && (!MODE_XGA || commit_phase)) begin
                if(commit_load && new_height>=old_height)
                    displayed[commit_index]<=new_height<SPECTRUM_BASE_HEIGHT ? SPECTRUM_BASE_HEIGHT : new_height;
                else displayed[commit_index]<=old_height>SPECTRUM_BASE_HEIGHT+6'd2 ? old_height-6'd2 : SPECTRUM_BASE_HEIGHT;
            end
        end
    end

    always @(posedge clk) begin
        if(!rst && level_valid && level_bin!=0 && level_bin<=64)
            pending[band_index]<=bin_level[6:1];
    end

    // 分段对数幅度，仅用于可视化，不作为校准后的 dB 测量值。
    function [6:0] height;
        input [21:0] value;
        integer b;
        reg [21:0] fraction;
        begin
            height=0;
            for(b=5;b<22;b=b+1) begin
                if(value[b]) begin
                    fraction=value>>(b-3);
                    if(b>=20) height=120;
                    else height=(b-5)*8+fraction[2:0];
                end
            end
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;arm_count<=0;sample_count<=0;bin_count<=0;
            start<=0;window_valid<=0;window_product<=0;
            mag_valid<=0;level_valid<=0;mag_bin<=0;level_bin<=0;
            abs_re<=0;abs_im<=0;bin_level<=0;
            last_de<=0;last_vs<=1;raster_x<=0;raster_y<=0;
            bar_index<=0;bar_phase<=0;side_index<=0;side_phase<=0;
            commit_busy<=0;commit_load<=0;commit_index<=0;commit_phase<=0;
        end else begin
            last_de<=de;last_vs<=vs;
            if(de) raster_x<=raster_x+1'b1;else raster_x<=0;
            if(!de || x<(MODE_576 ? 48 : 8)) begin bar_index<=0;bar_phase<=0;end
            else if(advance_x && bar_phase==(bar_index[1:0]==3 ? 4'd8 : 4'd9)) begin
                bar_phase<=0;
                if(bar_index!=63) bar_index<=bar_index+1'b1;
            end else if(advance_x) bar_phase<=bar_phase+1'b1;
            if(frame_tick) raster_y<=0;else if(last_de && !de) raster_y<=raster_y+1'b1;
            if(frame_tick) begin side_index<=0;side_phase<=0;end
            else if(last_de && !de && advance_y) begin
                if(y<32) begin side_index<=0;side_phase<=0;end
                // 64 bins span all 480 image rows: alternate 8 and 7 rows.
                // The original 640x480 layout retains six rows per bin.
                else if(side_phase==(MODE_576 ? (side_index[0] ? 6 : 7) : 5)) begin
                    side_phase<=0;if(side_index!=63) side_index<=side_index+1'b1;
                end else side_phase<=side_phase+1'b1;
            end
            start<=0;window_valid<=0;
            mag_valid<=fft_valid;
            if(fft_valid) begin
                mag_bin<=bin_count;bin_count<=bin_count+1'b1;
                abs_re<=fft_re[20] ? (~fft_re+21'd1) : fft_re;
                abs_im<=fft_im[20] ? (~fft_im+21'd1) : fft_im;
            end
            level_valid<=mag_valid;
            if(mag_valid) begin level_bin<=mag_bin;bin_level<=height(magnitude);end
            if(level_valid) begin
                // 每柱只有一个频点，直接写入，不再读取整组进行最大值比较。
                if(level_bin==511) state<=HOLD;
            end
            case(state)
                IDLE: begin
                    if(!fft_busy) begin
                        start<=1;arm_count<=0;sample_count<=0;bin_count<=0;
                        state<=ARM;
                    end
                end
                ARM: begin
                    // 等待 FFT 控制器完成启动，随后只接收连续的有效 PCM 样本。
                    if(arm_count==31) state<=CAPTURE;
                    else arm_count<=arm_count+1'b1;
                end
                CAPTURE: if(audio_valid) begin
                    window_product<=$signed(audio_sample[23:12])*$signed({1'b0,triangle});
                    window_valid<=1;
                    if(sample_count==511) state<=TRANSFORM;
                    else sample_count<=sample_count+1'b1;
                end
                TRANSFORM: begin end
                HOLD: if(commit_busy && commit_load && commit_index==63 && (!MODE_XGA || commit_phase)) state<=IDLE;
                default: state<=IDLE;
            endcase
            if(frame_tick) begin
                // 垂直消隐期间串行提交 64 柱，共用比较器和减法器。
                commit_busy<=1;commit_load<=state==HOLD;commit_index<=0;commit_phase<=0;
            end else if(commit_busy) begin
                commit_phase<=!commit_phase;
                if(!MODE_XGA || commit_phase) begin
                    if(commit_index==63) commit_busy<=0;
                    else commit_index<=commit_index+1'b1;
                end
            end
        end
    end

    // 底部留 4px，非柱像素和留白区域完整透传图片。
    wire in_panel=de && x>=(MODE_576 ? 48 : 8) && x<(MODE_576 ? 672 : 632) &&
        y>=(MODE_576 ? 448 : 352) && y<(MODE_576 ? 572 : 476);
    wire [9:0] from_bottom=(MODE_576 ? 10'd571 : 10'd475)-y;
    function [23:0] spectrum_color;
        input [7:0] position;
        begin
            // 青蓝到青绿，保持一套克制的渐变；WARNING 仍统一红色。
            case(position[6:4])
                3'd0: spectrum_color=24'h2088c0;
                3'd1: spectrum_color=24'h2498c4;
                3'd2: spectrum_color=24'h28a8c4;
                3'd3: spectrum_color=24'h30b4bc;
                3'd4: spectrum_color=24'h38beb0;
                3'd5: spectrum_color=24'h40c4a0;
                3'd6: spectrum_color=24'h50c890;
                default: spectrum_color=24'h68cc88;
            endcase
        end
    endfunction

    // 普通柱子与同一拍原图各占 50%；9 位加法避免溢出，右移取整不增加流水延迟。
    // WARNING 保留不透明红色标记，供后级报警图层识别；柱间空隙仍完整透传。
    wire [23:0] bar_color=side_layout ? ambient_color : spectrum_color(from_bottom[7:0]);
    // Move the fixed two-pixel floor to the coordinate side of the
    // comparison. The RAM height now feeds a five-bit comparator directly.
    // Differences are evaluated only within the original 20-pixel side bars.
    wire [4:0] left_excess=5'd25-x[4:0];
    wire [4:0] right_excess=x[4:0]-(MODE_576 ? 5'd22 : 5'd6);
    wire left_hit=x>=8 && x<28 && (x>=26 || left_excess<{1'b0,display_height[5:2]});
    wire right_hit=x>=(MODE_576 ? 692 : 612) && x<(MODE_576 ? 712 : 632) &&
        (x<(MODE_576 ? 694 : 614) || right_excess<{1'b0,display_height[5:2]});
    wire side_hit=de && y>=32 && y<(MODE_576 ? 512 : 416) && side_phase<2 && (left_hit || right_hit);
    wire bar_hit=side_layout ? side_hit : in_panel &&
        bar_phase>=4'd1 && bar_phase<4'd8 && from_bottom<{2'b00,display_height,1'b0};
    wire [8:0] mixed_r={1'b0,rgb_in[23:16]}+{1'b0,bar_color[23:16]};
    wire [8:0] mixed_g={1'b0,rgb_in[15:8]}+{1'b0,bar_color[15:8]};
    wire [8:0] mixed_b={1'b0,rgb_in[7:0]}+{1'b0,bar_color[7:0]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin hs_out<=1;vs_out<=1;de_out<=0;rgb_out<=0;end
        else begin
            hs_out<=hs;vs_out<=vs;de_out<=de;rgb_out<=rgb_in;
            if(enable && bar_hit)
                if(alarm) rgb_out<=24'hff2020;
                else rgb_out<={mixed_r[8:1],mixed_g[8:1],mixed_b[8:1]};
        end
    end
endmodule
