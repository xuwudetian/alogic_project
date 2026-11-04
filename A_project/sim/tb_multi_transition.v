`timescale 1ns/1ps
module tb_multi_transition;
    reg clk=0,rst=1,tick=0,req=0,select_effect=1,pause=0;
    reg [2:0] bank=0,pic=0;
    reg [31:0] resolution={16'd640,16'd480};
    wire ack,valid,scaled,sliding,mask;
    wire [2:0] active,active_pic,target;
    wire [2:0] style;
    wire [5:0] level;
    wire [8:0] gain;wire [18:0] offset;wire [39:0] dimensions;
    integer effect,pass,n,oldbank,saved_level;reg oldack;
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.frame_tick(tick),.request_toggle(req),
        .pending_bank(bank),.pending_picture(pic),.pending_scaled(1'b1),
        .ack_toggle(ack),.active_bank(active),.active_picture(active_pic),.active_scaled(scaled),
        .display_valid(valid),.gain(gain),.pending_resolution(resolution),.active_resolution(dimensions),
        .transition_mode(select_effect ? 4'd1 : 4'd0),.effect_pause(pause),.effects_disabled(1'b0),.slide_active(sliding),
        .slide_offset(offset),.slide_bank(target),.mask_active(mask),.mask_style(style),.mask_level(level));
    always #5 clk=~clk;
    task frame;begin
        @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(6) @(negedge clk);
    end endtask
    task request_image;begin
        oldbank=active;oldack=ack;bank=(bank+1)%6;pic=bank;req=!req;
        resolution={16'd1920,16'd1440};repeat(45) @(negedge clk);frame;
    end endtask
    task pause_frames;begin
        saved_level=level;pause=1;repeat(3) frame;
        if(level!=saved_level) $fatal(1,"mask moved during UI pause");
        pause=0;
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;req=1;repeat(45) @(negedge clk);frame;
        if(mask || sliding || !valid || gain!=0) $fatal(1,"boot must retain fade");
        repeat(20) frame;if(!ack || gain!=256) $fatal(1,"boot failed");
        for(pass=0;pass<2;pass=pass+1) for(effect=0;effect<4;effect=effect+1) begin
            select_effect=1;request_image;
            if(effect==0) begin
                if(!sliding || mask || active!=oldbank) $fatal(1,"rotation must begin with slide");
                repeat(30) frame;
                if(sliding || active!=bank || ack!=oldack) $fatal(1,"slide release ordering");
                frame;
            end else begin
                if(!mask || style!=effect || level!=0 || sliding || gain!=256) $fatal(1,"wrong mask choice");
                select_effect=0; // A mid-effect setting change must not alter this transaction.
                for(n=1;n<=16;n=n+1) begin
                    frame;
                    if(level!=n*2 || active!=oldbank || ack!=oldack || style!=effect) $fatal(1,"cover progress");
                    if(n==7) pause_frames;
                end
                frame; // Hold the all-black old frame.
                pause_frames;
                if(active!=oldbank || ack!=oldack || level!=32) $fatal(1,"bank changed before black frame");
                frame;
                if(active!=bank || active_pic!=pic || ack!=oldack || dimensions!==40'h0192001440)
                    $fatal(1,"atomic metadata commit");
                pause_frames;frame;
                if(ack!=req || level!=32) $fatal(1,"new frame must settle before ACK");
                // The source may prepare another image after ACK; never commit it during reveal.
                req=!req;bank=(bank+1)%6;pic=bank;repeat(45) @(negedge clk);oldbank=active;oldack=ack;
                for(n=15;n>=0;n=n-1) begin
                    frame;if(level!=n*2 || active!=oldbank || ack!=oldack) $fatal(1,"reveal/queued request");
                    if(n==9) pause_frames;
                end
                frame;if(mask || sliding || gain!=256) $fatal(1,"mask did not release");
                // Queued transaction uses current fade setting, so it is a normal fade.
                frame;frame;if(gain!=240 || mask || sliding) $fatal(1,"queued fade selection");
                repeat(37) frame;if(ack!=req || active!=bank || gain!=256) $fatal(1,"queued fade failed");
            end
            if(ack!=req || active!=bank || mask || sliding) $fatal(1,"transaction incomplete");
        end
        // Advance past the slide, then reset during a spatial effect.
        select_effect=1;request_image;repeat(31) frame;request_image;repeat(4) frame;
        @(negedge clk);rst=1;@(negedge clk);
        if(mask || sliding || valid || gain || level || offset || ack || dut.next_effect) $fatal(1,"reset left effect state");
        $display("PASS multi transition: all styles twice, cold fade, frame atomicity, pause, switch latch, metadata, ACK ownership, queued image, reset");$finish;
    end
    initial begin #1000000;$fatal(1,"multi transition timeout");end
endmodule
