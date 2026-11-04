`timescale 1ns/1ps
// Unsigned setup divider. One subtract/shift per cycle; no combinational divider.
module bmp_setup_divider(input clk,input rst,input start,input [31:0] numerator,
    input [31:0] denominator,output reg done,output reg [31:0] quotient);
    reg busy;
    reg [5:0] count;
    reg [31:0] dividend,divisor;
    reg [32:0] remainder;
    wire [32:0] trial={remainder[31:0],dividend[31]};
    always @(posedge clk) begin
        if(rst) begin busy<=0;done<=0;quotient<=0;count<=0;dividend<=0;divisor<=1;remainder<=0;end
        else begin
            done<=0;
            if(start) begin busy<=1;count<=0;dividend<=numerator;divisor<=denominator;remainder<=0;quotient<=0;end
            else if(busy) begin
                dividend<=dividend<<1;
                remainder<=trial>={1'b0,divisor} ? trial-{1'b0,divisor} : trial;
                quotient<={quotient[30:0],trial>={1'b0,divisor}};
                if(count==31) begin busy<=0;done<=1;end else count<=count+1'b1;
            end
        end
    end
endmodule

// Streaming BMP24 -> complete display frame. Center crop, pixel-center mapping,
// separable bilinear interpolation (Q16 coordinates, Q8 weights, one final round).
// Two output-width rows suffice even for large sources; no source-sized BRAM.
module bmp_bilinear #(
    parameter integer WIDTH=640, HEIGHT=480, MAX_SOURCE_DIMENSION=16384,
    parameter integer MODE_576=0
)(
    input clk,input rst_n,input file_start,input [31:0] file_size,
    input file_valid,input [7:0] file_byte,input [31:0] file_byte_offset,
    input file_end,input [7:0] upstream_error,input pixel_ready,
    output sector_room,output reg header_accepted,output pixel_valid,
    output reg [23:0] pixel_rgb,output reg [15:0] pixel_x,pixel_y,
    output reg frame_commit,bmp_done,output reg [7:0] bmp_error,
    output reg top_down,output reg [31:0] pixel_offset,output [31:0] row_stride,
    output reg scaled,output reg [59:0] error_detail,
    output [15:0] source_width,output [15:0] source_height
);
    localparam RBYTE=0,BYTE=1,PARSE=2,MULTIPLY=3,CHECK_HEADER=4,
        CROP_WAIT=5,STEP_X=6,WAIT_X=7,STEP_Y=8,WAIT_Y=9,SETUP=10,
        ROW_CHECK=11,H_LERP=12,MAC_MUL=13,MAC_ADD=14,MAC_SAVE=15,
        H_ADVANCE=16,H_CHECK=17,V_READ=18,V_WAIT=19,V_LERP=20,V_OUT=21,V_SECOND=22,V_JOIN=23,Y_SETTLE=24,
        HEADER_CHECK=25,Y_READY=26,H_SETTLE=27;
    reg [4:0] state;
    reg active,eof,gap;
    reg [7:0] end_error;
    // 位宽由合法尺寸上限推导，保留终止值（WIDTH/HEIGHT也必须可表示）。
    localparam X_BITS=$clog2(WIDTH+1),Y_BITS=$clog2(HEIGHT+1);
    localparam PIXEL_BITS=$clog2(WIDTH*HEIGHT+1);
    localparam SOURCE_BITS=$clog2(MAX_SOURCE_DIMENSION+1);
    localparam ROW_BITS=$clog2(((MAX_SOURCE_DIMENSION*3+3)/4)*4+1);
    reg [31:0] received,consumed;
    reg [PIXEL_BITS-1:0] pixels;
    wire [31:0] diagnostic_pixels=pixels;
    reg [ROW_BITS-1:0] row_stride_value;
    assign row_stride=row_stride_value;
    reg [7:0] header[0:53];
    // Validate independent fields before enabling the setup registers. This
    // removes the wide header arithmetic -> priority chain -> register-enable
    // path; the one extra setup clock does not change pixels or error priority.
    reg [5:0] header_bad;

    // A whole sector is reserved before requesting it. The arbiter can finish
    // that sector and service WAV while an enlarged output row is generated.
    reg [7:0] bytes[0:1023] /* fehdl force_ram=1, ram_style="bram" */;
    reg [9:0] head,tail;
    reg [10:0] used;
    reg [7:0] byte_q;
    wire push=active && !file_start && file_valid;
    wire pop=active && state==RBYTE && used!=0 && !file_start;
    assign sector_room=!active || used<=480;
    always @(posedge clk) begin
        if(push && used<1024) bytes[tail]<=file_byte;
        if(pop) byte_q<=bytes[head];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin head<=0;tail<=0;used<=0;end
        else if(file_start) begin head<=0;tail<=0;used<=0;end
        else begin
            if(push && used<1024) tail<=tail+1'b1;
            if(pop) head<=head+1'b1;
            case({push && used<1024,pop})
                2'b10:used<=used+1'b1;
                2'b01:used<=used-1'b1;
                default:begin end
            endcase
        end
    end
    function [31:0] le32;
        input integer a;
        begin le32={header[a+3],header[a+2],header[a+1],header[a]};end
    endfunction
    wire [31:0] raw_width={header[21],header[20],header[19],header[18]};
    wire [31:0] raw_height={header[25],header[24],header[23],header[22]};
    wire [31:0] abs_height=raw_height[31] ? (~raw_height+1'b1) : raw_height;
    reg [15:0] sw,sh,crop_w,crop_h,crop_x,crop_y;
    // 高度上界只在文件头确认时改变，提前寄存可缩短纵向裁剪到状态机的路径。
    // CROP_WAIT 除法期间已经稳定，不增加像素/行延迟，不改变采样坐标。
    reg [15:0] last_source_y;
    assign source_width=sw;
    assign source_height=sh;
    reg [ROW_BITS-1:0] source_row_bytes;
    reg [31:0] required_data,mul_term;
    reg [15:0] mul_bits;
    reg [4:0] mul_count;
    wire [32:0] required_end={1'b0,pixel_offset}+{1'b0,required_data};
    reg wide;
    reg div_start;
    reg [31:0] div_n,div_d,step_x,step_y;
    wire div_done;
    wire [31:0] div_q;
    bmp_setup_divider setup_div(clk,!rst_n || file_start,div_start,div_n,div_d,div_done,div_q);

    reg signed [32:0] pos_x,pos_y,start_x;
    wire [31:0] span_x=step_x*(WIDTH-1),span_y=step_y*(HEIGHT-1);
    wire signed [32:0] origin_x=($signed({1'b0,sw,16'd0})-33'sd65536-$signed({1'b0,span_x}))>>>1;
    wire signed [32:0] origin_y=($signed({1'b0,sh,16'd0})-33'sd65536-$signed({1'b0,span_y})+(top_down ? 33'sd0 : 33'sd1))>>>1;
    // Quantize in logical top-down space, including bottom-up storage. Rounding
    // the mirrored coordinate up preserves exactly the same Q8 sample weights.
    // 舍入与边界比较分拍，避免纵坐标加法、两次比较和状态译码串成临界路径。
    reg signed [32:0] sample_y;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) sample_y<=0;
        else sample_y<=top_down ? pos_y : ((pos_y+33'sd255) & ~33'sd255);
    // Bounds are nonnegative integer Q16 values. A nonnegative coordinate is
    // >= an upper bound exactly when its integer part is >= that bound; no
    // 33-bit subtract is needed. The lower-bound equality must also test the
    // fractional bits, so a positive subpixel coordinate is still interpolated.
    reg [15:0] last_source_x;
    always @(posedge clk) last_source_x<=crop_x+crop_w-16'd1;
    wire x_low=pos_x[32] || pos_x[31:16]<crop_x ||
        (pos_x[31:16]==crop_x && pos_x[15:0]==0);
    wire x_high=!pos_x[32] && pos_x[31:16]>=last_source_x;
    wire y_low=sample_y[32] || sample_y[31:16]<crop_y ||
        (sample_y[31:16]==crop_y && sample_y[15:0]==0);
    wire y_high=!sample_y[32] && sample_y[31:16]>=last_source_y;
    // Increment the unclamped integer coordinate in parallel with the range
    // checks. Incrementing sx0/sy0 serialized clamp -> carry -> cache-tag test
    // on the row-control path. These expressions preserve every sample/weight.
    reg [15:0] sx0,sx1;
    reg [7:0] wx;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sx0<=0;sx1<=0;wx<=0;end
        else begin
            sx0<=x_low ? crop_x : x_high ? last_source_x : pos_x[31:16];
            sx1<=x_low ? crop_x : x_high ? last_source_x : pos_x[31:16]+16'd1;
            wx<=(x_low || x_high) ? 8'd0 : pos_x[15:8];
        end
    end
    reg [15:0] sy0,sy1;
    reg [7:0] wy;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sy0<=0;sy1<=0;wy<=0;end
        else begin
            sy0<=y_low ? crop_y : y_high ? last_source_y : sample_y[31:16];
            sy1<=y_low ? crop_y : y_high ? last_source_y : sample_y[31:16]+16'd1;
            wy<=(y_low || y_high) ? 8'd0 : sample_y[15:8];
        end
    end
    reg [SOURCE_BITS-1:0] source_row,source_x,held_x,held_row;
    reg [Y_BITS-1:0] out_y;
    reg [X_BITS-1:0] hx,vx;
    reg [ROW_BITS-1:0] in_row;
    reg [1:0] phase;
    reg [7:0] blue,green;
    reg [23:0] previous_rgb,left_rgb,right_rgb;
    reg row_end_pending;
    wire needed=out_y<HEIGHT && (source_row==sy0 || source_row==sy1);

    // Packed Q8 RGB components: two 640-pixel rows occupy 3840 x 16.
    // Explicit 32K implementation consumes two blocks, preserving full
    // intermediate precision and the original one-cycle synchronous read.
    localparam LINE_ABITS=$clog2(WIDTH*6);
    wire [15:0] line_q;
    reg [15:0] lv,rv;
    reg [SOURCE_BITS-1:0] tag0,tag1;
    reg valid0,valid1;
    wire have_y0=sy0[0] ? valid1 && tag1==sy0 : valid0 && tag0==sy0;
    wire have_y1=sy1[0] ? valid1 && tag1==sy1 : valid0 && tag0==sy1;
    reg [1:0] channel;
    reg vertical;
    reg signed [16:0] difference;
    reg [23:0] base;
    reg [7:0] weight;
    reg signed [25:0] product;
    reg signed [26:0] blend;
    reg [23:0] v_result;
    wire [7:0] lh=(sx0==sx1 ? right_rgb : left_rgb) >> ((2-channel)*8);
    wire [7:0] rh=right_rgb >> ((2-channel)*8);
    wire h_write=active && state==MAC_SAVE && !vertical;
    wire [LINE_ABITS-1:0] line_write_address=(held_row[0] ? WIDTH*3 : 0)+hx*3+channel;
    wire [LINE_ABITS-1:0] line_read_address=((state==V_SECOND ? sy1[0] : sy0[0]) ? WIDTH*3 : 0)+vx*3+channel;
    bmp_bilinear_line_memory #(.DEPTH(WIDTH*6),.ADDR_BITS(LINE_ABITS)) line_memory(
        .write_clk(clk),.write_enable(h_write),.write_address(line_write_address),
        .write_data(blend[15:0]),.read_clk(clk),
        .read_enable(state==V_READ || state==V_SECOND),
        .read_address(line_read_address),.read_data(line_q)
    );
    assign pixel_valid=active && state==V_OUT && pixel_ready;

    // RGB channel selection is local to the three-channel MAC sequence.
    // Reset it in the surrounding states unconditionally: including row-tag
    // and coordinate comparisons in its enable creates a long path into the
    // address multipliers. None of these surrounding states consumes channel.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) channel<=0;
        else if(file_start) channel<=0;
        else if(active) begin
            if(state==MAC_SAVE && channel!=2) channel<=channel+1'b1;
            else if(state==BYTE || state==H_ADVANCE || state==H_CHECK ||
                    state==ROW_CHECK || state==V_OUT) channel<=0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RBYTE;active<=0;eof<=0;gap<=0;end_error<=0;received<=0;consumed<=0;pixels<=0;
            header_accepted<=0;pixel_rgb<=0;pixel_x<=0;pixel_y<=0;frame_commit<=0;bmp_done<=0;bmp_error<=0;header_bad<=0;
            top_down<=0;pixel_offset<=0;row_stride_value<=0;scaled<=0;error_detail<=0;
            sw<=0;sh<=0;crop_w<=1;crop_h<=1;crop_x<=0;crop_y<=0;source_row_bytes<=0;
            last_source_y<=0;
            required_data<=0;mul_term<=0;mul_bits<=0;mul_count<=0;wide<=0;
            div_start<=0;div_n<=0;div_d<=1;step_x<=0;step_y<=0;
            pos_x<=0;pos_y<=0;start_x<=0;
            source_row<=0;source_x<=0;out_y<=0;hx<=0;vx<=0;held_x<=0;held_row<=0;
            in_row<=0;phase<=0;blue<=0;green<=0;previous_rgb<=0;left_rgb<=0;right_rgb<=0;row_end_pending<=0;
            tag0<=0;tag1<=0;valid0<=0;valid1<=0;vertical<=0;
            difference<=0;base<=0;weight<=0;product<=0;blend<=0;v_result<=0;lv<=0;rv<=0;
        end else begin
            frame_commit<=0;bmp_done<=0;div_start<=0;
            if(file_start) begin
                state<=RBYTE;active<=1;eof<=0;gap<=0;end_error<=0;received<=0;consumed<=0;pixels<=0;
                header_accepted<=0;bmp_error<=0;top_down<=0;scaled<=0;error_detail<=0;
                pixel_offset<=0;row_stride_value<=0;source_row<=0;source_x<=0;out_y<=0;hx<=0;vx<=0;
                in_row<=0;phase<=0;row_end_pending<=0;valid0<=0;valid1<=0;
            end else if(active) begin
                if(push) begin
                    received<=received+1'b1;
                    if(file_byte_offset!=received || used==1024) gap<=1;
                end
                if(file_end && !eof) begin eof<=1;end_error<=upstream_error;end
                case(state)
                    RBYTE: begin
                        if(pop) state<=BYTE;
                        else if(eof && !push) begin
                            active<=0;bmp_done<=1;
                            if(end_error!=0) bmp_error<=8'h38;
                            else if(bmp_error==0) begin
                                if(header_accepted && !gap && received==file_size && pixels==WIDTH*HEIGHT)
                                    frame_commit<=1;
                                else begin
                                    bmp_error<=8'h37;
                                    error_detail<={diagnostic_pixels,(!header_accepted ? 10'd7 : gap ? 10'd5 : received!=file_size ? 10'd6 : 10'd4),received[15:0],2'd0};
                                end
                            end
                        end
                    end
                    BYTE: begin
                        consumed<=consumed+1'b1;state<=RBYTE;
                        if(consumed<54) begin header[consumed]<=byte_q;if(consumed==53) state<=HEADER_CHECK;end
                        else if(header_accepted && bmp_error==0 && consumed>=pixel_offset && source_row<sh) begin
                            row_end_pending<=0;
                            if(in_row<source_row_bytes) case(phase)
                                0:begin blue<=byte_q;phase<=1;end
                                1:begin green<=byte_q;phase<=2;end
                                2:begin
                                    phase<=0;source_x<=source_x+1'b1;previous_rgb<={byte_q,green,blue};
                                    if(needed && hx<WIDTH && source_x==sx1) begin
                                        left_rgb<=previous_rgb;right_rgb<={byte_q,green,blue};held_x<=source_x;held_row<=source_row;
                                        state<=H_LERP;
                                    end
                                end
                            endcase
                            if(in_row==row_stride-1) begin
                                source_row<=source_row+1'b1;source_x<=0;phase<=0;in_row<=0;row_end_pending<=1;
                                if(!(in_row<source_row_bytes && phase==2 && needed && hx<WIDTH && source_x==sx1)) state<=ROW_CHECK;
                            end else in_row<=in_row+1'b1;
                        end
                    end
                    HEADER_CHECK: begin
                        header_bad[0]<=header[0]!="B" || header[1]!="M";
                        header_bad[1]<=raw_width==0 || raw_width>MAX_SOURCE_DIMENSION || abs_height==0 || abs_height>MAX_SOURCE_DIMENSION || le32(14)<40;
                        header_bad[2]<={header[27],header[26]}!=1;
                        header_bad[3]<={header[29],header[28]}!=24;
                        header_bad[4]<=le32(30)!=0;
                        header_bad[5]<=le32(10)<54 || le32(10)>=file_size || le32(14)>file_size-14 || le32(10)-14<le32(14);
                        state<=PARSE;
                    end
                    PARSE: begin
                        state<=RBYTE;
                        if(header_bad[0]) bmp_error<=8'h31;
                        else if(header_bad[1]) bmp_error<=8'h32;
                        else if(header_bad[2]) bmp_error<=8'h33;
                        else if(header_bad[3]) bmp_error<=8'h34;
                        else if(header_bad[4]) bmp_error<=8'h35;
                        else if(header_bad[5]) bmp_error<=8'h36;
                        else begin
                            sw<=raw_width[15:0];sh<=abs_height[15:0];top_down<=raw_height[31];pixel_offset<=le32(10);
                            source_row_bytes<=(raw_width<<1)+raw_width;
                            row_stride_value<=(((raw_width<<1)+raw_width+3)>>2)<<2;
                            mul_term<=(((raw_width<<1)+raw_width+3)>>2)<<2;
                            mul_bits<=abs_height[15:0];mul_count<=0;required_data<=0;state<=MULTIPLY;
                        end
                    end
                    MULTIPLY: begin
                        if(mul_bits[0]) required_data<=required_data+mul_term;
                        mul_term<=mul_term<<1;mul_bits<=mul_bits>>1;
                        if(mul_count==15) state<=CHECK_HEADER;else mul_count<=mul_count+1'b1;
                    end
                    CHECK_HEADER: begin
                        if(required_end[32]) begin bmp_error<=8'h36;state<=RBYTE;end
                        else if(required_end>file_size || le32(2)<required_end || le32(2)>file_size) begin
                            bmp_error<=8'h37;state<=RBYTE;
                            error_detail<={required_end[31:0],(required_end>file_size ? 10'd1 : le32(2)<required_end ? 10'd2 : 10'd3),file_size[15:0],2'd0};
                        end else begin
                            header_accepted<=1;scaled<=sw!=WIDTH || sh!=HEIGHT;
                            // One common source-pixel step preserves aspect ratio
                            // even when the ideal centered crop has fractional edges.
                            crop_w<=sw;crop_h<=sh;crop_x<=0;crop_y<=0;
                            last_source_y<=sh-16'd1;
                            // 576p VIC17 carries a 4:3 image in 720x576 samples.
                            // Retain the original 4:3 crop so compact 640x480
                            // mode does not lose the left/right picture edges.
                            div_n<=MODE_576 ? (sw*3>sh*4 ? {sh,16'd0} : {sw,16'd0}) :
                                (sw*HEIGHT>sh*WIDTH ? {sh,16'd0} : {sw,16'd0});
                            div_d<=MODE_576 ? (sw*3>sh*4 ? 540 : 720) :
                                (sw*HEIGHT>sh*WIDTH ? HEIGHT : WIDTH);
                            div_start<=1;state<=CROP_WAIT;
                        end
                    end
                    CROP_WAIT:if(div_done) begin
                        step_x<=div_q;
                        step_y<=MODE_576 ? div_q-((div_q+15)>>4) : div_q;
                        state<=SETUP;
                    end
                    SETUP:begin
                        start_x<=origin_x;pos_x<=origin_x;pos_y<=origin_y;
                        state<=RBYTE;
                    end
                    ROW_CHECK:begin
                        row_end_pending<=0;
                        if(out_y<HEIGHT && have_y0 && have_y1) begin vx<=0;state<=V_READ;end
                        else begin hx<=0;pos_x<=start_x;state<=RBYTE;end
                    end
                    H_LERP:begin
                        difference<=$signed({1'b0,rh})-$signed({1'b0,lh});base<={8'd0,lh,8'd0};weight<=wx;
                        vertical<=0;state<=MAC_MUL;
                    end
                    MAC_MUL:begin product<=difference*$signed({1'b0,weight});state<=MAC_ADD;end
                    MAC_ADD:begin blend<=$signed({1'b0,base})+product+(vertical ? 27'sd32768 : 27'sd0);state<=MAC_SAVE;end
                    MAC_SAVE:begin
                        if(vertical) begin
                            if(channel==0) v_result[23:16]<=blend[23:16];
                            else if(channel==1) v_result[15:8]<=blend[23:16];
                            if(channel==2) begin
                                pixel_rgb<={v_result[23:8],blend[23:16]};pixel_x<=vx;
                                pixel_y<=top_down ? out_y : HEIGHT-1-out_y;state<=V_OUT;
                            end else begin state<=V_READ;end
                        end else begin
                            if(channel==2) state<=H_ADVANCE;
                            else begin state<=H_LERP;end
                        end
                    end
                    H_ADVANCE:begin
                        hx<=hx+1'b1;pos_x<=pos_x+$signed({1'b0,step_x});
                        if(hx==WIDTH-1) begin
                            if(held_row[0]) begin tag1<=held_row;valid1<=1;end
                            else begin tag0<=held_row;valid0<=1;end
                            state<=row_end_pending ? ROW_CHECK : RBYTE;
                        end else state<=H_SETTLE;
                    end
                    H_SETTLE:state<=H_CHECK;
                    H_CHECK:begin
                        if(sx1==held_x) begin state<=H_LERP;end
                        else state<=RBYTE;
                    end
                    V_READ:state<=V_WAIT;
                    V_WAIT:begin lv<=line_q;state<=V_SECOND;end
                    V_SECOND:state<=V_JOIN;
                    V_JOIN:begin rv<=line_q;state<=V_LERP;end
                    V_LERP:begin
                        difference<=$signed({1'b0,rv})-$signed({1'b0,lv});base<={lv,8'd0};weight<=wy;
                        vertical<=1;state<=MAC_MUL;
                    end
                    V_OUT:if(pixel_ready) begin
                        pixels<=pixels+1'b1;
                        if(vx==WIDTH-1) begin out_y<=out_y+1'b1;pos_y<=pos_y+$signed({1'b0,step_y});state<=Y_SETTLE;end
                        else begin vx<=vx+1'b1;state<=V_READ;end
                    end
                    Y_SETTLE:state<=Y_READY;
                    Y_READY:state<=ROW_CHECK;
                    default:state<=RBYTE;
                endcase
            end
        end
    end
endmodule

// Keep the two existing 32 Kbit blocks; use one small block for the 224
// overflow words at WIDTH=720. Identical one-clock read latency and Q8 data.
module bmp_bilinear_line_memory #(parameter DEPTH=3840,parameter ADDR_BITS=$clog2(DEPTH))(
    input write_clk,input write_enable,input [ADDR_BITS-1:0] write_address,
    input [15:0] write_data,input read_clk,input read_enable,
    input [ADDR_BITS-1:0] read_address,output [15:0] read_data
);
    generate if(DEPTH<=4096) begin: standard
        bram32k_sdp #(.DEPTH(DEPTH),.ADDR_BITS(ADDR_BITS)) memory(
            .write_clk(write_clk),.write_enable(write_enable),.write_address(write_address),.write_data(write_data),
            .read_clk(read_clk),.read_enable(read_enable),.read_address(read_address),.read_data(read_data));
    end else if(DEPTH<=4608) begin: extended
        wire [15:0] main_q;
        wire [15:0] tail_q;
        reg tail_select;
        bram32k_sdp #(.DEPTH(4096),.ADDR_BITS(12)) memory(
            .write_clk(write_clk),.write_enable(write_enable && write_address<4096),
            .write_address(write_address[11:0]),.write_data(write_data),
            .read_clk(read_clk),.read_enable(read_enable && read_address<4096),
            .read_address(read_address[11:0]),.read_data(main_q));
        // Explicit 9K implementation prevents the 224-word spill from being
        // expanded into registers when all sixteen 32K blocks are occupied.
        EG_LOGIC_BRAM #(
            .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),
            .ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),
            .DATA_DEPTH_A(512),.DATA_DEPTH_B(512),
            .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
            .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
            .RESETMODE("SYNC"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
            .INIT_FILE("NONE"),.FILL_ALL("NONE"),.IMPLEMENT("9K")
        ) tail_memory (
            .doa(),.dob(tail_q),.dia(write_data),.dib(16'd0),
            .cea(write_enable && write_address>=4096 && write_address<DEPTH),
            .ocea(1'b1),.clka(write_clk),.wea(1'b1),.rsta(1'b0),
            .ceb(read_enable && read_address>=4096 && read_address<DEPTH),
            .oceb(1'b1),.clkb(read_clk),.web(1'b0),.rstb(1'b0),
            .bea(1'b1),.beb(1'b1),.addra(write_address[8:0]),.addrb(read_address[8:0])
        );
        always @(posedge read_clk) if(read_enable) begin
            tail_select<=read_address>=4096;
        end
        assign read_data=tail_select ? tail_q : main_q;
    end else begin: general_depth
        bram32k_sdp #(.DEPTH(DEPTH),.ADDR_BITS(ADDR_BITS)) memory(
            .write_clk(write_clk),.write_enable(write_enable),.write_address(write_address),.write_data(write_data),
            .read_clk(read_clk),.read_enable(read_enable),.read_address(read_address),.read_data(read_data));
    end endgenerate
endmodule
