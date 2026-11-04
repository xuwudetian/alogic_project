`timescale 1ns/1ps
// SDRAM owner/arbiter. Publish only after all 393216 packed words are committed.
// The old display bank becomes writable only after vertical-blank ACK.
// Bounded 512-word line reads have priority over the 1024-word camera FIFO.
// Refill the next write burst while the SDRAM handles the current transaction.
module preview_frame_store(
    input clk,input rst_n,input mem_forward_clk,
    input camera_clk,input camera_rst_n,
    input pixel_valid,input [15:0] pixel_rgb565,input [9:0] pixel_x,input [9:0] pixel_y,input frame_start,
    input display_acknowledge,output reg published_toggle,output reg published_bank,
    input line_request,input line_frame_bank,input [9:0] line_row,input line_cache,
    output reg line_acknowledge,
    output cache_write_enable,output [9:0] cache_write_address,output [31:0] cache_write_data,
    output initialized,output reg [31:0] frames_committed,output reg [31:0] frames_dropped);
    reg camera_done,camera_good,capturing,packing,overflow;
    reg [15:0] first_pixel;
    reg [19:0] sample_count;
    reg camera_acknowledge;
    (* async_reg="true" *) reg [1:0] camera_ack_sync,init_sync;
    wire fifo_full,fifo_empty,fifo_valid;
    wire [10:0] fifo_count;
    wire [31:0] fifo_data;
    wire sample=capturing && pixel_valid && !frame_start;
    wire fifo_push=sample && packing && !fifo_full;
    wire [31:0] fifo_input={pixel_rgb565,first_pixel};
    always @(posedge camera_clk or negedge camera_rst_n) begin
        if(!camera_rst_n) begin
            camera_done<=0;camera_good<=0;capturing<=0;packing<=0;overflow<=0;
            first_pixel<=0;sample_count<=0;camera_ack_sync<=0;init_sync<=0;
        end else begin
            camera_ack_sync<={camera_ack_sync[0],camera_acknowledge};
            init_sync<={init_sync[0],initialized};
            if(frame_start) begin
                if(capturing) begin
                    capturing<=0;packing<=0;camera_good<=0;camera_done<=~camera_done;
                end else if(init_sync[1] && camera_ack_sync[1]==camera_done) begin
                    capturing<=1;packing<=0;overflow<=0;sample_count<=0;
                end
            end else if(sample) begin
                // Saturation prevents malformed overlong streams wrapping the
                // expected sample count and becoming publishable again.
                if(sample_count<786432) sample_count<=sample_count+1'b1;
                else overflow<=1;
                packing<=~packing;
                if(!packing) first_pixel<=pixel_rgb565;
                else if(fifo_full) overflow<=1;
                if(pixel_x==1023 && pixel_y==767) begin
                    capturing<=0;packing<=0;
                    camera_good<=sample_count==786431 && packing && !overflow && !fifo_full;
                    camera_done<=~camera_done;
                end
            end
        end
    end
    localparam IDLE=0,SEND_WRITE=2,WAIT_WRITE=3,SEND_READ=4,WAIT_READ=5,DRAIN=6;
    reg [2:0] state;
    reg [3:0] issued,received;
    reg filling,burst_ready;
    reg [255:0] write_words;
    wire fifo_pop=(filling && issued<8) || (state==DRAIN && !fifo_empty);
    preview_async_fifo camera_fifo(.write_clk(camera_clk),.write_rst_n(camera_rst_n),
        .write_enable(fifo_push),.write_data(fifo_input),.full(fifo_full),
        .read_clk(clk),.read_rst_n(rst_n),.read_enable(fifo_pop),.read_data(fifo_data),
        .read_valid(fifo_valid),.empty(fifo_empty),.read_count(fifo_count));
    (* async_reg="true" *) reg [1:0] camera_done_sync,display_ack_sync,line_request_sync;
    reg camera_done_seen,done_pending,done_good;
    reg [2:0] done_settle;
    reg write_bank,awaiting_display;
    reg [18:0] words_written;
    reg line_pending,line_request_seen,fetch_bank,fetch_cache;
    reg [9:0] fetch_row;
    reg [8:0] fetch_offset;
    wire [20:0] write_address=(write_bank ? 21'd393216:21'd0)+{2'd0,words_written};
    wire [20:0] read_address=(fetch_bank ? 21'd393216:21'd0)
        +{2'd0,fetch_row,9'd0}+{12'd0,fetch_offset};
    wire memory_ready,memory_done,memory_read_valid,clock_enable;
    wire [2:0] memory_read_index;
    wire [31:0] memory_read_data;
    wire memory_request=(state==SEND_WRITE || state==SEND_READ);
    wire memory_write=(state==SEND_WRITE);
    wire ras_n,cas_n,we_n,data_output_enable;
    wire [10:0] sdram_address;
    wire [1:0] sdram_bank;
    wire [31:0] data_out,data_in;
    preview_sdram_controller memory_controller(.clk(clk),.rst_n(rst_n),
        .request(memory_request),.write_request(memory_write),.address(memory_write?write_address:read_address),
        .write_words(write_words),.ready(memory_ready),.initialized(initialized),.clock_enable(clock_enable),.done(memory_done),
        .read_valid(memory_read_valid),.read_index(memory_read_index),.read_data(memory_read_data),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.sdram_address(sdram_address),.bank(sdram_bank),
        .data_out(data_out),.data_output_enable(data_output_enable),.data_in(data_in));
    preview_sdram_phy memory_phy(.clk(clk),.rst_n(rst_n),.mem_forward_clk(mem_forward_clk),.clock_enable(clock_enable),.initialized(initialized),
        .ras_n(ras_n),.cas_n(cas_n),.we_n(we_n),.address(sdram_address),.bank(sdram_bank),
        .data_out(data_out),.data_output_enable(data_output_enable),.data_in(data_in));
    assign cache_write_enable=memory_read_valid && state==WAIT_READ;
    assign cache_write_address={fetch_cache,fetch_offset}+{7'd0,memory_read_index};
    assign cache_write_data=memory_read_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;issued<=0;received<=0;write_words<=0;filling<=0;burst_ready<=0;
            camera_done_sync<=0;display_ack_sync<=0;line_request_sync<=0;
            camera_done_seen<=0;done_pending<=0;done_good<=0;done_settle<=0;
            write_bank<=0;awaiting_display<=0;words_written<=0;camera_acknowledge<=0;
            published_toggle<=0;published_bank<=1;line_acknowledge<=0;
            line_pending<=0;line_request_seen<=0;fetch_bank<=0;fetch_cache<=0;fetch_row<=0;fetch_offset<=0;
            frames_committed<=0;frames_dropped<=0;
        end else begin
            camera_done_sync<={camera_done_sync[0],camera_done};
            display_ack_sync<={display_ack_sync[0],display_acknowledge};
            line_request_sync<={line_request_sync[0],line_request};
            // The controller latches all eight words on request acceptance,
            // so the same staging registers can refill during WAIT_WRITE or
            // a display read. Full BL8 availability avoids partial-tail stalls.
            if(!filling && !burst_ready && !awaiting_display && state!=DRAIN &&
               !(done_pending && !done_good) && words_written<393216 && fifo_count>=8) begin
                filling<=1;issued<=0;received<=0;
            end
            if(filling) begin
                if(fifo_pop) issued<=issued+1'b1;
                if(fifo_valid) begin
                    write_words[received*32+:32]<=fifo_data;received<=received+1'b1;
                    if(received==7) begin filling<=0;burst_ready<=1;end
                end
            end
            if(camera_done_sync[1]!=camera_done_seen) begin
                // camera_good is bundled with the toggle and held until ACK.
                camera_done_seen<=camera_done_sync[1];done_pending<=1;done_good<=camera_good;done_settle<=4;
            end else if(done_settle!=0) done_settle<=done_settle-1'b1;
            if(line_request_sync[1]!=line_request_seen && !line_pending) begin
                // Bundled fields remain stable until this line's ACK.
                line_request_seen<=line_request_sync[1];line_pending<=1;
                fetch_bank<=line_frame_bank;fetch_row<=line_row;fetch_cache<=line_cache;fetch_offset<=0;
            end
            if(awaiting_display && display_ack_sync[1]==published_toggle) begin
                awaiting_display<=0;write_bank<=~write_bank;words_written<=0;
                camera_acknowledge<=camera_done_seen;done_pending<=0;
            end
            case(state)
                IDLE: if(initialized) begin
                    if(line_pending) state<=SEND_READ;
                    else if(!awaiting_display) begin
                        if(done_pending && !done_good && done_settle==0) begin
                            state<=DRAIN;filling<=0;burst_ready<=0;issued<=0;received<=0;
                        end
                        // Never let malformed input cross the frame boundary
                        // into the other frame, even before camera_done arrives.
                        else if(burst_ready && words_written<393216) state<=SEND_WRITE;
                        else if(done_pending && done_good && done_settle==0 && fifo_empty && !filling && !burst_ready) begin
                            if(words_written==393216) begin
                                published_bank<=write_bank;published_toggle<=~published_toggle;
                                awaiting_display<=1;frames_committed<=frames_committed+1'b1;
                            end else begin done_good<=0;state<=DRAIN;end
                        end
                    end
                end
                SEND_WRITE: if(memory_ready) begin burst_ready<=0;state<=WAIT_WRITE;end
                WAIT_WRITE: if(memory_done) begin words_written<=words_written+8;state<=IDLE;end
                SEND_READ: if(memory_ready) state<=WAIT_READ;
                WAIT_READ: if(memory_done) begin
                    if(fetch_offset==504) begin line_pending<=0;line_acknowledge<=line_request_seen;state<=IDLE;end
                    else begin fetch_offset<=fetch_offset+8;state<=IDLE;end
                end
                DRAIN: begin
                    // No new camera data arrives until ACK; drain partial BL8 tail.
                    if(line_pending) state<=SEND_READ;
                    else if(fifo_empty && !fifo_valid) begin
                        camera_acknowledge<=camera_done_seen;done_pending<=0;words_written<=0;
                        frames_dropped<=frames_dropped+1'b1;state<=IDLE;
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
