`timescale 1ns/1ps
module tb_wav;
    reg clk=0,rst=1,start=0,valid=0,ended=0;
    reg [31:0] size=60,offset=0;
    reg [7:0] data=0,bytes[0:127];
    wire sv,accepted,complete;
    wire [15:0] sample;
    wire [7:0] error;
    integer n,count=0,mode=0;
    always #5 clk=~clk;
    wav_pcm_parser dut(clk,rst,start,size,valid,data,offset,ended,sv,sample,accepted,complete,error);
    task u32;input integer p;input [31:0] v;
        begin bytes[p]=v;bytes[p+1]=v>>8;bytes[p+2]=v>>16;bytes[p+3]=v>>24;end
    endtask
    task prepare;
        begin
            for(n=0;n<128;n=n+1) bytes[n]=0;
            size=60;
            u32(0,32'h46464952);u32(4,52);u32(8,32'h45564157);
            u32(12,32'h4b4e554a);u32(16,1);bytes[20]=8'h99;bytes[21]=0;
            u32(22,32'h20746d66);u32(26,18);
            bytes[30]=1;bytes[32]=1;u32(34,48000);u32(38,96000);bytes[42]=2;bytes[44]=16;
            u32(48,32'h61746164);u32(52,4);bytes[56]=8'h34;bytes[57]=8'h12;
            bytes[58]=8'hfe;bytes[59]=8'hff;
        end
    endtask
    task run;
        begin
            count=0;@(negedge clk);start=1;@(negedge clk);start=0;
            for(n=0;n<size;n=n+1) begin
                data=bytes[n];offset=n;valid=1;@(negedge clk);
                valid=0;repeat(2) @(negedge clk);
            end
            ended=1;@(negedge clk);ended=0;repeat(2) @(negedge clk);
        end
    endtask
    always @(negedge clk) if(sv) begin
        if(mode==0 && sample!==(count==0 ? 16'h1234 : 16'hfffe)) $fatal(1,"PCM endian/sign");
        count=count+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;prepare;run;
        if(error || !accepted || count!=2) $fatal(1,"valid RIFF E%h samples%0d",error,count);
        mode=1;prepare;u32(34,44100);run;
        if(error!=8'h52 || accepted || count) $fatal(1,"44.1K accepted");
        prepare;bytes[32]=2;run;
        if(error!=8'h52) $fatal(1,"stereo accepted");
        prepare;bytes[30]=3;run;
        if(error!=8'h52) $fatal(1,"float accepted");
        prepare;u32(52,6);run;
        if(error!=8'h51) $fatal(1,"out-of-file data accepted");
        prepare;u32(52,3);run;
        if(error!=8'h52) $fatal(1,"odd PCM accepted");
        prepare;bytes[0]="X";run;
        if(error!=8'h51) $fatal(1,"raw PCM accepted");
        prepare;u32(48,32'h4b4e554a);run;
        if(error!=8'h53) $fatal(1,"missing data accepted");
        $display("PASS WAV: real RIFF, extended fmt, odd unknown chunk padding, signed LE samples, rate/channels/format/bounds rejection");
        $finish;
    end
endmodule
