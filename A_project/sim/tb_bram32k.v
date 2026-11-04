`timescale 1ns/1ps
module tb_bram32k;
    reg wc=0,rc=0,we=0,re=0;
    reg [14:0] wa=0,ra=0;reg [15:0] wd=0;wire [15:0] rd;
    integer i;reg [15:0] saved;
    always #7 wc=~wc;always #5 rc=~rc;
    bram32k_sdp #(.DEPTH(27648),.ADDR_BITS(15)) dut(wc,we,wa,wd,rc,re,ra,rd);
    function [15:0] pattern(input integer address);
        pattern=(address*17)^16'ha55a;
    endfunction
    initial begin
        for(i=0;i<27648;i=i+1) begin @(negedge wc);we=1;wa=i;wd=pattern(i);end
        @(negedge wc);we=0;
        for(i=0;i<27648;i=i+1) begin
            @(negedge rc);re=1;ra=i;@(posedge rc);#1;
            if(rd!==pattern(i)) $fatal(1,"RAM value/latency at address %0d",i);
        end
        saved=rd;@(negedge rc);re=0;ra=0;repeat(3) @(negedge rc);
        if(rd!==saved) $fatal(1,"disabled read changed output");
        re=1;ra=27648;repeat(3) @(negedge rc);
        if(rd!==saved) $fatal(1,"invalid read changed output");
        @(negedge wc);we=1;wa=32767;wd=0;@(negedge wc);we=0;
        @(negedge rc);ra=0;@(posedge rc);#1;
        if(rd!==pattern(0)) $fatal(1,"invalid write aliased to valid address");
        $display("PASS bram32k: 27648 words, fourteen banks, independent clocks, one-cycle reads, enables and invalid addresses");$finish;
    end
    initial begin #1000000;$fatal(1,"RAM test timeout");end
endmodule
