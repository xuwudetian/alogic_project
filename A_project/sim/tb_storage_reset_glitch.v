`timescale 1ns/1ps
// Inject sub-cycle state-bit skew at IDLE(1000)->PICK(0010).
// The intermediate binary code 1010 must never asynchronously reset storage.
module tb_storage_reset_glitch;
    reg clk=0,rst=1,ack=0,done=0,commit_ack=0,next_request=0;
    wire wr,we,commit;
    wire [3:0] state;
    wire [5:0] available;
    wire [7:0] error;
    wire [59:0] detail;
    integer pixels=0;
    always #5 clk=~clk;
    sd_card_bmp #(.POWER_WAIT_CYCLES(4),.READY_WAIT_CYCLES(2)) dut(
        .clk(clk),.rst(rst),.next_toggle(next_request),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(done),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.state_code(state),.error_code(error),.available_images(available),
        .debug_status(detail),.write_req(wr),.write_req_ack(ack),.write_en(we),
        .SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(1'b0));
    defparam dut.decoder.EXPECTED_WIDTH=3,dut.decoder.EXPECTED_HEIGHT=2;
    defparam dut.sd_card_top_m0.WITH_AUDIO=1;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) done=!done;end
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;
        wait(commit!=commit_ack);@(negedge clk);commit_ack=commit;wait(state==8);
        if(available!=10 || !dut.audio_found) $fatal(1,"initial catalog missing");
        @(negedge clk);next_request=!next_request;
        wait(state==2);
        #0.1;force dut.state=4'ha;
        #0.8;force dut.state=4'h2;
        #0.1;release dut.state;
        wait(error!=0 || commit!=commit_ack);
        if(error!=0) begin
            $display("REPRO state skew: E%h S%h L%h N%h H%h R%h available=%b audio_found=%b size=%0d",error,state,detail[59:28],detail[27:18],detail[17:2],detail[1:0],available,dut.audio_found,dut.size);
            $fatal(1,"sub-cycle state decode reset erased metadata before next file");
        end
        if(available!=10 || !dut.audio_found || pixels!=6) $fatal(1,"metadata or frame damaged");
        $display("PASS state skew: no asynchronous reset during IDLE-to-PICK; image/audio catalog and next frame preserved");
        $finish;
    end
    initial begin #10000000;$fatal(1,"state skew timeout S%h E%h",state,error);end
endmodule
