`timescale 1ns/1ps
module tb_fat_edges;
    reg clk=0,rst_n=0,start=0;
    reg [31:0] first_cluster=127,file_size=0;
    reg [7:0] spc=1;
    wire active,finished,file_valid,request;
    wire [7:0] file_byte,error;
    wire [31:0] offset,lba;
    wire [59:0] detail;
    reg busy=0,valid=0,done=0;
    reg [7:0] data=0;
    reg [8:0] index=0;
    reg [31:0] current_lba;
    integer phase=0,received=0,mode=0,cycle=0,slot,expected_lba;
    always #10 clk=~clk;
    fat32_file_streamer dut(clk,rst_n,start,first_cluster,file_size,spc,
        32'd32,32'd4096,32'd100000,active,finished,file_valid,file_byte,offset,error,
        request,lba,busy,valid,data,index,done,8'd0,detail);
    function [31:0] cluster_at;
        input integer ordinal;
        case(ordinal)
            0:cluster_at=127;
            1:cluster_at=128;
            2:cluster_at=65537;
            default:cluster_at=130;
        endcase
    endfunction
    function [7:0] disk_byte;
        input [31:0] sector;
        input [8:0] byte_index;
        reg [31:0] cluster_number,value;
        begin
            if(sector<4096) begin
                cluster_number=(sector-32)*128+byte_index/4;
                case(cluster_number)
                    127:value=mode==1 ? 32'd0 : 32'hf0000080;
                    128:value=mode==2 ? 32'h000186a1 : 32'd65537;
                    65537:value=32'd130;
                    130:value=mode==3 ? 32'd1 : 32'hffffffff;
                    default:value=0;
                endcase
                disk_byte=value>>(byte_index[1:0]*8);
            end else disk_byte=sector[7:0]^byte_index[7:0];
        end
    endfunction
    always @(negedge clk) begin
        valid=0;done=0;cycle=cycle+1;
        if(!rst_n) begin phase=0;busy=0;end
        else case(phase)
            0:if(request && !busy) begin
                current_lba=lba;busy=1;index=0;phase=1;
            end
            1:if(cycle%7!=0) begin
                valid=1;data=disk_byte(current_lba,index);phase=2;
            end
            2:if(index==511) phase=3;else begin index=index+1'b1;phase=1;end
            3:begin done=1;busy=0;phase=4;end
            4:phase=0;
        endcase
    end
    always @(posedge clk) if(rst_n && file_valid) begin
        slot=received/(512*spc);
        expected_lba=4096+(cluster_at(slot)-2)*spc+(received/512)%spc;
        if(offset!==received || file_byte!==disk_byte(expected_lba,received%512))
            $fatal(1,"FAT byte mismatch SPC%0d offset%0d",spc,received);
        received=received+1;
    end
    task run_file;
        input [7:0] cluster_sectors;
        input integer fault;
        input [7:0] expected;
        begin
            spc=cluster_sectors;mode=fault;received=0;
            file_size=4*512*spc-37;
            @(negedge clk);start=1;@(negedge clk);start=0;
            wait(finished);@(negedge clk);
            if(error!==expected || (expected==0 && received!=file_size))
                $fatal(1,"FAT boundary E%h expected%h bytes%0d/%0d",error,expected,received,file_size);
            if(fault==1 && (detail[59:28]!=127 || detail[27:0]!=0))
                $fatal(1,"invalid-cluster diagnostic");
            if(fault==2 && (detail[59:28]!=128 ||
                {detail[1:0],detail[27:18],detail[17:2]}!=28'd100001))
                $fatal(1,"high-cluster diagnostic");
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        run_file(1,0,0);run_file(8,0,0);run_file(64,0,0);run_file(128,0,0);
        run_file(1,1,8'h24);run_file(1,0,0);
        run_file(1,2,8'h24);run_file(1,0,0);
        run_file(1,3,8'h24);run_file(1,0,0);
        $display("PASS FAT edges: clusters127/128/65537, SPC1/8/64/128, reserved nibble, restart, invalid chain detection/recovery");
        $finish;
    end
    initial begin #30000000;$fatal(1,"FAT edges timeout");end
endmodule
