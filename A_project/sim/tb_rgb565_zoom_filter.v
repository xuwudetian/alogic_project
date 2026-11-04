`timescale 1ns/1ps
module tb_rgb565_zoom_filter;
    reg clk=0,rst=1,enable=1,valid=0;
    reg [7:0] size=40;
    reg [31:0] data=0;
    wire ov;wire [31:0] od;
    integer s,r,w,k,outputs=0,total=0,wi,byte_n,pixel_n,sx,sy;
    reg [31:0] expected;
    reg [15:0] p;
    always #5 clk=~clk;
    frame_zoom_filter_rgb565 dut(.clk(clk),.rst(rst),.enable(enable),.size(size),
        .target_width(10'd0),.valid(valid),.data(data),.out_valid(ov),.out_data(od));
    function [15:0] color(input integer x,input integer y);
        color=((x&255)/8)*2048+(((y*43+x/3)&255)/4)*32+(((x^y*11)&255)/8);
    endfunction
    function [31:0] word_at(input integer xword,input integer row);
        word_at={color(xword*2,row),color(xword*2+1,row)};
    endfunction
    always @(posedge clk) if(!rst && ov) begin
        expected=0;
        for(k=0;k<2;k=k+1) begin
            pixel_n=outputs*2+k;
            sx=((pixel_n%(size*4))*640+size*4-1)/(size*4);
            sy=pixel_n/(size*4);p=color(sx,sy);
            expected[31-k*16 -: 16]=p;
        end
        if(od!==expected) $fatal(1,"zoom filter size%0d output%0d got%h expected%h",size,outputs,od,expected);
        outputs=outputs+1;total=total+1;
    end
    initial begin
        for(s=40;s<=160;s=s+1) begin
            @(negedge clk);rst=1;size=s;valid=0;repeat(3) @(negedge clk);
            rst=0;outputs=0;
            for(r=0;r<3;r=r+1) for(w=0;w<320;w=w+1) begin
                @(negedge clk);valid=1;data=word_at(w,r);
                if(w%37==36) begin @(negedge clk);valid=0;repeat(2) @(negedge clk);end
            end
            @(negedge clk);valid=0;repeat(5) @(negedge clk);
            if(outputs!=size*6 || dut.pending!=0) $fatal(1,"zoom filter length/residue size%0d count%0d bits%0d",size,outputs,dut.pending);
        end
        $display("PASS RGB565 zoom filter: all 121 widths 160..640, independent nearest-pixel byte oracle, consecutive rows, input stalls, exact output lengths (%0d words)",total);$finish;
    end
endmodule
