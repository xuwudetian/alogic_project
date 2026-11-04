`timescale 1ns/1ps
module tb_fat;
    reg clk=0,rst_n=0,scan_start=0,file_start=0;
    wire scan_busy,scan_done,file_busy,file_done,file_valid;
    wire [7:0] scan_error,file_error,file_byte,spc;
    wire [31:0] partition,fat,data_start,max_cluster,c0,c1,c2,c3,s0,s1,s2,s3,file_offset;
    wire [5:0] resources;
    wire sr,fr;
    wire [31:0] sl,fl;
    reg busy=0,valid=0,done=0;
    reg [7:0] byte_data=0;
    reg [8:0] index=0;
    reg [31:0] current_lba;
    reg scanning=1;
    integer phase=0,nbytes=0,mode=0,requests=0;
    wire request=scanning ? sr : fr;
    wire [31:0] lba=scanning ? sl : fl;
    always #5 clk=~clk;
    fat32_volume_scanner scanner(clk,rst_n,scan_start,scan_busy,scan_done,scan_error,
        partition,spc,fat,data_start,max_cluster,resources,c0,c1,c2,c3,,,s0,s1,s2,s3,,,
        sr,sl,busy,valid && scanning,byte_data,index,done && scanning,8'd0,,,,2'd0);
    fat32_file_streamer streamer(clk,rst_n,file_start,c1,s1,spc,fat,data_start,max_cluster,
        file_busy,file_done,file_valid,file_byte,file_offset,file_error,
        fr,fl,busy,valid && !scanning,byte_data,index,done && !scanning,8'd0,);
    function [7:0] disk_byte;
        input [31:0] sector;
        input [8:0] offset;
        reg [31:0] value;
        begin
            disk_byte=0;
            if(sector==0) begin
                case(offset)
                    0:disk_byte=8'heb;
                    11:disk_byte=0;12:disk_byte=2;13:disk_byte=2;14:disk_byte=32;
                    16:disk_byte=1;
                    32:disk_byte=8'ha0;33:disk_byte=8'h86;34:disk_byte=1; // 100000 sectors
                    36:disk_byte=0;37:disk_byte=2; // FAT: 512 sectors
                    44:disk_byte=2;
                    510:disk_byte=8'h55;511:disk_byte=8'haa;
                endcase
            end else if(sector==32) begin
                value=32'h0fffffff;
                case(offset[8:2])
                    2:value=9; // root directory is fragmented too
                    4:value=mode==1 ? 32'h0fffffff : mode==2 ? 4 : 6;
                    6:value=32'h0fffffff;
                    9:value=32'h0fffffff;
                endcase
                disk_byte=value>>(8*offset[1:0]);
            end else if(sector==544 || sector==545) begin
                disk_byte=offset[4:0]==0 ? 8'he5 : 0;
            end else if(sector==558) begin
                case(offset)
                    0:disk_byte="P";1:disk_byte="I";2:disk_byte="C";3:disk_byte="2";
                    4,5,6,7:disk_byte=" ";
                    8:disk_byte="B";9:disk_byte="M";10:disk_byte="P";
                    11:disk_byte=8'h21; // archive + read-only is still a regular file
                    26:disk_byte=4;
                    28:disk_byte=8'hd0;29:disk_byte=7; // 2000 bytes
                endcase
            end else disk_byte=sector[7:0]^offset[7:0];
        end
    endfunction
    always @(negedge clk) begin
        valid=0;done=0;
        if(!rst_n) begin phase=0;busy=0;end
        else case(phase)
            0:if(request && !busy) begin
                current_lba=lba;busy=1;index=0;phase=1;requests=requests+1;
            end
            1:begin
                valid=1;byte_data=disk_byte(current_lba,index);phase=2;
            end
            2:if(index==511) phase=3;else begin index=index+1'b1;phase=1;end
            3:begin done=1;busy=0;phase=4;end
            4:phase=0;
        endcase
    end
    always @(posedge clk) begin
        #1;
        if(file_valid) begin
            if(file_offset!=nbytes) $fatal(1,"file offset");
            if(mode==0) begin
                if(file_byte!==disk_byte(nbytes<1024 ? 548+nbytes/512 : 552+(nbytes-1024)/512,nbytes%512))
                    $fatal(1,"fragment data");
            end
            nbytes=nbytes+1;
        end
    end
    task run_file;
        input integer m,expected;
        begin
            mode=m;nbytes=0;
            @(negedge clk);file_start=1;@(negedge clk);file_start=0;
            wait(file_done);#2;
            if(file_error!=expected) $fatal(1,"FAT error %h expected %h",file_error,expected);
            if(m==0 && nbytes!=2000) $fatal(1,"file length");
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        @(negedge clk);scan_start=1;@(negedge clk);scan_start=0;
        wait(scan_done);#2;
        if(scan_error!=0 || resources!=2 || c1!=4 || s1!=2000 || data_start!=544)
            $fatal(1,"root chain scan %h %h %d",scan_error,resources,c1);
        scanning=0;repeat(5) @(negedge clk);
        run_file(0,0);run_file(1,8'h25);run_file(2,8'h23);
        $display("PASS FAT32: multi-sector fragmented root, sparse PIC2, attributes, fragmented file, EOF/loop errors");
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAT timeout");end
endmodule
