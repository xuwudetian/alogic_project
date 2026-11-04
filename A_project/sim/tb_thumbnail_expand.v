`timescale 1ns/1ps
module tb_thumbnail_expand;
    reg clk=0,rst=1,tick=0,browse=0,select=0,alarm=0,directory=0,status_panel=0,disabled=0;
    reg [3:0] selected=0;
    reg [8:0] ready=511;
    reg request=0;
    reg [3:0] pending=0,mode=0;
    wire active,moving,valid,ack,scaled,slide,mask;
    wire [3:0] target,picture,bank,slide_bank;
    wire [4:0] phase;
    wire [7:0] size;
    wire [9:0] left;
    wire [8:0] top,gain;
    wire [1:0] border;
    wire [2:0] dim,mask_style;
    wire [5:0] mask_level;
    wire [18:0] offset;
    integer slot,n,count=0,held_phase;
    real q;
    integer expected_size,expected_left,expected_top;
    always #20 clk=~clk;
    thumbnail_expand dut(.clk(clk),.rst(rst),.frame_tick(tick),.browse(browse),
        .select_toggle(select),.select_index(selected),.ready(ready),.active_picture(picture),.pending_picture(pending),
        .display_valid(valid),.request_toggle(request),.ack_toggle(ack),
        .directory(directory),.status_panel(status_panel),.alarm(alarm),.effects_disabled(disabled),
        .active(active),.moving(moving),.target(target),.phase(phase),.size(size),
        .left(left),.top(top),.border_size(border),.dim(dim));
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1),.DIRECTORY_HOLD_ENABLE(1),.THUMBNAIL_SELECT_ENABLE(1)) transition(
        .clk(clk),.rst(rst),.frame_tick(tick),.request_toggle(request),.pending_bank(pending),
        .pending_picture(pending),.pending_scaled(1'b0),.pending_resolution({16'd640,16'd480}),
        .transition_mode(mode),.effect_pause(browse || active || alarm),.effects_disabled(disabled),
        .directory_hold(directory || (active && alarm)),.thumbnail_select(active),
        .ack_toggle(ack),.active_bank(bank),.active_picture(picture),.active_scaled(scaled),
        .display_valid(valid),.gain(gain),.slide_active(slide),.slide_offset(offset),.slide_bank(slide_bank),
        .mask_active(mask),.mask_style(mask_style),.mask_level(mask_level));
    task frame;begin @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(80) @(negedge clk);end endtask
    task confirm(input integer id);begin
        @(negedge clk);browse=1;repeat(4) @(negedge clk);
        selected=id;select=!select;browse=0;repeat(4) @(negedge clk);
    end endtask
    task submit(input integer id);begin
        @(negedge clk);pending=id;request=!request;repeat(80) @(negedge clk);
    end endtask
    task geometry;begin
        q=phase<=2 ? 1.0 : (17.0-phase)/15.0;
        if(q<0) q=0;q=q*q*q;
        expected_size=phase==0 ? 40 : phase<=2 ? 41 : $rtoi(160-119*q+0.5);
        expected_left=phase==0 ? 56+184*(slot%3) : $rtoi((54+184*(slot%3))*q+0.5);
        expected_top=phase==0 ? 48+144*(slot/3) : $rtoi((47+144*(slot/3))*q+0.5);
        if(expected_left+expected_size*4>640) expected_left=640-expected_size*4;
        if(expected_top+expected_size*3>480) expected_top=480-expected_size*3;
        if(size!=expected_size || left!=expected_left || top!=expected_top || left+size*4>640 || top+size*3>480)
            $fatal(1,"card geometry slot%0d phase%0d size%0d/%0d left%0d/%0d top%0d/%0d",slot,phase,size,expected_size,left,expected_left,top,expected_top);
        if(gain!=256 || mask || slide || bank!=slot) $fatal(1,"carousel effect leaked into card");
        count=count+1;
    end endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;disabled=1;submit(0);frame;frame;frame;disabled=0;
        for(slot=0;slot<9;slot=slot+1) begin
            mode=slot;confirm(slot);
            if(!active || moving) $fatal(1,"confirmation did not retain grid");
            // An earlier in-flight commit must be ACKed before the selection.
            if(slot!=picture) begin submit((slot+4)%9);frame;frame;end
            submit(slot);
            n=0;while(!moving && n<12) begin frame;n=n+1;end
            if(!moving || target!=slot) $fatal(1,"selection bank/ACK wait stuck");
            for(n=0;n<20;n=n+1) begin
                if(phase!=n) $fatal(1,"animation phase skipped");geometry;
                if(n==7) begin
                    alarm=1;held_phase=phase;repeat(3) frame;
                    if(phase!=held_phase) $fatal(1,"alarm failed to suspend card");alarm=0;
                end
                frame;
            end
            if(active || moving || picture!=slot || ack!=request) $fatal(1,"animation did not settle");
        end
        // Remote selections outside the browser keep the original carousel path.
        selected=2;select=!select;repeat(4) @(negedge clk);if(active) $fatal(1,"non-browser command animated");
        disabled=1;confirm(1);if(active) $fatal(1,"SW2 off ignored");disabled=0;
        confirm(1);directory=1;frame;if(active) $fatal(1,"directory did not cancel card");directory=0;
        confirm(1);status_panel=1;frame;if(active) $fatal(1,"settings did not cancel card");status_panel=0;
        confirm(1);ready[1]=0;frame;if(active) $fatal(1,"media invalidation did not cancel card");ready[1]=1;
        confirm(1);repeat(121) frame;if(active) $fatal(1,"missing commit wait not bounded");
        confirm(1);submit(1);repeat(4) frame;if(!moving) $fatal(1,"restart setup");
        selected=2;select=!select;repeat(4) @(negedge clk);
        if(!active || moving || target!=2) $fatal(1,"new selection did not restart from the new card");
        submit(2);repeat(4) frame;if(!moving) $fatal(1,"second selected bank stalled");
        submit(3);frame;if(active || moving) $fatal(1,"explicit next command did not cancel card");
        frame;frame;if(picture!=3 || ack!=request) $fatal(1,"interrupted picture commit lost");
        $display("PASS thumbnail expand: nine origins, 180 frame geometries, 20-frame ease-out, commit/ACK isolation with older requests, all carousel modes, alarm pause/resume, SW2, cancellation and timeout");$finish;
    end
    initial begin #20000000;$fatal(1,"thumbnail expand timeout");end
endmodule
