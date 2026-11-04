`timescale 1ns/1ps
module tb_hotplug;
    reg clk=0,rst=1,ack=0,finished=0,commit_ack=0;
    wire wr,we,commit,no_signal;wire [2:0] bank;wire [3:0] state;
    wire [5:0] ready;integer pixels=0,probes=0,recovered=0;reg [2:0] old_bank;
    sd_card_bmp #(.CLK_FREQ_HZ(50000),.POWER_WAIT_CYCLES(12),.READY_WAIT_CYCLES(4),
        .FRAME_CACHE_ENABLE(1),.HOTPLUG_ENABLE(1),.PROBE_INTERVAL_CYCLES(500),.REINSERT_WAIT_CYCLES(800)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.disp_buf_idx(bank),.state_code(state),.write_req(wr),.write_req_ack(ack),.write_en(we),
        .SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(1'b0),.run_auto(1'b0),
        .thumbnail_valid(ready),.no_signal(no_signal));
    defparam dut.decoder.EXPECTED_WIDTH=3;defparam dut.decoder.EXPECTED_HEIGHT=2;
    always #5 clk=~clk;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;else if(we) begin pixels=pixels+1;if(pixels==6) finished=!finished;end
        if(commit!=commit_ack) begin commit_ack=commit;recovered=recovered+1;end
        if(dut.probe_done) probes=probes+1;
        if(dut.arbiter.probing && (dut.sector_valid || dut.wav_valid || dut.sector_done || dut.wav_done))
            $fatal(1,"heartbeat leaked into file parser");
        if(!rst && wr && dut.write_buf_idx==bank && !dut.first_frame) $fatal(1,"visible bank overwritten on remount");
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(ready==6'b001010 && probes>=2);@(negedge clk);
        if(no_signal || recovered!=1) $fatal(1,"healthy cached card flagged absent");
        old_bank=bank;
        // Remove during an idle heartbeat: cached images and no WAV still detect removal.
        force dut.raw_error=8'h12;wait(no_signal);
        if(bank!=old_bank) $fatal(1,"removal changed visible image");
        repeat(2000) @(negedge clk);release dut.raw_error;
        wait(recovered==2 && !no_signal);wait(ready==6'b001010);
        // Replace with an empty FAT32 card, then restore files without a user reset.
        force dut.raw_error=8'h12;wait(no_signal);wait(state==10);
        force dut.sd_card_top_m0.empty_card=1;release dut.raw_error;
        wait(state==9);repeat(3000) @(negedge clk);
        if(!no_signal || recovered!=2) $fatal(1,"empty card accepted");
        release dut.sd_card_top_m0.empty_card;
        dut.sd_card_top_m0.empty_card=0;
        wait(recovered==3 && !no_signal);
        $display("PASS hotplug: idle heartbeat, isolated probe data, removal, repeated auto-remount, empty FAT32 card, visible-bank protection");$finish;
    end
    initial begin #10000000;$fatal(1,"hotplug timeout state=%0d probes=%0d mounts=%0d",state,probes,recovered);end
endmodule
