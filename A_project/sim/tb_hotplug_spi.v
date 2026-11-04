`timescale 1ns/1ps
module tb_hotplug_spi;
    reg clk=0,rst=1,present=0,card_reset=1,ack=0,finished=0,commit_ack=0;
    wire cs,sclk,mosi,miso,card_miso,commit,wr,we,no_signal;
    wire [2:0] bank;wire [3:0] state;integer pixels=0,mounts=0;reg [2:0] saved_bank;
    always #10 clk=~clk;
    assign miso=present ? card_miso : 1'b1;
    sd_spi_card_model #(.FILESYSTEM(2)) card(card_reset,cs || !present,sclk,mosi,card_miso);
    // Simulation-only shortened watchdog. SPI electrical clock dividers are unchanged.
    sd_card_bmp #(.CLK_FREQ_HZ(1000000),.POWER_WAIT_CYCLES(32),.READY_WAIT_CYCLES(8),.HOTPLUG_ENABLE(1),
        .FRAME_CACHE_ENABLE(1),.PROBE_INTERVAL_CYCLES(1000),.REINSERT_WAIT_CYCLES(2000)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.disp_buf_idx(bank),.state_code(state),.write_req(wr),.write_req_ack(ack),.write_en(we),
        .SD_nCS(cs),.SD_DCLK(sclk),.SD_MOSI(mosi),.SD_MISO(miso),
        .audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(1'b0),.run_auto(1'b0),.no_signal(no_signal));
    defparam dut.decoder.EXPECTED_WIDTH=3;defparam dut.decoder.EXPECTED_HEIGHT=2;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;else if(we) begin pixels=pixels+1;if(pixels==6) finished=!finished;end
        if(commit!=commit_ack) begin commit_ack=commit;mounts=mounts+1;end
        if(dut.arbiter.probing && (dut.sector_valid || dut.wav_valid)) $fatal(1,"probe leaked to parsers");
    end
    initial begin
        repeat(5) @(negedge clk);rst=0;
        wait(no_signal); // No card at power-up, only pull-up on real MISO.
        if(mounts) $fatal(1,"boot without card published an image");
        present=1;card_reset=0;
        wait(mounts==1 && !no_signal);saved_bank=bank;
        wait(dut.arbiter.probing && dut.sector_read);@(negedge clk);present=0;card_reset=1;
        wait(no_signal);
        if(bank!=saved_bank || mounts!=1) $fatal(1,"removal replaced cached image");
        repeat(3000) @(negedge clk);present=1;card_reset=0;
        wait(mounts==2 && !no_signal);
        $display("PASS hotplug SPI: absent at power-up, pull-up MISO removal mid-transfer, CRC/timeouts, CMD0 reinit, automatic second mount");$finish;
    end
    initial begin #1200000000;$fatal(1,"hotplug SPI timeout state%0d mounts%0d",state,mounts);end
endmodule
