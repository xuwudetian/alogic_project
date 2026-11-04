`timescale 1ns/1ps
module tb_buzzer;
    reg clk=0,rst=1,enable=0,mute=0,tick=0;
    wire buzzer_n;
    integer n,k;
    always #5 clk=~clk;
    player_buzzer dut(clk,rst,enable,mute,tick,buzzer_n);
    task sample;
        begin
            tick=1;@(negedge clk);tick=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        if(buzzer_n!==1) $fatal(1,"buzzer sounded during reset");
        rst=0;repeat(3) @(negedge clk);
        if(buzzer_n!==1) $fatal(1,"buzzer sounded in normal mode");
        enable=1;#1;if(buzzer_n!==0) $fatal(1,"alarm not immediately audible");
        @(negedge clk);
        for(k=0;k<4;k=k+1) begin
            for(n=0;n<11999;n=n+1) begin
                sample;
                if(buzzer_n!==(k%2)) $fatal(1,"incorrect cadence before 12000 ticks");
            end
            sample;
            if(buzzer_n!==((k+1)%2)) $fatal(1,"missing 250ms boundary");
        end
        repeat(10) @(negedge clk);
        if(buzzer_n!==0) $fatal(1,"timer advanced without audio tick");
        mute=1;#1;if(buzzer_n!==1) $fatal(1,"mute did not silence buzzer");
        repeat(3) @(negedge clk);mute=0;#1;
        if(buzzer_n!==0) $fatal(1,"unmute did not restart on phase");
        @(negedge clk);enable=0;#1;
        if(buzzer_n!==1) $fatal(1,"exit waited for tick");
        repeat(3) @(negedge clk);enable=1;rst=1;#1;
        if(buzzer_n!==1) $fatal(1,"reset did not silence immediately");
        $display("PASS buzzer: low-active, 12000-tick cadence, idle/reset/exit/mute silence");$finish;
    end
    initial begin #2000000;$fatal(1,"buzzer timeout");end
endmodule
