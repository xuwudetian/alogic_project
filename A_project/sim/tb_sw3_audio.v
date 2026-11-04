`timescale 1ns/1ps
module tb_sw3_audio;
    reg fit=0;
    integer before_samples,before_images;
    reg clk=0,aclk=0,rst=1,ack=0,finished=0,commit_ack=0;
    reg browse=0,select_toggle=0,next_toggle=0,pause_ui=0;
    wire commit,wr,we,av,tick;
    wire [3:0] pic;
    wire [3:0] state;
    wire [8:0] ready;
    wire [7:0] error,status;
    wire [23:0] pcm,tone;
    integer pixels=0,samples=0,starts=0,image_starts=0;
    reg checking=1;
    reg consumed=0;
    reg [23:0] tone_expected;
    always #10 clk=~clk;
    always #20 aclk=~aclk;
    player_audio cadence(.clk(aclk),.rst(rst),.picture(3'd0),.volume(4'd8),.mute(1'b0),
        .valid(tick),.left(tone));
    sd_card_bmp #(.POWER_WAIT_CYCLES(50),.READY_WAIT_CYCLES(20),.UI_PAUSE_ENABLE(1),.FOUR_BANK_CACHE(1),.GENERAL_SCALE(1),.FIT_MODE_ENABLE(1),.FIT_DEBOUNCE_CYCLES(4)) dut(
        .fit_mode(fit),
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),
        .write_ready(1'b1),.commit_toggle(commit),.picture_id(pic),.state_code(state),.error_code(error),
        .write_req(wr),.write_req_ack(ack),.write_en(we),.SD_MISO(1'b1),
        .audio_clk(aclk),.audio_rst(rst),.audio_tick(tick),.tone(tone),.volume(4'd8),.mute(1'b0),
        .audio_valid(av),.audio_pcm(pcm),.audio_status(status),
        .browse(browse),.select_toggle(select_toggle),.select_index(4'd3),.thumbnail_valid(ready),.ui_pause(pause_ui));
    defparam dut.decoder.EXPECTED_WIDTH=160;
    defparam dut.decoder.EXPECTED_HEIGHT=120;
    defparam dut.sd_card_top_m0.WITH_AUDIO=1;
    defparam dut.sd_card_top_m0.BAD_BOOT_READS=1;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==19200) finished=!finished;end
        if(!rst && dut.wav.start) starts=starts+1;
        if(!rst && dut.file_start) image_starts=image_starts+1;
        if(!rst && state==11 && (dut.sector_read || dut.scan_start))
            $fatal(1,"read before power settle");
    end
    always @(posedge aclk) begin
        consumed<=dut.wav.pop;tone_expected<=tone;
    end
    always @(negedge aclk) if(checking && av && consumed) begin
        if(pcm!==(samples[0] ? 24'hfedc00 : 24'h123400))
            $fatal(1,"WAV PCM order corruption sample%0d %h",samples,pcm);
        samples=samples+1;
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(commit!=commit_ack);@(negedge clk);
        if(error || dut.boot_retries!=1 || pic!=1 || ready!=2) $fatal(1,"transient E20 recovery");
        commit_ack=commit;wait(state==8);
        browse=1;wait(ready==10);@(negedge clk);
        if(commit!=commit_ack || pic!=1) $fatal(1,"background preview replaced front image");
        browse=0;pause_ui=1;repeat(10) @(negedge clk);select_toggle=1;
        repeat(2000) begin
            @(negedge clk);
            if(wr || commit!=commit_ack || state!=8) $fatal(1,"paused image transaction started");
        end
        pause_ui=0;
        wait(commit!=commit_ack);@(negedge clk);
        if(pic!=3 || error || image_starts!=2) $fatal(1,"direct thumbnail selection");
        commit_ack=commit;wait(state==8);pause_ui=0;
        $display("begin contain reload at %0t samples%0d",$time,samples);
        before_samples=samples;before_images=image_starts;fit=1;
        wait(dut.fit_loaded);wait(commit!=commit_ack);@(negedge clk);
        if(pic!=3 || error || dut.driver_reset || !dut.media_enabled) $fatal(1,"fit reload interrupted WAV/media");
        commit_ack=commit;wait(state==8);wait(ready==10 && state==8);
        if(image_starts!=before_images+2 || samples<=before_samples || status!=1) $fatal(1,"fit reload audio/preload");
        $display("begin cover reload at %0t samples%0d",$time,samples);
        before_samples=samples;before_images=image_starts;fit=0;
        wait(!dut.fit_loaded);wait(commit!=commit_ack);@(negedge clk);
        commit_ack=commit;wait(state==8);wait(ready==10 && state==8);
        if(image_starts!=before_images+2 || samples<=before_samples || status!=1) $fatal(1,"cover reload audio/preload");
        wait(starts>=3 && samples>2300);
        if(status!=1 || dut.wav.full) $fatal(1,"WAV loop/flow status %h",status);
        // Inject the stall only during active playback, before the final
        // source sector. At a loop boundary the player correctly waits for
        // prefill instead of reporting underrun, so that is not a stall test.
        @(negedge clk);
        while(!dut.wav.playing || dut.wav.end_sync[1] || dut.wav.ended ||
              dut.wav.rdused<512 || dut.wav.file_reader.remaining_bytes<=512)
            @(negedge clk);
        // Deliberate media stall: silence and W55, never stale PCM or a picture E.
        $display("begin deliberate WAV stall at %0t samples%0d",$time,samples);
        checking=0;
        force dut.wav.file_reader.sector_busy=1;
        wait(dut.wav.underflow);repeat(20) @(negedge clk);
        if(status!=8'h55 || error!=0) $fatal(1,"audio underrun isolation");
        release dut.wav.file_reader.sector_busy;
        force dut.wav.parse_error=8'h52;
        wait(dut.wav.disable_sync[1]);wait(av);@(negedge aclk);
        if(pcm!==tone_expected || status!=8'h52 || error!=0) $fatal(1,"bad WAV fallback");
        release dut.wav.parse_error;
        $display("PASS SW3 reload with ordered continuous WAV PCM: 160x120 upscale from 3x2/6x4, full-frame preload and no-reread selection, transient E20 auto-reinit, fragmented WAV FAT chain, official async FIFO ordered PCM, concurrent previews, direct select, loop, isolated underrun, bad WAV fallback");
        $finish;
    end
    initial begin #300000000;$fatal(1,"media timeout E%h W%h state%0d samples%0d starts%0d image_starts%0d fit%b ready%h commit%b ack%b",error,status,state,samples,starts,image_starts,dut.fit_loaded,ready,commit,commit_ack);end
endmodule
