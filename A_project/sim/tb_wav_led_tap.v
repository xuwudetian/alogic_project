`timescale 1ns/1ps
module tb_wav_led_tap;
    reg clk=0,rst=1,tick=0,mute=0;
    wire valid,wav_sample_valid;
    wire [23:0] pcm;
    always #5 clk=~clk;
    media_wav dut(.clk(clk),.rst(rst),.enable(1'b0),.found(1'b0),.cluster(32'd0),.size(32'd0),
        .spc(8'd1),.fat_lba(32'd0),.data_lba(32'd0),.max_cluster(32'd100),.sector_busy(1'b0),
        .sector_valid(1'b0),.sector_byte(8'd0),.byte_index(9'd0),.sector_done(1'b0),.sector_error(8'd0),
        .audio_clk(clk),.audio_rst(rst),.tick(tick),.tone(24'h123400),.volume(4'd4),.mute(mute),
        .valid(valid),.pcm(pcm),.wav_sample_valid(wav_sample_valid));
    task step;
        input t;input tag;input [23:0] expected;
        begin
            tick=t;@(negedge clk);
            if(valid!==t || wav_sample_valid!==tag || pcm!==expected)
                $fatal(1,"PCM/tap alignment t=%b tag=%b pcm=%h expected=%h",t,wav_sample_valid,pcm,expected);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;repeat(4) @(negedge clk);
        step(1,0,24'h123400); // No WAV: oscillator remains audible, never tagged.
        force dut.accept_sync=2'b11;force dut.disable_sync=0;
        force dut.playing=1;force dut.empty=0;force dut.fifo_sample=16'h8000;
        step(1,1,24'hc00000); // Existing volume scaling, including signed minimum.
        step(0,0,24'hc00000);
        mute=1;step(1,1,24'd0);mute=0;
        force dut.empty=1;step(1,0,24'd0); // Underflow is not a new WAV sample.
        force dut.empty=0;force dut.disable_sync=2'b11;step(1,0,24'h123400);
        force dut.disable_sync=0;step(1,1,24'hc00000);
        rst=1;#1;
        if(valid!==0 || wav_sample_valid!==0 || pcm!==0) $fatal(1,"hotplug/reset left a stale tap");
        release dut.accept_sync;release dut.disable_sync;release dut.playing;
        release dut.empty;release dut.fifo_sample;
        repeat(3) @(negedge clk);rst=0;repeat(4) @(negedge clk);
        step(1,0,24'h123400);
        $display("PASS WAV LED tap: sample/tag alignment, fallback excluded, gain/mute unchanged, underrun/disabled/reset excluded");$finish;
    end
    initial begin #10000;$fatal(1,"WAV tap timeout");end
endmodule
