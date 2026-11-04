`timescale 1ns/1ps
module tb_picture_zoom;
    reg clk=0,rst=1,frame=0,fullscreen=0,pause=0;
    wire [4:0] phase;wire moving;wire [7:0] size;
    wire [9:0] left;wire [8:0] top;
    integer i,old_phase,old_size,old_top,step,previous_step;
    always #5 clk=~clk;
    player_picture_zoom dut(.clk(clk),.rst(rst),.frame_tick(frame),.fullscreen(fullscreen),
        .pause(pause),.phase(phase),.moving(moving),.size(size),.left(left),.top(top),
        .width(),.height());
    task tick;begin
        @(negedge clk);frame=1;@(negedge clk);frame=0;
    end endtask
    task geometry;begin
        if(size<136 || size>160 || left*2+size*4!=640 || top>32 || top+size*3>480)
            $fatal(1,"invalid bounds p%0d size%0d left%0d top%0d",phase,size,left,top);
    end endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(phase!==0 || size!==136 || left!==48 || top!==32 || moving) $fatal(1,"framed endpoint");
        fullscreen=1;
        for(i=0;i<16;i=i+1) begin
            old_phase=phase;old_size=size;old_top=top;
            repeat(7) @(negedge clk);
            if(phase!=old_phase || size!=old_size || top!=old_top) $fatal(1,"geometry changed mid-frame");
            tick;geometry;
            if(phase!=i+1 || size<old_size || size-old_size>2) $fatal(1,"expansion is not eased/monotone");
            if(top>old_top || old_top-top>3) $fatal(1,"vertical expansion jumped");
            step=size-old_size;
            if(i<8 && i>0 && step<previous_step || i>=8 && step>previous_step)
                $fatal(1,"expansion did not ease in/out");
            previous_step=step;
        end
        if(size!=160 || left!=0 || top!=0 || moving) $fatal(1,"640x480 full image endpoint");
        repeat(5) tick;
        if(phase!=16) $fatal(1,"endpoint overshot");
        fullscreen=0;repeat(7) tick;
        old_phase=phase;old_size=size;old_top=top;pause=1;
        repeat(5) tick;
        if(phase!=old_phase || size!=old_size || top!=old_top) $fatal(1,"menu/alarm/preview pause");
        fullscreen=1;repeat(3) tick;
        if(phase!=old_phase) $fatal(1,"paused switch moved image");
        pause=0;tick;
        if(phase!=old_phase+1 || size<old_size || size-old_size>2) $fatal(1,"reversal jumped");
        fullscreen=0;
        while(phase!=0) begin
            old_size=size;old_top=top;tick;geometry;
            if(size>old_size || old_size-size>2) $fatal(1,"shrink jumped");
            if(top<old_top || top-old_top>3) $fatal(1,"vertical shrink jumped");
        end
        if(size!=136 || left!=48 || top!=32 || moving) $fatal(1,"framed restoration");
        for(i=0;i<60;i=i+1) begin fullscreen=!fullscreen;tick;geometry;end
        fullscreen=0;repeat(18) tick;
        if(phase!=0) $fatal(1,"rapid switch recovery");
        $display("PASS SW1 zoom: 544x408 <-> 640x480, 16-frame eased size/origin, blanking updates, both directions, reversal, pause/resume, rapid toggles");
        $finish;
    end
endmodule
