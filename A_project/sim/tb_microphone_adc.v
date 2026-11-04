`timescale 1ns/1ps
module tb_microphone_adc;
    reg clk=0,rst=1;
    wire valid;wire [11:0] sample;
    integer cycles=0,last_sample=-1,received=0;
    always #20 clk=~clk;
    player_microphone_adc dut(clk,rst,valid,sample);
    always @(posedge clk) begin
        cycles=cycles+1;
        if(valid) begin
            if(last_sample>=0 && cycles-last_sample!=128) $fatal(1,"ADC strobe rate changed");
            if(sample!=2048 || dut.converter.s!=1) $fatal(1,"ADC channel/data mismatch");
            last_sample=cycles;received=received+1;
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        repeat(1300) @(negedge clk);
        if(received!=10) $fatal(1,"ADC stalled or duplicated result");
        rst=1;#1;if(valid || sample!=0) $fatal(1,"ADC reset did not clear output");
        $display("PASS microphone ADC controller: channel1, 12.5MHz, 195.3125kS/s, stable data pulse, reset; analog boundary model only");$finish;
    end
endmodule
