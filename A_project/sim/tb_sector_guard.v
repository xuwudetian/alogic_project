`timescale 1ns/1ps
module tb_sector_guard;
    reg clk=0,rst=1,req=0,rv=0,rdone=0,ready=1;
    reg [7:0] rb=0,re=0;
    wire busy,valid,done,raw_req,slow,toggle;
    wire [7:0] data,error;
    wire [8:0] index;
    wire [31:0] lba;
    wire [59:0] diag;
    integer delivered=0,n;
    always #10 clk=~clk;
    sd_sector_guard #(.CLK_FREQ_HZ(10000)) dut(
        clk,rst,req,32'd2048,busy,valid,data,index,done,error,
        raw_req,lba,slow,rv,rb,rdone,re,diag,toggle,ready);
    always @(posedge clk) if(!rst && valid) begin
        if(index!=delivered || data!==index[7:0]) $fatal(1,"guard replay sequence");
        delivered=delivered+1;
    end
    task start;
        begin
            rst=1;req=0;rv=0;rdone=0;re=0;
            repeat(3) @(negedge clk);
            rst=0;delivered=0;@(negedge clk);req=1;@(negedge clk);req=0;
        end
    endtask
    task attempt;
        input integer length;
        input [7:0] result;
        begin
            wait(raw_req);
            for(n=0;n<length;n=n+1) begin
                @(negedge clk);rv=1;rb=n;
                @(negedge clk);rv=0;
            end
            @(negedge clk);re=result;rdone=1;
            wait(!raw_req);@(negedge clk);rdone=0;
        end
    endtask
    initial begin
        start;
        attempt(511,0);repeat(4) @(negedge clk);
        if(delivered!=0 || !slow) $fatal(1,"short sector escaped or did not back off");
        attempt(512,0);wait(done);@(negedge clk);
        if(error!=0 || delivered!=512 || diag[27:18]!=512 || diag[1:0]!=1)
            $fatal(1,"short-sector retry");
        start;
        ready=0;attempt(512,0);repeat(40) @(negedge clk);
        if(delivered!=0 || !busy || done) $fatal(1,"unready consumer received bytes");
        ready=1;wait(delivered==173);@(negedge clk);ready=0;
        repeat(40) @(negedge clk);
        if(delivered!=173 || index!=173) $fatal(1,"replay did not pause cleanly");
        ready=1;wait(done);@(negedge clk);
        if(error!=0 || delivered!=512) $fatal(1,"stalled replay did not resume");
        start;
        attempt(512,8'h14);attempt(512,8'h14);attempt(512,8'h14);
        wait(done);@(negedge clk);
        if(error!=8'h14 || delivered!=0 || diag[1:0]!=2) $fatal(1,"persistent CRC containment");
        start;
        attempt(511,0);attempt(511,0);attempt(511,0);
        wait(done);@(negedge clk);
        if(error!=8'h16 || delivered!=0 || diag[27:18]!=511) $fatal(1,"byte-count diagnostic");
        start;
        wait(done);@(negedge clk);
        if(error!=8'h10 || delivered!=0 || raw_req) $fatal(1,"sector timeout containment");
        $display("PASS sector guard: short-sector recovery, CRC rejection, bounded retries, byte counts, timeout, no unverified bytes");
        $finish;
    end
    initial begin #3000000;$fatal(1,"sector guard test timeout");end
endmodule
