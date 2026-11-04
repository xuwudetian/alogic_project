`timescale 1ns/1ps
module tb_directory_flow;
    reg clk=0,rst=1,vs=1,remote=0,req=0,disable_effects=1;
    reg [7:0] command=0;
    reg [23:0] argument=0;
    reg [3:0] pending=5,transition_mode=0;
    wire frame_tick=ui.frame_tick;
    wire directory,directory_active,browse,alarm,ack,valid,slide,mask,scaled;
    wire [3:0] focus,bank,picture,slide_bank;
    wire [1:0] selection;
    wire [8:0] gain;
    wire [18:0] slide_offset;
    wire [5:0] mask_level;
    wire [2:0] mask_style;
    wire tone_valid,audio_valid;
    wire [23:0] tone,audio_pcm;
    integer n,held_bank,held_gain,held_state,held_offset,held_level;
    integer cycles=0,last_sample=0,samples=0,menu_samples=0;
    reg held_ack;
    always #20 clk=~clk;
    player_control #(.REMOTE_ENABLE(1),.CURRENT_PICTURE_FOCUS_ENABLE(1)) controls(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.key_next(1'b1),.key_auto(1'b1),.key_menu(1'b1),
        .switches(4'd0),.available(9'h1ff),.thumbnail_valid(9'h1ff),.current_picture(picture),
        .directory(directory),.directory_focus(selection),.browse(browse),.focus(focus),.alarm(alarm),
        .sensor_alarm(1'b0),.sensor_alarm_clear(1'b0),.network_alarm(1'b0),.playback_fault(1'b0),
        .remote_valid(remote),.remote_command(command),.remote_argument(argument),.auto_active(1'b1));
    player_ui_overlay #(.DIRECTORY_ANIMATION_ENABLE(1)) ui(
        .clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'h123456),
        .directory(directory),.selection(selection),.alarm(alarm),.directory_run(1'b0),
        .no_signal(1'b0),.boot_ready(1'b1),.directory_active(directory_active));
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1),.DIRECTORY_HOLD_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.request_toggle(req),.pending_bank(pending),
        .pending_picture(pending),.pending_scaled(1'b0),.pending_resolution({16'd640,16'd480}),
        .transition_mode(transition_mode),.effect_pause(directory_active || browse || alarm),
        .directory_hold(directory_active),.effects_disabled(disable_effects),
        .ack_toggle(ack),.active_bank(bank),.active_picture(picture),.active_scaled(scaled),
        .display_valid(valid),.gain(gain),.slide_active(slide),.slide_offset(slide_offset),
        .slide_bank(slide_bank),.mask_active(mask),.mask_style(mask_style),.mask_level(mask_level));
    player_audio source(.clk(clk),.rst(rst),.picture(picture),.volume(4'd4),.mute(1'b0),
        .valid(tone_valid),.left(tone));
    player_alarm_audio audio(.clk(clk),.rst(rst),.enable(alarm),.tick(tone_valid),
        .mute(1'b0),.volume(4'd4),.media_valid(tone_valid),.media_pcm(tone),
        .valid(audio_valid),.pcm(audio_pcm));
    always @(posedge clk) begin
        #1;
        if(rst) begin cycles=0;last_sample=0;samples=0;menu_samples=0;end
        else begin
            cycles=cycles+1;
            if(audio_valid) begin
                if(samples!=0 && cycles-last_sample!=520 && cycles-last_sample!=521)
                    $fatal(1,"directory interrupted 48kHz audio");
                samples=samples+1;last_sample=cycles;
                if(directory_active) menu_samples=menu_samples+1;
            end
        end
    end
    task frame;begin
        @(negedge clk);vs=0;repeat(4) @(negedge clk);vs=1;repeat(596) @(negedge clk);
    end endtask
    task send;
        input [7:0] cmd;input [23:0] arg;
        begin
            @(negedge clk);command=cmd;argument=arg;remote=1;
            @(negedge clk);remote=0;repeat(3) @(negedge clk);
        end
    endtask
    task remember;begin
        held_bank=bank;held_gain=gain;held_ack=ack;held_state=dut.state;
        held_offset=slide_offset;held_level=mask_level;
    end endtask
    task unchanged;begin
        if(bank!=held_bank || gain!=held_gain || ack!=held_ack || dut.state!=held_state ||
           slide_offset!=held_offset || mask_level!=held_level)
            $fatal(1,"picture changed under directory state=%0d/%0d bank=%0d/%0d gain=%0d/%0d",
                dut.state,held_state,bank,held_bank,gain,held_gain);
    end endtask
    task close_menu;begin
        send(8'h12,24'd0);frame;remember;
        for(n=12;n>=0;n=n-1) begin
            frame;unchanged;
            if(ui.directory_phase!=n || directory_active!==(n!=0)) $fatal(1,"exit tail pause");
        end
    end endtask
    task open_menu;begin
        send(8'h12,24'd1);frame;remember;
        repeat(14) begin frame;unchanged;end
        if(ui.directory_phase!=13) $fatal(1,"menu did not settle");
    end endtask
    task settle_picture;begin
        n=0;
        while((ack!=req || dut.state!=0) && n<100) begin frame;n=n+1;end
        if(ack!=req || dut.state!=0 || gain!=256 || bank!=pending) $fatal(1,"picture failed to resume");
    end endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;repeat(5) @(negedge clk);
        // Cold boot may publish its first image even with a menu already open.
        send(8'h12,24'd1);frame;
        req=1;repeat(45) @(negedge clk);frame;
        if(!valid || picture!=5) $fatal(1,"directory blocked the first background");
        repeat(14) frame;close_menu;frame;settle_picture;
        open_menu;
        send(8'h10,24'd3);frame;
        if(directory || !browse || focus!=5) $fatal(1,"preview did not focus the currently playing picture");
        repeat(14) frame;
        send(8'h12,24'd0);frame;
        // A queued cut must not replace the background until exit is complete.
        open_menu;pending=2;req=!req;repeat(45) @(negedge clk);
        remember;repeat(4) begin frame;unchanged;end
        close_menu;frame;settle_picture;
        disable_effects=0;
        // Freeze/resume the fade, slide and mask paths, including their bank ACKs.
        for(transition_mode=0;transition_mode<4;transition_mode=transition_mode+1'b1) begin
            pending=pending+1'b1;req=!req;repeat(45) @(negedge clk);
            frame;repeat(5) frame;
            if(dut.state==0) $fatal(1,"effect did not start");
            open_menu;close_menu;frame;settle_picture;
        end
        if(samples<50 || menu_samples<20) $fatal(1,"audio continuity coverage too short");
        $display("PASS directory flow: current-picture preview focus, cold-boot background, pending cut isolation, fade/slide/mask freeze, last-exit-frame ownership, resume, uninterrupted 48kHz audio (%0d samples, %0d under menu)",samples,menu_samples);
        $finish;
    end
    initial begin #30000000;$fatal(1,"directory flow timeout");end
endmodule
