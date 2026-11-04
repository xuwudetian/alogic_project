`timescale 1ns/1ps
// Independent known glyph and full-coordinate latency checks, no hierarchy forces.
module tb_chinese_pixels;
    reg clk=0,rst=1;reg [9:0] x=0;reg [8:0] y=0;reg [3:0] modes=0;
    reg panel=0,alarm=0,directory=0,image_valid=1,browse=0;
    reg [39:0] resolution=40'h0192001080;
    reg [1:0] run_mode=2;
    wire cover_on;wire [23:0] color;
    reg [23:0] expected[0:4];reg [4:0] covers=0;
    integer i,xx,yy,phase,count=0;reg [15:0] bits;reg hit,ref_cover;reg [23:0] ref_color;
    always #5 clk=~clk;
    player_status_osd dut(.clk(clk),.rst(rst),.x(x),.y(y),.brightness(9'sd0),
        .bright_digits(12'h000),.contrast_digits(12'h128),.picture(3'd5),.scaled(1'b1),
        .auto_play(1'b1),.run_mode(run_mode),.error_code(8'h37),.audio_status(8'h53),
        .state_code(4'd8),.volume(4'd4),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(modes),
        .directory(directory),.status_panel(panel),.alarm(alarm),.browse(browse),
        .image_valid(image_valid),.source_resolution(resolution),
        .debug_status(60'h123456789abcd),.time_digits(24'h012345),.cover_on(cover_on),.color(color));
    function [15:0] auto_row;input [3:0] r;begin case(r)
        0,1:auto_row=16'h0300;2,3,6,9,12:auto_row=16'h1ff8;
        4,5,7,8,10,11,13:auto_row=16'h1008;default:auto_row=0;
    endcase end endfunction
    function [7:0] resolution_label;input integer n;begin case(n)
        0:resolution_label=102;1:resolution_label=103;2:resolution_label=159;
        3:resolution_label=160;default:resolution_label=161;
    endcase end endfunction
    function [7:0] picture_label;input integer n;begin case(n)
        0:picture_label=103;1:picture_label=162;2:picture_label=163;default:picture_label=164;
    endcase end endfunction
    task check_cell(input integer sx,sy,input [7:0] wanted,input [3:0] wanted_column);begin
        @(negedge clk);x=sx;y=sy;#1;
        if(dut.code!==wanted || dut.column!==wanted_column || !dut.text_on)
            $fatal(1,"OSD label or value mismatch x=%0d y=%0d code=%0d column=%0d",sx,sy,dut.code,dut.column);
    end endtask
    initial begin
        for(i=0;i<5;i=i+1) expected[i]=0;
        repeat(4) @(negedge clk);rst=0;
        for(phase=0;phase<4;phase=phase+1) begin
            modes=phase==1 ? 1 : 0;alarm=phase==2;directory=phase==3;
            for(yy=0;yy<28;yy=yy+1) for(xx=0;xx<32;xx=xx+1) begin
                @(negedge clk);x=xx;y=yy;
                ref_cover=phase==0 && yy<24;ref_color=yy==23 ? 24'h404848 : 24'h606060;
                bits=auto_row(yy-4);
                if(xx>=8 && xx<24 && yy>=4 && yy<20 && bits[15-(xx-8)]) ref_color=24'hffffff;
                @(posedge clk);
                for(i=4;i>0;i=i-1) expected[i]=expected[i-1];
                expected[0]=ref_color;covers={covers[3:0],ref_cover};count=count+1;#1;
                if(count>5 && cover_on!==covers[4]) $fatal(1,"Chinese cover latency");
                if(count>5 && covers[4] && xx>=5 && xx<28 && color!==expected[4])
                    $fatal(1,"Chinese glyph pixel/half alignment x=%0d y=%0d got=%h expected=%h",xx,yy,color,expected[4]);
            end
        end
        @(negedge clk);directory=0;alarm=0;panel=1;modes=9;x=184;y=176;
        repeat(8) @(negedge clk);
        if(!cover_on || dut.base!=24'ha5dfd9) $fatal(1,"editing not visible with SW1 hidden");
        image_valid=1;modes=0;
        for(xx=0;xx<80;xx=xx+1) begin
            check_cell(424+xx,4,resolution_label(xx/16),xx%16);
        end
        for(xx=0;xx<64;xx=xx+1) check_cell(184+xx,316,picture_label(xx/16),xx%16);
        check_cell(256,316,22,0); // Picture index 5 displays as picture 6.
        check_cell(184,144,165,0);check_cell(200,144,166,0);
        check_cell(344,316,120,0);check_cell(360,316,121,0);check_cell(440,316,122,0);
        check_cell(184,296,111,0);check_cell(200,296,158,0);
        check_cell(432,296,17,0);check_cell(440,296,15,0);check_cell(448,296,20,0);
        for(xx=0;xx<64;xx=xx+1) begin
            case(xx/16) 0:i=196;1:i=121;2:i=100;3:i=101;endcase
            check_cell(184+xx,276,i,xx%16);
        end
        for(phase=0;phase<4;phase=phase+1) begin
            run_mode=phase%2==0 ? 2 : 1;browse=phase>=2;
            for(xx=0;xx<32;xx=xx+1) begin
                if(run_mode==2) case(xx/8) 0:i=33;1:i=53;2:i=52;3:i=47;endcase
                else case(xx/8) 0:i=0;1:i=45;2:i=33;3:i=46;endcase
                check_cell(424+xx,276,i,xx%8);
                check_cell(8+xx,4,xx<16 ? (run_mode==1 ? 106 : 108) : 107,xx%16);
            end
            for(xx=40;xx<424;xx=xx+1) check_cell(xx,4,0,xx%8);
        end
        browse=0;
        // Full-width dimensions remain in the header only.
        resolution=40'h6553565535;
        for(xx=0;xx<11;xx=xx+1) begin
            case(xx)
                0,6:i=22;1,2,4,7,8,10:i=21;3,9:i=19;default:i=56;
            endcase
            check_cell(512+xx*8,4,i,0);
        end
        image_valid=0;
        for(xx=0;xx<11;xx=xx+1) begin
            check_cell(512+xx*8,4,xx==5 ? 56 : 13,0);
        end
        // The removed preview footer must not leave either text or a gray strip.
        @(negedge clk);browse=1;panel=0;directory=0;alarm=0;x=176;y=400;
        repeat(8) @(negedge clk);
        for(phase=0;phase<2;phase=phase+1) begin
            modes=phase;
            for(yy=399;yy<=424;yy=yy+1) for(xx=175;xx<=464;xx=xx+1) begin
                @(negedge clk);x=xx;y=yy;#1;
                if(dut.cover0 || dut.text_on || cover_on)
                    $fatal(1,"preview footer still covers x=%0d y=%0d SW1=%0d",xx,yy,phase);
            end
        end
        $display("PASS Chinese pixels: known AUTO glyph, halves, five-stage alignment, hide/menu/alarm, settings AUTO/MAN, Chinese header modes, removed header parameters, retained header dimensions, spaced picture/scale rows, transparent footer");$finish;
    end
endmodule
