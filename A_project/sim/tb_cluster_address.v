`timescale 1ns/1ps

// Exercise the public sector interface using a 64-bit multiply reference.
// No internal state, shift count, or address-generation implementation is read.
module tb_cluster_address;
    reg clk=0,rst_n=0,start=0;
    reg [31:0] first_cluster=2,file_size=1,data_base=0;
    reg [31:0] fat_base=32'hfffff000,max_cluster=32'hffffffff;
    reg [7:0] spc=1;
    reg busy=0,valid=0,done=0;
    reg [7:0] data=0;
    reg [8:0] index=0;
    wire active,finished,file_valid,request;
    wire [7:0] file_byte,error;
    wire [31:0] offset,lba;
    wire [59:0] detail;
    integer received=0,requests=0,first_cases=0,chain_cases=0;
    integer k,n,reset_case;
    reg check_payload=0;
    reg [31:0] first_value,next_value,expected;
    always #5 clk=~clk;

    fat32_file_streamer dut(
        .clk(clk),.rst_n(rst_n),.file_start(start),.first_cluster(first_cluster),
        .file_size(file_size),.sectors_per_cluster(spc),.fat_start_lba(fat_base),
        .data_start_lba(data_base),.max_cluster(max_cluster),.file_busy(active),
        .file_done(finished),.file_valid(file_valid),.file_byte(file_byte),
        .file_byte_offset(offset),.fs_error(error),.sector_req(request),
        .sector_lba(lba),.sector_busy(busy),.sector_valid(valid),
        .sector_byte(data),.sector_byte_index(index),.sector_done(done),
        .sector_error(8'd0),.error_detail(detail));

    function [31:0] reference_lba;
        input [31:0] cluster,base;
        input [7:0] cluster_sectors;
        reg [63:0] wide_result;
        begin
            wide_result={32'd0,base}+
                ({32'd0,cluster}-64'd2)*{56'd0,cluster_sectors};
            reference_lba=wide_result[31:0];
        end
    endfunction

    always @(posedge clk) begin
        #1;
        if(rst_n && check_payload && file_valid) begin
            if(offset!==received || file_byte!==((received%512)^8'h5a)%256)
                $fatal(1,"payload/offset changed SPC=%0d offset=%0d expected=%0d byte=%h",
                       spc,offset,received,file_byte);
            received=received+1;
            if(received>file_size) $fatal(1,"extra payload beyond declared file size");
        end
    end

    task reset_reader;
        begin
            @(negedge clk);rst_n=0;start=0;busy=0;valid=0;done=0;check_payload=0;
            #1;
            if(request!==0 || active!==0 || file_valid!==0 || lba!==0)
                $fatal(1,"reset did not clear pending address/request");
            repeat(2) @(negedge clk);
            rst_n=1;
        end
    endtask

    task start_file;
        begin
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            if(active!==1) $fatal(1,"file busy did not assert at start");
        end
    endtask

    task wait_request;
        input [31:0] wanted_lba;
        integer waited;
        begin
            waited=0;
            while(request!==1 && waited<40) begin
                @(negedge clk);waited=waited+1;
            end
            if(request!==1) $fatal(1,"missing sector request SPC=%0d",spc);
            if(lba!==wanted_lba)
                $fatal(1,"address mismatch SPC=%0d first=%h base=%h got=%h expected=%h",
                       spc,first_cluster,data_base,lba,wanted_lba);
            if(error!==0 || active!==1) $fatal(1,"request issued with error or idle");
            requests=requests+1;
        end
    endtask

    task hold_backend;
        input [31:0] wanted_lba;
        integer cycles;
        begin
            busy=1;
            // Longer than maximum address preparation, without assuming its states.
            for(cycles=0;cycles<20;cycles=cycles+1) begin
                @(negedge clk);
                if(request!==0 || finished!==0 || active!==1)
                    $fatal(1,"request/finish escaped backend busy SPC=%0d",spc);
            end
            if(lba!==wanted_lba) $fatal(1,"prepared LBA wrong while backend busy");
            busy=0;
            wait_request(wanted_lba);
        end
    endtask

    task sector_response;
        input is_fat;
        input [31:0] cluster,following_cluster;
        integer byte_number;
        begin
            busy=1;valid=0;done=0;
            for(byte_number=0;byte_number<512;byte_number=byte_number+1) begin
                @(negedge clk);
                index=byte_number;valid=1;
                if(is_fat) begin
                    if(byte_number/4==cluster[6:0])
                        data=following_cluster>>(8*(byte_number%4));
                    else data=0;
                end else data=(byte_number^8'h5a)%256;
            end
            @(negedge clk);valid=0;done=1;
            @(negedge clk);done=0;busy=0;
        end
    endtask

    task check_first;
        input [7:0] cluster_sectors;
        input [31:0] cluster,base;
        begin
            reset_reader;
            spc=cluster_sectors;first_cluster=cluster;data_base=base;file_size=1;
            busy=1;start_file;
            hold_backend(reference_lba(cluster,base,cluster_sectors));
            first_cases=first_cases+1;
        end
    endtask

    task check_chain;
        input [7:0] cluster_sectors;
        input [31:0] cluster,following_cluster,base;
        integer sector_number,waited;
        reg [31:0] address;
        begin
            reset_reader;
            spc=cluster_sectors;first_cluster=cluster;data_base=base;
            file_size=512*cluster_sectors+1;received=0;check_payload=1;
            busy=1;start_file;
            address=reference_lba(cluster,base,cluster_sectors);
            hold_backend(address);
            for(sector_number=0;sector_number<cluster_sectors;sector_number=sector_number+1) begin
                if(sector_number!=0) wait_request(address+sector_number);
                sector_response(0,0,0);
            end
            // A real FAT sector supplies a noncontiguous next cluster.
            wait_request(fat_base+(cluster>>7));
            sector_response(1,cluster,following_cluster);
            hold_backend(reference_lba(following_cluster,base,cluster_sectors));
            sector_response(0,0,0);
            wait_request(fat_base+(following_cluster>>7));
            sector_response(1,following_cluster,32'hffffffff);
            waited=0;
            while(finished!==1 && waited<20) begin
                @(negedge clk);waited=waited+1;
            end
            if(finished!==1 || active!==0 || error!==0 || received!=file_size)
                $fatal(1,"fragmented chain completion mismatch SPC=%0d bytes=%0d/%0d E%h",
                       spc,received,file_size,error);
            check_payload=0;chain_cases=chain_cases+1;
        end
    endtask

    task check_invalid;
        input [7:0] invalid_spc;
        integer waited;
        begin
            reset_reader;
            spc=invalid_spc;first_cluster=32'd7;file_size=1;data_base=32'hffffffff;
            start_file;waited=0;
            while(finished!==1 && waited<20) begin
                if(request!==0) $fatal(1,"invalid SPC issued a sector request");
                @(negedge clk);waited=waited+1;
            end
            if(finished!==1 || error!==8'h24 || request!==0 || file_valid!==0 ||
               active!==0 || detail[59:28]!==first_cluster)
                $fatal(1,"invalid SPC=%0d not rejected as E24, error=%h",spc,error);
        end
    endtask

    initial begin
        for(k=0;k<8;k=k+1) begin
            check_first(1<<k,32'd2,32'hfffffffe);
            check_first(1<<k,32'h80000003,32'h89abcdef);
            check_first(1<<k,32'hfffffffe,32'hfffffff1);
            check_chain(1<<k,32'h001fffff,32'h0ffffff0,32'hfedcba98);
        end
        check_invalid(0);check_invalid(3);check_invalid(255);
        // Reset before offset calculation and early/middle/last shift clocks.
        for(reset_case=0;reset_case<4;reset_case=reset_case+1) begin
            reset_reader;
            spc=128;first_cluster=32'habcdef01;file_size=1;data_base=32'hffffffff;
            start_file;
            case(reset_case)
                0:n=0;1:n=1;2:n=4;default:n=8;
            endcase
            repeat(n) begin
                @(negedge clk);
                if(request!==0) $fatal(1,"request appeared before address ready");
            end
            rst_n=0;#1;
            if(request!==0 || active!==0 || lba!==0)
                $fatal(1,"reset during address preparation failed");
            repeat(2) @(negedge clk);rst_n=1;
            repeat(20) begin
                @(negedge clk);
                if(request!==0 || active!==0 || finished!==0)
                    $fatal(1,"reset preparation produced a stale transaction");
            end
            check_first(2,32'd129,32'hffffff00);
        end
        reset_reader;
        $display("PASS cluster address: %0d first-address cases, %0d fragmented chains, all SPC1..128, high-bit/32-bit wrap, busy gating, E24 invalid SPC, preparation resets; %0d requests",
                 first_cases,chain_cases,requests);
        $finish;
    end
    initial begin #10000000;$fatal(1,"cluster address timeout");end
endmodule
