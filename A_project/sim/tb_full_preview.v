`timescale 1ns/1ps
module tb_full_preview;
    reg clk=0,pclk=0,rst=1,key2=1,key3=1,key4=1;
    reg write_ack=0,finish_toggle=0,commit_ack=0;
    reg [7:0] frame_counter=0;
    reg [15:0] random_state=16'hbeef;
    wire frame_tick=frame_counter==0;
    wire next_toggle,auto_toggle,browse,directory,alarm,select_toggle,write_req,write_en,commit,auto_play;
    wire [2:0] select_index,picture,write_bank,display_bank;
    wire [1:0] run_mode;
    wire [31:0] resolution;
    reg [5:0] banks_written=0;
    time last_select_time;
    wire [5:0] available,thumbnail_valid;
    wire [3:0] state;
    wire [7:0] error,audio_status;
    wire [59:0] detail;
    integer pixels=0,decoded_pixels=0,commits=0,starts=0,preview_starts=0,n;
    always #10 clk=~clk;
    always #20 pclk=~pclk;
    always @(posedge pclk) if(rst) frame_counter<=0;else frame_counter<=frame_counter+1'b1;
    always @(posedge clk) random_state<={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
    player_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(100)) controls(
        .clk(pclk),.rst(rst),.frame_tick(frame_tick),.key_next(key2),.key_menu(key3),.key_auto(key4),
        .switches(4'd0),.next_toggle(next_toggle),.auto_toggle(auto_toggle),
        .available(available),.thumbnail_valid(thumbnail_valid),.browse(browse),
        .directory(directory),.alarm(alarm),.select_toggle(select_toggle),.select_index(select_index),
        .auto_active(auto_play),.run_mode(run_mode));
    sd_card_bmp #(.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8),.UI_PAUSE_ENABLE(1),.FOUR_BANK_CACHE(1),.GENERAL_SCALE(1),.RUN_MODE_CONTROL(1)) storage(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(auto_toggle),.interval_seconds(4'd9),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finish_toggle),.write_overflow(1'b0),
        .write_ready(random_state[1:0]!=0),.write_req(write_req),.write_req_ack(write_ack),.write_en(write_en),
        .commit_toggle(commit),.picture_id(picture),.write_buf_idx(write_bank),.disp_buf_idx(display_bank),.state_code(state),.error_code(error),.SD_MISO(1'b1),
        .available_images(available),.auto_play(auto_play),.debug_status(detail),
        .audio_clk(pclk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),
        .audio_status(audio_status),.browse(browse),.select_toggle(select_toggle),
        .select_index(select_index),.thumbnail_valid(thumbnail_valid),.ui_pause(directory || alarm),
        .run_auto(run_mode==2),.source_resolution(resolution));
    // Six independent file entries/cache banks; PIC5/PIC6 reuse PIC1/PIC2 RGB
    // fixture contents so the test does not require extra binary sample files.
    defparam storage.sd_card_top_m0.IMAGE_COUNT=6;
    always @(negedge clk) begin
        write_ack=write_req;
        if(rst || write_req) pixels=0;
        else if(write_en) begin
            pixels=pixels+1;if(pixels==307200) begin finish_toggle=!finish_toggle;banks_written[write_bank]=1;end
        end
        if(!rst && error!=0)
            $fatal(1,"full image E%h S%h L%h N%h H%h R%h",error,state,detail[59:28],detail[27:18],detail[17:2],detail[1:0]);
        if(!rst && storage.file_start) begin
            starts=starts+1;decoded_pixels=0;
            if(storage.background) preview_starts=preview_starts+1;
            if(storage.file_busy || storage.file_done || storage.bmp_done)
                $fatal(1,"overlapping full image transaction");
        end
        if(!rst && storage.pixel_valid) decoded_pixels=decoded_pixels+1;
        if(!rst && storage.bmp_done) begin
            if(decoded_pixels!=307200) $fatal(1,"missing decoded pixels %0d",decoded_pixels);
            $display("full image PIC%0d background=%b bytes=%0d pixels=%0d",storage.selected+1,storage.background,storage.file_offset+1,decoded_pixels);
        end
        if(!rst && write_en && !storage.first_frame && write_bank==display_bank) $fatal(1,"visible bank overwritten");
        if(!rst && commit!=commit_ack) begin
            if(!banks_written[display_bank] || !storage.cache_valid[picture]) $fatal(1,"incomplete frame committed");
            commit_ack=commit;commits=commits+1;
        end
    end
    task press;
        input integer key;
        begin
            @(negedge pclk);case(key) 2:key2=0;3:key3=0;4:key4=0;endcase
            repeat(12) @(negedge pclk);key2=1;key3=1;key4=1;
            repeat(300) @(negedge pclk);
        end
    endtask
    task hold_menu;
        begin
            @(negedge pclk);key3=0;repeat(120) @(negedge pclk);key3=1;
            repeat(300) @(negedge pclk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(commits==1 && state==8);
        if(picture!=0 || available!=63) $fatal(1,"full card catalog");
        if(resolution!=={16'd640,16'd480}) $fatal(1,"first image source dimensions");
        press(2);wait(directory);press(4);wait(browse);
        // Overlay changes while a large background transaction is in progress.
        wait(storage.background && state==5);press(2);wait(directory);press(2);wait(!directory);
        wait(thumbnail_valid==63 && state==8);
        if(preview_starts!=5 || commits!=1 || banks_written!=63 || storage.cache_valid!=63) $fatal(1,"full preview/cache count");
        if(resolution!=={16'd640,16'd480}) $fatal(1,"preload replaced source dimensions");
        if(run_mode!=2 || !auto_play) $fatal(1,"AUTO boot lost during preview");
        press(2);wait(directory);press(3);press(3);press(4);
        if(!controls.status_panel) $fatal(1,"settings menu entry failed");
        repeat(5) press(3);press(2);
        if(run_mode!=1) $fatal(1,"settings did not select MAN");
        hold_menu;press(2);wait(!browse && !directory);
        press(3);
        wait(commits==2 && state==8);
        if(picture!=1 || audio_status!=0) $fatal(1,"run target or W00");
        // MAN short KEY3 advances through all remaining banks and wraps from
        // PIC6 to PIC1; every switch must be a cache hit.
        for(n=0;n<5;n=n+1) begin
            press(3);
            wait(commits==3+n && state==8);
            if(picture!=((2+n)%6)) $fatal(1,"full six-picture Run sequence");
            if(n<2 && resolution!=={16'd1280,16'd960}) $fatal(1,"scaled cache dimensions lost");
            if(n>=2 && resolution!=={16'd640,16'd480}) $fatal(1,"native cache dimensions lost");
        end
        if(starts!=6 || preview_starts!=5 || audio_status!=0) $fatal(1,"cache hit reread BMP or changed audio");
        $display("PASS full preview: AUTO boot, settings MAN, six full 640x480/1280x960 BMP entries loaded once, six banks, PIC6-to-PIC1 wrap, KEY3 cache hits, pause/resume, random backpressure, W00");
        $finish;
    end
    initial begin #(64'd3000000000);$fatal(1,"full preview timeout S%h E%h",state,error);end
endmodule
