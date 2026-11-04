`timescale 1ns/1ps
module tb_wave_schedule;
    reg clk=0,rst=1,vs=1,av=0;
    reg signed [23:0] sample=0;
    integer rate=0,n,k,cycle_count;
    reg saved_bank,old_bank,edge_tick;
    reg [13:0] snapshot[0:127];
    player_video #(.WAVE_DECIMATE_LOG2(1),.WAVE_GAIN_BOOST(0)) dut(.clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(4'd0),
        .audio_valid(av),.audio_sample(sample),.debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1));
    always #20 clk=~clk;
    // A commit must never happen during the body of a frame.
    always @(posedge clk) begin
        old_bank=dut.display_bank;edge_tick=dut.frame_tick;
        #1;
        if(!rst && old_bank!==dut.display_bank && !edge_tick)
            $fatal(1,"bank changed outside frame boundary");
    end
    task run_samples;
        input integer clocks,value;
        input enabled;
        integer c;
        begin
            for(c=0;c<clocks;c=c+1) begin
                @(negedge clk);sample=value;av=0;
                if(enabled) begin
                    rate=rate+48000;
                    if(rate>=25000000) begin rate=rate-25000000;av=1;end
                end
            end
            @(negedge clk);av=0;repeat(3) @(negedge clk);
        end
    endtask
    task boundary;
        begin vs=0;repeat(3) @(negedge clk);vs=1;repeat(3) @(negedge clk);end
    endtask
    task remember;
        begin
            saved_bank=dut.display_bank;
            for(n=0;n<128;n=n+1) snapshot[n]=dut.wave[{saved_bank,7'd0}+n];
        end
    endtask
    task unchanged;
        begin
            if(dut.display_bank!==saved_bank) $fatal(1,"premature frame replacement");
            for(n=0;n<128;n=n+1)
                if(dut.wave[{saved_bank,7'd0}+n]!==snapshot[n]) $fatal(1,"display bank overwritten");
        end
    endtask
    task wait_three_frames;
        begin
            remember;
            for(k=0;k<3;k=k+1) begin
                // Early positive samples must never become the next captured block.
                run_samples(420000,4194304,1);
                unchanged;
                if(dut.sample_index!=0 || dut.wave_ready || dut.trigger_wait!=0)
                    $fatal(1,"capture began before final frame");
                boundary;unchanged;
            end
            if(dut.wave_hold_frame || $signed(dut.visual_pcm)<16380)
                $fatal(1,"late capture not opened or filter failed to follow during hold");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        run_samples(420000,0,1);
        if(!dut.wave_ready || dut.wave_valid) $fatal(1,"startup capture failed");
        boundary;
        if(!dut.wave_valid || dut.wave_frame_wait!=3) $fatal(1,"first frame delayed");
        // Steady cadence: exactly the fourth subsequent boundary commits.
        repeat(2) begin
            wait_three_frames;
            run_samples(420000,-4194304,1);
            unchanged;
            if(!dut.wave_ready) $fatal(1,"late capture missed nominal deadline");
            for(n=0;n<128;n=n+1)
                if(dut.wave[{dut.capture_bank,7'd0}+n][6:0]!=92)
                    $fatal(1,"captured old early-window audio instead of recent audio");
            boundary;
            if(dut.display_bank===saved_bank || dut.wave_frame_wait!=3)
                $fatal(1,"fourth frame did not commit");
        end
        // An incomplete block at its target boundary must remain hidden.
        wait_three_frames;
        run_samples(5200,-4194304,1);
        if(dut.wave_ready) $fatal(1,"partial block marked ready");
        boundary;unchanged;
        run_samples(420000,-4194304,1);
        if(!dut.wave_ready) $fatal(1,"late block never completed");
        boundary;
        if(dut.display_bank===saved_bank || dut.wave_frame_wait!=3)
            $fatal(1,"late complete block not committed");
        // Loss of sample strobes cancels cadence; returning audio gets first-frame service.
        run_samples(1250010,0,0);
        if(dut.wave_valid || dut.wave_ready || dut.wave_frame_wait!=0 || dut.smooth_state!=0)
            $fatal(1,"idle did not clear scheduling state");
        run_samples(420000,0,1);
        boundary;
        if(!dut.wave_valid || dut.wave[{dut.display_bank,7'd0}][6:0]!=64)
            $fatal(1,"restart not displayed promptly");
        $display("PASS wave schedule: four-frame cadence, late capture, continuous filter, no partial swaps, missing-sample recovery");
        $finish;
    end
    initial begin #400000000;$fatal(1,"wave scheduling timeout");end
endmodule
