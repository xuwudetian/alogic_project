`timescale 1ns/1ps

module fat32_volume_scanner #(parameter integer AUDIO_SELECT_ENABLE=0,
    parameter integer INDEXED_RESOURCES=0) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [8:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource6_cluster,
    output reg  [31:0] resource7_cluster,
    output reg  [31:0] resource8_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg  [31:0] resource6_size,
    output reg  [31:0] resource7_size,
    output reg  [31:0] resource8_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error,
    output reg audio_found,output reg [31:0] audio_cluster,output reg [31:0] audio_size,
    input wire [1:0] audio_select,
    input wire [3:0] resource_index,
    output wire [31:0] resource_cluster,output wire [31:0] resource_size
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;
    localparam ST_ROOT_FAT_REQ = 4'd12;
    localparam ST_ROOT_FAT_WAIT = 4'd13;
    localparam ST_ROOT_FAT_PARSE = 4'd14;

    reg [3:0] state;
    reg [7:0] sector_buffer [0:511];
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [7:0] root_sector_index;
    reg [8:0] root_chain_count;
    reg [31:0] root_next_cluster;
    reg directory_end;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg       dir_audio_match;
    reg [1:0] dir_audio_index;
    reg       dir_audio_numbered;
    reg [3:0] audio_present;
    reg       audio1_numbered;
    reg [3:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    reg dir_cluster_valid;
    // Cluster bytes finish at directory offset 27; the descriptor is used
    // at offset 31. Register the range test in those four available clocks.
    always @(posedge clk or negedge rst_n)
        if(!rst_n) dir_cluster_valid<=0;
        else dir_cluster_valid<={dir_cluster_high,dir_cluster_low}>=2 &&
            {dir_cluster_high,dir_cluster_low}<=max_cluster;
    // One indexed descriptor read avoids nine wide register banks and their
    // 9:1 mux in the player. Legacy individual outputs remain available for
    // standalone catalog users. Valid bits qualify the unreset RAM contents.
    generate if(INDEXED_RESOURCES!=0) begin: indexed_resources
        (* ram_style="dram" *) reg [63:0] descriptors[0:15];
        assign {resource_cluster,resource_size}=descriptors[resource_index];
        always @(posedge clk) begin
            if(rst_n && sector_valid && state==ST_ROOT_WAIT && !directory_end &&
               sector_byte_index[4:0]==31 && dir_entry_match &&
               dir_cluster_valid &&
               {sector_byte,dir_file_size[23:0]}>=54)
                descriptors[dir_resource_index]<={dir_cluster_high,dir_cluster_low,sector_byte,dir_file_size[23:0]};
        end
    end else begin: individual_resources
        assign resource_cluster=0;
        assign resource_size=0;
    end endgenerate
    // Four descriptors share a synchronous block-RAM port. A zero sentinel
    // supplies absent entries without 64 reset/data-mask LUTs. The small RAM
    // trades spare 9K blocks for scarce routing/slice capacity; no parallel
    // catalog registers or four-way 64-bit mux are needed. Validity resets
    // independently, so stale descriptors are never published as found.
    reg [63:0] audio_catalog [0:7] /* fehdl force_ram=1, ram_style="bram" */;
    wire [1:0] audio_lookup=AUDIO_SELECT_ENABLE!=0 ? audio_select : 2'd0;
    wire audio_entry_valid=dir_audio_match &&
        dir_cluster_valid &&
        {sector_byte,dir_file_size[23:0]}>=44;
    wire audio_entry_replace=!audio_present[dir_audio_index] ||
        (dir_audio_index==0 && dir_audio_numbered && !audio1_numbered);
    wire audio_catalog_write=sector_valid && state==ST_ROOT_WAIT && !directory_end &&
        sector_byte_index[4:0]==31 && audio_entry_valid && audio_entry_replace;
    wire [2:0] audio_write_address=audio_catalog_write ? {1'b0,dir_audio_index} : 3'd4;
    wire [63:0] audio_write_data=audio_catalog_write ?
        {{dir_cluster_high,dir_cluster_low},{sector_byte,dir_file_size[23:0]}} : 64'd0;

    assign scan_busy = (state != ST_IDLE);

    always @(posedge clk) begin
        audio_catalog[audio_write_address] <= audio_write_data;
        {audio_cluster,audio_size} <= audio_catalog[
            audio_present[audio_lookup] ? {1'b0,audio_lookup} : 3'd4];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) audio_found<=0;
        else audio_found<=audio_present[audio_lookup];
    end

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 9'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource6_cluster <= 32'd0;
            resource7_cluster <= 32'd0;
            resource8_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            resource6_size <= 32'd0;
            resource7_size <= 32'd0;
            resource8_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            root_sector_index <= 0;
            root_chain_count <= 0;
            root_next_cluster <= 0;
            directory_end <= 0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_audio_match<=0;dir_audio_index<=0;dir_audio_numbered<=0;
            audio_present<=0;audio1_numbered<=0;
            dir_resource_index <= 4'd0;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid && (state == ST_READ0_WAIT || state == ST_BOOT_WAIT))
                sector_buffer[sector_byte_index] <= sector_byte;

            if (sector_valid && state == ST_ROOT_FAT_WAIT) begin
                if (sector_byte_index[8:2] == root_cluster[6:0])
                    case (sector_byte_index[1:0])
                        0: root_next_cluster[7:0] <= sector_byte;
                        1: root_next_cluster[15:8] <= sector_byte;
                        2: root_next_cluster[23:16] <= sector_byte;
                        3: root_next_cluster[31:24] <= {4'd0,sector_byte[3:0]};
                    endcase
            end
            if (sector_valid && state == ST_ROOT_WAIT && !directory_end) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                        dir_audio_match <= 1'b0;
                        if (sector_byte == 0) directory_end <= 1'b1;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        dir_audio_match <= (sector_byte & 8'h18)==0 && sector_byte!=8'h0f &&
                            {dir_name0,dir_name1,dir_name2,dir_name3,dir_name4}=="AUDIO" &&
                            (dir_name5==" " || (dir_name5>="1" && dir_name5<="4")) &&
                            {dir_name6,dir_name7,dir_name8,dir_name9,dir_name10}=="  WAV";
                        dir_audio_index <= dir_name5==" " ? 2'd0 : dir_name5[1:0]-2'd1;
                        dir_audio_numbered <= dir_name5!=" ";
                        if ((sector_byte & 8'h18) == 0 && sector_byte != 8'h0f &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "9" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3 - "1";
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if(audio_entry_valid && audio_entry_replace) begin
                            audio_present[dir_audio_index]<=1;
                            if(dir_audio_index==0) audio1_numbered<=dir_audio_numbered;
                        end
                        if (dir_entry_match && dir_cluster_valid &&
                            {sector_byte,dir_file_size[23:0]} >= 54) begin
                            resource_valid[dir_resource_index]<=1'b1;
                            if(INDEXED_RESOURCES==0) begin
                            case (dir_resource_index)
                                4'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd3: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd4: begin
                                    resource4_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource4_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd5: begin
                                    resource5_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource5_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd6: begin
                                    resource6_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource6_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd7: begin
                                    resource7_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource7_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                4'd8: begin
                                    resource8_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource8_size <= {sector_byte, dir_file_size[23:0]};
                                end
                                default: begin end
                            endcase
                            end
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 9'd0;
                    audio_present<=0;audio1_numbered<=0;
                    root_sector_index <= 0;
                    root_chain_count <= 0;
                    directory_end <= 0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sector_buffer[450] == 8'h0b || sector_buffer[450] == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2 ||
                        (le16(40) & 16'h0080) != 0) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    if (total_sectors <= reserved_sectors + fat_span)
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    else state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    // AUDIO1 may follow legacy AUDIO in a later root sector.
                    // All nine pictures and all numbered audio slots are
                    // required before skipping later directory clusters.
                    if ((resource_valid == 9'h1ff && audio_present==4'hf && audio1_numbered) || directory_end) begin
                        if (resource_valid == 0)
                            finish_with_error(ERR_RESOURCE_MISSING);
                        else state <= ST_FINISH;
                    end else if (root_sector_index + 1 < sectors_per_cluster) begin
                        root_sector_index <= root_sector_index + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_ROOT_REQ;
                    end else begin
                        sector_lba <= fat_start_lba + (root_cluster >> 7);
                        state <= ST_ROOT_FAT_REQ;
                    end
                end
                ST_ROOT_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_ROOT_FAT_WAIT;
                end
                ST_ROOT_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0) finish_with_error(ERR_SECTOR);
                    else state <= ST_ROOT_FAT_PARSE;
                end
                ST_ROOT_FAT_PARSE: begin
                    if (root_next_cluster >= 32'h0ffffff8 && resource_valid != 0)
                        state <= ST_FINISH;
                    else if (root_next_cluster < 2 || root_next_cluster > max_cluster ||
                             root_next_cluster == root_cluster || root_chain_count == 255)
                        finish_with_error(ERR_RESOURCE_MISSING);
                    else begin
                        root_cluster <= root_next_cluster;
                        root_chain_count <= root_chain_count + 1'b1;
                        root_sector_index <= 0;
                        sector_lba <= data_start_lba + ((root_next_cluster-2) << sectors_per_cluster_shift);
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
