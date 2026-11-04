`timescale 1ns/1ps
module tb_wave_wide_schedule;
    reg clk=0,rst=1,vs=1,av=0;
    reg signed [23:0] sample=0;
    integer rate=0,f,c,k,commits=0,last_commit=-1,expected_height;
    reg bank,edge_tick,previous_bank;
    player_video dut(.clk(clk),.rst(rst),.hs(1'b1),.vs(vs),.de(1'b0),.rgb(24'd0),
        .brightness(9'sd0),.contrast(9'd128),.gain(9'd256),.display_valid(1'b1),
        .picture(3'd0),.scaled(1'b0),.auto_play(1'b0),.error_code(8'd0),.state_code(4'd0),
        .volume(4'd8),.interval_seconds(4'd3),.menu(3'd0),.modes(4'd0),
        .audio_valid(av),.audio_sample(sample),.debug_status(60'd0),.audio_status(8'd0),.image_valid(1'b1));
    always #20 clk=~clk;
    always @(posedge clk) begin
        previous_bank=dut.display_bank;edge_tick=dut.frame_tick;
        #1;if(!rst && previous_bank!==dut.display_bank && !edge_tick) $fatal(1,"non-atomic waveform commit");
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(f=0;f<10;f=f+1) begin
            bank=dut.display_bank;
            // No upward crossing: default trigger must time out within 8ms,
            // then complete 21.33ms capture across two video frames.
            sample=f<4 ? 4194304 : -4194304;
            for(c=0;c<420000;c=c+1) begin
                @(negedge clk);av=0;rate=rate+48000;
                if(rate>=25000000) begin rate=rate-25000000;av=1;end
            end
            @(negedge clk);av=0;vs=0;repeat(4) @(negedge clk);vs=1;repeat(4) @(negedge clk);
            if(dut.display_bank!==bank) begin
                if(last_commit>=0 && f-last_commit!=4) $fatal(1,"default cadence is not four frames");
                expected_height=f<4 ? 24 : 104;
                for(k=0;k<128;k=k+1)
                    if(dut.wave[{dut.display_bank,7'd0}+k][6:0]!=expected_height)
                        $fatal(1,"stale/partial/default gain sample at frame %0d point %0d",f,k);
                if(dut.wave_frame_wait!=2) $fatal(1,"capture budget incorrect");
                last_commit=f;commits=commits+1;
            end
            if(f==0 && dut.wave_valid) $fatal(1,"long capture published within one frame");
            if(f==1 && !dut.wave_valid) $fatal(1,"startup long capture failed");
        end
        if(commits!=3) $fatal(1,"expected 3 fresh blocks, got %0d",commits);
        repeat(1250010) @(negedge clk);
        if(dut.wave_valid || dut.wave_ready || dut.wave_frame_wait!=0) $fatal(1,"idle did not cancel long capture");
        $display("PASS default wide wave schedule: real 48kHz, 8ms trigger timeout, 21.33ms capture, 4-frame cadence, recent audio, atomic swap, idle");$finish;
    end
    initial begin #300000000;$fatal(1,"real-rate wide schedule timeout");end
endmodule
