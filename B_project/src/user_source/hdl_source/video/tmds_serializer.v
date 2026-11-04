`timescale 1ns/1ps
// Coherent 1:5 clocks come from one PLL. Toggle loads each ten-bit symbol once.
// Two clock crossings leave >=2 serial periods of settling on the symbol bus.
// DDR d0/d1 are both sampled on the positive serial edge by EG_LOGIC_ODDR.
module tmds_serializer(input pixel_clk,input serial_clk,input rst_n,
    input [9:0] symbol,output serial_out);
    reg pixel_toggle;
    reg [1:0] toggle_sync;
    reg load;
    (* async_reg="true" *) reg [2:0] serial_reset;
    wire serial_rst_n=serial_reset[2];
    always @(posedge serial_clk or negedge rst_n)
        if(!rst_n) serial_reset<=0;
        else serial_reset<={serial_reset[1:0],1'b1};
    reg [9:0] shift;
    wire [1:0] pair=load ? symbol[1:0] : shift[1:0];
    reg [1:0] pair_q;
    always @(posedge pixel_clk or negedge rst_n)
        if(!rst_n) pixel_toggle<=0;else pixel_toggle<=~pixel_toggle;
    always @(posedge serial_clk or negedge serial_rst_n) begin
        if(!serial_rst_n) begin toggle_sync<=0;load<=0;shift<=0;pair_q<=0;end
        else begin
            toggle_sync<={toggle_sync[0],pixel_toggle};
            // Same load edge, with the XOR registered before the fast mux.
            load<=toggle_sync[0]^toggle_sync[1];
            pair_q<=pair;
            if(load) shift<={2'd0,symbol[9:2]};
            else shift<={2'd0,shift[9:2]};
        end
    end
`ifdef SIMULATION
    reg q,falling_bit;
    always @(posedge serial_clk or negedge serial_rst_n)
        if(!serial_rst_n) falling_bit<=0;else falling_bit<=pair_q[1];
    always @(serial_clk or negedge serial_rst_n)
        if(!serial_rst_n) q<=0;
        else if(serial_clk) q<=pair_q[0];
        else q<=falling_bit;
    assign serial_out=q;
`else
    EG_LOGIC_ODDR output_ddr(.clk(serial_clk),.rst(~serial_rst_n),.d0(pair_q[0]),.d1(pair_q[1]),.q(serial_out));
`endif
endmodule
