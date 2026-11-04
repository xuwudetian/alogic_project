`timescale 1ns/1ps
// Directory fixtures exercise the actual streamed short-name parser and its
// shared descriptor port, including a fragmented FAT32 root directory.
module tb_audio_catalog;
    reg clk=0,rst=1,start=0,busy=0,valid=0,done=0;
    reg [7:0] data=0;
    reg [8:0] index=0;
    reg [1:0] selection=0;
    wire request,scandone,found;
    wire [31:0] lba,cluster,size;
    wire [8:0] images;
    reg [8:0] expected_images=9'h03f;
    reg [3:0] image_selection=0;
    wire [31:0] image_cluster,image_size;
    wire [7:0] error;
    reg [7:0] root0[0:511],root1[0:511];
    integer n,reads=0,pass_reads=0,k,expected_reads=4;
    reg [31:0] requested_lba;
    always #5 clk=~clk;
    fat32_volume_scanner #(.AUDIO_SELECT_ENABLE(1),.INDEXED_RESOURCES(1)) dut(
        .clk(clk),.rst_n(!rst),.scan_start(start),.scan_done(scandone),
        .fs_error(error),.resource_valid(images),.sector_req(request),.sector_lba(lba),
        .sector_busy(busy),.sector_valid(valid),.sector_byte(data),.sector_byte_index(index),
        .sector_done(done),.sector_error(8'd0),.audio_found(found),.audio_cluster(cluster),
        .audio_size(size),.audio_select(selection),.resource_index(image_selection),
        .resource_cluster(image_cluster),.resource_size(image_size));
    task entry;
        input integer bank,slot;
        input [87:0] name;
        input [7:0] attr;
        input [31:0] first_cluster,file_size;
        integer byte_number;
        reg [7:0] value;
        begin
            for(byte_number=0;byte_number<32;byte_number=byte_number+1) begin
                value=0;
                if(byte_number<11) value=name>>(8*(10-byte_number));
                else case(byte_number)
                    11:value=attr;
                    20:value=first_cluster[23:16];21:value=first_cluster[31:24];
                    26:value=first_cluster[7:0];27:value=first_cluster[15:8];
                    28:value=file_size[7:0];29:value=file_size[15:8];
                    30:value=file_size[23:16];31:value=file_size[31:24];
                endcase
                if(bank==0) root0[slot*32+byte_number]=value;
                else root1[slot*32+byte_number]=value;
            end
        end
    endtask
    task fixture;
        begin
            for(k=0;k<512;k=k+1) begin root0[k]=0;root1[k]=0;end
            // Deleted entries keep the first root cluster open for traversal.
            for(k=0;k<16;k=k+1) root0[k*32]=8'he5;
            entry(0,0,"PIC1    BMP",8'h20,10,78);
            entry(0,1,"PIC2    BMP",8'h20,11,78);
            entry(0,2,"PIC3    BMP",8'h20,12,78);
            entry(0,3,"PIC4    BMP",8'h20,13,78);
            entry(0,4,"PIC5    BMP",8'h20,14,78);
            entry(0,5,"PIC6    BMP",8'h20,15,78);
        end
    endtask
    function [7:0] disk;
        input [31:0] sector;input integer offset;
        begin
            disk=0;
            if(sector==0) case(offset)
                0:disk=8'heb;12:disk=2;13:disk=1;14:disk=32;16:disk=1;
                32:disk=8'ha0;33:disk=8'h86;34:disk=1;37:disk=2;44:disk=2;
                510:disk=8'h55;511:disk=8'haa;
            endcase
            else if(sector==32) begin
                disk=offset%4==3 ? 8'h0f : 8'hff;
                if(offset/4==2) disk=offset%4==0 ? 5 : 0;
            end else if(sector==544) disk=root0[offset];
            else if(sector==547) disk=root1[offset];
        end
    endfunction
    initial forever begin
        @(negedge clk);
        if(request) begin
            busy=1;reads=reads+1;requested_lba=lba;
            for(n=0;n<512;n=n+1) begin
                index=n;data=disk(requested_lba,n);valid=1;@(negedge clk);
                valid=0;@(negedge clk);
            end
            done=1;@(negedge clk);done=0;busy=0;
        end
    end
    task scan;
        begin
            pass_reads=reads;
            @(negedge clk);start=1;@(negedge clk);start=0;
            wait(scandone);repeat(3) @(negedge clk);
            if(error!==0 || images!==expected_images || reads-pass_reads!=expected_reads)
                $fatal(1,"fragmented root scan E%h images=%b reads=%0d",error,images,reads-pass_reads);
        end
    endtask
    task check;
        input [1:0] wanted;
        input expected_found;
        input [31:0] expected_cluster,expected_size;
        begin
            @(negedge clk);selection=wanted;repeat(3) @(negedge clk);
            if(found!==expected_found || cluster!==expected_cluster || size!==expected_size)
                $fatal(1,"catalog slot=%0d found=%b cluster=%0d size=%0d expected=%b/%0d/%0d",
                    wanted,found,cluster,size,expected_found,expected_cluster,expected_size);
        end
    endtask
    initial begin
        fixture;
        entry(0,6,"AUDIO   WAV",8'h20,20,1044);
        entry(0,7,"AUDIO2  WAV",8'h20,22,2044);
        entry(0,8,"AUDIO2  WAV",8'h20,99,9999); // First valid duplicate wins.
        entry(0,9,"AUDIO3  WAV",8'h20,23,3044);
        entry(1,0,"AUDIO1  WAV",8'h20,21,4044);
        entry(1,1,"AUDIO4  WAV",8'h20,24,5044);
        repeat(3) @(negedge clk);rst=0;scan;
        check(0,1,21,4044);check(1,1,22,2044);check(2,1,23,3044);check(3,1,24,5044);
        if(reads!=4) $fatal(1,"selection must use cached metadata without SD reads");

        // Reverse alias order: a later legacy name must not replace AUDIO1.
        fixture;
        entry(0,6,"AUDIO1  WAV",8'h20,31,6044);
        entry(0,7,"AUDIO2  WAV",8'h20,32,7044);
        entry(0,8,"AUDIO3  WAV",8'h20,33,8044);
        entry(1,0,"AUDIO   WAV",8'h20,30,9044);
        entry(1,1,"AUDIO4  WAV",8'h20,34,10044);
        scan;check(0,1,31,6044);check(1,1,32,7044);check(2,1,33,8044);check(3,1,34,10044);

        // Rescans must invalidate stale RAM entries, and reject malformed ones.
        fixture;
        entry(0,6,"AUDIO   WAV",8'h20,40,11044);
        entry(0,7,"AUDIO2  WAV",8'h20,42,12044);
        entry(0,8,"AUDIO3  WAV",8'h10,43,13044); // Directory attribute.
        entry(0,9,"AUDIO4  WAV",8'h20,1,14044);  // Invalid cluster.
        entry(0,10,"AUDIO4  WAV",8'h20,44,43);   // Too short for RIFF.
        entry(0,11,"AUDIO5  WAV",8'h20,45,15044);
        entry(0,12,"AUDIO3  WAV",8'h0f,43,13044); // Long-name attribute.
        scan;check(0,1,40,11044);check(1,1,42,12044);check(2,0,0,0);check(3,0,0,0);

        @(negedge clk);rst=1;repeat(2) @(negedge clk);
        if(found!==0 || cluster!==0 || size!==0) $fatal(1,"reset exposed stale descriptors");
        rst=0;fixture;entry(1,0,"AUDIO   WAV",8'h20,50,16044);
        scan;check(0,1,50,16044);check(1,0,0,0);check(2,0,0,0);check(3,0,0,0);

        // Six pictures plus every numbered audio track must not stop the scan
        // before PIC7..PIC9 in the next, noncontiguous root-directory cluster.
        fixture;
        entry(0,6,"AUDIO1  WAV",8'h20,61,1044);
        entry(0,7,"AUDIO2  WAV",8'h20,62,2044);
        entry(0,8,"AUDIO3  WAV",8'h20,63,3044);
        entry(0,9,"AUDIO4  WAV",8'h20,64,4044);
        entry(1,0,"PIC7    BMP",8'h20,16,78);
        entry(1,1,"PIC8    BMP",8'h20,17,78);
        entry(1,2,"PIC9    BMP",8'h20,18,78);
        expected_images=9'h1ff;scan;
        check(0,1,61,1044);check(1,1,62,2044);check(2,1,63,3044);check(3,1,64,4044);
        for(k=0;k<9;k=k+1) begin
            @(negedge clk);image_selection=k;repeat(2) @(negedge clk);
            if(image_cluster!==10+k || image_size!==78)
                $fatal(1,"image descriptor %0d is %0d/%0d",k,image_cluster,image_size);
        end

        // A complete nine-picture/four-audio catalog may still finish early.
        fixture;
        entry(0,6,"PIC7    BMP",8'h20,16,78);
        entry(0,7,"PIC8    BMP",8'h20,17,78);
        entry(0,8,"PIC9    BMP",8'h20,18,78);
        entry(0,9,"AUDIO1  WAV",8'h20,61,1044);
        entry(0,10,"AUDIO2  WAV",8'h20,62,2044);
        entry(0,11,"AUDIO3  WAV",8'h20,63,3044);
        entry(0,12,"AUDIO4  WAV",8'h20,64,4044);
        expected_reads=2;scan;
        check(0,1,61,1044);check(1,1,62,2044);check(2,1,63,3044);check(3,1,64,4044);
        $display("PASS audio catalog: four audio and nine image descriptors, fragmented root, no-read selection, AUDIO/AUDIO1 priority both orders, duplicate handling, invalid entries, rescan/reset, trailing PIC7-PIC9 with all audio present, complete-catalog early finish");
        $finish;
    end
    initial begin #2000000;$fatal(1,"audio catalog timeout");end
endmodule
