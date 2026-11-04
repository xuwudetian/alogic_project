`timescale 1ns/1ps
module tb_preview_failure;
    reg clk=0,aclk=0,rst=1,ack=0,finished=0,commit_ack=0,browse=0,next_toggle=0,select_toggle=0;
    wire wr,we,commit,av,tick;
    wire [23:0] pcm,tone;
    wire [7:0] error,status;
    wire [3:0] state;
    wire [5:0] ready;
    wire [2:0] pic;
    wire [59:0] debug_status;
    integer pixels=0,samples=0;
    always #10 clk=~clk;always #20 aclk=~aclk;
    player_audio cadence(.clk(aclk),.rst(rst),.picture(3'd0),.volume(4'd8),.mute(1'b0),.valid(tick),.left(tone));
    sd_card_bmp #(.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8)) dut(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),
        .write_ready(!browse),.commit_toggle(commit),.picture_id(pic),.state_code(state),.error_code(error),
        .write_req(wr),.write_req_ack(ack),.write_en(we),.SD_MISO(1'b1),
        .audio_clk(aclk),.audio_rst(rst),.audio_tick(tick),.tone(tone),.volume(4'd8),.mute(1'b0),
        .audio_valid(av),.audio_pcm(pcm),.audio_status(status),.debug_status(debug_status),
        .browse(browse),.select_toggle(select_toggle),.select_index(3'd1),.thumbnail_valid(ready));
    defparam dut.decoder.EXPECTED_WIDTH=3;defparam dut.decoder.EXPECTED_HEIGHT=2;
    defparam dut.sd_card_top_m0.WITH_AUDIO=1;defparam dut.sd_card_top_m0.BAD_PIC4_SIZE=1;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) finished=!finished;end
        if(!rst && dut.background && (we || wr)) $fatal(1,"preview leaked into SDRAM writer");
    end
    always @(negedge aclk) if(av && dut.wav.playing) samples=samples+1;
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(commit!=commit_ack);@(negedge clk);commit_ack=commit;wait(state==8);
        browse=1;wait(error==8'h37);repeat(1000) @(negedge clk);
        if(state!=8 || ready!=2 || pic!=1 || commit!=commit_ack || debug_status[27:19]!=2 || debug_status[2:0]!=3)
            $fatal(1,"preview E37 isolation/diagnostic failed S%0d E%h debug%h",state,error,debug_status);
        wait(samples>700);
        if(status!=1 || debug_status[27:19]!=2) $fatal(1,"audio overwrote BMP diagnosis or stopped");
        browse=0;select_toggle=!select_toggle; // reselect known-good PIC2 through the real CDC request
        wait(commit!=commit_ack);@(negedge clk);
        if(error!=0 || pic!=1 || pixels!=6) $fatal(1,"good image cannot recover after bad preview");
        $display("PASS preview failure: bad PIC4 E37 isolated, no SDRAM writes, retained PIC2/audio, stable reason/slot, good-image recovery");
        $finish;
    end
    initial begin #60000000;$fatal(1,"preview failure timeout S%0d E%h",state,error);end
endmodule
