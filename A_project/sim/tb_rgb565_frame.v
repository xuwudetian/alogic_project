`timescale 1ns/1ps
// Exercise the actual FIFOs and controllers against an independent byte-stream
// memory oracle, including all 9 full-size frames and the final SDRAM address.
module tb_rgb565_frame;
    localparam PIXELS=307200,WORDS=153600,TOTAL_WORDS=1382400;
    reg mclk=0,wclk=0,pclk=0,rst=1,wreq=0,rreq=0,we=0,re=0;
    reg [3:0] wb=0,rb=0,next_bank=0;
    reg [15:0] din=0;
    reg flip=0,sliding=0,hold_memory=0;
    reg [18:0] offset=0;
    reg [20:0] read_words=WORDS;
    wire wack,rack,wfinish,rfinish,ready,overflow,underflow,mw,mr;
    wire [20:0] wa,ra;
    wire [31:0] wd;
    wire [15:0] dout;
    reg [31:0] memory[0:2097151];
    reg [7:0] valid_pipe=0;
    reg [31:0] data_pipe[0:7];
    reg [9:0] cycles=0;
    integer bank,p,x,y,n,j,stored=0,reads=0,expected_address,word_index,abort_pixels;
    reg check_write=0,check_read=0;
    reg [15:0] expected;
    always #12.5 mclk=~mclk;
    always #10 wclk=~wclk;
    always #20 pclk=~pclk;

    function [15:0] source_pixel(input integer bank_id,input integer index);
        integer xx,yy;
        begin
            xx=index%640;yy=index/640;
            source_pixel=(((xx^bank_id*29)&255)/8)*2048+(((yy+bank_id*17)&255)/4)*32+(((xx+yy*3+bank_id*11)&255)/8);
        end
    endfunction
    function [15:0] display_pixel(input integer bank_id,input integer index);
        begin
            display_pixel=source_pixel(bank_id,(bank_id%2 ? (479-index/640)*640 : (index/640)*640)+index%640);
        end
    endfunction
    function [31:0] source_word(input integer bank_id,input integer index);
        source_word={source_pixel(bank_id,index*2),source_pixel(bank_id,index*2+1)};
    endfunction
    frame_read_write #(.READ_DATA_BITS(16),.WRITE_DATA_BITS(16),.BURST_SIZE(128),.SLIDE_ENABLE(1)) dut(
        .rst(rst),.mem_clk(mclk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(cycles<12),.Sdr_busy(hold_memory),
        .App_rd_en(mr),.App_rd_addr(ra),.Sdr_rd_en(valid_pipe[7]),.Sdr_rd_dout(data_pipe[7]),
        .read_clk(pclk),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),
        .read_addr_0(21'd0),.read_addr_1(21'd153600),.read_addr_2(21'd307200),
        .read_addr_3(21'd460800),.read_addr_4(21'd614400),.read_addr_5(21'd768000),
        .read_addr_6(21'd921600),.read_addr_7(21'd1075200),.read_addr_8(21'd1228800),
        .read_addr_index(rb),.read_len(read_words),.read_en(re),.read_data(dout),
        .App_wr_en(mw),.App_wr_addr(wa),.App_wr_din(wd),.App_wr_dm(),
        .write_clk(wclk),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),
        .write_addr_0(21'd0),.write_addr_1(21'd153600),.write_addr_2(21'd307200),
        .write_addr_3(21'd460800),.write_addr_4(21'd614400),.write_addr_5(21'd768000),
        .write_addr_6(21'd921600),.write_addr_7(21'd1075200),.write_addr_8(21'd1228800),
        .write_addr_index(wb),.write_len(21'd153600),.write_en(we),.write_data(din),.write_v_flip(flip),
        .write_overflow(overflow),.read_underflow(underflow),.write_ready(ready),
        .slide_active(sliding),.slide_offset(offset),.slide_bank(next_bank));
    always @(posedge mclk) begin
        if(rst) begin valid_pipe<=0;cycles<=0;end
        else begin valid_pipe<={valid_pipe[6:0],mr};cycles<=cycles+1'b1;end
        if(mr) data_pipe[0]<=memory[ra];
        for(j=1;j<8;j=j+1) data_pipe[j]<=data_pipe[j-1];
        if(!rst && mw && mr) $fatal(1,"read/write arbitration collision");
        if(!rst && mw && check_write) begin
            expected_address=wb*WORDS+(flip ? 479-stored/320 : stored/320)*320+stored%320;
            if(wa!==expected_address || wd!==source_word(wb,stored) || wa>=TOTAL_WORDS)
                $fatal(1,"packed write bank%0d word%0d @%0d expected@%0d data%h expected%h",wb,stored,wa,expected_address,wd,source_word(wb,stored));
            memory[wa]=wd;stored=stored+1;
        end
        if(!rst && mr && check_read) begin
            word_index=reads+(sliding ? offset/2 : 0);
            expected_address=word_index<WORDS ? rb*WORDS+word_index : next_bank*WORDS+word_index-WORDS;
            if(ra!==expected_address || ra>=TOTAL_WORDS || reads>=WORDS)
                $fatal(1,"packed read bank%0d word%0d @%0d expected@%0d",rb,reads,ra,expected_address);
            reads=reads+1;
        end
    end
    task begin_write;
        begin
            @(negedge wclk);we=0;wreq=1;
            wait(wack);@(negedge wclk);wreq=0;wait(!wack);wait(ready);
            stored=0;
        end
    endtask
    task begin_read;
        begin
            @(negedge pclk);re=0;rreq=1;
            wait(rack);@(negedge pclk);rreq=0;wait(!rack);
            reads=0;check_read=1;
            repeat(1000) @(negedge pclk);
        end
    endtask
    initial begin
        memory[TOTAL_WORDS]=32'hdeadbeef;memory[2097151]=32'h1234abcd;
        repeat(8) @(negedge wclk);rst=0;repeat(8) @(negedge wclk);
        // Restart transactions with 1, 2 and 3 pending pixels in the packer.
        for(abort_pixels=1;abort_pixels<=3;abort_pixels=abort_pixels+1) begin
            begin_write;
            repeat(abort_pixels) begin @(negedge wclk);we=1;din=16'hbadb;end
            @(negedge wclk);we=0;repeat(16) @(negedge wclk);
        end
        for(bank=0;bank<9;bank=bank+1) begin
            wb=bank;flip=bank%2;begin_write;check_write=1;
            for(p=0;p<PIXELS;p=p+1) begin
                @(negedge wclk);we=0;
                while(!ready) @(negedge wclk);
                we=1;din=source_pixel(bank,p);
                if(p%127==126) begin @(negedge wclk);we=0;repeat(2) @(negedge wclk);end
            end
            @(negedge wclk);we=0;wait(wfinish);repeat(8) @(negedge mclk);check_write=0;
            if(stored!=WORDS || overflow) $fatal(1,"packed frame word total/overflow bank%0d: %0d",bank,stored);
        end
        if(memory[TOTAL_WORDS]!==32'hdeadbeef || memory[2097151]!==32'h1234abcd) $fatal(1,"SDRAM capacity guard");
        // Abort in each unpack phase, then begin a fresh frame.
        for(abort_pixels=1;abort_pixels<=3;abort_pixels=abort_pixels+1) begin
            rb=8;begin_read;
            repeat(abort_pixels) begin @(negedge pclk);re=1;end
            @(negedge pclk);re=0;check_read=0;
        end
        for(n=0;n<14;n=n+1) begin
            // All nine bank selectors, plus complete rasters in both
            // orientations and three full-frame sliding seams at the top bank.
            rb=n<9 ? n : n==10 ? 7 : 8;next_bank=7;sliding=n>=11;
            read_words=n<9 ? 1280 : WORDS;
            offset=n==11 ? 10240 : n==12 ? 153600 : n==13 ? 296960 : 0;
            begin_read;
            for(y=0;y<(n<9 ? 4 : 480);y=y+1) begin
                for(x=0;x<640;x=x+1) begin
                    p=y*640+x+(sliding ? offset : 0);
                    expected=p<PIXELS ? display_pixel(rb,p) : display_pixel(next_bank,p-PIXELS);
                    @(negedge pclk);re=1;@(posedge pclk);#1;
                    if(dout!==expected || underflow || overflow)
                        $fatal(1,"packed raster bank%0d offset%0d (%0d,%0d) got%h expected%h underflow%b",rb,offset,x,y,dout,expected,underflow);
                end
                @(negedge pclk);re=0;repeat(159) @(negedge pclk);
            end
            if(reads!=read_words) $fatal(1,"packed read word total %0d",reads);
            check_read=0;
        end
        $display("PASS packed RGB565: 9 full frame writes, all byte lanes/pixels/addresses, 8MiB bounds, both orientations, real async FIFOs/backpressure/refresh, abort/reset phases, all bank reads, 5 full rasters and PIC9->PIC8 slide seams");
        $finish;
    end
    initial begin #600000000;$fatal(1,"packed frame timeout bank%0d stored%0d reads%0d",bank,stored,reads);end
endmodule
