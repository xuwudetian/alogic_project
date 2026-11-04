`timescale 1ns/1ps
module tb_slide_transition;
    reg clk=0,rst=1,tick=0,req=0,select_slide=1,pause=0;
    reg [2:0] bank=0,pic=0;
    reg [31:0] resolution={16'd640,16'd480};
    wire ack,valid,scaled,sliding;
    wire [2:0] active,active_pic,target;
    wire [8:0] gain;
    wire [18:0] offset;
    wire [39:0] dimensions;
    integer n;
    player_transition #(.SLIDE_ENABLE(1)) dut(.clk(clk),.rst(rst),.frame_tick(tick),
        .request_toggle(req),.pending_bank(bank),.pending_picture(pic),.pending_scaled(1'b1),
        .ack_toggle(ack),.active_bank(active),.active_picture(active_pic),.active_scaled(scaled),
        .display_valid(valid),.gain(gain),.pending_resolution(resolution),.active_resolution(dimensions),
        .transition_mode(select_slide ? 4'd2 : 4'd0),.effect_pause(pause),.effects_disabled(1'b0),.slide_active(sliding),.slide_offset(offset),.slide_bank(target));
    always #5 clk=~clk;
    task frame;begin
        @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(6) @(negedge clk);
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;req=1;repeat(45) @(negedge clk);
        frame;if(sliding || gain!=0 || !valid) $fatal(1,"cold start must fade from black");
        repeat(20) frame;
        if(!ack || gain!=256) $fatal(1,"cold start completion");
        bank=5;pic=5;resolution={16'd1920,16'd1080};req=0;repeat(45) @(negedge clk);
        frame;
        if(!sliding || target!=5 || offset!=0 || active!=0 || gain!=256) $fatal(1,"slide start");
        select_slide=0; // Only the next transaction changes style.
        for(n=1;n<=29;n=n+1) begin
            frame;
            if(!sliding || offset!=n*10240 || active!=0 || active_pic!=0 || gain!=256 || !ack)
                $fatal(1,"slide progress/early release at %0d",n);
            if(dimensions!==40'h0064000480) $fatal(1,"uncommitted source metadata leaked");
            if(n==12) begin
                pause=1;repeat(4) frame;
                if(offset!=12*10240 || !sliding || !ack) $fatal(1,"menu/alarm pause");
                pause=0;
            end
            repeat(20) @(negedge clk);
            if(offset!=n*10240) $fatal(1,"mid-frame scroll");
        end
        frame;
        if(sliding || offset!=0 || active!=5 || active_pic!=5 || !ack || dimensions!==40'h0192001080)
            $fatal(1,"slide atomic final commit");
        frame;if(ack) $fatal(1,"old bank not released after full new frame");
        bank=1;pic=1;req=1;repeat(45) @(negedge clk);frame;
        select_slide=1;frame;
        if(sliding || gain!=240 || active!=5 || ack) $fatal(1,"fade selection not latched");
        repeat(37) frame;
        if(active!=1 || !ack || gain!=256) $fatal(1,"fade fallback");
        bank=2;pic=2;req=0;repeat(45) @(negedge clk);frame;repeat(3) frame;
        @(negedge clk);rst=1;@(negedge clk);
        if(sliding || valid || offset || ack || gain) $fatal(1,"reset during slide");
        $display("PASS slide transition: cold start, 30 frames, metadata, mode latch, UI pause, delayed ACK, fade fallback, reset");$finish;
    end
    initial begin #1000000;$fatal(1,"slide transition timeout");end
endmodule
