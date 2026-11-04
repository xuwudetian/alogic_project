`timescale 1ns/1ps
module tb_thumbnail;
    reg clk=0,wclk=0,rst=1,we=0,hs=1,vs=1,de=0,browse=1;
    reg [3:0] slot=0,focus=8;
    reg [15:0] px=0,py=0;
    reg [23:0] wrgb=0;
    reg [8:0] ready=511,available=511,failed=0;
    wire oh,ov,od;
    wire [23:0] rgb;
    integer s,x,y,seen=0,col,lx,ly,index;
    reg [23:0] expected;
    always #5 clk=~clk;
    always #7 wclk=~wclk;
    thumbnail_video dut(wclk,we,slot,px,py,wrgb,clk,rst,hs,vs,de,24'h123456,
        browse,focus,ready,available,oh,ov,od,rgb,failed);
    function [23:0] color(input integer n);
        case(n)
            0:color=24'hff0000;1:color=24'h00ff00;2:color=24'h0000ff;
            3:color=24'hffffff;4:color=24'hffff00;5:color=24'h00ffff;6:color=24'hff00ff;7:color=24'h000000;default:color=24'h7bef7b;
        endcase
    endfunction
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(s=0;s<9;s=s+1) begin
            slot=s;wrgb=s==8 ? 24'h78ec78 : color(s);
            for(y=0;y<48;y=y+1) for(x=0;x<64;x=x+1) begin
                @(negedge wclk);we=1;px=x*10;py=y*10;
            end
            @(negedge wclk);we=0;
        end
        @(negedge clk);vs=0;repeat(3) @(negedge clk);vs=1;
        for(y=0;y<480;y=y+1) begin
            for(x=0;x<640;x=x+1) begin
                @(negedge clk);de=1;@(posedge clk);#1;
                col=x>=424 ? 2 : x>=240 ? 1 : 0;
                lx=x-(56+col*184);ly=y-(y>=336 ? 336 : y>=192 ? 192 : 48);index=(y>=336 ? 6 : y>=192 ? 3 : 0)+col;
                expected=24'h182024;
                if(lx>=0 && lx<160 && ly>=0 && ly<120) begin
                    expected=color(index);
                    if(lx<3 || lx>=157 || ly<3 || ly>=117) expected=index==8 ? 24'hffd050 : 24'h849498;
                    if(lx==16 && ly==10) seen=seen+1;
                end
                if(rgb!==expected || !od) $fatal(1,"3x3 pixel/bank/outline x%0d y%0d got%h expected%h",x,y,rgb,expected);
            end
            @(negedge clk);de=0;repeat(8) @(negedge clk);
        end
        ready=0;available=3;failed=1;
        vs=0;repeat(3) @(negedge clk);vs=1;
        for(y=0;y<360;y=y+1) begin
            for(x=0;x<640;x=x+1) begin
                @(negedge clk);de=1;@(posedge clk);#1;
                if(x==72 && y==58 && rgb!==24'ha02020) $fatal(1,"failed preview has no red feedback");
                if(x==136 && y==98 && rgb!==24'hffffff) $fatal(1,"failed preview lacks exclamation mark");
                if(x==256 && y==58 && rgb!==24'h486068) $fatal(1,"pending preview feedback");
                if(x==440 && y==346 && rgb!==24'h282c30) $fatal(1,"absent preview feedback");
            end
            @(negedge clk);de=0;repeat(8) @(negedge clk);
        end
        browse=0;de=1;repeat(3) @(negedge clk);
        if(rgb!==24'h123456 || seen!=9) $fatal(1,"normal video bypass");
        $display("PASS thumbnails: nine RGB565 caches, 3x3 layout checked every pixel, 32K bank boundaries, focus/missing/failure and bypass");
        $finish;
    end
endmodule
