`timescale 1ns/1ps
module tb_boot_recovery;
    reg clk=0,rst=1,kn=1,ka=1,km=1,ack=0,done=0,commit_ack=0;
    reg [5:0] count=0;
    wire nt,at,wr,we,commit,autoplay,directory,alarm,browse;
    wire [1:0] run_mode;
    wire [3:0] state;
    wire [5:0] available,ready;
    wire [7:0] error;
    wire [2:0] bank;
    integer pixels=0;
    reg recovering=0,saw_recovery_write=0;
    always #5 clk=~clk;
    always @(posedge clk) count<=count+1'b1;
    player_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(30)) control(
        .clk(clk),.rst(rst),.frame_tick(count==0),.key_next(kn),.key_auto(ka),.key_menu(km),.switches(4'd0),
        .next_toggle(nt),.auto_toggle(at),.auto_active(autoplay),.available(available),.thumbnail_valid(ready),
        .directory(directory),.alarm(alarm),.browse(browse),.run_mode(run_mode),.playback_fault(error!=0));
    sd_card_bmp #(.CLK_FREQ_HZ(10000),.POWER_WAIT_CYCLES(4),.READY_WAIT_CYCLES(2),.UI_PAUSE_ENABLE(1),.RUN_MODE_CONTROL(1)) dut(
        .clk(clk),.rst(rst),.next_toggle(nt),.auto_toggle(at),.interval_seconds(4'd9),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(done),.write_overflow(1'b0),.write_ready(1'b1),
        .commit_toggle(commit),.state_code(state),.error_code(error),.write_req(wr),.write_req_ack(ack),
        .write_en(we),.disp_buf_idx(bank),.auto_play(autoplay),.available_images(available),.thumbnail_valid(ready),
        .SD_MISO(1'b1),.audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd4),.mute(1'b0),
        .browse(browse),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(directory || alarm),.run_auto(run_mode==2));
    defparam dut.decoder.EXPECTED_WIDTH=3,dut.decoder.EXPECTED_HEIGHT=2;
    always @(negedge clk) begin
        ack=wr;
        if(rst || wr) pixels=0;
        else if(we) begin pixels=pixels+1;if(pixels==6) done=!done;end
        if(recovering && wr) begin
            saw_recovery_write=1;
            if(dut.write_buf_idx!=1 || dut.first_frame || commit!=commit_ack)
                $fatal(1,"recovery would overwrite the visible bank");
        end
    end
    task press(input integer key);
        begin
            @(negedge clk);case(key) 2:kn=0;3:km=0;4:ka=0;endcase
            repeat(10) @(negedge clk);kn=1;ka=1;km=1;repeat(80) @(negedge clk);
        end
    endtask
    initial begin
        force dut.card_ready=0;
        repeat(3) @(negedge clk);rst=0;
        wait(state==10);repeat(5) @(negedge clk);
        if(error!=8'h11 || commit || wr) $fatal(1,"missing-card containment");
        release dut.card_ready;
        press(2);press(3);press(4); // directory -> continue playback (retry), preserving AUTO
        wait(commit!=commit_ack);
        if(error || bank!=0 || pixels!=6 || !autoplay) $fatal(1,"no-card recovery through UI");
        @(negedge clk);commit_ack=commit;wait(state==8);
        @(negedge clk);force dut.sector_error=8'h14;force dut.sector_debug=60'h1234567800156aa;
        repeat(2) @(negedge clk);release dut.sector_error;release dut.sector_debug;
        wait(state==10);repeat(10) @(negedge clk);
        if(error!=8'h14 || commit!=commit_ack || bank!=0) $fatal(1,"failed transaction changed display");
        if(dut.debug_status!==60'h1234567800156aa) $fatal(1,"service reset erased fatal diagnostics");
        recovering=1;press(2);press(4); // Continue playback is remembered; no mode submenu
        wait(commit!=commit_ack);
        if(error || bank!=1 || pixels!=6 || !saw_recovery_write) $fatal(1,"sector failure recovery");
        $display("PASS boot recovery: no-card timeout, real continue-playback key gestures, full reinit, retained display and opposite-bank commit");$finish;
    end
    initial begin #10000000;$fatal(1,"boot recovery timeout S%h E%h",state,error);end
endmodule
