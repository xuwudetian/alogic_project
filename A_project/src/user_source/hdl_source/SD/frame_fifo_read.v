`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128,
    parameter SLIDE_ENABLE           = 0,
    parameter FRAME_WORDS            = 307200,
    parameter ZOOM_ENABLE            = 0,
    parameter ROW_WORDS              = 480,
    parameter FRAME_HEIGHT           = 480,
    parameter EXPLICIT_ZOOM          = 0
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
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
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[10:0]                      wrusedw,                    // from fifo write used words
    output                          read_active,
    input                           slide_active,
    input [19:0]                    slide_offset,
    input [3:0]                     slide_bank,
    input                           zoom_active,
    input [7:0]                     zoom_size,
    output reg                      zoom_latch,
    output reg [7:0]                zoom_size_latch,
    input [10:0]                     zoom_width,zoom_height,
    output reg [10:0]                 zoom_width_latch,zoom_height_latch

);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete
localparam S_ZOOM_ROW                = 6;

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[2:0]                             state;                      //state machine
reg[3:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[3:0]                             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;
// A zoom row is still read as contiguous, refresh-safe SDRAM bursts. Only
// selected source rows are fetched; the pixel filter removes unneeded columns.
reg zoom_meta,zoom_sync;
reg [7:0] zoom_size_meta,zoom_size_sync;
reg [10:0] zoom_words,zoom_row;
reg [10:0] zoom_width_meta,zoom_width_sync,zoom_height_meta,zoom_height_sync;
reg [10:0] vertical_error;
reg [ADDR_BITS-1:0] zoom_row_base;
// When the same scaler is used for the music picture, preserve the existing
// vertical slide in source coordinates, including rows skipped by scaling.
reg [ADDR_BITS-1:0] zoom_source_offset;
reg zoom_next_bank;
wire zoom_wrap=slide_latch && !zoom_next_bank && zoom_source_offset>=FRAME_WORDS-ROW_WORDS;
wire [ADDR_BITS-1:0] zoom_next_row=zoom_wrap ? next_base : zoom_row_base+ROW_WORDS;
wire [10:0] selected_height=EXPLICIT_ZOOM!=0 ? zoom_height_latch : {zoom_size_latch,1'b0}+zoom_size_latch;
wire [11:0] vertical_next={1'b0,vertical_error}+selected_height;
// RGB888 rows contain 480 words (128+128+128+96); RGB565 rows
// contain 320 words (128+128+64). Never fetch past a selected row.
// Bound bursts at row, slide seam and frame end. Native 720-pixel rows
// contain 360 words, so a slide seam need not be 128-word aligned.
wire [ADDR_BITS-1:0] words_left=slide_latch && read_cnt<split_words ?
    split_words-read_cnt : read_len_latch-read_cnt;
wire [BURST_BITS-1:0] burst_length=zoom_latch ?
    (zoom_words>ROW_WORDS-BURST_SIZE ? ROW_WORDS-zoom_words : BURST_SIZE) :
    (words_left<BURST_SIZE ? words_left : BURST_SIZE);
always @(posedge mem_clk or posedge rst) begin
    if(rst) begin zoom_meta<=0;zoom_sync<=0;zoom_size_meta<=40;zoom_size_sync<=40;
        zoom_width_meta<=160;zoom_width_sync<=160;zoom_height_meta<=120;zoom_height_sync<=120;end
    else if(ZOOM_ENABLE!=0) begin
        zoom_meta<=zoom_active;zoom_sync<=zoom_meta;
        zoom_size_meta<=zoom_size;zoom_size_sync<=zoom_size_meta;
        zoom_width_meta<=zoom_width;zoom_width_sync<=zoom_width_meta;
        zoom_height_meta<=zoom_height;zoom_height_sync<=zoom_height_meta;
    end
end

// 帧请求到来前元数据保持稳定，并在S_ACK期间锁存。默认关闭扩展，兼容原例程。
function [ADDR_BITS-1:0] bank_base;input [3:0] index;begin
    case(index)
        0:bank_base=read_addr_0;1:bank_base=read_addr_1;2:bank_base=read_addr_2;
        3:bank_base=read_addr_3;4:bank_base=read_addr_4;5:bank_base=read_addr_5;
        6:bank_base=read_addr_6;7:bank_base=read_addr_7;8:bank_base=read_addr_8;
        default:bank_base=read_addr_0;
    endcase
end endfunction
reg slide_meta,slide_sync,slide_latch;
reg [19:0] offset_meta,offset_sync;
reg [3:0] next_meta,next_sync;
reg [ADDR_BITS-1:0] split_words;
reg [ADDR_BITS-1:0] next_base;
wire slide_frame=SLIDE_ENABLE!=0 && slide_sync && offset_sync!=0 && offset_sync<FRAME_WORDS;
wire [ADDR_BITS-1:0] frame_offset=slide_frame ? offset_sync : 0;
always @(posedge mem_clk or posedge rst) begin
    if(rst) begin
        slide_meta<=0;slide_sync<=0;offset_meta<=0;offset_sync<=0;
        next_meta<=0;next_sync<=0;slide_latch<=0;split_words<=0;next_base<=0;
    end else if(SLIDE_ENABLE!=0) begin
        slide_meta<=slide_active;slide_sync<=slide_meta;
        offset_meta<=slide_offset;offset_sync<=offset_meta;
        next_meta<=slide_bank;next_sync<=next_meta;
        if(state==S_ACK) begin
            slide_latch<=slide_frame;split_words<=FRAME_WORDS-offset_sync;
            next_base<=bank_base(next_sync);
        end
    end
end


wire rd_vld;
reg [3:0] rd_delay;
reg [10:0] received;
always @(posedge mem_clk or posedge rst)
    if(rst) received<=0;
    else if(state==S_CHECK_FIFO) received<=0;
    else if(Sdr_rd_en && state==S_READ_BURST) received<=received+1'b1;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= burst_length);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
assign read_active = state != S_IDLE && state != S_END;
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10 && received >= burst_length);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_index_d0 <= 3'b00;
		read_addr_index_d1 <= 3'b00;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
                App_rd_addr_r <= bank_base(read_addr_index_d1)+frame_offset;
			end
        else if(ZOOM_ENABLE!=0 && state==S_ZOOM_ROW)
            App_rd_addr_r<=zoom_next_row;
        // 旧图尾部与新图头部拼接，换库发生在完整突发返回后，不丢弃FIFO数据。
        else if(SLIDE_ENABLE!=0 && !zoom_latch && state==S_READ_BURST_END && slide_latch &&
                read_cnt==split_words) App_rd_addr_r<=next_base;
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < burst_length)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
		zoom_latch<=0;zoom_size_latch<=40;zoom_width_latch<=160;zoom_height_latch<=120;zoom_words<=0;zoom_row<=0;
        vertical_error<=0;zoom_row_base<=0;zoom_source_offset<=0;zoom_next_bank<=0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
                zoom_latch<=ZOOM_ENABLE!=0 && zoom_sync &&
                    (EXPLICIT_ZOOM!=0 ? zoom_width_sync!=0 && zoom_height_sync!=0 && zoom_height_sync<=FRAME_HEIGHT :
                     zoom_size_sync>=40 && zoom_size_sync<=160);
                zoom_size_latch<=zoom_size_sync;
                zoom_width_latch<=zoom_width_sync;zoom_height_latch<=zoom_height_sync;
                zoom_words<=0;zoom_row<=0;vertical_error<=0;
                zoom_row_base<=bank_base(read_addr_index_d1)+frame_offset;
                zoom_source_offset<=frame_offset;zoom_next_bank<=0;
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 3'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 3'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 3'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 3'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					read_len_latch <= read_len_d1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy &&
                        Sdr_init_done && !Sdr_init_ref_vld && !Sdr_busy)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + burst_length;
                    if(zoom_latch) zoom_words<=zoom_words+burst_length;
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
                else if(zoom_latch) begin
                    if(zoom_words==ROW_WORDS) begin
                        if(zoom_row==selected_height-1'b1) state<=S_END;
                        else begin zoom_row<=zoom_row+1'b1;zoom_words<=0;state<=S_ZOOM_ROW;end
                    end else state<=S_CHECK_FIFO;
                end
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
            S_ZOOM_ROW: begin
                // ceil(row*FRAME_HEIGHT/height), using at most four additions per row.
                zoom_row_base<=zoom_next_row;
                zoom_source_offset<=zoom_wrap ? 0 : zoom_source_offset+ROW_WORDS;
                if(zoom_wrap) zoom_next_bank<=1;
                if(vertical_next>=FRAME_HEIGHT) begin vertical_error<=vertical_next-FRAME_HEIGHT;state<=S_CHECK_FIFO;end
                else vertical_error<=vertical_next;
            end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
