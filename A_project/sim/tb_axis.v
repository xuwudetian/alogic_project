`timescale 1ns/1ps
module tb_axis;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,vs=0,de=0;
    reg [23:0] rgb=0;
    wire user,valid,last;
    wire [23:0] data;
    integer frame,line,pixel,total=0,line_ends=0,frame_starts=0;
    video_rgb_to_axis_640x480 dut(
        .I_clk(clk),.I_rst(rst),.I_vs(vs),.I_de(de),.I_rgb(rgb),
        .O_video_user(user),.O_video_valid(valid),.O_video_last(last),.O_video_data(data));

    task blank;
        input integer cycles;
        integer n;
        begin
            for(n=0;n<cycles;n=n+1) begin
                @(negedge clk);de=0;rgb=0;
                @(posedge clk);#1;
                if(valid || last || user) $fatal(1,"AXIS sideband asserted during blanking");
            end
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        for(frame=0;frame<2;frame=frame+1) begin
            @(negedge clk);vs=1;
            blank(4);
            @(negedge clk);vs=0;
            blank(4);
            for(line=0;line<480;line=line+1) begin
                for(pixel=0;pixel<640;pixel=pixel+1) begin
                    @(negedge clk);de=1;rgb={frame[0],line[8:0],pixel[9:0],4'ha};
                    @(posedge clk);#1;
                    if(!valid || data!==rgb) $fatal(1,"AXIS pixel mismatch at %0d,%0d",line,pixel);
                    if(last !== (pixel==639)) $fatal(1,"AXIS TLAST mismatch at frame=%0d line=%0d pixel=%0d: got %b",frame,line,pixel,last);
                    if(user !== (line==0 && pixel==0)) $fatal(1,"AXIS SOF mismatch");
                    total=total+1;line_ends=line_ends+last;frame_starts=frame_starts+user;
                end
                blank(160);
            end
        end
        if(total!=614400 || line_ends!=960 || frame_starts!=2) $fatal(1,"AXIS frame totals mismatch");
        $display("PASS AXIS: 2 frames, 614400 RGB pixels, 960 correct line ends, 2 frame starts, blanking");
        $finish;
    end
    initial begin #10000000;$fatal(1,"AXIS test timeout");end
endmodule
