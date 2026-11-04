`timescale 1ns/1ps
// 50 MHz -> 25 MHz MAC and 25 MHz +90 degree RGMII TX clock.
// At 100 Mb/s each nibble is repeated across both RGMII edges (vendor demo).
// 10 ns phase leaves margin for either strap setting of the PHY's 2 ns delay.
module net_clock(input clk,input rst,output mac_clk,output shifted_clk,output locked);
`ifdef SIMULATION
 reg c=0,s=0;reg [4:0] count=0;
 always #20 c=~c;
 initial begin #10;forever #20 s=~s;end
 always @(posedge clk or posedge rst)
  if(rst) count<=0;else if(!count[4]) count<=count+1'b1;
 assign mac_clk=c;assign shifted_clk=s;assign locked=count[4] && !rst;
`else
 wire raw;wire [2:0] unused;
 EG_LOGIC_BUFG feedback(.i(raw),.o(mac_clk));
 EG_PHY_PLL #(
  .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
  .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),
  .STDBY_ENABLE("DISABLE"),.PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),
  .GMC_GAIN(0),.ICP_CURRENT(9),.KVCO(2),.LPF_CAPACITOR(2),.LPF_RESISTOR(8),
  .REFCLK_DIV(2),.FBCLK_DIV(1),
  .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(40),.CLKC0_CPHASE(39),.CLKC0_FPHASE(0),
  .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(40),.CLKC1_CPHASE(49),.CLKC1_FPHASE(0)
 ) pll_inst(
  .refclk(clk),.reset(rst),.stdby(1'b0),.extlock(locked),
  .load_reg(1'b0),.psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'd0),.psdone(),
  .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'd0),.daddr(6'd0),.do(),
  .fbclk(mac_clk),.clkc({unused,shifted_clk,raw}));
`endif
endmodule
