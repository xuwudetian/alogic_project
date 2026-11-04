`timescale 1ns/1ps
module tb_media_arbiter;
    reg clk=0,rst=1,mr=0,ar=0,urgent=1,bb=0,bd=0,bv=0;
    reg [7:0] be=0;
    reg mready=1,aready=1;
    wire busy,req,mv,md,av,ad,ready,owner;
    wire [31:0] lba;
    wire [7:0] me,ae;
    always #5 clk=~clk;
    media_sector_arbiter dut(.clk(clk),.rst(rst),.main_req(mr),.main_lba(32'd123),
        .audio_req(ar),.audio_lba(32'd456),.audio_urgent(urgent),
        .busy(busy),.request(req),.lba(lba),.backend_busy(bb),.backend_done(bd),
        .backend_valid(bv),.backend_error(be),.main_valid(mv),.main_done(md),
        .main_error(me),.audio_valid(av),.audio_done(ad),.audio_error(ae),
        .main_ready(mready),.audio_ready(aready),.emit_ready(ready),.audio_owner(owner),
        .probe_req(1'b0),.probe_done(),.probe_error());
    task complete;
        input expected;
        begin
            wait(req);@(negedge clk);
            if(owner!==expected || lba!==(expected ? 456 : 123)) $fatal(1,"lost request");
            bb=1;bv=1;aready=0;#1;
            if(av!==expected || mv===expected || ready==expected) $fatal(1,"owner/replay");
            repeat(5) @(negedge clk);
            be=8'h14;bd=1;#1;
            if(ae!==(expected ? 8'h14 : 0) || me!==(expected ? 0 : 8'h14))
                $fatal(1,"cross-owner error");
            @(negedge clk);bb=0;bv=0;bd=0;aready=1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;mr=1;ar=1;
        @(negedge clk);mr=0;ar=0;
        complete(1);complete(0);
        repeat(3) @(negedge clk);
        if(busy || me || ae) $fatal(1,"sticky error leaked");
        $display("PASS media arbiter: simultaneous request queuing, priority, exclusive replay, owner-specific errors");
        $finish;
    end
    initial begin #10000;$fatal(1,"arbiter timeout");end
endmodule
