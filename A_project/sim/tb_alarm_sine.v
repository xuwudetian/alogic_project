`timescale 1ns/1ps
module tb_alarm_sine;
    reg clk=0,rst=1,enable=0,tick=0,mute=0,media_valid=0;
    reg [3:0] volume=4;
    wire valid;wire [23:0] pcm;
    integer n,v,k,expected,got,amplitude;
    reg [31:0] old_phase,step;
    reg old_tone;
    real sine_value;
    always #5 clk=~clk;
    player_alarm_audio dut(.clk(clk),.rst(rst),.enable(enable),.tick(tick),.mute(mute),
        .volume(volume),.media_valid(media_valid),.media_pcm(24'h123456),.valid(valid),.pcm(pcm));
    task check_tick;begin
        old_phase=dut.phase;old_tone=dut.high_tone;
        k=old_phase[31:24];
        sine_value=16384.0*$sin(6.283185307179586*k/256.0);
        amplitude=$rtoi(sine_value>=0 ? sine_value+0.5 : sine_value-0.5);
        expected=amplitude*$signed({1'b0,volume});
        expected=mute ? 0 : expected>>>3;
        step=old_tone ? 32'd107374182 : 32'd71582788;
        tick=1;@(posedge clk);#1;
        if(dut.phase!==old_phase+step) $fatal(1,"DDS phase/frequency changed");
        @(negedge clk);tick=0;@(posedge clk);#1;got=$signed(pcm[23:8]);
        if(!valid || got!=expected || pcm[7:0]!=0)
            $fatal(1,"sine mismatch phase%h volume%0d got%0d expected%0d",old_phase,volume,got,expected);
        @(negedge clk);@(negedge clk);
        if(valid) $fatal(1,"valid outside sample tick");
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;enable=1;
        // Check every table address and all editable volume values.
        for(v=0;v<16;v=v+1) begin
            volume=v;
            for(n=0;n<256;n=n+1) begin dut.phase={8'(n),24'd0};check_tick;end
        end
        enable=0;@(negedge clk);enable=1;volume=4;
        // Continuous low/high/low alternation without reinitializing phase.
        for(n=0;n<48001;n=n+1) begin
            if(dut.high_tone!==(n>=24000 && n<48000)) $fatal(1,"half-second interval");
            check_tick;
        end
        mute=1;check_tick;mute=0;
        enable=0;media_valid=1;repeat(2) @(negedge clk);
        if(!valid || pcm!==24'h123456) $fatal(1,"media restoration");
        $display("PASS alarm sine: all 256 phases, 16 volume levels, signed output, 800/1200Hz phase steps, half-second switch, mute and bypass");
        $finish;
    end
    initial begin #3000000;$fatal(1,"sine timeout");end
endmodule
