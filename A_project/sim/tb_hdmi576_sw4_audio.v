`timescale 1ns/1ps
// Real top, synchronized physical switch, tone generator, WAV gain/fallback,
// output pipeline and visuals. Inject FIFO PCM instead of an external SD card.
module tb_hdmi576_sw4_audio;
    reg clk=0;
    reg [3:0] switches=0;
    reg wav_available=0,bad_file=0,audio_reset=1,missing_card=0,mute=0;
    reg [3:0] test_volume=8,test_picture=0;
    reg [15:0] fifo_word=16'h2800;
    wire [3:0] test_modes={1'b0,mute,2'b00};
    tri1 sensor_scl,sensor_sda,eth_mdio;
    wire [5:0] seg_sel;
    wire [7:0] seg_data;
    integer ticks=0,consumed=0,outputs=0,previous_cycle=0,cycles=0,p,k,baseline;
    reg monitor=0,pending_valid=0;
    reg [23:0] media_reference=0,pending_pcm=0,next_pcm,check_pcm;
    reg check_valid;
    reg signed [20:0] scaled;
    reg frequency_check=0;
    reg signed [23:0] last_pcm=0;
    integer crossings=0,last_crossing=0;
    always #10 clk=~clk;
    top #(.BOOT_HOLD_CYCLES(100)) dut(.clk(clk),.rst_n(1'b1),
        .key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(switches),.sd_miso(1'b1),
        .sensor_scl(sensor_scl),.sensor_sda(sensor_sda),.uart_rx(1'b1),
        .eth_rx_clk(1'b0),.eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(eth_mdio),
        .seg_sel(seg_sel),.seg_data(seg_data));

    always @(posedge dut.video_clk) begin
        if(monitor) begin
            cycles=cycles+1;
            check_valid=pending_valid;check_pcm=pending_pcm;
            pending_valid=missing_card ? dut.tone_valid_delayed : dut.media_valid;
            if(dut.media_valid && !missing_card) begin
                if(dut.media_pcm!==media_reference)
                    $fatal(1,"WAV fallback/gain reference mismatch got=%h expected=%h",dut.media_pcm,media_reference);
            end
            if(pending_valid)
                pending_pcm=(missing_card || dut.physical_switches[3]) ? dut.tone_left : media_reference;
            if(audio_reset) media_reference=0;
            else if(dut.tone_valid) begin
                ticks=ticks+1;
                if(!dut.storage.wav.accept_sync[1] || dut.storage.wav.disable_sync[1])
                    media_reference=dut.tone_left;
                else if(dut.storage.wav.pop) begin
                    scaled=$signed(fifo_word)*$signed({1'b0,test_volume});
                    media_reference=mute ? 24'd0 : {scaled[18:3],8'd0};
                    consumed=consumed+1;
                end else media_reference=0;
            end
            #1;
            if(dut.audio_valid!==check_valid)
                $fatal(1,"SW4 inserted/dropped an output valid pulse");
            if(check_valid) begin
                if(dut.audio_left!==check_pcm || dut.audio_right!==check_pcm)
                    $fatal(1,"SW4 output mismatch sw=%b wav=%b got=%h expected=%h",switches[3],wav_available,dut.audio_left,check_pcm);
                if(outputs!=0 && cycles-previous_cycle!=562 && cycles-previous_cycle!=563)
                    $fatal(1,"SW4 changed 48 kHz output sample spacing: %0d",cycles-previous_cycle);
                previous_cycle=cycles;outputs=outputs+1;
                if(frequency_check && last_pcm<=0 && $signed(dut.audio_left)>0) begin
                    if(crossings!=0 && outputs-last_crossing!=48)
                        $fatal(1,"missing-card tone period %0d samples, expected 48",outputs-last_crossing);
                    crossings=crossings+1;last_crossing=outputs;
                end
                last_pcm=$signed(dut.audio_left);
            end
            if(seg_sel!==dut.diagnostic_sel || seg_data!==dut.diagnostic_data || dut.seg_sel_extra!==3)
                $fatal(1,"SW4 audio selection changed diagnostic scanning");
            if(dut.effects.audio_sample!==dut.audio_left || dut.spectrum_display.audio_sample!==dut.audio_left)
                $fatal(1,"audio waveform/spectrum disconnected from selected output");
        end
    end
    task hear;
        input integer count;
        integer target;
        begin target=outputs+count;wait(outputs>=target);@(negedge dut.video_clk);end
    endtask
    initial begin
        wait(!dut.rst_video && !dut.rst_board);
        force dut.alarm=0;force dut.volume=test_volume;force dut.modes=test_modes;
        force dut.active_picture=test_picture;force dut.no_signal_frame=missing_card;
        force dut.storage.wav.read_reset=audio_reset;
        force dut.storage.wav.accepted_once=wav_available;
        force dut.storage.wav.disabled=bad_file;
        force dut.storage.wav.ended=0;
        force dut.storage.wav.rdused=10'd1023;force dut.storage.wav.empty=0;
        force dut.storage.wav.fifo_sample=fifo_word;
        repeat(5) @(negedge dut.video_clk);
        audio_reset=0;monitor=1;
        // No WAV: each of nine image tones must be identical in both positions.
        for(p=0;p<9;p=p+1) begin
            test_picture=p;switches=0;hear(5);switches=8;hear(5);
        end
        // Valid WAV: PCM at SW4=0, tone at SW4=1. Decode keeps advancing.
        wav_available=1;switches=0;hear(12);
        baseline=consumed;switches=8;hear(12);
        if(consumed<baseline+10) $fatal(1,"built-in tone paused/restarted WAV consumption");
        fifo_word=16'he000;switches=0;hear(8);
        // Switch at varying offsets from sample boundaries, including bounce.
        for(k=0;k<12;k=k+1) begin
            repeat(73+k*13) @(negedge dut.video_clk);
            switches=switches^8;
        end
        hear(6);
        test_volume=3;switches=0;hear(6);switches=8;hear(6);
        mute=1;switches=0;hear(6);switches=8;hear(6);
        if(dut.audio_left!==0) $fatal(1,"SW4 bypassed mute");
        mute=0;test_volume=0;switches=0;hear(6);switches=8;hear(6);
        if(dut.audio_left!==0) $fatal(1,"SW4 bypassed zero volume");
        test_volume=8;bad_file=1;switches=0;hear(6);switches=8;hear(6);
        // A missing card must sound even while the WAV FIFO stays in reset.
        bad_file=0;missing_card=1;audio_reset=1;switches=0;hear(6);
        if(dut.media_valid!==0) $fatal(1,"test did not hold WAV in reset");
        frequency_check=1;crossings=0;
        for(p=0;p<9;p=p+1) begin
            test_picture=p;switches=0;hear(96);switches=8;hear(96);
        end
        frequency_check=0;
        if(crossings<35 || crossings>37) $fatal(1,"1 kHz tone missing: crossings=%0d",crossings);
        mute=1;hear(8);if(dut.audio_left!==0) $fatal(1,"missing-card tone bypassed mute");
        mute=0;test_volume=0;hear(8);if(dut.audio_left!==0) $fatal(1,"missing-card tone bypassed zero volume");
        test_volume=3;hear(8);test_volume=8;hear(8);
        // Restoring media returns to both original audio sources and cadence.
        audio_reset=0;missing_card=0;switches=0;hear(12);switches=8;hear(12);
        $display("PASS SW4 audio: %0d exact PCM outputs; nine image tones, WAV/SW4 selection, continuous decode, 1 kHz missing-card tone across all images/both switches with FIFO reset, mute/volume, reinsertion, diagnostics and visuals",outputs);
        $finish;
    end
    initial begin #60000000;$fatal(1,"SW4 audio timeout");end
endmodule
