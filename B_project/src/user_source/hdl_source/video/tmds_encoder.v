`timescale 1ns/1ps
// DVI 1.0 transition minimization and running-disparity encoding.
// Symbol bit 0 is transmitted first. control={VSYNC,HSYNC} for blue lane.
module tmds_encoder(input clk,input rst_n,input [7:0] data,
    input de,input [1:0] control,output reg [9:0] symbol);
    reg [8:0] q_m;
    reg [3:0] ones_data,ones_q;
    reg signed [5:0] disparity;
    reg signed [5:0] balance;
    integer i;
    always @* begin
        ones_data=0;
        for(i=0;i<8;i=i+1) ones_data=ones_data+data[i];
        q_m[0]=data[0];
        q_m[8]=!((ones_data>4) || (ones_data==4 && !data[0]));
        for(i=1;i<8;i=i+1)
            if(q_m[8]) q_m[i]=q_m[i-1]^data[i];
            else q_m[i]=~(q_m[i-1]^data[i]);
        ones_q=0;
        for(i=0;i<8;i=i+1) ones_q=ones_q+q_m[i];
        balance=$signed({1'b0,ones_q,1'b0})-6'sd8;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin disparity<=0;symbol<=10'b1101010100;end
        else if(!de) begin
            disparity<=0;
            case(control)
                0:symbol<=10'b1101010100;
                1:symbol<=10'b0010101011;
                2:symbol<=10'b0101010100;
                3:symbol<=10'b1010101011;
            endcase
        end else if(disparity==0 || balance==0) begin
            symbol<={~q_m[8],q_m[8],q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            if(q_m[8]) disparity<=disparity+balance;
            else disparity<=disparity-balance;
        end else if((disparity>0 && balance>0) || (disparity<0 && balance<0)) begin
            symbol<={1'b1,q_m[8],~q_m[7:0]};
            disparity<=disparity-balance+(q_m[8] ? 6'sd2 : 6'sd0);
        end else begin
            symbol<={1'b0,q_m[8],q_m[7:0]};
            disparity<=disparity+balance-(q_m[8] ? 6'sd0 : 6'sd2);
        end
    end
endmodule
