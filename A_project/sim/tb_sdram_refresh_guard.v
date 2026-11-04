`timescale 1ns/1ps
module tb_sdram_refresh_guard;
    reg clk=0,rst=1,ready=0,raw_busy=0;
    wire busy;
    integer slot=0,cycles=0,starts=0;
    always #12.5 clk=~clk;
    sdram_refresh_admission dut(.clk(clk),.rst(rst),.init_done(ready),
        .controller_busy(raw_busy),.app_busy(busy));
    always @(posedge clk) begin
        if(rst || !ready) slot=0;else slot=slot==1249 ? 0 : slot+1;
        #1;
        if(busy!==(!ready || raw_busy || slot<32 || slot>=1058))
            $fatal(1,"refresh admission mismatch slot=%0d",slot);
        if(!busy) begin
            starts=starts+1;
            // A burst starts up to three clocks after admission; even the
            // maximum 128 beats plus the pipeline drain must precede refresh.
            if(slot+3+128+32>=1240) $fatal(1,"admitted burst overlaps refresh");
        end
    end
    initial begin
        repeat(8) @(negedge clk);rst=0;repeat(8) @(negedge clk);ready=1;
        for(cycles=0;cycles<6500;cycles=cycles+1) begin
            @(negedge clk);raw_busy=cycles%317<17;
        end
        ready=0;repeat(5) @(negedge clk);ready=1;raw_busy=0;
        repeat(1400) @(negedge clk);
        if(starts<5000) $fatal(1,"admission excessively restrictive");
        $display("PASS refresh admission: 1250-cycle slots, pre/post guard, core busy, reset and init restart");
        $finish;
    end
endmodule
