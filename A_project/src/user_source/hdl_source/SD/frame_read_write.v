`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
    parameter SLIDE_ENABLE           = 0,
    parameter ZOOM_ENABLE            = 0,
    parameter EXPLICIT_ZOOM          = 0
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
    input[ADDR_BITS - 1:0]           read_addr_4,
    input[ADDR_BITS - 1:0]           read_addr_5,
    input[ADDR_BITS - 1:0]           read_addr_6,
    input[ADDR_BITS - 1:0]           read_addr_7,
    input[ADDR_BITS - 1:0]           read_addr_8,
	input[3:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
    input[ADDR_BITS - 1:0]           write_addr_4,
    input[ADDR_BITS - 1:0]           write_addr_5,
    input[ADDR_BITS - 1:0]           write_addr_6,
    input[ADDR_BITS - 1:0]           write_addr_7,
    input[ADDR_BITS - 1:0]           write_addr_8,
	input[3:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data,
    input                           write_v_flip,
    output reg                      write_overflow,
    output reg                      read_underflow,
    output                          write_ready,
    input                           slide_active,
    input [19:0]                    slide_offset,
    input [3:0]                     slide_bank,
    input                           zoom_active,
    input [7:0]                     zoom_size,
    input [10:0]                     zoom_left,
    input [10:0]                     zoom_top,
    input [10:0]                     zoom_width,zoom_height

);
wire[8:0] wrusedw;
wire[8:0] rdusedw;
wire[8:0] write_used;
wire write_full,read_empty;
wire packed_write_enable,packed_read_enable,read_fifo_empty;
wire write_fifo_empty,write_fifo_pop;
wire [9:0] write_available;
wire [31:0] packed_write_data,packed_read_data;
wire write_fifo_aclr,read_fifo_aclr;
wire write_reset = write_fifo_aclr | rst;
// rst/fifo clear originate in mem_clk. Assert immediately, but release the
// pixel-side registers only after three read-clock edges. FIFO pointer logic
// has its own synchronizers; the unpacker must obey the same reset contract.
(* async_reg="true" *) reg [2:0] read_reset_sync,unpack_reset_sync;
wire read_clear_async=read_fifo_aclr | rst;
wire read_reset=read_reset_sync[2];
wire unpack_reset=unpack_reset_sync[2];
always @(posedge read_clk or posedge rst)
    if(rst) read_reset_sync<=3'b111;
    else read_reset_sync<={read_reset_sync[1:0],1'b0};
always @(posedge read_clk or posedge read_clear_async)
    if(read_clear_async) unpack_reset_sync<=3'b111;
    else unpack_reset_sync<={unpack_reset_sync[1:0],1'b0};
wire zoom_latch;
wire [7:0] zoom_size_latch;
wire [10:0] zoom_width_latch,zoom_height_latch;
wire [31:0] filtered_read_data;
wire filtered_read_enable;
wire pixel_read_enable;
generate if(ZOOM_ENABLE!=0 && (READ_DATA_BITS==24 || READ_DATA_BITS==16 || READ_DATA_BITS==8)) begin: zoom_reader
    reg [10:0] display_x;
    reg [9:0] display_y;
    reg previous_read;
    wire [10:0] local_x=display_x-zoom_left;
    wire [10:0] local_y=display_y-zoom_top;
    wire [10:0] width=EXPLICIT_ZOOM!=0 ? zoom_width : {zoom_size,2'b00};
    wire [10:0] height=EXPLICIT_ZOOM!=0 ? zoom_height : {zoom_size,1'b0}+zoom_size;
    assign pixel_read_enable=read_en && (!zoom_active || (local_x<width && local_y<height));
    always @(posedge read_clk or posedge read_reset) begin
        if(read_reset) begin display_x<=0;display_y<=0;previous_read<=0;end
        else begin
            previous_read<=read_en;
            if(read_req) begin display_x<=0;display_y<=0;previous_read<=0;end
            else begin
                if(read_en) display_x<=display_x+1'b1;else display_x<=0;
                if(previous_read && !read_en) display_y<=display_y+1'b1;
            end
        end
    end
    if(READ_DATA_BITS==8) begin: rgb332
    frame_zoom_filter_rgb332 #(.SOURCE_WIDTH(FRAME_WIDTH)) filter(.clk(mem_clk),.rst(rst || read_fifo_aclr),
        .enable(zoom_latch),.target_width(zoom_width_latch),.valid(Sdr_rd_en),.data(Sdr_rd_dout),
        .out_valid(filtered_read_enable),.out_data(filtered_read_data));
    end else if(READ_DATA_BITS==16) begin: rgb565
    frame_zoom_filter_rgb565 #(.SOURCE_WIDTH(FRAME_WIDTH),.EXPLICIT_ZOOM(EXPLICIT_ZOOM)) filter(.clk(mem_clk),.rst(rst || read_fifo_aclr),
        .enable(zoom_latch),.size(zoom_size_latch),.target_width(zoom_width_latch),.valid(Sdr_rd_en),.data(Sdr_rd_dout),
        .out_valid(filtered_read_enable),.out_data(filtered_read_data));
    end else begin: rgb888
    frame_zoom_filter #(.SOURCE_WIDTH(FRAME_WIDTH),.EXPLICIT_ZOOM(EXPLICIT_ZOOM)) filter(.clk(mem_clk),.rst(rst || read_fifo_aclr),
        .enable(zoom_latch),.size(zoom_size_latch),.target_width(zoom_width_latch),.valid(Sdr_rd_en),.data(Sdr_rd_dout),
        .out_valid(filtered_read_enable),.out_data(filtered_read_data));
    end
end else begin: no_zoom_reader
    assign pixel_read_enable=read_en;
    assign filtered_read_enable=Sdr_rd_en;
    assign filtered_read_data=Sdr_rd_dout;
end endgenerate
// SDRAM addresses/lengths count 32-bit words; the active video ports carry
// RGB888 or RGB565 pixels, tightly packed without unused SDRAM byte lanes.
generate if(WRITE_DATA_BITS==24) begin: pack_rgb888
    reg [1:0] phase;
    reg [23:0] tail;
    assign packed_write_enable=write_en && phase!=0;
    assign packed_write_data=phase==1 ? {tail,write_data[23:16]} :
                             phase==2 ? {tail[15:0],write_data[23:8]} :
                                        {tail[7:0],write_data[23:0]};
    always @(posedge write_clk or posedge write_reset) begin
        if(write_reset) begin phase<=0;tail<=0;end
        else if(write_en && !write_full) begin phase<=phase+1'b1;tail<=write_data;end
    end
end else if(WRITE_DATA_BITS==16) begin: pack_rgb565
    reg phase;
    reg [15:0] first_pixel;
    assign packed_write_enable=write_en && phase;
    assign packed_write_data={first_pixel,write_data};
    always @(posedge write_clk or posedge write_reset) begin
        if(write_reset) begin phase<=0;first_pixel<=0;end
        else if(write_en && !write_full) begin phase<=!phase;first_pixel<=write_data;end
    end
end else if(WRITE_DATA_BITS==8) begin: pack_rgb332
    reg [1:0] phase;
    reg [23:0] tail;
    assign packed_write_enable=write_en && phase==3;
    assign packed_write_data={tail,write_data};
    always @(posedge write_clk or posedge write_reset) begin
        if(write_reset) begin phase<=0;tail<=0;end
        else if(write_en && !write_full) begin phase<=phase+1'b1;tail<={tail[15:0],write_data};end
    end
end else begin: write_word_compatibility
    assign packed_write_enable=write_en;
    assign packed_write_data=write_data;
end endgenerate

// Use the normal FIFO output as an explicit prefetched word in packed mode.
// App_wr_en consumes that word while a simultaneous FIFO read replaces it.
generate if(WRITE_DATA_BITS==24 || WRITE_DATA_BITS==16 || WRITE_DATA_BITS==8) begin: write_prefetch
    reg valid;
    assign write_fifo_pop=!write_fifo_empty && (!valid || App_wr_en);
    assign write_available={1'b0,rdusedw}+valid;
    always @(posedge mem_clk or posedge write_reset)
        if(write_reset) valid<=0;
        else if(write_fifo_pop) valid<=1;
        else if(App_wr_en) valid<=0;
end else begin: write_fifo_compatibility
    assign write_fifo_pop=App_wr_en;
    assign write_available={1'b0,rdusedw};
end endgenerate

generate if(READ_DATA_BITS==24) begin: unpack_rgb888
    reg [1:0] phase;
    reg [23:0] tail,pixel;
    reg word_valid;
    wire consume_word=pixel_read_enable && phase!=3 && word_valid;
    assign packed_read_enable=!unpack_reset && !read_fifo_empty && (!word_valid || consume_word);
    assign read_empty=phase!=3 && !word_valid;
    assign read_data=pixel;
    // Normal-read/NOREG loads the FIFO output on the request edge. Track this
    // slot explicitly across blanking and phase 3 (which uses only tail).
    // The read_en -> pixel delay remains one clock, as video_delay requires.
    always @(posedge read_clk or posedge unpack_reset)
        if(unpack_reset) word_valid<=0;
        else if(packed_read_enable) word_valid<=1;
        else if(consume_word) word_valid<=0;
    always @(posedge read_clk or posedge unpack_reset) begin
        if(unpack_reset) begin phase<=0;tail<=0;pixel<=0;end
        else if(pixel_read_enable && !read_empty) begin
            case(phase)
                0: pixel<=packed_read_data[31:8];
                1: pixel<={tail[7:0],packed_read_data[31:16]};
                2: pixel<={tail[15:0],packed_read_data[31:24]};
                3: pixel<=tail;
            endcase
            if(phase!=3) tail<=packed_read_data[23:0];
            phase<=phase+1'b1;
        end
    end
end else if(READ_DATA_BITS==16) begin: unpack_rgb565
    reg phase,word_valid;
    reg [15:0] tail,pixel;
    wire consume_word=pixel_read_enable && !phase && word_valid;
    assign packed_read_enable=!unpack_reset && !read_fifo_empty && (!word_valid || consume_word);
    assign read_empty=!phase && !word_valid;
    assign read_data=pixel;
    always @(posedge read_clk or posedge unpack_reset) begin
        if(unpack_reset) begin phase<=0;word_valid<=0;tail<=0;pixel<=0;end
        else begin
            if(packed_read_enable) word_valid<=1;
            else if(consume_word) word_valid<=0;
            if(pixel_read_enable && !read_empty) begin
                pixel<=phase ? tail : packed_read_data[31:16];
                if(!phase) tail<=packed_read_data[15:0];
                phase<=!phase;
            end
        end
    end
end else if(READ_DATA_BITS==8) begin: unpack_rgb332
    reg [1:0] phase;
    reg word_valid;
    reg [23:0] tail;
    reg [7:0] pixel;
    wire consume_word=pixel_read_enable && phase==0 && word_valid;
    assign packed_read_enable=!unpack_reset && !read_fifo_empty && (!word_valid || consume_word);
    assign read_empty=phase==0 && !word_valid;
    assign read_data=pixel;
    always @(posedge read_clk or posedge unpack_reset) begin
        if(unpack_reset) begin phase<=0;word_valid<=0;tail<=0;pixel<=0;end
        else begin
            if(packed_read_enable) word_valid<=1;
            else if(consume_word) word_valid<=0;
            if(pixel_read_enable && !read_empty) begin
                pixel<=phase==0 ? packed_read_data[31:24] : tail[23:16];
                tail<=phase==0 ? packed_read_data[23:0] : {tail[15:0],8'd0};
                phase<=phase+1'b1;
            end
        end
    end
end else begin: read_word_compatibility
    assign packed_read_enable=pixel_read_enable;
    assign read_empty=read_fifo_empty;
    assign read_data=packed_read_data;
end endgenerate
reg [3:0] write_reset_release;
always @(posedge write_clk or posedge write_reset)
    if(write_reset) write_reset_release<=0;
    else write_reset_release<={write_reset_release[2:0],1'b1};
assign write_ready = write_reset_release[3] && !write_req &&
                     !write_full && write_used < 9'd480;
always @(posedge write_clk or posedge rst)
    if(rst) write_overflow<=0;
    else if(write_req) write_overflow<=0;
    else if(write_en && write_full) write_overflow<=1;
always @(posedge read_clk or posedge read_reset)
    if(read_reset) read_underflow<=0;
    else if(read_req) read_underflow<=0;
    else if(pixel_read_enable && read_empty) read_underflow<=1;

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire O_wr_busy;
wire O_rd_busy;
wire read_active;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
// Reserve at least 256 displayed pixels before granting a 128-word write.
assign App_rd_busy = O_rd_busy || (read_active && wrusedw < 256);
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 #(.SHOW_AHEAD_EN(WRITE_DATA_BITS!=24 && WRITE_DATA_BITS!=16 && WRITE_DATA_BITS!=8)) write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr | rst    ),
	.we                      	(packed_write_enable                 ),          // Write Request
	.re                      	(write_fifo_pop        		  ),          // Read Request
	.di                       	(packed_write_data               ),          // Input Data
	.empty_flag                 (write_fifo_empty),          // Read side Empty flag
	.full_flag                  (write_full               ),
	.wrusedw                	(write_used               ),
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH*WRITE_DATA_BITS/32),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
    .write_addr_4                 (write_addr_4),
    .write_addr_5                 (write_addr_5),
    .write_addr_6                 (write_addr_6),
    .write_addr_7                 (write_addr_7),
    .write_addr_8                 (write_addr_8),
	.write_addr_index           (write_addr_index         ),    
    .write_v_flip               (write_v_flip),
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(write_available           )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 #(.SHOW_AHEAD_EN(1'b0)) read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr | rst       ),
	.we                     	(ZOOM_ENABLE!=0 && zoom_latch ? filtered_read_enable : Sdr_rd_en),
	.re                     	(packed_read_enable                    ),          // Read Request
	.di                      	(ZOOM_ENABLE!=0 && zoom_latch ? filtered_read_data : Sdr_rd_dout),
	.empty_flag					(read_fifo_empty                 ),
	.full_flag					(                           ),          // Write side Full flag
	.wrusedw                	(wrusedw         	  	  		 ),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(packed_read_data                  )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
    .SLIDE_ENABLE               (SLIDE_ENABLE             ),
    .FRAME_WORDS                (FRAME_WIDTH*FRAME_HEIGHT*READ_DATA_BITS/32),
    .ROW_WORDS                  (FRAME_WIDTH*READ_DATA_BITS/32),
    .ZOOM_ENABLE                (ZOOM_ENABLE),
    .FRAME_HEIGHT               (FRAME_HEIGHT),
    .EXPLICIT_ZOOM              (EXPLICIT_ZOOM)
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(Sdr_rd_en),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
    .read_active                (read_active),
	
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
	.read_req                   (read_req                 ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
    .read_addr_4                 (read_addr_4),
    .read_addr_5                 (read_addr_5),
    .read_addr_6                 (read_addr_6),
    .read_addr_7                 (read_addr_7),
    .read_addr_8                 (read_addr_8),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
    .slide_active               (slide_active),
    .slide_offset               (READ_DATA_BITS==8 ? (slide_offset>>2) : READ_DATA_BITS==16 ? (slide_offset>>1) :
                                 READ_DATA_BITS==24 ? ((slide_offset>>2)+(slide_offset>>1)) : slide_offset),
    .slide_bank                 (slide_bank),
    .zoom_active                (zoom_active),.zoom_size(zoom_size),
    .zoom_width(zoom_width),.zoom_height(zoom_height),
    .zoom_width_latch(zoom_width_latch),.zoom_height_latch(zoom_height_latch),
    .zoom_latch                 (zoom_latch),.zoom_size_latch(zoom_size_latch),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	({1'b0,wrusedw}           )
);

endmodule

// Four tightly packed RGB332 source pixels per SDRAM word. The selected
// width is a multiple of four, so each row ends with an empty reservoir.
module frame_zoom_filter_rgb332 #(parameter SOURCE_WIDTH=1024)(
    input clk,input rst,input enable,input [10:0] target_width,
    input valid,input [31:0] data,
    output reg out_valid,output reg [31:0] out_data
);
    reg [10:0] source_x,error;
    reg [23:0] tail;
    reg [1:0] held;
    reg [55:0] queue_next;
    reg [2:0] count_next;
    reg [10:0] error_next;
    reg [11:0] sum;
    integer k;
    always @* begin
        queue_next={32'd0,tail};count_next={1'b0,held};error_next=error;sum=0;
        for(k=0;k<4;k=k+1) begin
            if(valid) begin
                sum=(source_x==0 && k==0 ? SOURCE_WIDTH-target_width : {1'b0,error_next})+target_width;
                if(sum>=SOURCE_WIDTH) begin
                    error_next=sum-SOURCE_WIDTH;
                    queue_next={queue_next[47:0],data[31-k*8 -: 8]};count_next=count_next+1'b1;
                end else error_next=sum;
            end
        end
        out_valid=enable && count_next>=4;
        case(count_next)
            4:out_data=queue_next[31:0];5:out_data=queue_next[39:8];
            6:out_data=queue_next[47:16];7:out_data=queue_next[55:24];
            default:out_data=0;
        endcase
        if(count_next>=4) count_next=count_next-4;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin source_x<=0;error<=0;tail<=0;held<=0;end
        else if(!enable) begin source_x<=0;error<=0;tail<=0;held<=0;end
        else begin
            tail<=queue_next[23:0];held<=count_next[1:0];
            if(valid) begin error<=error_next;source_x<=source_x==SOURCE_WIDTH-4 ? 0 : source_x+4;end
        end
    end
endmodule

// RGB565 equivalent of the existing nearest-pixel display zoom. Process both
// packed pixels each cycle; retain one selected halfword across input stalls.
// The source coordinates are identical to the RGB888 path for all sizes 40..160.
module frame_zoom_filter_rgb565 #(parameter SOURCE_WIDTH=640,parameter EXPLICIT_ZOOM=0)(
    input clk,input rst,input enable,input [7:0] size,input [10:0] target_width,
    input valid,input [31:0] data,
    output reg out_valid,output reg [31:0] out_data
);
    reg [9:0] source_x,error;
    reg [15:0] tail;
    reg pending;
    reg [47:0] next_queue;
    reg [5:0] next_bits;
    reg [10:0] sum_a,sum_b;
    reg [9:0] next_error;
    wire [10:0] width=EXPLICIT_ZOOM!=0 ? target_width : {size,2'b00};
    always @* begin
        next_queue={32'd0,tail};next_bits=pending ? 16 : 0;
        next_error=error;sum_a=0;sum_b=0;
        if(valid) begin
            sum_a=(source_x==0 ? SOURCE_WIDTH-width : {1'b0,error})+width;
            if(sum_a>=SOURCE_WIDTH) begin
                next_error=sum_a-SOURCE_WIDTH;
                next_queue={next_queue[31:0],data[31:16]};next_bits=next_bits+16;
            end else next_error=sum_a;
            sum_b={1'b0,next_error}+width;
            if(sum_b>=SOURCE_WIDTH) begin
                next_error=sum_b-SOURCE_WIDTH;
                next_queue={next_queue[31:0],data[15:0]};next_bits=next_bits+16;
            end else next_error=sum_b;
        end
        out_valid=enable && next_bits>=32;
        out_data=next_bits==48 ? next_queue[47:16] : next_queue[31:0];
        if(next_bits>=32) next_bits=next_bits-32;
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin source_x<=0;error<=0;tail<=0;pending<=0;end
        else if(!enable) begin source_x<=0;error<=0;tail<=0;pending<=0;end
        else begin
            tail<=next_queue[15:0];pending<=next_bits!=0;
            if(valid) begin
                error<=next_error;source_x<=source_x==SOURCE_WIDTH-2 ? 0 : source_x+2;
            end
        end
    end
endmodule

// Decimate selected 640-pixel RGB888 source rows before the existing async
// FIFO. A 72-bit byte reservoir sustains one packed SDRAM word per clock,
// including the two complete pixels present in every third input word.
module frame_zoom_filter #(parameter SOURCE_WIDTH=640,parameter EXPLICIT_ZOOM=0)(
    input clk,input rst,input enable,input [7:0] size,input [10:0] target_width,
    input valid,input [31:0] data,
    output reg out_valid,output reg [31:0] out_data
);
    reg [1:0] phase;
    reg [15:0] tail;
    reg [9:0] source_x,error;
    reg [71:0] queue;
    reg [6:0] bits;
    reg [71:0] next_queue;
    reg [6:0] next_bits;
    reg [10:0] sum_a,sum_b;
    reg [9:0] next_error;
    reg [23:0] a,b;
    wire [10:0] width=EXPLICIT_ZOOM!=0 ? target_width : {size,2'b00};
    always @* begin
        a=phase==0 ? data[31:8] : phase==1 ? {tail[7:0],data[31:16]} : {tail,data[31:24]};
        b=data[23:0];
        next_queue=queue;next_bits=bits;next_error=error;sum_a=0;sum_b=0;
        if(valid) begin
            sum_a=(source_x==0 ? SOURCE_WIDTH-width : {1'b0,error})+width;
            if(sum_a>=SOURCE_WIDTH) begin
                next_error=sum_a-SOURCE_WIDTH;
                next_queue={next_queue[47:0],a};next_bits=next_bits+24;
            end else next_error=sum_a;
            if(phase==2) begin
                sum_b={1'b0,next_error}+width;
                if(sum_b>=SOURCE_WIDTH) begin
                    next_error=sum_b-SOURCE_WIDTH;
                    next_queue={next_queue[47:0],b};next_bits=next_bits+24;
                end else next_error=sum_b;
            end
        end
        out_valid=enable && next_bits>=32;
        out_data=0;
        if(next_bits>=32) begin
            case(next_bits)
                32:out_data=next_queue[31:0];40:out_data=next_queue[39:8];
                48:out_data=next_queue[47:16];56:out_data=next_queue[55:24];
                64:out_data=next_queue[63:32];72:out_data=next_queue[71:40];default:out_data=0;
            endcase
            next_bits=next_bits-32;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin phase<=0;tail<=0;source_x<=0;error<=0;queue<=0;bits<=0;end
        else if(!enable) begin phase<=0;source_x<=0;error<=0;queue<=0;bits<=0;end
        else begin
            queue<=next_queue;bits<=next_bits;
            if(valid) begin
                phase<=phase==2 ? 0 : phase+1'b1;
                tail<=data[15:0];error<=next_error;
                source_x<=source_x==SOURCE_WIDTH-2 ? 0 : source_x+(phase==2 ? 2 : 1);
            end
        end
    end
endmodule
