`timescale 1ns/1ps
module tb_xga9;
    reg c=0,p=0,r=1;
    always @(posedge p) c<=~c;
    always #7.6923075 p=~p;
    wire hs,vs,de,toggle,req;
    player_xga_source timing(c,r,req,req,hs,vs,de,toggle);
    reg [79:0] dp=0,vp=0;
    reg [23:0] data[0:79];
    integer sx=0,sy=0,i;
    reg ld=0,lv=0;
    function [23:0] color(input integer x,input integer y);
        color={x[7:3],x[7:5],y[7:2],y[7:6],x[9:8],y[8],2'b10,x[9:8],y[8]};
    endfunction
    always @(posedge c) begin
        dp<={dp[78:0],de};vp<={vp[78:0],vs};data[0]<=color(sx,sy);
        for(i=1;i<80;i=i+1) data[i]<=data[i-1];
        if(r) begin sx<=0;sy<=0;ld<=0;lv<=0;dp<=0;vp<=0;end
        else begin
            ld<=de;lv<=vs;
            if(lv && !vs) begin sx<=0;sy<=0;end
            else begin if(de) sx<=sx+1;else sx<=0;if(ld&&!de) sy<=sy+1;end
        end
    end
    wire oh,ov,od;
    wire [23:0] rgb;
    player_xga_scaler scaler(c,r,vp[79],dp[79],data[79],toggle,p,r,oh,ov,od,rgb);
    integer x=0,y=0,frames=0,pixels=0,line_clocks=0,frame_clocks=0,last_frame=0;
    reg old_de=0,old_vs=0,old_hs=0;
    always @(negedge p) if(!r) begin
        frame_clocks=frame_clocks+1;line_clocks=line_clocks+1;
        if(old_vs && !ov) begin
            if(frames>0) begin
                if(pixels!=786432 || y!=768) $fatal(1,"frame shape pixels=%d lines=%d",pixels,y);
                if(frames>1 && frame_clocks-last_frame!=1083264) $fatal(1,"frame total");
            end
            frames=frames+1;last_frame=frame_clocks;pixels=0;y=0;
            if(frames==3) begin $display("PASS XGA 1024x768, every pixel matches floor(5*x/8), floor(5*y/8), 1344x806 totals");$finish;end
        end
        if(od) begin
            if(rgb!==color(x*5/8,y*5/8)) $fatal(1,"pixel x=%d y=%d got=%h expected=%h",x,y,rgb,color(x*5/8,y*5/8));
            x=x+1;pixels=pixels+1;
        end
        if(old_de&&!od) begin if(x!=1024)$fatal(1,"line width %d",x);x=0;y=y+1;end
        if(old_hs&&!oh) begin if(frames>1 && line_clocks!=1344)$fatal(1,"line total %d",line_clocks);line_clocks=0;end
        old_de=od;old_vs=ov;old_hs=oh;
    end
    initial begin #201;r=0;#60000000;$fatal(1,"timeout");end
endmodule
