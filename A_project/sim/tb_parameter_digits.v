`timescale 1ns/1ps
module tb_parameter_digits;
    reg clk=0,rst=1;
    reg [7:0] brightness=0;
    reg [8:0] contrast=128;
    wire [11:0] b,c;
    integer n;
    always #5 clk=~clk;
    player_parameter_digits dut(clk,rst,brightness,contrast,b,c);
    function [11:0] digits(input integer v);
        begin digits=((v/100)<<8) | (((v/10)%10)<<4) | (v%10);end
    endfunction
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(n=0;n<512;n=n+1) begin
            brightness=n%256;contrast=n;
            repeat(40) @(negedge clk);
            if(b!==digits(n%256) || c!==digits(n)) $fatal(1,"parameter decimal conversion %0d",n);
        end
        $display("PASS parameter digits: every 8-bit brightness and 9-bit contrast code, bounded settling");$finish;
    end
endmodule
