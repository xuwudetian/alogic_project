`timescale 1ns/1ps
module tb_sw3_cache;
    reg fit=0,hold_ack=0;
    integer preserved_picture,old_starts,old_samples;
    reg clk=0,mem_clk=0,rst=1,next_toggle=0,select_toggle=0,pause=0,run_auto=0;
    wire autoplay;
    reg [3:0] selection=0;
    reg commit_ack=0,finish_toggle=0,memory_busy=1;
    wire commit,request,ack,we,wfinish,overflow,ready,flip,mw;
    wire [23:0] pixel;
    wire [31:0] md;
    wire [20:0] ma;
    wire [3:0] wb,db,picture;
    wire [3:0] state;
    wire [8:0] valid,failed;
    wire [7:0] error;
    integer stored=0,commits=0,starts=0,stalls=0,i,j,before_starts,bank_count[0:8];
    reg [31:0] memory_words[0:6911];
    function [31:0] packed_color(input integer pic,input integer word_index);
        reg [23:0] rgb;
        begin
            rgb=24'h503014+pic*24'h010101;
            case(word_index%3)
                0:packed_color={rgb,rgb[23:16]};
                1:packed_color={rgb[15:0],rgb[23:8]};
                2:packed_color={rgb[7:0],rgb};
            endcase
            if(dut.fit_loaded && (word_index<192 || word_index>=576)) packed_color=0;
        end
    endfunction
    time selection_time;
    always #10 clk=~clk;
    always #12.5 mem_clk=~mem_clk;
    sd_card_bmp #(.WRITE_DATA_BITS(24),.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8),.UI_PAUSE_ENABLE(1),.FRAME_CACHE_ENABLE(1),.GENERAL_SCALE(1),.RUN_MODE_CONTROL(1),.FIT_MODE_ENABLE(1),.FIT_DEBOUNCE_CYCLES(4)) dut(
        .fit_mode(fit),
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(1'b0),.interval_seconds(4'd15),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finish_toggle),.write_overflow(overflow),
        .write_ready(ready),.commit_toggle(commit),.write_buf_idx(wb),.disp_buf_idx(db),.picture_id(picture),
        .state_code(state),.error_code(error),.write_req(request),.write_req_ack(ack),.write_en(we),
        .write_data(pixel),.write_v_flip(flip),.SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),
        .audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),.browse(1'b0),
        .select_toggle(select_toggle),.select_index(selection),.ui_pause(pause),.thumbnail_valid(valid),.thumbnail_failed(failed),
        .run_auto(run_auto),.auto_play(autoplay));
    defparam dut.decoder.EXPECTED_WIDTH=32,dut.decoder.EXPECTED_HEIGHT=32;
    defparam dut.sd_card_top_m0.IMAGE_COUNT=9;
    frame_read_write #(.READ_DATA_BITS(24),.WRITE_DATA_BITS(24),.BURST_SIZE(128),.FRAME_WIDTH(32),.FRAME_HEIGHT(32)) memory(
        .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),.Sdr_busy(memory_busy),
        .Sdr_rd_en(1'b0),.Sdr_rd_dout(32'd0),.read_clk(clk),.read_req(1'b0),
        .read_addr_0(21'd0),.read_addr_1(21'd768),.read_addr_2(21'd1536),.read_addr_3(21'd2304),.read_addr_4(21'd3072),.read_addr_5(21'd3840),.read_addr_6(21'd4608),.read_addr_7(21'd5376),.read_addr_8(21'd6144),
        .read_addr_index(db),.read_len(21'd768),.read_en(1'b0),
        .App_wr_en(mw),.App_wr_addr(ma),.App_wr_din(md),.write_clk(clk),.write_req(request),
        .write_req_ack(ack),.write_finish(wfinish),.write_addr_0(21'd0),.write_addr_1(21'd768),
        .write_addr_2(21'd1536),.write_addr_3(21'd2304),.write_addr_4(21'd3072),.write_addr_5(21'd3840),.write_addr_6(21'd4608),.write_addr_7(21'd5376),.write_addr_8(21'd6144),.write_addr_index(wb),.write_len(21'd768),
        .write_en(we),.write_data(pixel),.write_v_flip(flip),.write_overflow(overflow),.write_ready(ready));
    always @(posedge mem_clk) begin
        if(rst) begin finish_toggle<=0;stored=0;end
        else if(ack) begin stored=0;bank_count[wb]=0;end
        else begin
            if(mw) begin
                if(ma!==(wb*768+stored) || md!==packed_color(dut.selected,stored))
                    $fatal(1,"nine-bank address/RGB %h @%0d selected%0d",md,ma,dut.selected);
                if(!dut.first_frame && wb==db) $fatal(1,"overwriting visible bank during load/recovery");
                memory_words[ma]=md;stored=stored+1;bank_count[wb]=stored;
            end
            if(wfinish) finish_toggle<=!finish_toggle;
        end
    end
    always @(negedge clk) begin
        if(!rst && overflow) $fatal(1,"nine-bank FIFO overflow");
        if(!rst && state==5 && !ready) stalls=stalls+1;
        if(!rst && dut.file_start) starts=starts+1;
        if(!rst && !hold_ack && commit!=commit_ack) begin
            if(bank_count[db]!=768 || !dut.cache_valid[picture]) $fatal(1,"published partial frame");
            commit_ack=commit;commits=commits+1;
        end
    end
    task select_pic;
        input [3:0] value;
        integer previous_commits;
        begin
            @(negedge clk);selection=value;previous_commits=commits;
            repeat(5) @(negedge clk);selection_time=$time;select_toggle=!select_toggle;
            wait(commits>previous_commits);wait(state==8);
            if(picture!=value) $fatal(1,"selection target");
        end
    endtask
    task verify_cache;
        reg [8:0] banks;
        begin
            banks=0;
            for(i=0;i<9;i=i+1) begin
                if(banks[dut.cache_bank[i]]) $fatal(1,"duplicate cached bank");
                banks[dut.cache_bank[i]]=1;
                for(j=0;j<768;j=j+1)
                    if(memory_words[dut.cache_bank[i]*768+j]!==packed_color(i,j))
                        $fatal(1,"cached frame content pic%0d pixel%0d",i,j);
            end
        end
    endtask
    initial begin
        for(i=0;i<9;i=i+1) bank_count[i]=0;
        dut.sd_card_top_m0.bad_chain=1;
        repeat(8) @(negedge clk);rst=0;
        wait(memory.write_used>=480);repeat(100) @(negedge clk);
        if(ready || stored || stalls==0) $fatal(1,"new decoder backpressure not exercised");
        memory_busy=0;wait(commits==1);
        wait(dut.background && state==5);selection=0;
        repeat(5) @(negedge clk);select_toggle=!select_toggle;selection_time=$time;
        wait(commits==2);
        if(state!=5 || picture!=0 || $time-selection_time>1000) $fatal(1,"cache hit stalled behind background preload");
        selection=8;
        repeat(5) @(negedge clk);select_toggle=!select_toggle;
        wait(commits==3);wait(dut.attempted==511 && state==8);
        if(picture!=8 || valid!=509 || failed!=2 || dut.cache_valid!=509 || starts!=9) $fatal(1,"bad FAT containment/preload/select priority");
        dut.sd_card_top_m0.bad_chain=0;select_pic(1);wait(valid==511 && state==8);verify_cache;
        before_starts=starts;
        for(i=0;i<27;i=i+1) begin
            select_pic(i%9);
            if($time-selection_time>1000) $fatal(1,"cache-hit control latency");
            if(starts!=before_starts || request || we) $fatal(1,"cached selection reread/rewrote");
        end
        for(i=0;i<9;i=i+1) begin
            j=commits;@(negedge clk);next_toggle=!next_toggle;
            wait(commits>j);wait(state==8);
            if(picture!=i || starts!=before_starts) $fatal(1,"nine-slot next/wrap reread");
        end
        // Reject unused four-bit codes without changing display/cache state.
        @(negedge clk);selection=15;repeat(5) @(negedge clk);select_toggle=!select_toggle;
        repeat(30) @(negedge clk);
        if(picture!=8 || starts!=before_starts || request) $fatal(1,"invalid slot accepted");
        pause=1;repeat(10) @(negedge clk);selection=0;select_toggle=!select_toggle;
        repeat(100) @(negedge clk);if(picture!=8 || request) $fatal(1,"paused request was committed");
        pause=0;wait(picture==0 && state==8);
        // Recover without resetting display state: the old visible bank is protected.
        @(negedge clk);force dut.sector_error=8'h13;repeat(2) @(negedge clk);release dut.sector_error;
        wait(state==10);next_toggle=!next_toggle;
        wait(dut.cache_valid==0);wait(valid==511 && state==8);verify_cache;
        if(starts!=before_starts+9 || error) $fatal(1,"recovery preload");
        if(autoplay) $fatal(1,"manual recovery unexpectedly enabled autoplay");
        run_auto=1;repeat(10) @(negedge clk);if(!autoplay) $fatal(1,"automatic selection");
        run_auto=0;repeat(10) @(negedge clk);if(autoplay) $fatal(1,"manual selection");
        // Debounce rejects short chatter without invalidating any slot.
        old_starts=starts;fit=1;repeat(2) @(negedge clk);fit=0;
        repeat(12) @(negedge clk);
        if(dut.fit_loaded || dut.cache_valid!=511 || starts!=old_starts) $fatal(1,"switch chatter reload");
        // A pending old-mode publication must finish before any invalidation.
        hold_ack=1;selection=4;select_toggle=!select_toggle;
        wait(commit!=commit_ack);fit=1;repeat(20) @(negedge clk);
        if(dut.fit_loaded || dut.cache_valid!=511 || starts!=old_starts || request) $fatal(1,"changed mode before commit ACK");
        preserved_picture=picture;hold_ack=0;
        wait(dut.fit_loaded);wait(valid==511 && state==8);verify_cache;
        if(starts!=old_starts+9 || picture!=preserved_picture || !dut.media_enabled || dut.driver_reset)
            $fatal(1,"contain reload did not preserve current image/media");
        old_starts=starts;
        for(i=0;i<9;i=i+1) select_pic(i);
        if(starts!=old_starts) $fatal(1,"contain cache hits reread");
        // UI pause queues a mode change; playback state and banks stay intact.
        pause=1;repeat(8) @(negedge clk);fit=0;repeat(20) @(negedge clk);
        if(!dut.fit_loaded || dut.cache_valid!=511 || starts!=old_starts) $fatal(1,"mode change bypassed UI pause");
        pause=0;wait(!dut.fit_loaded);wait(state==5);
        // Change again while decoding. The active file remains in cover mode;
        // the latest requested mode wins at the next safe boundary.
        fit=1;repeat(20) @(negedge clk);
        if(dut.fit_loaded || dut.decoder.general_scale.core.fit_active) $fatal(1,"in-flight file changed mode");
        wait(dut.fit_loaded);wait(valid==511 && state==8);verify_cache;
        if(picture!=8 || error || failed) $fatal(1,"rapid switch/current image/cache failure");
        old_starts=starts;fit=0;wait(!dut.fit_loaded);wait(valid==511 && state==8);verify_cache;
        if(starts!=old_starts+9 || picture!=8) $fatal(1,"return to cover");
        $display("PASS SW3 cache: real SDRAM writer/FIFOs, all nine distinct slots, exact black-bar/cover data, debounce, pending ACK, UI pause, rapid toggles during decode, visible-bank protection and no-read cache hits");$finish;
    end
    initial begin #150000000;$fatal(1,"nine bank timeout S%h E%h valid%h starts%0d",state,error,valid,starts);end
endmodule
