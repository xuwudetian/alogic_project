`timescale 1ns/1ps
module tb_alarm_glow;
    reg clk=0,rst=1,hs=1,vs=1,de=0,alarm=0,directory=0;reg [23:0] rgb=24'h123456;
    wire oh,ov,od;wire [23:0] pixel;integer n,expected_phase,level;
    player_ui_overlay dut(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de),.rgb(rgb),
        .directory(directory),.selection(2'd0),.alarm(alarm),.directory_run(1'b0),
        .out_hs(oh),.out_vs(ov),.out_de(od),.out_rgb(pixel));
    always #5 clk=~clk;
    task frame;begin
        de=0;vs=0;repeat(3) @(negedge clk);vs=1;repeat(3) @(negedge clk);
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;alarm=1;
        for(n=0;n<128;n=n+1) begin
            directory=n>=64; // Sensor alarm must override a remembered open menu.
            frame;expected_phase=(32+n)%64;level=expected_phase<32 ? expected_phase : 63-expected_phase;
            de=1;rgb=24'h123456;repeat(5) @(negedge clk);
            if(!od || pixel!=={8'(level*4),16'd0}) $fatal(1,"red background phase %0d got %h",n,pixel);
            rgb=24'hff2020;repeat(5) @(negedge clk);
            if(pixel!=={8'(193+level*2),8'(level),8'(level)}) $fatal(1,"wave/spectrum pulse");
            rgb=24'hb01010;repeat(5) @(negedge clk);
            if(pixel!=={8'(128+level*2),8'd8,8'd8}) $fatal(1,"wave soft edge lost");
            if(dut.alarm_phase!=expected_phase) $fatal(1,"pulse changed outside frame");
        end
        alarm=0;directory=0;rgb=24'h123456;repeat(5) @(negedge clk);
        if(pixel!==rgb) $fatal(1,"alarm exit did not restore picture");
        de=0;repeat(4) @(negedge clk);if(od || pixel!==0) $fatal(1,"blanking not black");
        alarm=1;repeat(4) @(negedge clk);
        if(dut.alarm_phase!=31) $fatal(1,"reentry should start bright");
        $display("PASS alarm glow: 64-frame period, frame-locked pulse, full background, main/edge ink, clean exit, blanking, bright reentry");$finish;
    end
endmodule
