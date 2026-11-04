`timescale 1ns/1ps
module tb_storage_flow;
    reg clk=0,mem_clk=0,rst=1,next_toggle=0,commit_ack=0,finish_toggle=0,memory_busy=1;
    wire commit,request,ack,write_enable,write_finish,overflow,ready,flip;
    wire [31:0] pixel,mem_data;
    wire [20:0] mem_address;
    wire [2:0] write_bank,display_bank,picture;
    wire [3:0] state;
    wire [5:0] available;
    wire [7:0] error;
    wire [59:0] detail;
    wire mem_write;
    integer stored=0,commits=0,stall_cycles=0;
    reg [2:0] expected_picture=0;
    reg paused=0;
    always #10 clk=~clk;
    always #12.5 mem_clk=~mem_clk;
    sd_card_bmp #(.POWER_WAIT_CYCLES(16),.READY_WAIT_CYCLES(8)) storage(
        .clk(clk),.rst(rst),.next_toggle(next_toggle),.auto_toggle(1'b0),.interval_seconds(4'd3),
        .commit_ack_toggle(commit_ack),.write_finish_toggle(finish_toggle),
        .write_overflow(overflow),.write_ready(ready),.commit_toggle(commit),
        .write_buf_idx(write_bank),.disp_buf_idx(display_bank),.picture_id(picture),
        .state_code(state),.error_code(error),.available_images(available),
        .write_req(request),.write_req_ack(ack),.write_en(write_enable),.write_data(pixel),
        .write_v_flip(flip),.SD_MISO(1'b1),.debug_status(detail),
        .audio_clk(clk),.audio_rst(rst),.audio_tick(1'b0),.tone(24'd0),.volume(4'd8),.mute(1'b0),
        .browse(1'b0),.select_toggle(1'b0),.select_index(3'd0));
    defparam storage.decoder.EXPECTED_WIDTH=64;
    defparam storage.decoder.EXPECTED_HEIGHT=32;
    frame_read_write #(.BURST_SIZE(128),.FRAME_WIDTH(64),.FRAME_HEIGHT(32)) memory(
        .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),
        .Sdr_busy(memory_busy),.Sdr_rd_en(1'b0),.Sdr_rd_dout(32'd0),
        .read_clk(clk),.read_req(1'b0),.read_addr_0(21'd0),.read_addr_1(21'd2048),
        .read_addr_2(21'd0),.read_addr_3(21'd0),.read_addr_4(21'd0),.read_addr_5(21'd0),.read_addr_index(3'd0),
        .read_len(21'd2048),.read_en(1'b0),
        .App_wr_en(mem_write),.App_wr_addr(mem_address),.App_wr_din(mem_data),
        .write_clk(clk),.write_req(request),.write_req_ack(ack),.write_finish(write_finish),
        .write_addr_0(21'd0),.write_addr_1(21'd2048),.write_addr_2(21'd0),.write_addr_3(21'd0),.write_addr_4(21'd0),.write_addr_5(21'd0),
        .write_addr_index(write_bank),.write_len(21'd2048),
        .write_en(write_enable),.write_data(pixel),.write_v_flip(flip),
        .write_overflow(overflow),.write_ready(ready));
    always @(posedge mem_clk) begin
        if(rst) begin finish_toggle<=0;stored=0;end
        else if(ack) stored=0;
        else begin
            if(mem_write) begin
                if(mem_address!==(write_bank*2048+stored) ||
                   mem_data!==(32'h50301400+expected_picture*32'h01010100))
                    $fatal(1,"integrated pixel/address mismatch pic%0d word%0d %h @%0d",
                        expected_picture,stored,mem_data,mem_address);
                stored=stored+1;
            end
            if(write_finish) finish_toggle<=!finish_toggle;
        end
    end
    always @(posedge clk) begin
        if(!rst && overflow) $fatal(1,"integrated E40");
        if(!rst && state==5 && !ready) stall_cycles=stall_cycles+1;
    end
    task accept_frame;
        input [2:0] expected;
        begin
            wait(commit!=commit_ack);@(negedge clk);
            if(error!=0 || picture!=expected || stored!=2048 || available!=15)
                $fatal(1,"integrated commit E%h picture%0d stored%0d",error,picture,stored);
            repeat(20) @(negedge clk);
            commit_ack=commit;commits=commits+1;
            wait(state==8);repeat(10) @(negedge clk);
        end
    endtask
    task next_picture;
        input [2:0] expected;
        begin expected_picture=expected;next_toggle=!next_toggle;end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;
        wait(memory.write_used>=480);
        repeat(100) @(negedge clk);
        if(ready || stored!=0 || stall_cycles==0) $fatal(1,"integrated backpressure");
        memory_busy=0;accept_frame(0);
        storage.sd_card_top_m0.bad_chain=1;
        next_picture(1);
        wait(error==8'h24 && state==8);repeat(10) @(negedge clk);
        if(commit!=commit_ack || picture!=0 || detail[59:28]!=65537 || detail[27:0]!=0)
            $fatal(1,"E24 did not retain old image and exact FAT evidence");
        next_picture(2);accept_frame(2);
        next_picture(3);accept_frame(3);
        next_picture(0);accept_frame(0);
        storage.sd_card_top_m0.bad_chain=0;
        next_picture(1);accept_frame(1);
        rst=1;commit_ack=0;next_toggle=0;expected_picture=0;
        repeat(8) @(negedge clk);rst=0;accept_frame(0);
        if(commits!=6) $fatal(1,"commit count");
        $display("PASS storage flow: four fragmented BMPs, high clusters, real FIFOs, backpressure, E24 evidence/old-frame retention/recovery, KEY1-equivalent reset");
        $finish;
    end
    initial begin #30000000;$fatal(1,"storage flow timeout E%h S%h stored%0d",error,state,stored);end
endmodule

module sd_card_top #(parameter integer IMAGE_COUNT=4)(
    input clk,input rst,output SD_nCS,output SD_DCLK,output SD_MOSI,input SD_MISO,
    output sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,output reg sd_sec_read_end,
    input sd_sec_write,input [31:0] sd_sec_write_addr,input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req,output sd_sec_write_end,
    input read_slow,output [7:0] sd_sec_read_error
);
    reg bad_chain=0;
    reg [2:0] state=0;
    reg [8:0] byte_index=0;
    reg [31:0] lba=0;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_init_done=!rst;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;assign sd_sec_read_error=0;
    function [31:0] first;
        input integer image;
        case(image)
            0:first=127;1:first=65537;2:first=256;3:first=70000;4:first=512;5:first=80000;6:first=90000;7:first=95000;default:first=98000;
        endcase
    endfunction
    function [7:0] card_byte;
        input [31:0] sector;
        input [8:0] offset;
        integer image,cluster_number,ordinal,file_offset,channel,entry;
        reg [31:0] value;
        begin
            card_byte=0;
            if(sector==0) begin
                case(offset)
                    0:card_byte=8'heb;12:card_byte=2;13:card_byte=1;14:card_byte=32;16:card_byte=1;
                    32:card_byte=8'hc0;33:card_byte=8'h86;34:card_byte=1;
                    37:card_byte=4;44:card_byte=2;
                    510:card_byte=8'h55;511:card_byte=8'haa;
                endcase
            end else if(sector>=32 && sector<1056) begin
                cluster_number=(sector-32)*128+offset/4;value=0;
                for(image=0;image<IMAGE_COUNT;image=image+1) begin
                    ordinal=(cluster_number-first(image))/2;
                    if(cluster_number>=first(image) && cluster_number<=first(image)+24 &&
                       (cluster_number-first(image))%2==0)
                        value=ordinal==12 ? 32'h0fffffff : cluster_number+2;
                end
                if(bad_chain && cluster_number==65537) value=0;
                card_byte=value>>(offset[1:0]*8);
            end else if(sector==1056 && offset<32*IMAGE_COUNT) begin
                entry=offset/32;value=first(entry);
                case(offset%32)
                    0:card_byte="P";1:card_byte="I";2:card_byte="C";3:card_byte="1"+entry;
                    4,5,6,7:card_byte=" ";8:card_byte="B";9:card_byte="M";10:card_byte="P";
                    11:card_byte=8'h20;
                    20:card_byte=value>>16;21:card_byte=value>>24;
                    26:card_byte=value;27:card_byte=value>>8;
                    28:card_byte=8'h36;29:card_byte=8'h18;
                endcase
            end else begin
                cluster_number=sector-1056+2;
                for(image=0;image<IMAGE_COUNT;image=image+1) begin
                    if(cluster_number>=first(image) && cluster_number<=first(image)+24 &&
                       (cluster_number-first(image))%2==0) begin
                        ordinal=(cluster_number-first(image))/2;file_offset=ordinal*512+offset;
                        case(file_offset)
                            0:card_byte="B";1:card_byte="M";
                            2:card_byte=8'h36;3:card_byte=8'h18;10:card_byte=54;
                            14:card_byte=40;18:card_byte=64;
                            22:card_byte=8'he0;23,24,25:card_byte=8'hff;
                            26:card_byte=1;28:card_byte=24;
                            default:if(file_offset>=54 && file_offset<6198) begin
                                channel=(file_offset-54)%3;
                                card_byte=(channel==0 ? 8'h14 : channel==1 ? 8'h30 : 8'h50)+image;
                            end
                        endcase
                    end
                end
            end
        end
    endfunction
    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin state<=0;byte_index<=0;sd_sec_read_data<=0;end
        else case(state)
            0:if(sd_sec_read) begin lba<=sd_sec_read_addr;byte_index<=0;state<=1;end
            1:begin sd_sec_read_data<=card_byte(lba,byte_index);sd_sec_read_data_valid<=1;state<=2;end
            2:if(byte_index==511) state<=3;else begin byte_index<=byte_index+1'b1;state<=1;end
            3:begin sd_sec_read_end<=1;state<=4;end
            4:if(!sd_sec_read) state<=0;
        endcase
    end
endmodule
