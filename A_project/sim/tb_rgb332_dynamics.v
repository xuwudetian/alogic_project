`timescale 1ns/1ps
module tb_rgb332_dynamics;
    reg clk=0,rst=1,tick=0,fixed_audio=0,valid=0;
    reg signed [23:0] sample=0;
    wire beat0,beat1;wire [23:0] color0,color1;
    reg [23:0] expected_color;reg [6:0] expected_envelope;
    integer n,warmup=0,frames=0,beats=0;
    always #7.6923075 clk=~clk;
    player_music_dynamics original(clk,rst,tick,fixed_audio,valid,sample,beat0,color0);
    player_music_dynamics #(.PIPELINED_COLOR(1)) pipelined(clk,rst,tick,fixed_audio,valid,sample,beat1,color1);
    always @(posedge clk) begin
        expected_color=color0;expected_envelope=original.envelope;
        if(rst) warmup=0;else warmup=warmup+1;
        #1;
        if(warmup>2) begin
            if(color1!==expected_color || pipelined.envelope!==expected_envelope)
                $fatal(1,"frame-color pipeline changed peak/smoothing");
            if(beat0!==beat1) $fatal(1,"beat event changed");
            if(beat1) beats=beats+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(n=0;n<60000;n=n+1) begin
            @(negedge clk);valid=(n%13==0 || n%97==96);tick=n%97==96;
            fixed_audio=(n/1700)%3==0;sample=(n*7919)^(n<<11);
            if(n%1700>1400) sample=0;
            if(tick) frames=frames+1;
        end
        @(negedge clk);valid=0;tick=0;repeat(4) @(negedge clk);
        if(frames<600 || beats==0) $fatal(1,"dynamics stimulus did not exercise windows/beats");
        $display("PASS native music dynamics: exact legacy frame peaks/envelopes/colors delayed one blanking clock over 618 frames, boundary PCM, fixed source, silence and identical beat events");
        $finish;
    end
endmodule
