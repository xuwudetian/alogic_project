`timescale 1ns/1ps
module tb_storage_spi;
    wire mbr_done,superfloppy_done;
    storage_spi_case #(.FILESYSTEM(1)) mbr(mbr_done);
    storage_spi_case #(.FILESYSTEM(2)) superfloppy(superfloppy_done);
    initial begin
        wait(mbr_done && superfloppy_done);
        $display("PASS storage SPI: both FAT32 layouts, CRC retry, bad-media rejection and rescan");
        $finish;
    end
endmodule

module storage_spi_case(output reg finished=0);
    parameter integer FILESYSTEM=1;
    reg clk=0,rst=1,write_ack=0,write_finish=0,commit_ack=0;
    reg next_toggle=0;
    always #10 clk=~clk;
    wire cs,sclk,mosi,miso,commit,wr,we;
    wire [31:0] pixel;
    wire [7:0] error;
    wire [3:0] state;
    wire [5:0] available;
    wire [59:0] diagnostic;
    integer pixels=0,phase=0;
    sd_card_bmp #(.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8)) dut(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(write_finish),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.write_buf_idx(),.disp_buf_idx(),.picture_id(),.state_code(state),
        .error_code(error),.auto_play(),.scaled_image(),.available_images(available),
        .write_req(wr),.write_req_ack(write_ack),.write_en(we),.write_data(pixel),.write_v_flip(),
        .SD_nCS(cs),.SD_DCLK(sclk),.SD_MOSI(mosi),.SD_MISO(miso),
        .debug_status(diagnostic),.debug_toggle(),.audio_clk(clk),.audio_rst(rst),
        .audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0));
    defparam dut.decoder.EXPECTED_WIDTH=3;
    defparam dut.decoder.EXPECTED_HEIGHT=2;
    sd_spi_card_model #(.FILESYSTEM(FILESYSTEM)) card(rst,cs,sclk,mosi,miso);
    always @(negedge clk) begin
        write_ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin
            pixels=pixels+1;
            if(pixel!==32'hf0501400) $fatal(1,"pin-level storage pixel mismatch");
            if(pixels==6) write_finish=!write_finish;
        end
        if(!rst && phase==0 && card.reads==1 && dut.sector_valid)
            $fatal(1,"unverified/corrupt sector escaped the guard");
    end
    initial begin
        // Corrupt the 0xAA on the wire, without modifying the card's correct CRC.
        card.data_faults=1;
        repeat(5) @(negedge clk);rst=0;
        wait(commit!=commit_ack);@(negedge clk);
        if(error!=0 || pixels!=6 || available!=1) $fatal(1,"real SPI failed to commit BMP: E%h S%h",error,state);
        // Includes the streamer's final FAT read, which validates the file chain.
        if(!dut.slow_read || card.reads!=(FILESYSTEM==1 ? 6 : 5))
            $fatal(1,"first bad signature retry: slow=%b reads=%0d last_LBA=%0d",
                   dut.slow_read,card.reads,card.last_lba);
        if(diagnostic[27:18]!=512) $fatal(1,"diagnostic count");
        commit_ack=commit;
        wait(state==8);
        // A permanent media signature error must not be hidden by CRC success.
        phase=1;rst=1;repeat(5) @(negedge clk);
        card.bad_signature=1;commit_ack=0;write_finish=0;rst=0;
        wait(state==9);@(negedge clk);
        if(error!=8'h20 || commit || wr || diagnostic[17:2]!=0 ||
           diagnostic[27:18]!=512 || diagnostic[59:28]!=0)
            $fatal(1,"bad on-disk signature was not reported precisely");
        // KEY2's request-toggle path can rescan after a corrected card image.
        card.bad_signature=0;next_toggle=!next_toggle;
        wait(commit!=commit_ack);@(negedge clk);
        if(error!=0 || pixels!=6) $fatal(1,"scan retry failed");
        phase=2;rst=1;repeat(5) @(negedge clk);
        card.corrupt_crc=1;commit_ack=0;write_finish=0;rst=0;
        wait(state==10);repeat(10) @(negedge clk);
        if(error!=8'h14 || commit || wr || card.reads!=3 ||
           diagnostic[27:18]!=512 || diagnostic[17:2]!=16'h55aa || diagnostic[1:0]!=2)
            $fatal(1,"persistent CRC error did not halt with retained diagnostics");
        $display("PASS storage SPI: layout=%0d, 100kHz init, AA corruption retry, FAT/BMP commit, E20/rescan, persistent CRC halt",FILESYSTEM);
        finished=1;
    end
    initial begin
        #180000000;
        if(!finished) $fatal(1,"storage SPI timeout E%h S%h reads=%0d",error,state,card.reads);
    end
endmodule
