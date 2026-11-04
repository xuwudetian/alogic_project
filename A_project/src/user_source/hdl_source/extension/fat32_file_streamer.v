`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error,
    output reg  [59:0] error_detail
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_CLUSTER_OFFSET = 4'd6;
    localparam ST_FINISH     = 4'd7;
    localparam ST_LBA_SHIFT  = 4'd8;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;
    reg [2:0] cluster_shift;
    wire [27:0] fat_cluster_value = {fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0};

    // FAT cluster sizes are powers of two, 1..128 sectors. Reuse sector_lba
    // as the offset accumulator for at most seven shift clocks, then add the
    // data base. Both first/next-cluster paths share this arithmetic; no wide
    // multiplier, barrel shifter, or additional 32-bit data register is needed.
    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case(value)
                2:spc_shift=1;4:spc_shift=2;8:spc_shift=3;16:spc_shift=4;
                32:spc_shift=5;64:spc_shift=6;128:spc_shift=7;
                default:spc_shift=0;
            endcase
        end
    endfunction

    assign file_busy = (state != ST_IDLE);

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            if(state==ST_IDLE)
                error_detail <= {first_cluster,first_cluster[25:16],first_cluster[15:0],first_cluster[27:26]};
            else
                error_detail <= {current_cluster,fat_cluster_value[25:16],fat_cluster_value[15:0],fat_cluster_value[27:26]};
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            state <= ST_CLUSTER_OFFSET;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
            cluster_shift <= 0;
            error_detail <= 0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;

            if (state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
            end

            if (state == ST_FAT_WAIT && sector_valid) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 1'b1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd3)
                    fat_byte3 <= sector_byte;
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    error_detail <= 0;
                    if (file_size == 0) begin
                        state <= ST_FINISH;
                    end else if (first_cluster < 2 || first_cluster > max_cluster ||
                                 sectors_per_cluster == 0 ||
                                 (sectors_per_cluster & (sectors_per_cluster-1'b1)) != 0) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        current_cluster <= first_cluster;
                        state <= ST_CLUSTER_OFFSET;
                    end
                end
                ST_CLUSTER_OFFSET: begin
                    sector_lba <= current_cluster - 32'd2;
                    cluster_shift <= spc_shift(sectors_per_cluster);
                    state <= ST_LBA_SHIFT;
                end
                ST_LBA_SHIFT: begin
                    if(cluster_shift!=0) begin
                        sector_lba <= {sector_lba[30:0],1'b0};
                        cluster_shift <= cluster_shift-1'b1;
                    end else begin
                        sector_lba <= data_start_lba + sector_lba;
                        state <= ST_DATA_REQ;
                    end
                end
                ST_DATA_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_bytes == 0 ||
                                 (remaining_bytes == 1 && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_DATA_REQ;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    next_cluster <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
                    if (final_chain_check) begin
                        final_chain_check <= 1'b0;
                        if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8)
                            state <= ST_FINISH;
                        else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster)
                            finish_with_error(ERR_CLUSTER_RANGE);
                        else
                            finish_with_error(ERR_FAT_LOOP);
                    end else if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else if (chain_count >= MAX_VISITED_CLUSTERS) begin
                        finish_with_error(ERR_VISITED_EXHAUSTED);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} == current_cluster) begin
                        finish_with_error(ERR_FAT_LOOP);
                    end else begin
                        advance_to_next_cluster({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0});
                    end
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
