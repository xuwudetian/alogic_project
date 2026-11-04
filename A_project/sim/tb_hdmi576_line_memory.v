`timescale 1ns/1ps
module tb_hdmi576_line_memory;
    reg wc=0,rc=0,we=0,re=0;
    reg [12:0] wa=0,ra=0;reg [15:0] wd=0;wire [15:0] rd;
    integer i,index;reg [15:0] held;
    always #7 wc=~wc;always #5 rc=~rc;
    bmp_bilinear_line_memory #(.DEPTH(4320)) dut(.write_clk(wc),.write_enable(we),.write_address(wa),.write_data(wd),
        .read_clk(rc),.read_enable(re),.read_address(ra),.read_data(rd));
    function [15:0] pattern(input integer address);pattern=(address*53)^16'h9a76;endfunction
    initial begin
        for(i=0;i<4320;i=i+1) begin @(negedge wc);we=1;wa=i;wd=pattern(i);end
        @(negedge wc);we=0;
        // Alternate the spill with main-bank words before scanning all data.
        for(i=0;i<448;i=i+1) begin
            index=i%2==0 ? 4096+i/2 : 3872+i/2;
            @(negedge rc);re=1;ra=index;@(posedge rc);#1;
            if(rd!==pattern(index)) $fatal(1,"9K/main selection or latency at %0d got%h",index,rd);
            held=rd;@(negedge rc);re=0;ra=index<4096 ? 4319 : 0;
            repeat(2) @(negedge rc);if(rd!==held) $fatal(1,"disabled read changed bank output");
        end
        for(i=0;i<4320;i=i+1) begin
            @(negedge rc);re=1;ra=i;@(posedge rc);#1;
            if(rd!==pattern(i)) $fatal(1,"composite line data at %0d",i);
        end
        @(negedge wc);we=1;wa=4320;wd=0;@(negedge wc);wa=8191;@(negedge wc);we=0;
        @(negedge rc);re=1;ra=4096;@(posedge rc);#1;
        if(rd!==pattern(4096)) $fatal(1,"invalid spill write aliased");
        @(negedge rc);ra=0;@(posedge rc);#1;if(rd!==pattern(0)) $fatal(1,"invalid main write aliased");
        $display("PASS 4320x16 line RAM: 4096 main+224 9K spill words, every location,448 alternating bank reads, one-edge latency, independent clocks, read enable hold, invalid write isolation; digital boundary model");$finish;
    end
    initial begin #1000000;$fatal(1,"line RAM timeout");end
endmodule
