`timescale 1ns/1ps
module tb_diagnostics;
    reg clk=0,vclk=0,async_reset=0,update=0;
    reg [13:0] status=0;
    wire rb,rv;
    wire [13:0] snapshot;
    wire [5:0] selects;
    wire [7:0] segments;
    wire [6:0] high_digit,low_digit;
    always #10 clk=~clk;
    always #23 vclk=~vclk;
    player_reset br(clk,async_reset,rb);
    player_reset vr(vclk,async_reset,rv);
    player_status_cdc dut(vclk,rv,update,status,clk,rb,snapshot);
    seg_decoder hi(snapshot[7:4],high_digit);
    seg_decoder lo(snapshot[3:0],low_digit);
    seg_scan #(.CLK_FREQ(1200),.SCAN_FREQ(100)) scan(clk,!rb,selects,segments,
        {1'b1,low_digit},{1'b1,high_digit},8'hff,8'hff,8'hff,8'hff);
    task publish(input [13:0] value);
        begin
            @(negedge vclk);status=value;update=1;@(negedge vclk);update=0;
            // Input may change immediately; the held snapshot must stay coherent.
            status=~value;repeat(12) @(negedge clk);
            if(snapshot!==value) $fatal(1,"diagnostic CDC incoherent %h expected %h",snapshot,value);
            repeat(6) @(negedge vclk);
        end
    endtask
    initial begin
        // No external reset pulse: player_reset's configuration value starts the scanner.
        repeat(20) @(negedge clk);
        if((^selects)===1'bx || (^segments)===1'bx || rb || rv) $fatal(1,"cold-start scanner unknown");
        publish({4'd8,2'd2,8'h41});
        wait(selects==6'b111110);#1;if(segments!=={1'b1,low_digit}) $fatal(1,"E41 low digit");
        publish({4'd10,2'd3,8'h14});
        async_reset=1;#1;if(selects!==6'b111111 || snapshot!==0) $fatal(1,"PLL loss/reset assertion");
        repeat(4) @(negedge clk);async_reset=0;repeat(12) @(negedge vclk);
        publish({4'd8,2'd0,8'h00});
        $display("PASS diagnostics: no-button cold reset, coherent status/E41 CDC, active-low scan, loss-of-lock recovery");$finish;
    end
    initial begin #100000;$fatal(1,"diagnostics timeout");end
endmodule
