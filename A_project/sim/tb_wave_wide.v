`timescale 1ns/1ps
module tb_wave_wide;
    reg clk=0,rst=1,vs=1,av=0;
    reg signed [23:0] sample=0;
    integer n,g,count,old_bank;
    reg [13:0] frozen[0:127];
    player_video #(.WAVE_TRIGGER_ENABLE(0),.WAVE_SMOOTH_ENABLE(0)) dut(
        .clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd4),.interval_seconds(4'd3),.transition_mode(4'd0),.menu(3'd0),.modes(4'd0),
        .audio_valid(av),.audio_sample(sample),.debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1));
    always #20 clk=~clk;
    task feed(input integer value);
        begin @(negedge clk);av=1;sample=value;@(negedge clk);av=0;repeat(3) @(negedge clk);end
    endtask
    task frame;
        begin vs=0;repeat(3) @(negedge clk);vs=1;repeat(3) @(negedge clk);end
    endtask
    task reset_dut;
        begin rst=1;av=0;repeat(3) @(negedge clk);rst=0;end
    endtask
    initial begin
        reset_dut;
        for(n=0;n<1023;n=n+1) begin
            feed(4194304);
            if(dut.wave_ready) $fatal(1,"capture shorter than 1024 input samples");
        end
        feed(4194304);
        if(!dut.wave_ready || dut.wave_valid) $fatal(1,"long block completion failed");
        for(n=0;n<128;n=n+1) begin
            if(dut.wave[n][6:0]!=24) $fatal(1,"half-scale amplitude not boosted from 28 to 40px");
            frozen[n]=dut.wave[n];
        end
        repeat(50) feed(-8388608);
        for(n=0;n<128;n=n+1) if(dut.wave[n]!==frozen[n]) $fatal(1,"ready block overwritten");
        frame;
        if(!dut.wave_valid || dut.wave_frame_wait!=2) $fatal(1,"two-frame capture budget not set");
        old_bank=dut.display_bank;
        repeat(2) begin repeat(200) feed(-8388608);frame;end
        if(dut.wave_hold_frame || dut.sample_index!=0) $fatal(1,"hold/capture scheduling mismatch");
        repeat(700) feed(-8388608);frame;
        if(dut.display_bank!=old_bank) $fatal(1,"partial long window became visible");
        repeat(324) feed(-8388608);frame;
        if(dut.display_bank==old_bank) $fatal(1,"complete long window did not publish");
        for(n=0;n<128;n=n+1)
            if(dut.wave[{dut.display_bank,7'd0}+n][6:0]!=127) $fatal(1,"negative saturation wrapped");
        reset_dut;
        repeat(1024) feed(8388607);
        if(dut.wave[127][6:0]!=0) $fatal(1,"positive saturation wrapped");
        reset_dut;
        for(n=0;n<1024;n=n+1) feed(n%2==0 ? 8388607 : -8388608);
        for(n=0;n<128;n=n+1) if(dut.wave[n][6:0]!=64) $fatal(1,"group averaging alias rejection failed");
        // Saturated bottom line must remain visible, and stay outside spectrum.
        force dut.wave_valid=1;
        @(negedge clk);dut.xp[2]=100;dut.yp[2]=343;
        force dut.line_a2=127;force dut.line_b2=127;
        @(posedge clk);#1;if(!dut.line_hit3) $fatal(1,"127+1 overflow dropped bottom line");
        @(negedge clk);dut.xp[2]=100;dut.yp[2]=352;@(posedge clk);#1;
        if(dut.line_hit3) $fatal(1,"wave intruded into spectrum");
        release dut.wave_valid;release dut.line_a2;release dut.line_b2;
        $display("PASS wide waveform: 1024 samples=21.33ms, 4x window, 10/7 gain, averaging, frozen/partial banks, clipping boundaries");
        $finish;
    end
    initial begin #10000000;$fatal(1,"wide waveform timeout");end
endmodule
