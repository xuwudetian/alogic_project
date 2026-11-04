`timescale 1ns/1ps
module tb_beat_transition;
    reg clk=0,rst=1,frame=0,req=0,is_auto=1,music=1,beat=0,pause=0,disabled=1,thumb=0;
    reg [3:0] bank=0,mode=0;wire ack,valid;
    wire [3:0] active;integer i;reg saved_ack;
    always #5 clk=~clk;
    player_transition #(.SLIDE_ENABLE(1),.MULTI_EFFECT_ENABLE(1),.DIRECTORY_HOLD_ENABLE(1),
        .THUMBNAIL_SELECT_ENABLE(1),.BEAT_SYNC_ENABLE(1),.BEAT_WAIT_FRAMES(3)) dut(
        .clk(clk),.rst(rst),.frame_tick(frame),.request_toggle(req),.pending_bank(bank),.pending_picture(bank),
        .pending_scaled(1'b0),.pending_resolution({16'd640,16'd480}),.ack_toggle(ack),.active_bank(active),
        .display_valid(valid),.transition_mode(mode),.effect_pause(pause),.effects_disabled(disabled),
        .directory_hold(pause),.thumbnail_select(thumb),.request_auto(is_auto),.music_active(music),.music_beat(beat));
    task tick;begin @(negedge clk);frame=1;@(negedge clk);frame=0;repeat(4) @(negedge clk);end endtask
    task onset;begin @(negedge clk);beat=1;@(negedge clk);beat=0;end endtask
    task request;begin bank=bank+1;req=!req;saved_ack=ack;repeat(45) @(negedge clk);end endtask
    task pending;begin if(active==bank || ack!=saved_ack || dut.state!=0) $fatal(1,"transition began without beat/deadline");end endtask
    task finish_cut;begin
        if(active!=bank || ack!=saved_ack) $fatal(1,"cut/ACK not atomic");
        tick;if(ack!=req) $fatal(1,"ACK missing after complete frame");tick;
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        request;tick;finish_cut; // initial picture never waits
        onset;request;tick;pending; // pre-deadline beat is not reused
        onset;repeat(20) @(negedge clk);pending;tick;finish_cut;
        request;tick;pending;tick;pending;tick;finish_cut; // hard deadline
        is_auto=0;request;tick;finish_cut; // manual request in AUTO mode
        is_auto=1;music=0;request;tick;finish_cut; // fixed or muted audio
        music=1;request;pause=1;onset;repeat(5) tick;pending;
        pause=0;tick;pending;onset;tick;finish_cut;
        request;thumb=1;tick;finish_cut;thumb=0; // selection bypass
        disabled=0;mode=2;request;tick;pending;onset;tick;
        if(!dut.slide_active || dut.state!=4 || ack!=saved_ack) $fatal(1,"beat did not launch selected slide");
        repeat(35) tick;if(ack!=req || active!=bank) $fatal(1,"slide ownership lost");
        mode=3;request;tick;pending;onset;tick;
        if(!dut.mask_active || dut.mask_style!=1 || dut.state!=6) $fatal(1,"beat did not launch selected mask");
        repeat(40) tick;if(ack!=req || active!=bank) $fatal(1,"mask ownership lost");
        $display("PASS beat transition: initial/manual/fixed/thumbnail bypass, onset, bounded timeout, pause clears stale beats, slide/mask, frame-atomic ACK");$finish;
    end
    initial begin #1000000;$fatal(1,"beat transition timeout");end
endmodule
