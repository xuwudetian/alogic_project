`timescale 1ns/1ps
module tb_triggered_wave;
    reg clk=0,rst=1,de=0,frame=0,av=0;
    reg [9:0] x=0;reg [8:0] y=0;reg signed [23:0] sample=0;wire [1:0] ink;
    integer n,i,low,high,upcross,writes=0,commits=0,reference_point,reference_pcm;
    reg old_bank,was_commit;reg [6:0] snapshot[0:255];
    reg [1:0] expected[0:4];integer expected_y,a,b,phase,index,lo,hi;
    player_triggered_wave #(.IDLE_CYCLES(20000)) dut(clk,rst,de,frame,x,y,av,sample,ink,1'b0);
    always #5 clk=~clk;
    always @(posedge clk) begin
        old_bank=dut.display_bank;was_commit=!rst && frame && !de && dut.ready;
        if(!rst && dut.take && !dut.timeout_idle) begin
            if(dut.valid && dut.capture_bank==dut.display_bank) $fatal(1,"write to visible bank");
            reference_pcm=$signed(dut.pcm);
            reference_point=64-((reference_pcm+(reference_pcm>>>1))>>>9);
            if(reference_point<8) reference_point=8;
            if(reference_point>120) reference_point=120;
            if(dut.point!==7'(reference_point)) $fatal(1,"gain/saturation mismatch pcm%0d",reference_pcm);
            writes=writes+1;
        end
        #1;
        if(!rst && dut.display_bank!=old_bank) begin
            if(!was_commit || writes!=256) $fatal(1,"non-atomic frame: writes=%0d",writes);
            writes=0;commits=commits+1;
        end
    end
    task send_sine;input integer k;begin
        @(negedge clk);av=1;sample=$rtoi(18000.0*$sin(6.283185307179586*k/48.0))*256;
        @(negedge clk);av=0;repeat(2) @(negedge clk);
    end endtask
    task tick_frame;begin
        @(negedge clk);de=0;frame=1;@(negedge clk);frame=0;
    end endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(n=0;n<900;n=n+1) send_sine(n);
        if(!dut.ready || dut.valid || writes!=256) $fatal(1,"incomplete block or early publish");
        tick_frame;
        low=127;high=0;upcross=0;
        for(i=0;i<256;i=i+1) begin
            snapshot[i]=dut.points[{dut.display_bank,8'(i)}][6:0];
            if(snapshot[i]<low) low=snapshot[i];if(snapshot[i]>high) high=snapshot[i];
            if(i>0 && snapshot[i-1]>64 && snapshot[i]<=64) upcross=upcross+1;
        end
        if(low<10 || low>14 || high<114 || high>118 || upcross<4 || upcross>6)
            $fatal(1,"not 1.5x signed sine low=%0d high=%0d cycles=%0d",low,high,upcross);
        // Check every pixel against one stored waveform, including its five-stage pipeline.
        for(i=0;i<5;i=i+1) expected[i]=0;
        for(expected_y=210;expected_y<350;expected_y=expected_y+1) begin
            for(n=0;n<650;n=n+1) begin
                @(negedge clk);de=n<640;x=n<640 ? n : 0;y=expected_y;
                av=(n%200)==0;sample=0;
                for(i=4;i>0;i=i-1) expected[i]=expected[i-1];
                expected[0]=0;index=(n*2)/5;phase=(n*2)%5;
                if(n>=8 && n<632 && expected_y>=216 && expected_y<344) begin
                    a=((5-phase)*snapshot[index]+phase*snapshot[index+1]+2)/5;
                    index=((n-1)*2)/5;phase=((n-1)*2)%5;
                    b=((5-phase)*snapshot[index]+phase*snapshot[index+1]+2)/5;
                    lo=a<b ? a:b;hi=a>b ? a:b;
                    if(expected_y-216>=lo && expected_y-216<=hi) expected[0]=2;
                    else if(expected_y-215==lo || expected_y-216==hi+1) expected[0]=1;
                end
                @(posedge clk);#1;
                if(ink!==expected[4]) $fatal(1,"ink mismatch x%0d y%0d got%0d want%0d",n,expected_y,ink,expected[4]);
            end
        end
        av=0;de=0;tick_frame;tick_frame;
        for(n=900;n<1800;n=n+1) send_sine(n);
        if(!dut.ready) $fatal(1,"second capture missing");
        tick_frame;
        if(commits!=2) $fatal(1,"frame count");
        repeat(20010) @(negedge clk);
        if(dut.valid || ink) $fatal(1,"idle must clear waveform");
        force dut.pcm=16'sh7fff;#1;if(dut.point!==7'd8) $fatal(1,"positive saturation wraps");
        force dut.pcm=16'sh8000;#1;if(dut.point!==7'd120) $fatal(1,"negative saturation wraps");
        force dut.pcm=16'sd0;#1;if(dut.point!==7'd64) $fatal(1,"zero center");release dut.pcm;
        $display("PASS triggered wave: signed sine, 256 samples, phase trigger, atomic banks, full pixel reference, idle clear");$finish;
    end
    initial begin #3000000;$fatal(1,"wave timeout");end
endmodule
