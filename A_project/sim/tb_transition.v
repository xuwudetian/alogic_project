`timescale 1ns/1ps
module tb_transition;
    reg clk=0,rst=1,tick=0,req=0;
    reg [2:0] bank=0,pic=0;
    reg pending_scaled=0;
    reg [31:0] resolution={16'd640,16'd480};
    wire [39:0] active_resolution;
    wire ack,valid,scaled;
    wire [2:0] active,active_pic;
    wire [8:0] gain;
    integer k;
    reg [31:0] test_dimensions=0;
    reg test_request=0;
    wire [39:0] test_digits;
    wire test_ready,test_completed;
    player_resolution_bcd conversion(clk,rst,test_dimensions,test_request,test_digits,test_ready,test_completed);
    player_transition dut(.clk(clk),.rst(rst),.frame_tick(tick),.request_toggle(req),
        .pending_bank(bank),.pending_picture(pic),.pending_scaled(pending_scaled),.ack_toggle(ack),
        .active_bank(active),.active_picture(active_pic),.active_scaled(scaled),.display_valid(valid),.gain(gain),
        .pending_resolution(resolution),.active_resolution(active_resolution),.transition_mode(4'd0),.effect_pause(1'b0),.effects_disabled(1'b0));
    always #5 clk=~clk;
    task frame;
        begin @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(5) @(negedge clk);end
    endtask
    task convert;
        input [15:0] width,height;
        input [39:0] expected;
        begin
            @(negedge clk);test_dimensions={width,height};test_request=!test_request;
            repeat(36) @(negedge clk);
            if(!test_ready || test_completed!=test_request || test_digits!==expected)
                $fatal(1,"BCD conversion %0dx%0d -> %h expected %h",width,height,test_digits,expected);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;req=1;
        repeat(45) @(negedge clk);
        if(valid || ack) $fatal(1,"mid-frame commit");
        frame;
        if(!valid || ack || gain!=0 || scaled) $fatal(1,"initial black frame and resolution");
        if(active_resolution!==40'h0064000480) $fatal(1,"initial source size");
        frame;
        if(!ack) $fatal(1,"commit acknowledgement");
        repeat(18) frame;
        if(gain!=256) $fatal(1,"fade in unity");
        bank=1;pic=2;pending_scaled=1;resolution={16'd1920,16'd1080};
        repeat(30) @(negedge clk);
        repeat(2) frame;
        if(active!=0 || active_pic!=0 || scaled || !valid)
            $fatal(1,"uncommitted load changed active image metadata");
        if(active_resolution!==40'h0064000480) $fatal(1,"background size leaked");
        req=0;
        repeat(45) @(negedge clk);
        if(scaled) $fatal(1,"mid-frame resolution change");
        frame;
        for(k=0;k<16;k=k+1) begin
            frame;
            if(active!=0 || scaled || gain!=(15-k)*16) $fatal(1,"fade out and old resolution");
        end
        frame;
        if(active!=1 || active_pic!=2 || !scaled || gain!=0 || !ack) $fatal(1,"black switch and new resolution");
        if(active_resolution!==40'h0192001080) $fatal(1,"source size not committed with bank");
        frame;
        if(ack) $fatal(1,"old buffer not released");
        repeat(18) frame;
        if(gain!=256) $fatal(1,"second fade in");
        pending_scaled=0;pic=3;bank=0;
        repeat(8) @(negedge clk);
        repeat(3) frame;
        if(!scaled || active_pic!=2 || active!=1 || !valid || gain!=256)
            $fatal(1,"failed/background load replaced committed image metadata");
        bank=5;pic=5;resolution={16'd1080,16'd1920};pending_scaled=1;req=1;
        repeat(45) @(negedge clk);
        repeat(20) frame;
        if(active!=5 || active_pic!=5 || !ack || active_resolution!==40'h0108001920)
            $fatal(1,"sixth bank/picture/size commit truncated");
        convert(1,1,40'h0000100001);
        convert(641,481,40'h0064100481);
        convert(16384,1080,40'h1638401080);
        convert(1080,16384,40'h0108016384);
        $display("PASS transition: no mid-frame swap, monotonic fade, black dwell, acknowledged release, committed resolution retained during pending/failed loads");
        $finish;
    end
endmodule
