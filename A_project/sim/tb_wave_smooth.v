`timescale 1ns/1ps
module tb_wave_smooth;
    reg clk=0,rst=1,av=0,vs=1;
    reg signed [23:0] sample=0;
    integer model=0,updated,pcm16,previous,n,k,guard,peak,cy;
    reg [13:0] frozen[0:127];
    player_video #(.WAVE_DECIMATE_LOG2(1),.WAVE_GAIN_BOOST(0)) dut(.clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(4'd0),
        .audio_valid(av),.audio_sample(sample),.debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1));
    always #5 clk=~clk;
    task reset_dut;
        begin
            @(negedge clk);rst=1;av=0;vs=1;model=0;
            repeat(3) @(negedge clk);rst=0;
        end
    endtask
    task feed;
        input integer value;
        begin
            @(negedge clk);sample=value;av=1;
            pcm16=value>>>8;
            updated=model+(((pcm16*4)-model)>>>2);
            @(posedge clk);#1;
            if($signed(dut.smooth_state)!==updated || $signed(dut.visual_pcm)!==(updated>>>2) || !dut.visual_valid)
                $fatal(1,"filter arithmetic value=%0d got=%0d expected=%0d",value,$signed(dut.visual_pcm),updated>>>2);
            model=updated;
            @(negedge clk);av=0;sample=24'h7fffff;
            repeat(3) @(negedge clk);
            if($signed(dut.smooth_state)!==model || dut.visual_valid)
                $fatal(1,"invalid cycles changed filter");
            if(dut.wave_y<8 || dut.wave_y>120) $fatal(1,"display margin overflow");
        end
    endtask
    task frame;
        begin @(negedge clk);vs=0;repeat(3) @(negedge clk);vs=1;repeat(3) @(negedge clk);end
    endtask
    initial begin
        reset_dut;
        // Both full-scale polarities settle without arithmetic overflow or clipping.
        for(k=0;k<2;k=k+1) begin
            reset_dut;
            repeat(650) feed(k==0 ? 8388607 : -8388608);
            if(!dut.wave_ready) $fatal(1,"DC capture timeout");
            for(n=0;n<128;n=n+1)
                if(dut.wave[{dut.capture_bank,7'd0}+n][6:0] !== (k==0 ? 7'd8 : 7'd120))
                    $fatal(1,"full-scale did not preserve margins");
        end
        // The filter keeps following audio after capture finishes, without corrupting RAM.
        for(n=0;n<128;n=n+1) frozen[n]=dut.wave[{dut.capture_bank,7'd0}+n];
        repeat(120) feed(8388607);
        if($signed(dut.visual_pcm)<32760) $fatal(1,"filter froze with ready block");
        for(n=0;n<128;n=n+1)
            if(frozen[n]!==dut.wave[{dut.capture_bank,7'd0}+n]) $fatal(1,"ready RAM overwritten");
        // High-frequency alternating input is attenuated; silence settles at the center.
        reset_dut;peak=0;
        for(n=0;n<160;n=n+1) begin
            feed(n%2==0 ? 8388607 : -8388608);
            if(n>80) begin
                cy=$signed(dut.visual_pcm);if(cy<0) cy=-cy;
                if(cy>peak) peak=cy;
            end
        end
        if(peak>5000 || peak<4000) $fatal(1,"unexpected alternating-signal attenuation %0d",peak);
        repeat(100) feed(0);
        if($signed(dut.visual_pcm)<-1 || $signed(dut.visual_pcm)>1) $fatal(1,"silence filter residue");
        // Trigger and render heights must use the same filtered pair.
        reset_dut;guard=0;
        while(!dut.wave_ready && guard<800) begin
            previous=dut.sample_index;
            feed($rtoi(6000000.0*$sin(6.283185307179586*guard/96.0)));
            if(previous==0 && dut.sample_index==1 && !dut.trigger_active)
                $fatal(1,"capture without trigger");
            guard=guard+1;
        end
        if(!dut.wave_ready) $fatal(1,"filtered sine trigger stuck");
        if(dut.wave[{dut.capture_bank,7'd0}][6:0]<55 || dut.wave[{dut.capture_bank,7'd0}][6:0]>64)
            $fatal(1,"filtered sine did not start near upward crossing");
        frame;
        if(!dut.wave_valid) $fatal(1,"first frame not committed");
        repeat(1250005) @(negedge clk);
        if(dut.wave_valid || dut.wave_ready || dut.smooth_state!=0) $fatal(1,"idle did not clear filter");
        model=0;
        feed(4194304);
        if($signed(dut.visual_pcm)!=4096) $fatal(1,"restart retained old history");
        $display("PASS smooth waveform: full-scale margins, continuous filtering, frozen RAM, HF attenuation, silence, filtered trigger, idle/restart");
        $finish;
    end
    initial begin #50000000;$fatal(1,"smooth test timeout");end
endmodule
