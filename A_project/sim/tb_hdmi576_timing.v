`timescale 1ns/1ps
module tb_hdmi576_timing;
    reg clk=0,rst=1;
    wire hs,vs,de,u,valid,last;
    wire [7:0] r,g,b;
    wire [23:0] data;
    integer cycle=0,frame_start=-1,line_start=-1,hs_start=-1,vs_start=-1;
    integer frames=0,pixels=0,rows=0,ends=0,starts=0,row_pixels=0;
    reg old_hs=0,old_vs=0,old_de=0;
    reg armed=0;reg [23:0] expected_rgb;
    always #18.5185 clk=~clk;
    color_bar timing(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb_r(r),.rgb_g(g),.rgb_b(b));
    video_rgb_to_axis_640x480 #(.WIDTH(720)) axis(.I_clk(clk),.I_rst(rst),.I_vs(vs),.I_de(de),.I_rgb({r,g,b}),
      .O_video_user(u),.O_video_valid(valid),.O_video_last(last),.O_video_data(data));
    always @(posedge clk) begin
        if(!rst) begin
            if(armed) begin
                if(de) begin
                    if(!old_de) begin rows=rows+1;row_pixels=0;end
                    pixels=pixels+1;row_pixels=row_pixels+1;
                end
                if(!de && old_de && row_pixels!=720) $fatal(1,"active line length %0d",row_pixels);
                if(old_hs && !hs) begin
                    if(line_start>=0 && cycle-line_start!=864) $fatal(1,"line total %0d",cycle-line_start);
                    line_start=cycle;hs_start=cycle;
                end
                if(!old_hs && hs && hs_start>=0 && cycle-hs_start!=64) $fatal(1,"HS width %0d",cycle-hs_start);
                if(!old_vs && vs && vs_start>=0 && cycle-vs_start!=4320) $fatal(1,"VS width %0d",cycle-vs_start);
            end
            if(old_vs && !vs) begin
                if(armed) begin
                    if(cycle-frame_start!=540000 || pixels!=414720 || rows!=576 || ends!=576 || starts!=1)
                        $fatal(1,"frame totals clocks%0d pixels%0d rows%0d ends%0d starts%0d",cycle-frame_start,pixels,rows,ends,starts);
                    frames=frames+1;
                    if(frames==2) begin $display("PASS 576p50 timing: 2 complete 864x625 frames, 720x576 active, negative HS64/VS5, AXIS720 SOF/TLAST/data");$finish;end
                end
                armed=1;frame_start=cycle;vs_start=cycle;pixels=0;rows=0;ends=0;starts=0;
            end
            old_hs=hs;old_vs=vs;old_de=de;expected_rgb={r,g,b};
            #1;
            if(valid!==old_de) $fatal(1,"AXIS valid pipeline");
            if(valid && data!==expected_rgb) $fatal(1,"AXIS data pipeline");
            if(armed) begin
                if(valid) begin
                    if(last!==(row_pixels==720)) $fatal(1,"AXIS end at pixel %0d",row_pixels);
                    if(u!==(rows==1 && row_pixels==1)) $fatal(1,"AXIS frame start");
                end else if(last || u) $fatal(1,"AXIS sideband in blanking");
                ends=ends+last;starts=starts+u;
            end
            cycle=cycle+1;
        end
    end
    initial begin repeat(5) @(negedge clk);rst=0;end
    initial begin #70000000;$fatal(1,"timing timeout");end
endmodule
