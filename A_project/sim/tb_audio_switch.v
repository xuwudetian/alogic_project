`timescale 1ns/1ps
// Full storage path: the real scanner, arbiter, guard, WAV parser and async
// FIFO run against a byte-accurate four-file FAT32 card model below.
module tb_audio_switch;
    reg clk=0,aclk=0,rst=1,ack=0,finished=0,commit_ack=0;
    reg [1:0] selection=0;
    reg [4:0] tick_div=0;
    wire tick=tick_div==0;
    wire commit,wr,we,av,tag;
    wire [2:0] pic;
    wire [3:0] state;
    wire [5:0] ready;
    wire [7:0] error,status;
    wire [23:0] pcm;
    integer pixels=0,image_starts=0,image_commits=0,local_resets=0;
    integer track_samples[0:3];
    integer sample_number=0,expected_sample,baseline_samples,k;
    integer previous_images,previous_commits,previous_reads;
    reg guard_images=0;
    always #10 clk=~clk;
    always #17 aclk=~aclk;
    always @(posedge aclk) if(rst) tick_div<=0;else tick_div<=tick_div+1'b1;
    sd_card_bmp #(.POWER_WAIT_CYCLES(8),.READY_WAIT_CYCLES(4),
        .UI_PAUSE_ENABLE(1),.FRAME_CACHE_ENABLE(1),.GENERAL_SCALE(1),
        .AUDIO_SELECT_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.next_toggle(1'b0),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finished),.write_overflow(1'b0),
        .write_ready(1'b1),.commit_toggle(commit),.picture_id(pic),.state_code(state),.error_code(error),
        .write_req(wr),.write_req_ack(ack),.write_en(we),.SD_MISO(1'b1),
        .audio_clk(aclk),.audio_rst(rst),.audio_tick(tick),.tone(24'h000100),.volume(4'd8),.mute(1'b0),
        .audio_valid(av),.audio_pcm(pcm),.audio_status(status),.audio_wav_sample_valid(tag),
        .audio_select(selection),.browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),
        .thumbnail_valid(ready),.ui_pause(1'b0));
    defparam dut.decoder.EXPECTED_WIDTH=3;
    defparam dut.decoder.EXPECTED_HEIGHT=2;
    always @(negedge clk) begin
        ack=wr;
        if(rst) begin pixels=0;finished=0;commit_ack=0;end
        else begin
            if(wr) pixels=0;
            else if(we) begin
                if(dut.write_data!==32'hf0501400) $fatal(1,"audio switch damaged BMP pixels");
                pixels=pixels+1;if(pixels==6) finished=!finished;
            end
            if(commit!=commit_ack) begin commit_ack=commit;image_commits=image_commits+1;end
            if(dut.file_start) image_starts=image_starts+1;
            if(guard_images && (dut.driver_reset || error!=0 || pic!=0 || ready!=3 || wr))
                $fatal(1,"audio operation disturbed cached images E%h picture=%0d ready=%b",error,pic,ready);
            if(dut.wav.switch_reset && (dut.wav.audio_outstanding || dut.wav_req || dut.arbiter.pending_audio || dut.audio_owner))
                $fatal(1,"audio reset discarded a queued/in-flight SD transaction");
        end
    end
    always @(posedge dut.wav.switch_reset) local_resets=local_resets+1;
    always @(negedge aclk) begin
        if(rst || dut.wav.read_reset) sample_number=0;
        else if(av && tag) begin
            expected_sample=((dut.active_audio_select+1)<<12)+(sample_number%256);
            if(pcm!==(expected_sample<<8))
                $fatal(1,"mixed/stale/out-of-order PCM track=%0d sample=%0d actual=%h expected=%h",
                    dut.active_audio_select,sample_number,pcm,expected_sample<<8);
            sample_number=(sample_number+1)%1024;
            track_samples[dut.active_audio_select]=track_samples[dut.active_audio_select]+1;
        end
    end
    task heard;
        input [1:0] wanted;
        begin
            wait(dut.active_audio_select==wanted && dut.wav.switch_state==0 && status==1);
            baseline_samples=track_samples[wanted];
            wait(track_samples[wanted]>=baseline_samples+32);
            if(dut.wav.full || status!==1) $fatal(1,"new WAV did not play cleanly");
        end
    endtask
    task choose;
        input [1:0] wanted;
        begin @(negedge aclk);selection=wanted;heard(wanted);end
    endtask
    task restart;
        begin
            guard_images=0;
            @(negedge aclk);rst=1;selection=0;
            repeat(5) @(negedge aclk);rst=0;
            wait(ready==3 && state==8 && commit_ack==commit);heard(0);
            previous_images=image_starts;previous_commits=image_commits;guard_images=1;
        end
    endtask
    task unchanged_images;
        begin
            if(image_starts!=previous_images || image_commits!=previous_commits)
                $fatal(1,"audio selection restarted an image transaction");
        end
    endtask
    initial begin
        for(k=0;k<4;k=k+1) track_samples[k]=0;
        // Hold a real BMP sector across an audio reset. The local audio reset
        // must preserve the card's byte counter and the active picture owner.
        repeat(5) @(negedge aclk);rst=0;
        wait(dut.sd_card_top_m0.lba==552 && dut.sd_card_top_m0.state==1);
        @(negedge clk);dut.sd_card_top_m0.pause_io=1;
        @(negedge aclk);selection=1;wait(dut.wav.switch_state==1);
        repeat(80) begin
            @(negedge clk);
            if(!dut.arbiter.active || dut.audio_owner || dut.driver_reset ||
               dut.sd_card_top_m0.lba!=552 || dut.sd_card_top_m0.state!=1)
                $fatal(1,"local audio switch cancelled the active BMP transaction");
        end
        dut.sd_card_top_m0.pause_io=0;heard(1);
        wait(ready==3 && state==8 && commit_ack==commit);
        if(error!=0 || pic!=0) $fatal(1,"BMP failed after an audio switch during its sector");
        restart;
        // Initial playback must loop without rearranging or dropping samples.
        baseline_samples=track_samples[0];wait(track_samples[0]>=baseline_samples+1100);

        // Hold an actual old-file SD transfer, then request the next track.
        wait(dut.audio_owner && dut.sd_card_top_m0.state==1);
        @(negedge clk);dut.sd_card_top_m0.pause_io=1;
        @(negedge aclk);selection=1;
        wait(dut.wav.switch_state==1);
        repeat(80) begin
            @(negedge clk);
            if(!dut.wav.audio_outstanding || dut.wav.switch_reset || dut.active_audio_select!=0)
                $fatal(1,"busy switch failed to drain the old audio sector");
        end
        dut.sd_card_top_m0.pause_io=0;heard(1);unchanged_images;
        choose(2);choose(3);choose(0);unchanged_images;

        // Multiple mailbox updates while draining must converge on the final
        // selection, including binary transitions where both bits change.
        wait(dut.audio_owner && dut.sd_card_top_m0.state==1);
        @(negedge clk);dut.sd_card_top_m0.pause_io=1;
        @(negedge aclk);selection=1;repeat(12) @(negedge aclk);
        selection=2;repeat(12) @(negedge aclk);selection=3;
        repeat(20) @(negedge aclk);
        if(dut.audio_select_sd!==3 || dut.active_audio_select!==0)
            $fatal(1,"bundled-data mailbox lost the final rapid selection");
        dut.sd_card_top_m0.pause_io=0;heard(3);unchanged_images;

        // A global reset during draining resets both owners coherently.
        wait(dut.audio_owner && dut.sd_card_top_m0.state==1);
        @(negedge clk);dut.sd_card_top_m0.pause_io=1;
        @(negedge aclk);selection=2;wait(dut.wav.switch_state==1);
        restart;unchanged_images;

        // This mount omits AUDIO3 and gives AUDIO4 an unsupported channel
        // count. Errors stay in the WAV path and another selection recovers.
        dut.sd_card_top_m0.present_mask=4'b1011;
        dut.sd_card_top_m0.bad_mask=4'b1000;
        restart;
        @(negedge aclk);selection=2;
        wait(dut.active_audio_select==2 && dut.wav.switch_state==0 && status==8'h50);
        previous_reads=dut.sd_card_top_m0.audio_reads;
        repeat(1500) @(negedge clk);
        if(dut.sd_card_top_m0.audio_reads!=previous_reads || tag || error!=0)
            $fatal(1,"missing WAV caused stale samples or SD requests");
        unchanged_images;
        @(negedge aclk);selection=3;
        wait(status==8'h52 && dut.wav.disable_sync[1]);
        repeat(20) @(negedge aclk);
        if(tag || error!=0) $fatal(1,"unsupported WAV leaked samples or picture error");
        choose(1);choose(0);unchanged_images;
        if(local_resets<10 || track_samples[0]<1100 || track_samples[1]<32 ||
           track_samples[2]<32 || track_samples[3]<32)
            $fatal(1,"audio switching coverage incomplete");
        $display("PASS four-WAV storage: distinct ordered PCM, looping, asynchronous CDC, busy/rapid switches, local FIFO reset, global reset during drain, missing/bad WAV recovery, cached picture isolation");
        $finish;
    end
    initial begin #20000000;$fatal(1,"audio switch timeout E%h W%h state=%0d active=%0d switch=%0d samples=%0d/%0d/%0d/%0d",
        error,status,state,dut.active_audio_select,dut.wav.switch_state,
        track_samples[0],track_samples[1],track_samples[2],track_samples[3]);end
endmodule

// Six data sectors contain two tiny BMPs and four individually identifiable
// WAV files. A transfer may be paused without changing its byte sequence.
module sd_card_top(
    input clk,input rst,output SD_nCS,output SD_DCLK,output SD_MOSI,input SD_MISO,
    output sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,output reg sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,output sd_sec_write_end,input read_slow,output [7:0] sd_sec_read_error
);
    reg [2:0] state=0;
    reg [8:0] index=0;
    reg [31:0] lba=0;
    reg pause_io=0;
    reg [3:0] present_mask=4'hf,bad_mask=0;
    integer audio_reads=0;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_init_done=!rst;assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    assign sd_sec_read_error=0;
    function [7:0] card;
        input [31:0] sector;input [8:0] off;
        integer entry,track,aoff,physical,channel;
        reg [15:0] sample;
        begin
            card=0;
            if(sector==0) case(off)
                0:card=8'heb;12:card=2;13:card=8;14:card=32;16:card=1;
                32:card=8'ha0;33:card=8'h86;34:card=1;37:card=2;44:card=2;
                510:card=8'h55;511:card=8'haa;
            endcase
            else if(sector==32) card=off[1:0]==3 ? 8'h0f : 8'hff;
            else if(sector==544 && off<64) begin
                entry=off/32;
                case(off%32)
                    0:card="P";1:card="I";2:card="C";3:card="1"+entry;
                    4,5,6,7:card=" ";8:card="B";9:card="M";10:card="P";11:card=8'h20;
                    26:card=3+entry;28:card=78;
                endcase
            end else if(sector==544 && off<192) begin
                track=off/32-2;
                if(!present_mask[track]) begin if(off%32==0) card=8'he5;end
                else case(off%32)
                    0:card="A";1:card="U";2:card="D";3:card="I";4:card="O";
                    5:card="1"+track;6,7:card=" ";8:card="W";9:card="A";10:card="V";11:card=8'h20;
                    26:card=8+track;28:card=8'h2c;29:card=8'h08;
                endcase
            end else if(sector>=592 && sector<624) begin
                track=(sector-592)/8;aoff=((sector-592)%8)*512+off;
                sample=((track+1)<<12)+(((aoff-44)/2)%256);
                case(aoff)
                    0:card="R";1:card="I";2,3:card="F";4:card=8'h24;5:card=8'h08;
                    8:card="W";9:card="A";10:card="V";11:card="E";
                    12:card="f";13:card="m";14:card="t";15:card=" ";
                    16:card=16;20:card=1;22:card=bad_mask[track] ? 2 : 1;24:card=8'h80;25:card=8'hbb;
                    29:card=8'h77;30:card=8'h01;32:card=2;34:card=16;
                    36:card="d";37:card="a";38:card="t";39:card="a";41:card=8'h08;
                    default:if(aoff>=44 && aoff<2092) card=aoff[0] ? sample[15:8] : sample[7:0];
                endcase
            end else if(sector==552 || sector==560) begin
                case(off)
                    0:card="B";1:card="M";2:card=78;10:card=54;14:card=40;
                    18:card=3;22:card=2;26:card=1;28:card=24;
                    default:if(off>=54 && off<78) begin
                        physical=(off-54)%12;channel=physical%3;
                        if(physical<9) card=channel==0 ? 20 : channel==1 ? 80 : 240;
                    end
                endcase
            end
        end
    endfunction
    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin state<=0;index<=0;sd_sec_read_data<=0;pause_io<=0;end
        else if(!pause_io) case(state)
            0:if(sd_sec_read) begin
                lba<=sd_sec_read_addr;index<=0;state<=1;
                if(sd_sec_read_addr>=592 && sd_sec_read_addr<624) audio_reads<=audio_reads+1;
            end
            1:begin sd_sec_read_data<=card(lba,index);sd_sec_read_data_valid<=1;state<=2;end
            2:state<=3;
            3:if(index==511) state<=4;else begin index<=index+1'b1;state<=1;end
            4:begin sd_sec_read_end<=1;state<=5;end
            5:if(!sd_sec_read) state<=0;
        endcase
    end
endmodule
