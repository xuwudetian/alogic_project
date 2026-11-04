`timescale 1ns/1ps
module tb_audio;
    reg clk=0,rst=1,mute=0;
    reg [3:0] volume=8;
    reg [3:0] picture=0;
    wire valid,acr;
    wire [23:0] left,right;
    wire [19:0] cts,n;
    integer cycle=0,count=0,last=0,acr_count=0;
    player_audio dut(clk,rst,picture,volume,mute,valid,left,right,acr,cts,n);
    always #5 clk=~clk;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(cycle=1;cycle<=250000;cycle=cycle+1) begin
            @(posedge clk);#1;
            if(valid) begin
                count=count+1;
                if(count>1 && cycle-last!=520 && cycle-last!=521) $fatal(1,"sample spacing");
                last=cycle;
                if(left!==right || left[7:0]!==0) $fatal(1,"PCM format");
                if($signed(left)>3072000 || $signed(left)<-3072000) $fatal(1,"amplitude");
            end
            if(acr) acr_count=acr_count+1;
        end
        if(count!=480 || cts!=25000 || n!=6144 || acr_count!=4) $fatal(1,"48k / ACR contract");
        @(negedge clk);picture=4;#1;
        if(dut.increment!==32'd98426334) $fatal(1,"fifth picture tone");
        picture=5;#1;if(dut.increment!==32'd118111601) $fatal(1,"sixth picture tone");
        picture=15;#1;if(dut.increment!==32'd39370534) $fatal(1,"invalid picture leaves latched tone");
        @(negedge clk);mute=1;
        repeat(600) @(posedge clk);
        if(left!==0) $fatal(1,"mute");
        $display("PASS audio: exact 480 samples/250000 clocks, stereo, ACR, mute");
        $finish;
    end
endmodule
