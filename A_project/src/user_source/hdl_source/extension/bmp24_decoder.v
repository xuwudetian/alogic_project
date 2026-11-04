`timescale 1ns/1ps

module promax_scale_line_buffer #(
    parameter integer DEPTH = 640,
    parameter integer ADDRESS_WIDTH = 10
) (
    input  wire                     clk,
    input  wire                     write_enable,
    input  wire [ADDRESS_WIDTH-1:0] write_address,
    input  wire [26:0]              write_data,
    input  wire                     read_enable,
    input  wire [ADDRESS_WIDTH-1:0] read_address,
    output reg  [26:0]              read_data
);
    reg [26:0] memory [0:DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;

    always @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule

module bmp24_decoder #(
    parameter integer EXPECTED_WIDTH = 640,
    parameter integer EXPECTED_HEIGHT = 480,
    parameter integer ALLOW_2X_SOURCE = 0,
    parameter integer GENERAL_SCALE = 0,
    parameter integer MODE_576 = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_end,
    input  wire [7:0]  upstream_error,
    output wire         header_accepted,
    output wire         pixel_valid,
    output wire  [23:0] pixel_rgb,
    output wire  [15:0] pixel_x,
    output wire  [15:0] pixel_y,
    output wire         frame_commit,
    output wire         bmp_done,
    output wire  [7:0]  bmp_error,
    output wire         top_down,
    output wire  [31:0] pixel_offset,
    output wire  [31:0] row_stride,
    output wire        source_scale_2x,
    output wire [59:0]  error_detail,
    input wire pixel_ready,output wire sector_room,
    output wire [31:0] source_resolution
);
    wire [15:0] original_width,original_height;
    assign source_resolution={original_width,original_height};
    generate if(GENERAL_SCALE!=0) begin: general_scale
        bmp_bilinear #(.WIDTH(EXPECTED_WIDTH),.HEIGHT(EXPECTED_HEIGHT),.MODE_576(MODE_576)) core(
        .clk(clk),.rst_n(rst_n),.file_start(file_start),.file_size(file_size),
        .file_valid(file_valid),.file_byte(file_byte),.file_byte_offset(file_byte_offset),
        .file_end(file_end),.upstream_error(upstream_error),.header_accepted(header_accepted),
        .pixel_valid(pixel_valid),.pixel_rgb(pixel_rgb),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .frame_commit(frame_commit),.bmp_done(bmp_done),.bmp_error(bmp_error),
        .top_down(top_down),.pixel_offset(pixel_offset),.row_stride(row_stride),.error_detail(error_detail),.pixel_ready(pixel_ready),.sector_room(sector_room),.scaled(source_scale_2x),
        .source_width(original_width),.source_height(original_height));
    end else begin: fixed_scale
        assign sector_room=1'b1;
        bmp24_fixed_decoder #(.EXPECTED_WIDTH(EXPECTED_WIDTH),.EXPECTED_HEIGHT(EXPECTED_HEIGHT),
            .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE)) core(
        .clk(clk),.rst_n(rst_n),.file_start(file_start),.file_size(file_size),
        .file_valid(file_valid),.file_byte(file_byte),.file_byte_offset(file_byte_offset),
        .file_end(file_end),.upstream_error(upstream_error),.header_accepted(header_accepted),
        .pixel_valid(pixel_valid),.pixel_rgb(pixel_rgb),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .frame_commit(frame_commit),.bmp_done(bmp_done),.bmp_error(bmp_error),
        .top_down(top_down),.pixel_offset(pixel_offset),.row_stride(row_stride),.error_detail(error_detail),.source_scale_2x(source_scale_2x),
        .original_width(original_width),.original_height(original_height));
    end endgenerate
endmodule

module bmp24_fixed_decoder #(
    parameter integer EXPECTED_WIDTH = 640,
    parameter integer EXPECTED_HEIGHT = 480,
    parameter integer ALLOW_2X_SOURCE = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_end,
    input  wire [7:0]  upstream_error,
    output reg         header_accepted,
    output reg         pixel_valid,
    output reg  [23:0] pixel_rgb,
    output reg  [15:0] pixel_x,
    output reg  [15:0] pixel_y,
    output reg         frame_commit,
    output reg         bmp_done,
    output reg  [7:0]  bmp_error,
    output reg         top_down,
    output reg  [31:0] pixel_offset,
    output reg  [31:0] row_stride,
    output wire        source_scale_2x,
    output reg [59:0]  error_detail,
    output wire [15:0] original_width,output wire [15:0] original_height
);
    localparam ERR_NONE        = 8'h00;
    localparam ERR_SIGNATURE   = 8'h31;
    localparam ERR_DIMENSIONS  = 8'h32;
    localparam ERR_PLANES      = 8'h33;
    localparam ERR_BPP         = 8'h34;
    localparam ERR_COMPRESSION = 8'h35;
    localparam ERR_OFFSET      = 8'h36;
    localparam ERR_TRUNCATED   = 8'h37;
    localparam ERR_UPSTREAM    = 8'h38;
    localparam integer BASE_ROW_STRIDE = ((EXPECTED_WIDTH * 3 + 3) / 4) * 4;
    localparam integer DOUBLE_ROW_STRIDE = ((EXPECTED_WIDTH * 6 + 3) / 4) * 4;
    localparam integer BASE_DATA_BYTES = BASE_ROW_STRIDE * EXPECTED_HEIGHT;
    localparam integer DOUBLE_DATA_BYTES = DOUBLE_ROW_STRIDE * EXPECTED_HEIGHT * 2;

    reg [7:0] header [0:53];
    reg decode_enabled;
    reg [31:0] byte_in_row;
    reg [31:0] physical_row;
    reg [31:0] pixels_received;
    reg [1:0] channel_phase;
    reg [7:0] blue_hold;
    reg [7:0] green_hold;
    reg [15:0] x_count;
    reg [31:0] source_width;
    reg [31:0] source_height;
    assign original_width=source_width[15:0];
    assign original_height=source_height[15:0];
    reg source_is_2x;
    reg [7:0] pair_red;
    reg [7:0] pair_green;
    reg [7:0] pair_blue;
    wire row_pair_write_enable;
    wire row_pair_read_enable;
    wire [9:0] row_pair_address;
    wire [26:0] row_pair_write_data;
    wire [26:0] row_pair_read_data;
    reg signature_ok_q;
    reg signed [31:0] parsed_height_q;
    reg [31:0] absolute_height_q;
    reg [31:0] parsed_width_q;
    reg [31:0] parsed_offset_q;
    reg [31:0] parsed_stride_q;
    reg [31:0] required_bytes_q;
    reg [31:0] required_end_q;
    reg [31:0] dib_size_q;
    reg [31:0] header_file_size_q;
    reg [15:0] planes_q;
    reg [15:0] bpp_q;
    reg [31:0] compression_q;
    reg end_pending;
    reg [7:0] end_error;
    reg [31:0] expected_offset;
    reg byte_gap;
    reg transaction_active;
    wire accept_byte=transaction_active && !file_start && !end_pending && file_valid;

    assign source_scale_2x = source_is_2x;
    assign row_pair_address = x_count[10:1];
    assign row_pair_write_data = {
        {1'b0, pair_red} + {1'b0, file_byte},
        {1'b0, pair_green} + {1'b0, green_hold},
        {1'b0, pair_blue} + {1'b0, blue_hold}
    };
    assign row_pair_write_enable = accept_byte && decode_enabled &&
                                   file_byte_offset >= pixel_offset &&
                                   physical_row < source_height &&
                                   byte_in_row < source_width * 3 &&
                                   channel_phase == 2'd2 && source_is_2x &&
                                   !physical_row[0] && x_count[0];
    assign row_pair_read_enable = accept_byte && decode_enabled &&
                                  file_byte_offset >= pixel_offset &&
                                  physical_row < source_height &&
                                  byte_in_row < source_width * 3 &&
                                  channel_phase == 2'd0 && source_is_2x &&
                                  physical_row[0] && !x_count[0];

    promax_scale_line_buffer #(
        .DEPTH(EXPECTED_WIDTH),
        .ADDRESS_WIDTH(10)
    ) u_scale_line_buffer (
        .clk(clk),
        .write_enable(row_pair_write_enable),
        .write_address(row_pair_address),
        .write_data(row_pair_write_data),
        .read_enable(row_pair_read_enable),
        .read_address(row_pair_address),
        .read_data(row_pair_read_data)
    );

    function [7:0] average_four;
        input [8:0] first_row_pair;
        input [7:0] second_row_first;
        input [7:0] second_row_second;
        reg [9:0] total;
        begin
            total = {1'b0, first_row_pair} +
                    {2'b00, second_row_first} +
                    {2'b00, second_row_second} + 10'd2;
            average_four = total[9:2];
        end
    endfunction

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {header[offset+1], header[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {header[offset+3], header[offset+2], header[offset+1], header[offset]};
        end
    endfunction

    task validate_header;
        begin
            if (!signature_ok_q) begin
                bmp_error <= ERR_SIGNATURE;
                decode_enabled <= 1'b0;
            end else if (!((parsed_width_q == EXPECTED_WIDTH &&
                            absolute_height_q == EXPECTED_HEIGHT) ||
                           (ALLOW_2X_SOURCE != 0 &&
                            parsed_width_q == EXPECTED_WIDTH*2 &&
                            absolute_height_q == EXPECTED_HEIGHT*2)) ||
                         dib_size_q < 40) begin
                bmp_error <= ERR_DIMENSIONS;
                decode_enabled <= 1'b0;
            end else if (planes_q != 1) begin
                bmp_error <= ERR_PLANES;
                decode_enabled <= 1'b0;
            end else if (bpp_q != 24) begin
                bmp_error <= ERR_BPP;
                decode_enabled <= 1'b0;
            end else if (compression_q != 0) begin
                bmp_error <= ERR_COMPRESSION;
                decode_enabled <= 1'b0;
            end else if (parsed_offset_q < 54 || parsed_offset_q >= file_size ||
                         parsed_offset_q < dib_size_q + 14 ||
                         required_end_q < parsed_offset_q) begin
                bmp_error <= ERR_OFFSET;
                decode_enabled <= 1'b0;
            end else if (required_end_q > file_size ||
                         header_file_size_q < required_end_q ||
                         header_file_size_q > file_size) begin
                bmp_error <= ERR_TRUNCATED;
                decode_enabled <= 1'b0;
                // L=所需完整文件字节数，N=1/2/3 分别为目录过短/头部过短/头部过长。
                error_detail <= {required_end_q,
                    (required_end_q>file_size ? 10'd1 : header_file_size_q<required_end_q ? 10'd2 : 10'd3),
                    file_size[15:0],2'd0};
            end else begin
                header_accepted <= 1'b1;
                decode_enabled <= 1'b1;
                top_down <= parsed_height_q[31];
                pixel_offset <= parsed_offset_q;
                row_stride <= parsed_stride_q;
                source_width <= parsed_width_q;
                source_height <= absolute_height_q;
                source_is_2x <= (parsed_width_q == EXPECTED_WIDTH*2);
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            header_accepted <= 1'b0;
            pixel_valid <= 1'b0;
            pixel_rgb <= 24'd0;
            pixel_x <= 16'd0;
            pixel_y <= 16'd0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;
            bmp_error <= ERR_NONE;
            top_down <= 1'b0;
            pixel_offset <= 32'd0;
            row_stride <= 32'd0;
            decode_enabled <= 1'b0;
            byte_in_row <= 32'd0;
            physical_row <= 32'd0;
            pixels_received <= 32'd0;
            channel_phase <= 2'd0;
            blue_hold <= 8'd0;
            green_hold <= 8'd0;
            x_count <= 16'd0;
            source_width <= EXPECTED_WIDTH;
            source_height <= EXPECTED_HEIGHT;
            source_is_2x <= 1'b0;
            pair_red <= 8'd0;
            pair_green <= 8'd0;
            pair_blue <= 8'd0;
            signature_ok_q <= 1'b0;
            parsed_height_q <= 32'sd0;
            absolute_height_q <= 32'd0;
            parsed_width_q <= 32'd0;
            parsed_offset_q <= 32'd0;
            parsed_stride_q <= 32'd0;
            required_bytes_q <= 32'd0;
            required_end_q <= 32'd0;
            dib_size_q <= 32'd0;
            header_file_size_q <= 32'd0;
            planes_q <= 16'd0;
            bpp_q <= 16'd0;
            compression_q <= 32'd0;
            end_pending<=0;end_error<=0;expected_offset<=0;byte_gap<=0;error_detail<=0;
            transaction_active<=0;
        end else begin
            pixel_valid <= 1'b0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;
            // 只结算已启动的事务；空闲和重复 EOF 不得产生新的完成/错误。
            end_pending<=file_end && transaction_active && !end_pending;
            if(file_end && transaction_active && !end_pending) end_error<=upstream_error;
            if(accept_byte) begin
                expected_offset<=file_byte_offset+1'b1;
                if(file_byte_offset!=expected_offset) byte_gap<=1;
            end

            if (file_start) begin
                transaction_active <= 1'b1;
                header_accepted <= 1'b0;
                bmp_error <= ERR_NONE;
                top_down <= 1'b0;
                pixel_offset <= 32'd0;
                row_stride <= 32'd0;
                decode_enabled <= 1'b0;
                byte_in_row <= 32'd0;
                physical_row <= 32'd0;
                pixels_received <= 32'd0;
                channel_phase <= 2'd0;
                x_count <= 16'd0;
                source_width <= EXPECTED_WIDTH;
                source_height <= EXPECTED_HEIGHT;
                source_is_2x <= 1'b0;
                pair_red <= 8'd0;
                pair_green <= 8'd0;
                pair_blue <= 8'd0;
                signature_ok_q <= 1'b0;
                parsed_height_q <= 32'sd0;
                absolute_height_q <= 32'd0;
                parsed_width_q <= 32'd0;
                parsed_offset_q <= 32'd0;
                parsed_stride_q <= 32'd0;
                required_bytes_q <= 32'd0;
                required_end_q <= 32'd0;
                dib_size_q <= 32'd0;
                header_file_size_q <= 32'd0;
                planes_q <= 16'd0;
                bpp_q <= 16'd0;
                compression_q <= 32'd0;
                end_pending<=0;end_error<=0;expected_offset<=0;byte_gap<=0;error_detail<=0;
            end

            if (accept_byte && file_byte_offset < 54)
                header[file_byte_offset] <= file_byte;

            if (accept_byte && file_byte_offset == 2)
                signature_ok_q <= (header[0] == "B" && header[1] == "M");

            if (accept_byte && file_byte_offset == 40) begin
                parsed_height_q <= le32(22);
                parsed_width_q <= le32(18);
                parsed_offset_q <= le32(10);
                dib_size_q <= le32(14);
                header_file_size_q <= le32(2);
                planes_q <= le16(26);
                bpp_q <= le16(28);
                compression_q <= le32(30);
            end

            if (accept_byte && file_byte_offset == 41) begin
                absolute_height_q <= parsed_height_q[31] ?
                                     (~parsed_height_q + 1'b1) : parsed_height_q;
                if (parsed_width_q == EXPECTED_WIDTH) begin
                    parsed_stride_q <= BASE_ROW_STRIDE;
                    required_bytes_q <= BASE_DATA_BYTES;
                end else begin
                    parsed_stride_q <= DOUBLE_ROW_STRIDE;
                    required_bytes_q <= DOUBLE_DATA_BYTES;
                end
            end

            if (accept_byte && file_byte_offset == 42)
                required_end_q <= parsed_offset_q + required_bytes_q;

            if (accept_byte && file_byte_offset == 52)
                validate_header();

            if (accept_byte && decode_enabled && file_byte_offset >= pixel_offset &&
                physical_row < source_height) begin
                if (byte_in_row < source_width * 3) begin
                    case (channel_phase)
                        2'd0: begin
                            blue_hold <= file_byte;
                            channel_phase <= 2'd1;
                        end
                        2'd1: begin
                            green_hold <= file_byte;
                            channel_phase <= 2'd2;
                        end
                        default: begin
                            if (!source_is_2x) begin
                                pixel_valid <= 1'b1;
                                pixel_rgb <= {file_byte, green_hold, blue_hold};
                                pixel_x <= x_count;
                                if (top_down)
                                    pixel_y <= physical_row[15:0];
                                else
                                    pixel_y <= EXPECTED_HEIGHT - 1 - physical_row[15:0];
                                pixels_received <= pixels_received + 1'b1;
                            end else if (!x_count[0]) begin
                                pair_red <= file_byte;
                                pair_green <= green_hold;
                                pair_blue <= blue_hold;
                            end else if (physical_row[0]) begin
                                pixel_valid <= 1'b1;
                                pixel_rgb <= {
                                    average_four(row_pair_read_data[26:18], pair_red, file_byte),
                                    average_four(row_pair_read_data[17:9], pair_green, green_hold),
                                    average_four(row_pair_read_data[8:0], pair_blue, blue_hold)
                                };
                                pixel_x <= x_count >> 1;
                                if (top_down)
                                    pixel_y <= physical_row[15:1];
                                else
                                    pixel_y <= EXPECTED_HEIGHT - 1 - physical_row[15:1];
                                pixels_received <= pixels_received + 1'b1;
                            end
                            x_count <= x_count + 1'b1;
                            channel_phase <= 2'd0;
                        end
                    endcase
                end

                if (byte_in_row == row_stride - 1'b1) begin
                    byte_in_row <= 32'd0;
                    physical_row <= physical_row + 1'b1;
                    channel_phase <= 2'd0;
                    x_count <= 16'd0;
                end else begin
                    byte_in_row <= byte_in_row + 1'b1;
                end
            end

            // 延后一拍结算：file_end 与最后一个有效字节同拍时，先让最后像素和计数入账。
            // 不能用少一个像素的旧计数误判 E37，也不能接受重复/跳号字节凑出的像素数。
            if (end_pending && transaction_active && !file_start) begin
                transaction_active <= 1'b0;
                bmp_done <= 1'b1;
                decode_enabled <= 1'b0;
                if (end_error != 0) begin
                    bmp_error <= ERR_UPSTREAM;
                end else if (bmp_error == ERR_NONE && header_accepted &&
                             !byte_gap && expected_offset==file_size &&
                             pixels_received == EXPECTED_WIDTH * EXPECTED_HEIGHT) begin
                    frame_commit <= 1'b1;
                end else if (bmp_error == ERR_NONE) begin
                    bmp_error <= ERR_TRUNCATED;
                    // L=实际输出像素数，N=4 像素不全/5 字节跳号/6 总字节不足/7 未接受头部。
                    error_detail <= {pixels_received,
                        (!header_accepted ? 10'd7 : byte_gap ? 10'd5 : expected_offset!=file_size ? 10'd6 : 10'd4),
                        expected_offset[15:0],2'd0};
                end
            end
        end
    end
endmodule
