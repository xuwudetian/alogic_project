`timescale 1ns/1ps
module tb_wave_trigger;
    reg clk=0,rst=1,vs=1,av=0;
    reg signed [23:0] sample=0;
    integer n,k,phase,start_phase,guard;
    reg [6:0] reference[0:127];
    player_video #(.WAVE_DECIMATE_LOG2(1),.WAVE_GAIN_BOOST(0),.WAVE_SMOOTH_ENABLE(0),.WAVE_UPDATE_FRAMES(1)) dut(.clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(4'd0),
        .audio_valid(av),.audio_sample(sample),.debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1));
    always #5 clk=~clk;
    task pair;
        input integer amplitude;
        begin
            av=1;sample=amplitude;@(negedge clk);av=0;repeat(2) @(negedge clk);
            av=1;sample=amplitude;@(negedge clk);av=0;repeat(2) @(negedge clk);
        end
    endtask
    task swap;
        reg saved_bank;
        integer j;
        begin
            saved_bank=dut.display_bank;
            if(dut.wave_valid) begin
                // A ready block must remain immutable even while new PCM arrives.
                for(j=0;j<128;j=j+1) reference[j]=dut.wave[{dut.capture_bank,7'd0}+j][6:0];
                repeat(4) pair(0);
                for(j=0;j<128;j=j+1)
                    if(reference[j]!==dut.wave[{dut.capture_bank,7'd0}+j][6:0])
                        $fatal(1,"ready block overwritten while waiting");
            end
            vs=0;repeat(2) @(negedge clk);vs=1;repeat(5) @(negedge clk);
            if(dut.display_bank===saved_bank || dut.wave_ready || dut.wave_hold_frame)
                $fatal(1,"waveform did not swap on eligible frame");
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        // An isolated negative excursion followed by zero must not start a block.
        repeat(8) begin pair(-1048576);pair(0);end
        if(dut.trigger_armed || dut.trigger_active || dut.sample_index!=0)
            $fatal(1,"isolated negative glitch armed trigger");
        pair(-1048576);pair(-1048576);pair(1048576);
        if(!dut.trigger_active || dut.sample_index!=1)
            $fatal(1,"sustained negative half-cycle failed to trigger");
        while(!dut.wave_ready) pair(-8388608);
        swap;
        // After a loud block, small zero-crossing ripple must not re-arm.
        repeat(8) begin pair(-131072);pair(-131072);pair(0);end
        if(dut.trigger_armed || dut.trigger_active)
            $fatal(1,"adaptive hysteresis accepted small ripple");
        pair(-1048576);pair(-1048576);pair(1048576);
        if(!dut.trigger_active) $fatal(1,"adaptive trigger rejected clean crossing");
        rst=1;repeat(3) @(negedge clk);rst=0;
        // Different start phases of a periodic triangle must produce identical captured blocks.
        for(k=0;k<5;k=k+1) begin
            phase=(k*7)%48;guard=0;
            while(!dut.wave_ready && guard<400) begin
                pair((phase<24 ? phase-12 : 36-phase)*131072);
                phase=(phase+1)%48;guard=guard+1;
            end
            if(!dut.wave_ready) $fatal(1,"trigger stuck");
            for(n=0;n<128;n=n+1) begin
                if(k==0) reference[n]=dut.wave[{dut.capture_bank,7'd0}+n][6:0];
                else if(reference[n]!==dut.wave[{dut.capture_bank,7'd0}+n][6:0])
                    $fatal(1,"phase instability block=%0d point=%0d",k,n);
            end
            swap;
        end
        // DC/silence have no crossing; timeout must still replace old data promptly.
        for(k=0;k<2;k=k+1) begin
            guard=0;
            while(!dut.wave_ready && guard<321) begin pair(k==0 ? 0 : 1048576);guard=guard+1;end
            if(!dut.wave_ready || guard>319) $fatal(1,"auto-trigger timeout %0d",guard);
            swap;
            for(n=0;n<128;n=n+1)
                if(dut.wave[{dut.display_bank,7'd0}+n][6:0] !== (k==0 ? 7'd64 : 7'd57))
                    $fatal(1,"DC/silence retained previous trace");
        end
        // Missing audio must clear both the trace and the refresh wait state.
        repeat(1250002) @(negedge clk);
        if(dut.wave_valid || dut.wave_ready || dut.wave_hold_frame)
            $fatal(1,"idle retained trace or refresh wait state");
        guard=0;
        while(!dut.wave_ready && guard<321) begin pair(0);guard=guard+1;end
        if(!dut.wave_ready) $fatal(1,"restart capture stuck");
        swap;
        $display("PASS wave trigger: glitch rejection, adaptive hysteresis, phase alignment, silence/DC, frozen ready bank, idle/restart");
        $finish;
    end
endmodule
