`timescale 1ns/1ps
module tb_hdmi576_zoom;
    reg clk=0,rst=1,frame=0,fullscreen=0,pause=0;
    wire [4:0] phase;wire moving;wire [7:0] size;
    wire [9:0] left,top,width,height;
    integer i,old_phase,old_w,old_h,old_t;
    always #5 clk=~clk;
    player_picture_zoom #(.MODE_576(1)) dut(.clk(clk),.rst(rst),.frame_tick(frame),.fullscreen(fullscreen),.pause(pause),
        .phase(phase),.moving(moving),.size(size),.left(left),.top(top),.width(width),.height(height));
    task tick;begin @(negedge clk);frame=1;@(negedge clk);frame=0;end endtask
    task geometry;begin
        if(width<640 || width>720 || height<480 || height>576 || left*2+width!=720 || top+height>576 || top>32 || width[0])
            $fatal(1,"bounds p%0d %0dx%0d @%0d,%0d",phase,width,height,left,top);
    end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(phase!=0 || width!=640 || height!=480 || left!=40 || top!=32 || moving) $fatal(1,"640x480 compact endpoint");
        fullscreen=1;
        for(i=0;i<16;i=i+1) begin
            old_phase=phase;old_w=width;old_h=height;old_t=top;
            repeat(7) @(negedge clk);
            if(phase!=old_phase || width!=old_w || height!=old_h || top!=old_t) $fatal(1,"mid-frame geometry changed");
            tick;geometry;
            if(phase!=i+1 || width<old_w || height<old_h || top>old_t || width-old_w>8) $fatal(1,"non-monotone expansion");
        end
        if(width!=720 || height!=576 || left!=0 || top!=0 || moving) $fatal(1,"720x576 full endpoint");
        repeat(5) tick;if(phase!=16) $fatal(1,"overshoot");
        fullscreen=0;repeat(7) tick;old_phase=phase;old_w=width;old_h=height;old_t=top;pause=1;
        repeat(5) tick;fullscreen=1;repeat(3) tick;
        if(phase!=old_phase || width!=old_w || height!=old_h || top!=old_t) $fatal(1,"pause changed geometry");
        pause=0;tick;if(phase!=old_phase+1 || width<old_w || width-old_w>8) $fatal(1,"reverse jump");
        fullscreen=0;while(phase!=0) begin old_w=width;old_h=height;tick;geometry;if(width>old_w || height>old_h) $fatal(1,"shrink reversed");end
        if(width!=640 || height!=480 || left!=40 || top!=32) $fatal(1,"compact restoration");
        for(i=0;i<60;i=i+1) begin fullscreen=!fullscreen;tick;geometry;end
        fullscreen=0;repeat(18) tick;if(phase!=0) $fatal(1,"rapid switching recovery");
        $display("PASS native SW1: 640x480 @(40,32) <->720x576 @(0,0), frame-stable geometry, both directions, reversal, pause/resume, rapid switching");$finish;
    end
endmodule
