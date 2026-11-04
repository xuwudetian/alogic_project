`timescale 1ns/1ps
module tb_rgb332_filter;
    reg clk=0,rst=1,enable=1,valid=0;
    reg [10:0] width=256;
    reg [31:0] data=0;
    wire ov;
    wire [31:0] od;
    integer w,i,j,n,expected_x,checked=0;
    reg [7:0] expected;
    always #12.5 clk=~clk;
    frame_zoom_filter_rgb332 dut(clk,rst,enable,width,valid,data,ov,od);
    function [7:0] color(input integer x);
        color=(x*17)^(x/7);
    endfunction
    always @(posedge clk) if(!rst && ov) begin
        for(j=0;j<4;j=j+1) begin
            expected_x=(n*1024+width-1)/width;
            expected=color(expected_x);
            if(od[31-j*8 -: 8]!==expected) $fatal(1,"RGB332 filter width%0d pixel%0d got%h expected%h source%0d",width,n,od[31-j*8 -: 8],expected,expected_x);
            n=n+1;checked=checked+1;
        end
    end
    initial begin
        for(w=256;w<=1024;w=w+4) begin
            @(negedge clk);rst=1;valid=0;width=w;n=0;
            repeat(2) @(negedge clk);rst=0;
            for(i=0;i<1024;i=i+4) begin
                @(negedge clk);valid=1;data={color(i),color(i+1),color(i+2),color(i+3)};
                if(i%28==0) begin @(negedge clk);valid=0;repeat(2) @(negedge clk);end
            end
            @(negedge clk);valid=0;repeat(3) @(negedge clk);
            if(n!=w || dut.held!=0) $fatal(1,"row residue/count width%0d count%0d",w,n);
        end
        $display("PASS RGB332 zoom: all 193 word-aligned widths 256..1024, %0d golden pixels, random input gaps, no row residue",checked);$finish;
    end
endmodule
