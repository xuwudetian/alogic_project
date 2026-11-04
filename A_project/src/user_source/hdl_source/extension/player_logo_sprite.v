`timescale 1ns/1ps
// 官方例程 Logo 的 32x24 字模，放大两倍；官网深蓝主体、红色横纹，背景透明。
// 共用字幕层坐标和流水，只生成最高优先级掩码，不增加 RGB 延迟链和扫描计数器。
module player_logo_sprite(
    input clk,input rst,input frame_tick,input [9:0] x,input [8:0] y,
    output pixel_on,output [23:0] pixel_color,input centered
);
    reg [9:0] logo_x;
    reg [8:0] logo_y;
    reg frame_div,started;
    reg left,up,steep;
    reg [7:0] random_state;
    // 起点和两端均为偶数，步长固定为 1/2，必然精确到达边界，无需越界反射减法器。
    wire move_left=logo_x!=0 && (left || logo_x==576);
    wire move_up=logo_y!=0 && (up || logo_y==432);
    wire [9:0] delta_x=move_left ? (steep ? 10'h3ff : 10'h3fe) : (steep ? 10'd1 : 10'd2);
    wire [8:0] delta_y=move_up ? (steep ? 9'h1fe : 9'h1ff) : (steep ? 9'd2 : 9'd1);
    wire [9:0] relative_x=x-(centered ? 10'd288 : logo_x);
    wire [8:0] relative_y=y-(centered ? 9'd152 : logo_y);
    // 官网 logo.svg：主体 #1C2C4E，右侧横纹 #ED1B23。原字模轮廓保持不变。
    // 在原字模有效点上与横纹掩码逐点等价；斜边判定省去第二组字模选择器。
    wire [4:0] red_boundary={1'b0,relative_y[5:2]}+(relative_y[5:4]!=0 ? 5'd11 : 5'd12);
    assign pixel_color=relative_x[5:1]>=red_boundary ? 24'hed1b23 : 24'h1c2c4e;
    wire [31:0] row_bits=logo_row(relative_y[5:1]);
    assign pixel_on=relative_x<64 && relative_y<48 && row_bits[31-relative_x[5:1]];

    // 来源：官方 lab_ex5_i2s/doc/TF卡图片/logo_640x480_24bit_不翻转.bmp。
    function [31:0] logo_row;
        input [4:0] line;
        begin case(line)
            0:logo_row=32'h000fffff; 1:logo_row=32'h002fffff;
            2:logo_row=32'h00300000; 3:logo_row=32'h0077fffe;
            4:logo_row=32'h007bfffe; 5:logo_row=32'h00780000;
            6:logo_row=32'h00f9fffc; 7:logo_row=32'h00fc0000;
            8:logo_row=32'h01fc0000; 9:logo_row=32'h01fefff0;
            10:logo_row=32'h03fe0000; 11:logo_row=32'h03ff0000;
            12:logo_row=32'h07df7fe0; 13:logo_row=32'h07cf8000;
            14:logo_row=32'h078fbfc0; 15:logo_row=32'h0f87bfc0;
            16:logo_row=32'h0f07c000; 17:logo_row=32'h1f03df80;
            18:logo_row=32'h1e03ef00; 19:logo_row=32'h3e03e000;
            20:logo_row=32'h3ff1ff00; 21:logo_row=32'h3ff9f000;
            22:logo_row=32'h7ff8f800; 23:logo_row=32'h7ffcf800;
            default:logo_row=0;
        endcase end
    endfunction

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            logo_x<=96;logo_y<=72;
            frame_div<=0;started<=0;left<=0;up<=0;steep<=0;random_state<=8'hb7;
        end else begin
            random_state<={random_state[6:0],random_state[7]^random_state[5]^random_state[4]^random_state[3]};
            // 首帧选择伪随机方向；两帧移动一次，仅在帧消隐期改变位置。
            if(frame_tick && !centered) begin
                frame_div<=!frame_div;
                if(!started) begin
                    started<=1;left<=random_state[0];up<=random_state[1];steep<=random_state[2];
                end else if(frame_div) begin
                    // 补码增量共用加法器；同时碰角时两轴都反向。
                    logo_x<=logo_x+delta_x;left<=move_left;
                    logo_y<=logo_y+delta_y;up<=move_up;
                end
            end
        end
    end
endmodule
