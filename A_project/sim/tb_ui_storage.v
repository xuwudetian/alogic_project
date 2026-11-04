`timescale 1ns/1ps
module tb_ui_storage;
    reg clk=0,rst=1,key2=1,key3=1,key4=1;
    reg write_ack=0,finish_toggle=0,commit_ack=0;
    reg [5:0] frame_counter=0;
    wire frame_tick=frame_counter==0;
    wire next_toggle,auto_toggle,browse,directory,alarm,select_toggle,write_req,write_en,commit;
    wire [2:0] select_index;
    wire [1:0] run_mode;
    wire auto_play,status_panel;
    wire [5:0] available,thumbnail_valid;
    wire [3:0] state;
    wire [7:0] error,audio_status;
    integer pixels=0,commits=0,starts=0,preview_starts=0;
    always #10 clk=~clk;
    always @(posedge clk) if(rst) frame_counter<=0;else frame_counter<=frame_counter+1'b1;
    player_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(30)) controls(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.key_next(key2),.key_menu(key3),.key_auto(key4),
        .switches(4'd0),.next_toggle(next_toggle),.auto_toggle(auto_toggle),
        .available(available),.thumbnail_valid(thumbnail_valid),.browse(browse),
        .directory(directory),.alarm(alarm),.select_toggle(select_toggle),.select_index(select_index),
        .auto_active(auto_play),.run_mode(run_mode),.status_panel(status_panel));
    sd_card_bmp #(.CLK_FREQ_HZ(100000),.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8),.UI_PAUSE_ENABLE(1),.RUN_MODE_CONTROL(1)) storage(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(auto_toggle),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finish_toggle),.write_overflow(1'b0),
        .write_ready(1'b1),.write_req(write_req),.write_req_ack(write_ack),.write_en(write_en),
        .commit_toggle(commit),.state_code(state),.error_code(error),.SD_MISO(1'b1),
        .run_auto(run_mode==2),.auto_play(auto_play),.available_images(available),
        .audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),
        .audio_status(audio_status),.browse(browse),.select_toggle(select_toggle),
        .select_index(select_index),.thumbnail_valid(thumbnail_valid),.ui_pause(directory || alarm));
    defparam storage.decoder.EXPECTED_WIDTH=3;
    defparam storage.decoder.EXPECTED_HEIGHT=2;
    always @(negedge clk) begin
        write_ack=write_req;
        if(rst || write_req) pixels=0;
        else if(write_en) begin pixels=pixels+1;if(pixels==6) finish_toggle=!finish_toggle;end
        if(!rst && error!=0) $fatal(1,"directory/preview produced E%h S%0d D%h",error,state,storage.debug_status);
        if(!rst && storage.file_start) begin
            starts=starts+1;
            if(storage.background) preview_starts=preview_starts+1;
            if(storage.file_busy || storage.file_done || storage.bmp_done)
                $fatal(1,"overlapping image transaction");
        end
        if(!rst && storage.background && (write_req || write_en))
            $fatal(1,"thumbnail leaked to SDRAM");
        if(!rst && commit!=commit_ack) begin commit_ack=commit;commits=commits+1;end
    end
    task press;
        input integer key;
        begin
            @(negedge clk);case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
            repeat(12) @(negedge clk);key2=1;key3=1;key4=1;
            repeat(80) @(negedge clk);
        end
    endtask
    task hold_menu;
        begin
            @(negedge clk);key3=0;repeat(45) @(negedge clk);key3=1;
            repeat(80) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(state==5);press(2);wait(directory);
        if(state==8 && commits!=1) $fatal(1,"in-flight image lost on directory entry");
        press(4);wait(browse);
        wait(thumbnail_valid==4'b1010 && state==8);
        press(2);wait(directory);press(4);wait(browse);
        repeat(200) @(negedge clk);
        if(error!=0 || audio_status!=0 || preview_starts!=1 || starts!=2 || commits!=1)
            $fatal(1,"unexpected retrigger E%h W%h preview%0d starts%0d commits%0d",
                   error,audio_status,preview_starts,starts,commits);
        // The reset-selected AUTO must drive the real storage timer without
        // ever editing playback mode or generating an old auto-toggle gesture.
        if(run_mode!=2 || !auto_play) $fatal(1,"boot did not enable storage AUTO");
        press(2);press(3);press(4);wait(!directory && !browse);
        wait(commits==2 && state==8);
        hold_menu;repeat(5) press(3);press(2);
        if(run_mode!=1 || auto_play || !status_panel) $fatal(1,"MAN selection did not stop storage timer");
        hold_menu;press(2);
        repeat(400000) @(negedge clk);
        if(commits!=2) $fatal(1,"MAN automatically advanced");
        press(3);wait(commits==3 && state==8);
        repeat(400000) @(negedge clk);
        if(commits!=3) $fatal(1,"MAN timer restarted after manual advance");
        hold_menu;press(4);
        if(run_mode!=2 || !auto_play) $fatal(1,"KEY4 did not restore AUTO");
        hold_menu;press(2);wait(commits==4 && state==8);
        if(audio_status!=0) $fatal(1,"mode edit changed W00");
        $display("PASS UI storage: AUTO boot drives timed advance, MAN suppresses timer and accepts KEY3, KEY4 restores AUTO, preview transaction completion, W00, no duplicate thumbnail load");
        $finish;
    end
    initial begin #60000000;$fatal(1,"UI storage timeout S%0d E%h",state,error);end
endmodule
