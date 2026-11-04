`timescale 1ns/1ps
module tb_spectrum_fft;
reg clk=0,rst=1,start=0,en=0;
reg signed [11:0] din=0;
wire busy,done,valid;
wire signed [20:0] re,im;
integer n,count=0,peak_bin=0;
real angle,power,peak=0.0;
always #20 clk=~clk;
spectrum_fft_512 dut(clk,rst,1'b0,start,en,din,12'd0,done,busy,valid,re,im);
always @(posedge clk) if(valid) begin
    if((^re===1'bx)||(^im===1'bx)) $fatal(1,"unknown FFT result");
    power=$itor(re)*$itor(re)+$itor(im)*$itor(im);
    if(count<256 && power>peak) begin peak=power;peak_bin=count;end
    count=count+1;
    if(count==512) begin
        if(peak_bin!=17) $fatal(1,"FFT peak bin %0d expected17",peak_bin);
        $display("PASS vendor FFT: 512 ordered outputs, peak bin17");
        $finish;
    end
end
initial begin
    repeat(10) @(negedge clk);rst=0;
    repeat(10) @(negedge clk);start=1;
    @(negedge clk);start=0;
    repeat(20) @(negedge clk);
    for(n=0;n<512;n=n+1) begin
        din=$rtoi(900.0*$sin(6.283185307179586*17*n/512));en=1;
        @(negedge clk);en=0;
        repeat(519) @(negedge clk);
    end
end
initial begin #30000000;$fatal(1,"FFT timeout count=%0d busy=%b",count,busy);end
endmodule
