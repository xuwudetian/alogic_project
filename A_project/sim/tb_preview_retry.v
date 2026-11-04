`timescale 1ns/1ps
module tb_preview_retry;
    reg clk=0,rst=1,ack=0,done=0,commit_ack=0,browse=0,pause=0;
    wire wr,we,commit;
    wire [3:0] state;
    wire [5:0] ready,failed;
    wire [7:0] error;
    integer pixels=0,attempts=0;
    always #5 clk=~clk;
    sd_card_bmp #(.POWER_WAIT_CYCLES(4),.READY_WAIT_CYCLES(2),.UI_PAUSE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(done),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.state_code(state),.error_code(error),.write_req(wr),.write_req_ack(ack),.write_en(we),
        .SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(browse),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(pause),
        .thumbnail_valid(ready),.thumbnail_failed(failed));
    defparam dut.decoder.EXPECTED_WIDTH=3,dut.decoder.EXPECTED_HEIGHT=2;
    defparam dut.sd_card_top_m0.BAD_PIC4_SIZE=1;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) done=!done;end
        if(!rst && dut.background && (wr || we)) $fatal(1,"preview used full-frame writer");
        if(!rst && dut.file_start && dut.selected==3) attempts=attempts+1;
    end
    task revisit;
        begin browse=0;repeat(10) @(negedge clk);browse=1;end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        wait(commit!=commit_ack);@(negedge clk);commit_ack=commit;wait(state==8);
        browse=1;wait(failed==8);repeat(10000) @(negedge clk);
        if(attempts!=1 || ready!=2 || commit!=commit_ack) $fatal(1,"first preview failure containment");
        // Directory/alarm overlays keep browse asserted; returning is a new visit too.
        pause=1;repeat(20) @(negedge clk);pause=0;
        wait(attempts==2);wait(failed==8);repeat(10000) @(negedge clk);
        if(attempts!=2) $fatal(1,"permanent failure retried without another visit");
        dut.sd_card_top_m0.bad_pic4=0;revisit;
        wait(ready==10);repeat(1000) @(negedge clk);
        if(attempts!=3 || failed || error || commit!=commit_ack) $fatal(1,"repaired thumbnail not accepted");
        $display("PASS preview retry: one attempt per visit, persistent failure indication, repaired-file recovery without SDRAM writes");$finish;
    end
    initial begin #10000000;$fatal(1,"preview retry timeout S%h E%h",state,error);end
endmodule
