`timescale 1ns/1ps
// Command-level SDRAM, real asynchronous clocks and coordinate-coded frames.
// Checks all 1024x768 native pixels, low RGB565 bits, vblank ownership,
// partial frames, busy-frame drop, forced FIFO overflow, drain/recovery/refresh.
module tb_preview_sdram;
    reg mem_clk=0,mem_forward_clk=0,video_clk=0,camera_clk=0,rst_n=0;
    always #5 mem_clk=~mem_clk;
    initial begin #3;forever begin mem_forward_clk=~mem_forward_clk;#5;end end
    always #7.5 video_clk=~video_clk;
    // Faster than nominal 48 MHz: drift against 100/66.667 MHz memory/video clocks.
    // Two PCLK cycles per RGB565 pixel, including a no-blanking stress frame.
    initial begin #3;forever #10.1 camera_clk=~camera_clk;end
    reg pixel_valid=0,frame_start=0;
    reg [15:0] pixel_rgb565=0;
    reg [9:0] pixel_x=0;
    reg [9:0] pixel_y=0;
    wire [23:0] rgb;
    wire hs,vs,de,frame_valid;
    wire [9:0] x;
    wire [9:0] y;
    camera_preview dut(.camera_clk(camera_clk),.camera_rst_n(rst_n),
        .pixel_valid(pixel_valid),.pixel_rgb565(pixel_rgb565),.pixel_x(pixel_x),.pixel_y(pixel_y),.frame_start(frame_start),
        .mem_clk(mem_clk),.mem_rst_n(rst_n),.mem_forward_clk(mem_forward_clk),.video_clk(video_clk),.video_rst_n(rst_n),
        .rgb(rgb),.hs(hs),.vs(vs),.de(de),.x(x),.y(y),.frame_valid(frame_valid));
    integer errors=0,checked_pixels=0,frame1_count=0,frame3_count=0,view_id=0,writes_before_stall=0;
    integer maximum_fifo=0;
    reg stress_capture=0;
    reg old_read_bank=1,was_vblank;
    function [15:0] pattern;
        input integer id,sx,sy;
        reg [4:0] r,b;
        reg [5:0] g;
        begin
            r=sx+sy+id*3;g=sx*3+sy+id*7;b=sx+sy*5+id*11;
            pattern={r,g,b};
        end
    endfunction
    function [23:0] expand;
        input [15:0] p;
        begin expand={p[15:11],p[15:13],p[10:5],p[10:9],p[4:0],p[4:2]};end
    endfunction
    task check;
        input condition;
        input [255:0] message;
        begin
            if(condition!==1'b1) begin
                errors=errors+1;
                if(errors<=12) $display("FAIL %0s t=%0t x=%0d y=%0d rgb=%h",message,$time,x,y,rgb);
            end
        end
    endtask
    task pulse_start;
        begin
            @(negedge camera_clk);pixel_valid=0;frame_start=1;
            @(negedge camera_clk);frame_start=0;
        end
    endtask
    task send_frame;
        input integer id,rows,line_blank;
        integer sx,sy;
        begin
            pulse_start;
            for(sy=0;sy<rows;sy=sy+1) begin
                for(sx=0;sx<1024;sx=sx+1) begin
                    pixel_valid=1;pixel_x=sx;pixel_y=sy;pixel_rgb565=pattern(id,sx,sy);
                    @(negedge camera_clk);pixel_valid=0;
                    @(negedge camera_clk);
                end
                repeat(line_blank) @(negedge camera_clk);
            end
        end
    endtask
    always @(posedge video_clk) begin
        was_vblank=dut.video_frame_start;
        #2;
        if(rst_n) begin
            if(dut.read_bank!=old_read_bank) check(was_vblank,"frame bank swaps only at vblank");
            old_read_bank=dut.read_bank;
            if(de && !frame_valid) check(rgb===0,"black until first complete frame");
            if(de && frame_valid) begin
                check(dut.valid_q,"line cache ready before display");
                if(x==0 && y==0) begin
                    if(rgb===expand(pattern(1,0,0))) view_id=1;
                    else if(rgb===expand(pattern(3,0,0))) view_id=3;
                    else begin view_id=0;check(0,"only complete good frames published");end
                end
                if(view_id) check(rgb===expand(pattern(view_id,x,y)),"native RGB565 pixel coordinates");
                checked_pixels=checked_pixels+1;
                if(x==1023 && y==767) begin
                    if(view_id==1) frame1_count=frame1_count+1;
                    if(view_id==3) frame3_count=frame3_count+1;
                end
            end
        end
    end
    always @(posedge mem_clk) begin
        if(stress_capture && dut.frame_store.fifo_count>maximum_fifo)
            maximum_fifo=dut.frame_store.fifo_count;
        if(rst_n && dut.frame_store.memory_request && dut.frame_store.memory_write && dut.frame_store.memory_ready) begin
            check(dut.frame_store.words_written<393216,"all writes remain inside frame extent");
            if(frame_valid) check(dut.frame_store.write_bank!=dut.read_bank,"writer never touches display frame");
        end
    end
    initial begin
        #37;rst_n=1;
        wait(dut.initialized);repeat(5) @(negedge camera_clk);
        send_frame(5,11,40);pulse_start;
        wait(dut.frames_dropped==1);
        repeat(8) @(negedge camera_clk);
        send_frame(1,768,40);
        // This camera frame arrives while publication is pending; drop whole.
        send_frame(7,768,0);
        wait(frame1_count>=1);
        check(dut.frames_committed==1,"busy camera frame was not published");
        wait(dut.frame_store.camera_ack_sync[1]==dut.frame_store.camera_done);
        // Inject an already-full frame extent. The write bound must prevent
        // crossing into the displayed bank while reads and refresh continue.
        // Subsequent FIFO overflow invalidates this frame, then drains sans reset.
        writes_before_stall=dut.frame_store.memory_phy.sdram.writes;
        force dut.frame_store.words_written=19'd393216;
        send_frame(2,768,0);
        check(dut.frame_store.overflow,"forced stall reached FIFO overflow");
        check(dut.frame_store.memory_phy.sdram.writes==writes_before_stall,"frame extent guard rejects all excess writes");
        release dut.frame_store.words_written;
        wait(dut.frames_dropped==2);
        check(dut.frames_committed==1,"overflow frame retained last good image");
        repeat(8) @(negedge camera_clk);
        stress_capture=1;
        send_frame(3,768,0);
        check(!dut.frame_store.overflow,"native no-blanking capture does not overflow");
        stress_capture=0;
        wait(frame3_count>=1);
        check(dut.frames_committed==2,"recovered complete frame published");
        check(dut.frame_store.memory_phy.sdram.refresh_commands>100,"periodic SDRAM refresh exercised");
        check(dut.frame_store.memory_phy.sdram.writes>=786432,"two frames physically written to SDRAM model");
        check(dut.frame_store.memory_phy.sdram.reads>=786432,"two frames physically read from SDRAM model");
        check(checked_pixels>=1572864,"at least two full display frames checked");
        if(errors) $fatal(1,"PREVIEW_SDRAM failed: %0d",errors);
        $display("PASS PREVIEW_SDRAM: native 1024x768 RGB565, BL8/CL3 init/refresh, partial/busy/overflow recovery, %0d display pixels, peak camera FIFO %0d/1024",checked_pixels,maximum_fifo);
        $finish;
    end
    initial begin #220000000;$fatal(1,"PREVIEW_SDRAM timeout committed=%0d dropped=%0d state=%0d",dut.frames_committed,dut.frames_dropped,dut.frame_store.state);end
endmodule
