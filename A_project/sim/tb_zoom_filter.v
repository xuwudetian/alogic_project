`timescale 1ns/1ps
module tb_zoom_filter;
    reg clk=0,rst=1,enable=1,valid=0;
    reg [7:0] size=40;
    reg [31:0] data=0;
    wire ov;wire [31:0] od;
    integer s,r,w,k,outputs=0,total=0,wi,byte_n,pixel_n,sx,sy;
    reg [31:0] expected;
    reg [23:0] p;
    always #5 clk=~clk;
    frame_zoom_filter dut(.clk(clk),.rst(rst),.enable(enable),.size(size),
        .target_width(10'd0),.valid(valid),.data(data),.out_valid(ov),.out_data(od));
    function [23:0] color(input integer x,input integer y);
        color={8'(x),8'(y*43+x/3),8'(x^y*11)};
    endfunction
    function [31:0] word_at(input integer xword,input integer row);
        integer j,b;reg [23:0] c;
        begin word_at=0;
            for(j=0;j<4;j=j+1) begin b=xword*4+j;c=color(b/3,row);word_at[31-j*8 -: 8]=c>>(8*(2-b%3));end
        end
    endfunction
    always @(posedge clk) if(!rst && ov) begin
        expected=0;
        for(k=0;k<4;k=k+1) begin
            byte_n=outputs*4+k;pixel_n=byte_n/3;
            sx=((pixel_n%(size*4))*640+size*4-1)/(size*4);
            sy=pixel_n/(size*4);p=color(sx,sy);
            expected[31-k*8 -: 8]=p>>(8*(2-byte_n%3));
        end
        if(od!==expected) $fatal(1,"zoom filter size%0d output%0d got%h expected%h",size,outputs,od,expected);
        outputs=outputs+1;total=total+1;
    end
    initial begin
        for(s=40;s<=160;s=s+1) begin
            @(negedge clk);rst=1;size=s;valid=0;repeat(3) @(negedge clk);
            rst=0;outputs=0;
            for(r=0;r<3;r=r+1) for(w=0;w<480;w=w+1) begin
                @(negedge clk);valid=1;data=word_at(w,r);
                if(w%37==36) begin @(negedge clk);valid=0;repeat(2) @(negedge clk);end
            end
            @(negedge clk);valid=0;repeat(5) @(negedge clk);
            if(outputs!=size*9 || dut.bits!=0) $fatal(1,"zoom filter length/residue size%0d count%0d bits%0d",size,outputs,dut.bits);
        end
        $display("PASS RGB888 zoom filter: all 121 widths 160..640, independent nearest-pixel byte oracle, consecutive rows, input stalls, exact output lengths (%0d words)",total);$finish;
    end
endmodule
