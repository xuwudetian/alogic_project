`timescale 1ns/1ps
module tb_media_catalog;
    reg clk=0,rst=1,start=0,busy=0,valid=0,done=0;
    reg [7:0] data=0;
    reg [8:0] index=0;
    wire request,scandone,found;
    wire [31:0] lba,cluster,size,c4,c5,s4,s5;
    wire [5:0] images;
    wire [7:0] error;
    integer n,reads=0;
    always #5 clk=~clk;
    fat32_volume_scanner dut(.clk(clk),.rst_n(!rst),.scan_start(start),.scan_done(scandone),
        .fs_error(error),.resource_valid(images),.resource4_cluster(c4),.resource5_cluster(c5),
        .resource4_size(s4),.resource5_size(s5),.sector_req(request),.sector_lba(lba),
        .sector_busy(busy),.sector_valid(valid),.sector_byte(data),.sector_byte_index(index),
        .sector_done(done),.sector_error(8'd0),.audio_found(found),.audio_cluster(cluster),.audio_size(size));
    function [7:0] disk;
        input [31:0] sector;input integer offset;
        integer entry;
        begin
            disk=0;entry=offset/32;
            if(sector==0) case(offset)
                0:disk=8'heb;12:disk=2;13:disk=2;14:disk=32;16:disk=1;
                32:disk=8'ha0;33:disk=8'h86;34:disk=1;37:disk=2;44:disk=2;
                510:disk=8'h55;511:disk=8'haa;
            endcase
            else if(sector==544) begin
                if(entry<4) case(offset%32)
                    0:disk="P";1:disk="I";2:disk="C";3:disk="1"+entry;
                    4,5,6,7:disk=" ";8:disk="B";9:disk="M";10:disk="P";11:disk=8'h20;
                    26:disk=4+entry;28:disk=78;
                endcase
                else if(offset%32==0) disk=8'he5;
            end else if(sector==545 && offset<64) case(offset%32)
                0:disk="P";1:disk="I";2:disk="C";3:disk="5"+entry;
                4,5,6,7:disk=" ";8:disk="B";9:disk="M";10:disk="P";11:disk=8'h20;
                26:disk=8+entry;28:disk=78+entry;
            endcase
            else if(sector==545 && offset<96) case(offset-64)
                0:disk="A";1:disk="U";2:disk="D";3:disk="I";4:disk="O";
                5,6,7:disk=" ";8:disk="W";9:disk="A";10:disk="V";11:disk=8'h20;
                26:disk=16;28:disk=44;29:disk=8;
            endcase
        end
    endfunction
    initial forever begin
        @(negedge clk);
        if(request) begin
            busy=1;reads=reads+1;
            for(n=0;n<512;n=n+1) begin
                index=n;data=disk(lba,n);valid=1;@(negedge clk);
                valid=0;@(negedge clk);
            end
            done=1;@(negedge clk);done=0;busy=0;
        end
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
        wait(scandone);@(negedge clk);
        if(error || images!=63 || !found || cluster!=16 || size!=2092 || reads!=3 || c4!=8 || c5!=9 || s4!=78 || s5!=79)
            $fatal(1,"AUDIO.WAV after all six PICs was skipped");
        $display("PASS media catalog: AUDIO.WAV in later root sector after PIC1..6, with PIC5/6 in later sector, correct short name/cluster/size");
        $finish;
    end
    initial begin #1000000;$fatal(1,"catalog timeout");end
endmodule
