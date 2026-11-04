`timescale 1ns/1ps
// Digital conversion handshake model only, NOT a validation of analog accuracy.
module EG_PHY_ADC #(parameter CH1="DISABLE",VREF="DISABLE")(
    input clk,input pd,input [2:0] s,input soc,output reg eoc=0,output reg [11:0] dout=0);
    reg [4:0] count=0;
    reg [11:0] analog_code=2048;
    always @(posedge clk or posedge pd) begin
        if(pd) begin count<=0;eoc<=0;dout<=0;end
        else begin
            eoc<=0;
            if(count==0 && soc) count<=1;
            else if(count==16) begin count<=0;eoc<=1;dout<=analog_code;end
            else if(count!=0) count<=count+1'b1;
        end
    end
endmodule
