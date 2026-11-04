`timescale 1ns/1ps
module tb_rgb332_scene;
    reg clk=0,rst=1,hs=1,vs=1,de=0,active=1,moving=1;
    reg [23:0] rgb=0;
    reg [9:0] left=54,top=47;reg [7:0] size=41;reg [1:0] border=3;
    wire oh,ov,od;wire [23:0] out;
    reg [23:0] expected[0:2];reg [2:0] ds=0,hq=7,vq=7;
    integer mode,row,col,j,count,ux,uy,lx,ly,slot,origin_x,origin_y;
    integer nl,nt,nw,nh,nb,gain;reg [23:0] target,base;
    always #7.6923075 clk=~clk;
    thumbnail_scene #(.MODE_XGA(1)) dut(.write_clk(clk),.write_enable(1'b0),.write_slot(4'd0),
        .pixel_x(16'd0),.pixel_y(16'd0),.pixel_rgb(24'd0),.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .browse(1'b0),.focus(4'd4),.ready(9'd0),.available(9'd511),.failed(9'd0),
        .active(active),.moving(moving),.target(4'd4),.left(left),.top(top),.size(size),
        .explicit_width(10'd0),.explicit_height(10'd0),.border_size(border),.dim(3'd4),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(out));
    function [23:0] pattern(input integer x,y);pattern={8'(x),8'(y),8'(x^y)};endfunction
    function [23:0] shade(input [23:0] p,input integer g);integer r,b,c;begin
        r=p[23:16]*g/256;b=p[15:8]*g/256;c=p[7:0]*g/256;shade={8'(r),8'(b),8'(c)};
    end endfunction
    function [23:0] reference(input integer x,y);integer ix,iy,local_x,local_y,c,r,s,g;reg [23:0] bg;begin
        ix=x*5/8;iy=y*5/8;c=ix>=424 ? 2 : ix>=240 ? 1 : 0;r=iy>=336 ? 2 : iy>=192 ? 1 : 0;
        local_x=ix-(56+c*184);local_y=iy-(48+r*144);s=r*3+c;
        bg=24'h182024;
        if(local_x>=0 && local_x<160 && local_y>=0 && local_y<120) begin
            bg=24'h486068;
            if(local_x<3 || local_x>=157 || local_y<3 || local_y>=117) bg=s==4 ? 24'hffd050 : 24'h849498;
        end
        if(ix>=240 && ix<400 && iy>=192 && iy<312) bg=24'h182024;
        g=(x>=nl+8 && x<nl+8+nw && y>=nt+10 && y<nt+10+nh) ? 32 : 128;
        reference=shade(bg,g);
        if(x>=nl && x<nl+nw && y>=nt && y<nt+nh)
            reference=nb!=0 && (x<nl+nb || x>=nl+nw-nb || y<nt+nb || y>=nt+nh-nb) ? 24'hffd050 : pattern(x,y);
        if(!moving) reference=pattern(x,y);
    end endfunction
    initial begin
        repeat(5) @(negedge clk);rst=0;repeat(10) @(negedge clk);
        for(mode=0;mode<3;mode=mode+1) begin
            if(mode==1) begin left=0;top=0;size=160;border=0;end
            if(mode==2) begin active=0;moving=0;end
            nl=(left*8+4)/5;nt=(top*8+4)/5;nw=((size*4*8)/5)/4*4;nh=size*3*8/5;nb=(border*8+4)/5;
            vs=0;repeat(10) @(negedge clk);vs=1;repeat(10) @(negedge clk);
            ds=0;hq=7;vq=7;count=0;for(j=0;j<3;j=j+1) expected[j]=0;
            for(row=0;row<768;row=row+1) begin
                for(col=0;col<1040;col=col+1) begin
                    @(negedge clk);de=col<1024;hs=!(col>=1026 && col<1030);rgb=pattern(col,row);
                    target=de ? reference(col,row) : 0;
                    @(posedge clk);for(j=2;j>0;j=j-1) expected[j]=expected[j-1];
                    expected[0]=target;ds={ds[1:0],de};hq={hq[1:0],hs};vq={vq[1:0],vs};#1;
                    if(out!==expected[2] || od!==ds[2] || oh!==hq[2] || ov!==vq[2])
                        $fatal(1,"native scene mode%0d (%0d,%0d) RGB%h expected%h DE%b/%b",mode,col,row,out,expected[2],od,ds[2]);
                    if(od) count=count+1;
                end
            end
            if(count!=786432) $fatal(1,"native scene frame count %0d",count);
        end
        $display("PASS native scene: three complete XGA frames, nine grid regions, exact card rectangle/border/shadow/dimming, full-screen independent pixels, bypass and three-clock RGB/sync alignment");
        $finish;
    end
    initial begin #60000000;$fatal(1,"scene timeout");end
endmodule
