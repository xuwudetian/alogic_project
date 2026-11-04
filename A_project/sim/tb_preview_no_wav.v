`timescale 1ns/1ps
module tb_preview_no_wav;
    reg clk=0,aclk=0,rst=1,ack=0,finished=0,commit_ack=0;
    reg browse=0,pause_ui=0,select_toggle=0;
    reg [2:0] selected=1;
    wire wr,we,commit,av,tick;
    wire [23:0] pcm,tone;
    wire [7:0] error,status;
    wire [3:0] state;
    wire [5:0] ready;
    integer pixels=0,round=0,starts=0;
    always #10 clk=~clk;
    always #20 aclk=~aclk;
    player_audio cadence(.clk(aclk),.rst(rst),.picture(3'd0),.volume(4'd8),
        .mute(1'b0),.valid(tick),.left(tone));
    sd_card_bmp #(.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8),.UI_PAUSE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),
        .write_ready(!browse),.write_req(wr),.write_req_ack(ack),.write_en(we),
        .commit_toggle(commit),.state_code(state),.error_code(error),.SD_MISO(1'b1),
        .audio_clk(aclk),.audio_rst(rst),.audio_tick(tick),.tone(tone),.volume(4'd8),.mute(1'b0),
        .audio_valid(av),.audio_pcm(pcm),.audio_status(status),.browse(browse),
        .select_toggle(select_toggle),.select_index(selected),.thumbnail_valid(ready),.ui_pause(pause_ui));
    defparam dut.decoder.EXPECTED_WIDTH=3;
    defparam dut.decoder.EXPECTED_HEIGHT=2;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) finished=!finished;end
        if(!rst && error!=0) $fatal(1,"unexpected preview E%h debug=%h",error,dut.debug_status);
        if(!rst && dut.file_start) begin
            starts=starts+1;
            if(dut.file_busy || dut.size<54 || dut.cluster<2)
                $fatal(1,"overlap or invalid metadata at file start");
        end
        if(!rst && dut.background && (wr || we)) $fatal(1,"preview SDRAM write");
    end
    task accept;begin
        wait(commit!=commit_ack);@(negedge clk);commit_ack=commit;wait(state==8);
    end endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;accept;
        for(round=0;round<8;round=round+1) begin
            pause_ui=1;repeat(30) @(negedge clk);
            browse=1;pause_ui=0;wait(ready==10 && state==8);
            repeat(30) @(negedge clk);
            pause_ui=1;repeat(20) @(negedge clk);
            pause_ui=0;repeat(20) @(negedge clk);
            selected=round[0] ? 1 : 3;
            browse=0;select_toggle=!select_toggle;accept;
        end
        if(status!=0 || dut.audio_found || starts!=10)
            $fatal(1,"no-WAV/transaction result W%h starts=%0d",status,starts);
        $display("PASS no-WAV previews: eight directory/preview/select cycles, no E37, W00 fallback, valid start metadata");
        $finish;
    end
    initial begin #50000000;$fatal(1,"preview timeout S%0d",state);end
endmodule
