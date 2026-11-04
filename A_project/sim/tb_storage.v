`timescale 1ns/1ps
module tb_storage;
    reg clk=0,rst=1,next_toggle=0,auto_toggle=0,commit_ack=0,write_ack=0,write_done=0;
    wire commit,write_req,we,flip,auto_play,scaled;
    wire [2:0] wb,db,pic;
    wire [3:0] state;
    wire [5:0] available;
    wire [7:0] error;
    wire [31:0] pixel;
    wire cs,sclk,mosi;
    integer pixels=0,commits=0,watch=0;
    sd_card_bmp #(.CLK_FREQ_HZ(500000),.POWER_WAIT_CYCLES(8),.READY_WAIT_CYCLES(4)) dut(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(auto_toggle),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(write_done),.write_overflow(1'b0),
        .commit_toggle(commit),.write_buf_idx(wb),.disp_buf_idx(db),.picture_id(pic),.state_code(state),
        .error_code(error),.auto_play(auto_play),.scaled_image(scaled),.available_images(available),
        .write_req(write_req),.write_req_ack(write_ack),.write_en(we),.write_data(pixel),.write_v_flip(flip),
        .SD_nCS(cs),.SD_DCLK(sclk),.SD_MOSI(mosi),.SD_MISO(1'b1),.write_ready(1'b1),
        .audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0),.ui_pause(1'b0));
    defparam dut.decoder.EXPECTED_WIDTH=3;
    defparam dut.decoder.EXPECTED_HEIGHT=2;
    always #5 clk=~clk;
    always @(negedge clk) begin
        write_ack=write_req;
        if(rst || write_req) pixels=0;
        else if(we) begin
            pixels=pixels+1;
            if(pixel[31:8]!==24'hf05014) $fatal(1,"storage RGB ordering");
            if(pixels==6) write_done=!write_done; // completion deliberately precedes file_end
        end
    end
    task accept_frame;
        input [2:0] expected_bank,expected_picture;
        input expected_scale,expected_flip;
        begin
            wait(commit!=commit_ack);#1;
            if(error!=0 || db!=expected_bank || pic!=expected_picture ||
               scaled!=expected_scale || flip!=expected_flip || pixels!=6)
                $fatal(1,"storage commit: E%h bank%d pic%d pixels%d",error,db,pic,pixels);
            repeat(30) @(negedge clk);
            if(state!=7 || write_req || wb!=expected_bank) $fatal(1,"back buffer released too early");
            commit_ack=commit;
            wait(state==8);repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        accept_frame(0,1,0,1);
        if(available!=4'b1010) $fatal(1,"sparse playlist");
        next_toggle=!next_toggle;
        accept_frame(1,3,1,0);
        next_toggle=!next_toggle;
        accept_frame(0,1,0,1);
        $display("PASS storage integration: FAT->BMP->RGB, early write completion, sparse playlist, alternating banks, delayed commit ACK");
        $finish;
    end
    initial begin #10000000;$fatal(1,"storage timeout state%d E%h",state,error);end
endmodule

// Simulation-only sector service, not an FPGA source. SPI hardware is not modeled.
module sd_card_top #(
    parameter WITH_AUDIO=0,parameter BAD_BOOT_READS=0,parameter BAD_PIC4_SIZE=0,parameter BAD_PIC2_SIZE=0
)(
    input clk,input rst,output SD_nCS,output SD_DCLK,output SD_MOSI,input SD_MISO,
    output sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,output reg sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,output sd_sec_write_end,
    input read_slow,output [7:0] sd_sec_read_error
);
    reg [2:0] state=0;
    reg [8:0] index=0;
    reg [31:0] lba=0;
    integer boot_reads=0;
    reg bad_pic2=BAD_PIC2_SIZE,bad_pic4=BAD_PIC4_SIZE;
    reg empty_card=0;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_init_done=!rst;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;
    assign sd_sec_read_error=0;
    function [7:0] card;
        input [31:0] sector;
        input [8:0] off;
        integer entry,size,w,h,stride,physical,chan,aoff;
        reg [31:0] value;
        begin
            card=0;
            if(sector==0) case(off)
                0:card=8'heb;12:card=2;13:card=2;14:card=32;16:card=1;
                32:card=8'ha0;33:card=8'h86;34:card=1;37:card=2;44:card=2;
                510:card=boot_reads<=BAD_BOOT_READS ? 0 : 8'h55;
                511:card=boot_reads<=BAD_BOOT_READS ? 0 : 8'haa;
            endcase
            else if(sector==32) begin
                card=off[1:0]==3 ? 8'h0f : 8'hff;
                if(WITH_AUDIO && (off[8:2]==8 || off[8:2]==10))
                    card=off[1:0]==0 ? off[8:2]+2 : 0;
            end
            else if(sector==544 && off<64 && !empty_card) begin
                entry=off/32;
                case(off%32)
                    0:card="P";1:card="I";2:card="C";3:card=entry ? "4" : "2";
                    4,5,6,7:card=" ";8:card="B";9:card="M";10:card="P";11:card=8'h20;
                    26:card=entry ? 6 : 4;
                    28:card=entry ? 134 : 78;
                endcase
            end else if(WITH_AUDIO && sector==544 && off>=64 && off<96) begin
                case(off-64)
                    0:card="A";1:card="U";2:card="D";3:card="I";4:card="O";
                    5,6,7:card=" ";8:card="W";9:card="A";10:card="V";11:card=8'h20;
                    26:card=8;28:card=8'h2c;29:card=8'h08;
                endcase
            end else if(WITH_AUDIO && sector>=556 && sector<=564) begin
                aoff=sector<558 ? (sector-556)*512+off :
                     sector<562 ? (sector-560)*512+1024+off : (sector-564)*512+2048+off;
                case(aoff)
                    0:card="R";1:card="I";2,3:card="F";
                    4:card=8'h24;5:card=8'h08;
                    8:card="W";9:card="A";10:card="V";11:card="E";
                    12:card="f";13:card="m";14:card="t";15:card=" ";
                    16:card=16;20:card=1;22:card=1;24:card=8'h80;25:card=8'hbb;
                    28:card=8'h00;29:card=8'h77;30:card=8'h01;32:card=2;34:card=16;
                    36:card="d";37:card="a";38:card="t";39:card="a";41:card=8'h08;
                    default:if(aoff>=44 && aoff<2092)
                        card=aoff[0] ? (aoff[1] ? 8'hfe : 8'h12) : (aoff[1] ? 8'hdc : 8'h34);
                endcase
            end else if(sector==548 || sector==552) begin
                size=sector==548 ? 78 : 134;
                w=sector==548 ? 3 : 6;h=sector==548 ? 2 : -4;
                stride=sector==548 ? 12 : 20;
                if(off==0) card="B";
                else if(off==1) card="M";
                else if(off>=2 && off<6) card=(size-(((bad_pic4 && sector==552) || (bad_pic2 && sector==548)) ? 1 : 0))>>(8*(off-2));
                else if(off==10) card=54;
                else if(off==14) card=40;
                else if(off==18) card=w;
                else if(off>=22 && off<26) card=h>>(8*(off-22));
                else if(off==26) card=1;
                else if(off==28) card=24;
                else if(off>=54 && off<size) begin
                    physical=(off-54)%stride;chan=physical%3;
                    if(physical<w*3) card=chan==0 ? 20 : chan==1 ? 80 : 240;
                end
            end
        end
    endfunction
    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin state<=0;index<=0;sd_sec_read_data<=0;end
        else case(state)
            0:if(sd_sec_read) begin
                lba<=sd_sec_read_addr;index<=0;state<=1;
                if(sd_sec_read_addr==0) boot_reads<=boot_reads+1;
            end
            1:begin sd_sec_read_data<=card(lba,index);sd_sec_read_data_valid<=1;state<=2;end
            2:state<=3;
            3:if(index==511) state<=4;else begin index<=index+1'b1;state<=1;end
            4:begin sd_sec_read_end<=1;state<=5;end
            5:if(!sd_sec_read) state<=0;
        endcase
    end
endmodule
