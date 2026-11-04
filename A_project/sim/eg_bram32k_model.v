`timescale 1ns/1ps
// Regression-only boundary model, NOT vendor implementation or timing model.
// Accept the independent-clock, unregistered 2048x16/32K and 512x16/9K
// configurations used by the frame scaler. Both have one-edge read latency.
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=16,DATA_WIDTH_B=16,ADDR_WIDTH_A=11,ADDR_WIDTH_B=11,
    parameter DATA_DEPTH_A=2048,DATA_DEPTH_B=2048,BYTE_ENABLE=0,BYTE_A=1,BYTE_B=1,
    parameter MODE="DP",REGMODE_A="NOREG",REGMODE_B="NOREG",
    parameter WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL",RESETMODE="SYNC",
    parameter DEBUGGABLE="NO",PACKABLE="NO",INIT_FILE="NONE",FILL_ALL="NONE",IMPLEMENT="32K"
)(output reg [DATA_WIDTH_A-1:0] doa,output reg [DATA_WIDTH_B-1:0] dob,
  input [DATA_WIDTH_A-1:0] dia,input [DATA_WIDTH_B-1:0] dib,
  input cea,ocea,clka,wea,rsta,ceb,oceb,clkb,web,rstb,
  input [BYTE_A-1:0] bea,input [BYTE_B-1:0] beb,
  input [ADDR_WIDTH_A-1:0] addra,input [ADDR_WIDTH_B-1:0] addrb);
    reg [15:0] mem[0:DATA_DEPTH_A-1];
    initial begin
        if(DATA_WIDTH_A!=16 || DATA_WIDTH_B!=16 ||
           !((IMPLEMENT=="32K" && ADDR_WIDTH_A==11 && ADDR_WIDTH_B==11 && DATA_DEPTH_A==2048 && DATA_DEPTH_B==2048) ||
             (IMPLEMENT=="9K" && ADDR_WIDTH_A==9 && ADDR_WIDTH_B==9 && DATA_DEPTH_A==512 && DATA_DEPTH_B==512)) || MODE!="DP" ||
           REGMODE_A!="NOREG" || REGMODE_B!="NOREG" || BYTE_ENABLE!=0 || INIT_FILE!="NONE")
            $fatal(1,"unsupported BRAM boundary model configuration");
    end
    always @(posedge clka) if(cea) begin
        if(rsta) doa<=0;
        else if(wea) mem[addra]<=dia;
        else doa<=mem[addra];
    end
    always @(posedge clkb) if(ceb) begin
        if(web) $fatal(1,"port B is read-only in the tested contract");
        if(rstb) dob<=0;else dob<=mem[addrb];
    end
endmodule
