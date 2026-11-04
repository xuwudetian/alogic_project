`timescale 1ns/1ps
module tb_hdmi576_adc;
    reg clk=0,rst=1;
    wire valid;wire [11:0] sample;
    integer cycles=0,last_soc=-1,first_soc=-1,socs=0,received=0,previous_valid=-1;
    reg old_soc=0;
    always #18.5185 clk=~clk;
    player_microphone_adc #(.CLK_HZ(27000000)) dut(.clk(clk),.rst(rst),.valid(valid),.sample(sample));
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!rst) begin
            if(dut.converter.soc && !old_soc) begin
                if(last_soc>=0 && cycles-last_soc!=138 && cycles-last_soc!=139) $fatal(1,"native ADC SOC cadence %0d",cycles-last_soc);
                if(first_soc<0) first_soc=cycles;
                last_soc=cycles;socs=socs+1;
                if(socs==101 && cycles-first_soc!=13824) $fatal(1,"ADC average changed: %0d clocks /100 SOC",cycles-first_soc);
            end
            if(valid) begin
                if(sample!=2048 || dut.converter.s!=1) $fatal(1,"ADC channel/data mismatch");
                if(previous_valid>=0 && cycles-previous_valid!=138 && cycles-previous_valid!=140) $fatal(1,"ADC EOC cadence");
                previous_valid=cycles;received=received+1;
            end
        end
        old_soc=dut.converter.soc;
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        wait(socs==101);repeat(120) @(negedge clk);
        if(received!=101) $fatal(1,"ADC lost/duplicated samples %0d",received);
        rst=1;#1;if(valid || sample!=0) $fatal(1,"ADC reset");
        $display("PASS native ADC: 100 SOC periods/13824 clocks at27MHz preserve195.3125kS/s average; channel1/data/EOC/reset; analog boundary model only");$finish;
    end
    initial begin #1000000;$fatal(1,"ADC timeout");end
endmodule
