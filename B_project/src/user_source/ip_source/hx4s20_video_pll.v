`timescale 1ns/1ps
// Same 1000 MHz VCO and 66.6667/333.3333 MHz video clocks as the supplied demo.
// CLKC2 supplies an independent 100 MHz preview memory domain. CNN stays 50 MHz.
// 1024x768, totals 1344x806: 61.542 Hz (the supplied demo's clock/timing pair).
module hx4s20_video_pll(input refclk,input reset,
    output pixel_clk,output serial_clk,output locked,output mem_clk,output mem_forward_clk);
`ifdef SIMULATION
    reg pclk=0, sclk=0, mclk=0, fclk=0;
    reg [4:0] lock_count=0;
    always #7.5 pclk=~pclk;
    always #1.5 sclk=~sclk;
    always #5 mclk=~mclk;
    // Forwarded SDRAM edge leads memory logic by 2 ns (72 degrees).
    initial begin #3;forever begin fclk=~fclk;#5;end end
    always @(posedge refclk or posedge reset)
        if(reset) lock_count<=0;
        else if(!lock_count[4]) lock_count<=lock_count+1'b1;
    assign pixel_clk=pclk;
    assign serial_clk=sclk;
    assign mem_clk=mclk;
    assign mem_forward_clk=fclk;
    assign locked=lock_count[4] && !reset;
`else
    wire pixel_raw;
    wire unused_clock;
    EG_LOGIC_BUFG feedback_buf(.i(pixel_raw),.o(pixel_clk));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),.FIN("50.000000"),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),
        .STDBY_ENABLE("DISABLE"),.PLLRST_ENA("ENABLE"),.SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(0),.ICP_CURRENT(9),.KVCO(2),.LPF_CAPACITOR(2),.LPF_RESISTOR(8),
        .REFCLK_DIV(3),.FBCLK_DIV(4),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(15),.CLKC0_CPHASE(14),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(3),.CLKC1_CPHASE(2),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(10),.CLKC2_CPHASE(9),.CLKC2_FPHASE(0),
        .CLKC3_ENABLE("ENABLE"),.CLKC3_DIV(10),.CLKC3_CPHASE(7),.CLKC3_FPHASE(0)
    ) pll_inst (
        .refclk(refclk),.reset(reset),.stdby(1'b0),.extlock(locked),
        .load_reg(1'b0),.psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'd0),.psdone(),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'd0),.daddr(6'd0),.do(),
        .fbclk(pixel_clk),.clkc({unused_clock,mem_forward_clk,mem_clk,serial_clk,pixel_raw})
    );
`endif
endmodule
