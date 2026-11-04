`timescale 1ns/1ps
module tb_hdmi576_audio_cdc;
    reg sc=0,ac=0,rst=1,arst=1,run_audio=1;
    reg [1:0] selected=0;
    integer i;
    always #10 sc=~sc;always #18.5185 if(run_audio) ac=~ac;
    sd_card_bmp #(.AUDIO_SELECT_ENABLE(1),.POWER_WAIT_CYCLES(1000000)) dut(
        .clk(sc),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(1'b0),.write_finish_toggle(1'b0),.write_overflow(1'b0),.write_ready(1'b1),.write_req_ack(1'b0),
        .SD_MISO(1'b1),.audio_clk(ac),.audio_rst(arst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(4'd0),.ui_pause(1'b0),.run_auto(1'b0),.audio_select(selected));
    task settled(input integer wanted);
        begin
            repeat(20) @(negedge ac);
            if(dut.audio_select_sd!==wanted || dut.audio_select_hold!==wanted || dut.audio_select_request!==dut.audio_select_ack ||
               dut.audio_select_request!==dut.audio_ack_sync[1])
                $fatal(1,"audio selection CDC failed wanted%0d source%0d receiver%0d req%b ack%b",wanted,dut.audio_select_hold,dut.audio_select_sd,dut.audio_select_request,dut.audio_select_ack);
        end
    endtask
    task check_sender_reset;
        begin #1;if(dut.audio_select_hold!==0 || dut.audio_select_request!==0 || dut.audio_ack_sync!==0)
            $fatal(1,"sender reset is not owned by audio clock domain");end
    endtask
    initial begin
        repeat(4) @(negedge ac);check_sender_reset;
        // Release the 27MHz source before the50MHz destination.
        selected=2;arst=0;repeat(6) @(negedge ac);
        if(dut.audio_select_hold!=2 || dut.audio_select_sd!=0) $fatal(1,"source-first reset release");
        @(negedge sc);rst=0;settled(2);
        for(i=0;i<4;i=i+1) begin @(negedge ac);selected=i;settled(i);end
        // Assert audio reset while its clock is stopped and SD reset is low.
        @(negedge ac);run_audio=0;#2;arst=1;check_sender_reset;
        #100;if(dut.audio_select_hold!==0 || dut.audio_select_request!==0) $fatal(1,"stopped audio reset changed");
        rst=1;repeat(5) @(negedge sc);selected=3;rst=0;
        repeat(6) @(negedge sc);if(dut.audio_select_sd!=0) $fatal(1,"destination-first reset release");
        run_audio=1;repeat(3) @(negedge ac);arst=0;settled(3);
        // A newer selection during the pending request must eventually arrive.
        @(negedge ac);selected=1;@(negedge ac);selected=2;@(negedge ac);selected=0;settled(0);
        $display("PASS audio selection CDC: all4 tracks, independent27/50MHz clocks, both reset-release orders, stopped-source-clock asynchronous audio reset, coalesced pending selection");$finish;
    end
    initial begin #100000;$fatal(1,"audio CDC timeout");end
endmodule
