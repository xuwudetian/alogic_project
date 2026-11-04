`timescale 1ns/1ps
module EG_LOGIC_ODDR (q, clk, d1, d0, rst);
    output q;         //  [Template:1 bit DDR edge output data.]
    input clk;        //  [Template:Synchronous clock.]
    input d1;         //  [Template:1 bit negedge input data.]
    input d0;         //  [Template:1 bit posedge input data.]
    input rst;        //  [Template:Reset,high active.]
    
    parameter ASYNCRST = "ENABLE";    //  "ENABLE", "DISABLE". [Template:Asynchronous reset.]

    tri1 gsr_n = glbl.gsrn;
    wire rst_node = (ASYNCRST=="ENABLE")? rst:1'b0;
    wire async_rst = ~gsr_n | rst_node ;   
    wire clk_node = clk;
    reg [1:0] comp_reg;
    reg true_reg;   
    wire ddr;
    buf (d_comp,d1);
    buf (d_true,d0);
    buf (q,ddr);
    always @(posedge clk_node or posedge async_rst)
    begin
     if(async_rst)
     comp_reg[0] = 1'b0 ;
     else
     comp_reg[0] = d_comp ;
    end
    always @(negedge clk_node or posedge async_rst)
    begin
     if(async_rst)
     comp_reg[1] = 1'b0 ;
     else
     comp_reg[1] = comp_reg[0] ;
    end

    always @(posedge clk_node or posedge async_rst)
    begin
     if(async_rst)
     true_reg = 1'b0 ;
     else
     true_reg = d_true ;
    end

    reg clk_mux;
    always @(clk_node)  clk_mux <= #0.1 clk_node; 
    assign   ddr = clk_mux ? true_reg : comp_reg[1] ;    

endmodule