`timescale 1ns/1ps
module tb_alarm_audio;
    reg clk=0,rst=1,enable=0,mute=0;
    wire tick,valid,acr;
    wire [23:0] tone,pcm;
    integer count=0,n,changes=0;
    reg [23:0] previous;
    always #20 clk=~clk;
    player_audio source(.clk(clk),.rst(rst),.picture(3'd0),.volume(4'd4),.mute(1'b0),
        .valid(tick),.left(tone),.right(),.acr_valid(acr),.acr_cts(),.acr_n());
    player_alarm_audio dut(.clk(clk),.rst(rst),.enable(enable),.tick(tick),.mute(mute),.volume(4'd4),
        .media_valid(tick),.media_pcm(24'h123456),.valid(valid),.pcm(pcm));
    initial begin
        repeat(4) @(negedge clk);rst=0;
        wait(valid);@(negedge clk);if(pcm!=24'h123456) $fatal(1,"media bypass");
        enable=1;previous=0;
        for(n=0;n<25000000;n=n+1) begin
            @(negedge clk);
            if(valid) begin count=count+1;if(pcm!=previous) changes=changes+1;previous=pcm;end
        end
        if(count!=48000 || changes<40000) $fatal(1,"rate or tone %0d %0d",count,changes);
        mute=1;repeat(600) @(negedge clk);if(pcm!=0) $fatal(1,"alarm mute");
        enable=0;repeat(600) @(negedge clk);if(pcm!=24'h123456) $fatal(1,"restore media");
        $display("PASS alarm: 48000 samples/sec, changing siren, mute, media restoration");$finish;
    end
    initial begin #1100000000;$fatal(1,"alarm timeout");end
endmodule
