`timescale 1ns/1ps
// Legacy module name retained for project-file compatibility. Parameters allow
// the native 1024x768 raster without changing the legacy test configuration.
module video_timing_640x480 #(
    parameter H_ACTIVE=640,H_FP=16,H_SYNC=96,H_BP=48,
    parameter V_ACTIVE=480,V_FP=10,V_SYNC=2,V_BP=33
)(
    input clk,input rst_n,output hs,output vs,output de,
    output [$clog2(H_ACTIVE)-1:0] x,output [$clog2(V_ACTIVE)-1:0] y,output frame_start);
    localparam H_TOTAL=H_ACTIVE+H_FP+H_SYNC+H_BP;
    localparam V_TOTAL=V_ACTIVE+V_FP+V_SYNC+V_BP;
    reg [$clog2(H_TOTAL)-1:0] h;
    reg [$clog2(V_TOTAL)-1:0] v;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin h<=0;v<=0;end
        else if(h==H_TOTAL-1) begin
            h<=0;
            if(v==V_TOTAL-1) v<=0;else v<=v+1'b1;
        end else h<=h+1'b1;
    end
    assign hs=!(h<H_SYNC);
    assign vs=!(v<V_SYNC);
    assign de=(h>=H_SYNC+H_BP && h<H_SYNC+H_BP+H_ACTIVE &&
               v>=V_SYNC+V_BP && v<V_SYNC+V_BP+V_ACTIVE);
    assign x=de ? h-(H_SYNC+H_BP) : 0;
    assign y=de ? v-(V_SYNC+V_BP) : 0;
    assign frame_start=(h==0 && v==0);
endmodule
