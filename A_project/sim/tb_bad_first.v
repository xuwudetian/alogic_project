`timescale 1ns/1ps
module bad_first_case #(parameter ALL_BAD=0)(output reg finished=0);
    reg clk=0,rst=1,ack=0,done=0,commit_ack=0;
    wire [3:0] state;
    wire [5:0] failed,ready;
    wire [7:0] error;
    wire wr,we,commit,autoplay;
    wire [2:0] picture,bank;
    integer pixels=0,attempts=0;
    always #5 clk=~clk;
    sd_card_bmp #(.CLK_FREQ_HZ(10000),.POWER_WAIT_CYCLES(4),.READY_WAIT_CYCLES(2)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(done),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.state_code(state),.error_code(error),.write_req(wr),.write_req_ack(ack),
        .write_en(we),.picture_id(picture),.disp_buf_idx(bank),.auto_play(autoplay),
        .SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(1'b0),
        .thumbnail_valid(ready),.thumbnail_failed(failed));
    defparam dut.decoder.EXPECTED_WIDTH=3,dut.decoder.EXPECTED_HEIGHT=2;
    defparam dut.sd_card_top_m0.BAD_PIC2_SIZE=1,dut.sd_card_top_m0.BAD_PIC4_SIZE=ALL_BAD;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) done=!done;end
        if(!rst && dut.file_start) attempts=attempts+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;
        if(ALL_BAD) begin
            wait(failed==4'b1010 && state==8);repeat(20000) @(negedge clk);
            if(commit || attempts!=2 || error!=8'h37 || ready!=0 || autoplay)
                $fatal(1,"all bad must stop after one attempt per file, without commit");
        end else begin
            wait(commit!=commit_ack);
            if(error || picture!=3 || bank!=0 || pixels!=6 || attempts!=2 || autoplay || failed!=2 || ready!=8)
                $fatal(1,"first-image fallback/commit failed E%h pic%0d attempts%0d",error,picture,attempts);
            @(negedge clk);commit_ack=commit;wait(state==8);
        end
        finished=1;
    end
endmodule
module tb_bad_first;
    wire one,all_bad;
    bad_first_case a(one);
    bad_first_case #(.ALL_BAD(1)) b(all_bad);
    initial begin wait(one && all_bad);$display("PASS bad first: automatic valid-image fallback, all-bad bounded attempts, no invalid commit");$finish;end
    initial begin #10000000;$fatal(1,"bad first timeout");end
endmodule
