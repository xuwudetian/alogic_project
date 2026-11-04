`timescale 1ns/1ps
module tb_music_dynamics;
    reg clk=0,rst=1,frame=0,fixed_audio=1,av=0;
    reg signed [23:0] pcm=0;
    wire beat;wire [23:0] color;
    integer i,j,beats=0;reg [23:0] old_color,bright_color;
    always #5 clk=~clk;
    player_music_dynamics dut(clk,rst,frame,fixed_audio,av,pcm,beat,color);
    always @(negedge clk) if(beat) beats=beats+1;
    task tick_frame;begin
        @(negedge clk);frame=1;@(negedge clk);frame=0;
    end endtask
    task window;input integer amplitude;begin
        for(j=0;j<256;j=j+1) begin
            @(negedge clk);av=1;pcm=(j%2==0 ? amplitude : -amplitude)*256;
            @(negedge clk);av=0;
        end
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(i=0;i<5;i=i+1) begin
            window(i*7000);tick_frame;
            if(color!==24'hffff00 || beat || beats) $fatal(1,"fixed source brightness/beat changed");
        end
        fixed_audio=0;window(0);tick_frame;old_color=color;
        window(16000);
        if(beats!=1 || color!=old_color) $fatal(1,"onset missing or tint changed mid-frame");
        tick_frame;if(color[15:8]<=old_color[15:8]) $fatal(1,"music brightness did not rise");
        for(i=0;i<40;i=i+1) begin window(16000);tick_frame;end
        if(beats!=1) $fatal(1,"steady PCM retriggered %0d beats",beats);
        bright_color=color;
        for(i=0;i<50;i=i+1) begin window(0);tick_frame;end
        if(color[15:8]>=bright_color[15:8] || color!==24'hbfbf00) $fatal(1,"silence did not decay to base tint");
        window(24000);if(beats!=2) $fatal(1,"next clear onset not detected");
        window(0);window(30000);if(beats!=2) $fatal(1,"refractory window failed");
        fixed_audio=1;tick_frame;
        if(color!==24'hffff00) $fatal(1,"switching to fixed source did not restore fixed tint");
        $display("PASS dynamics: PCM onsets, sustained tone rejection, cooldown, frame-stable shared tint, silence decay, fixed brightness");$finish;
    end
endmodule
