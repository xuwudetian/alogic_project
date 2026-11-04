`timescale 1ns/1ps
module hdmi576_reset_case #(parameter BITS=16)(output reg done=0);
    localparam WORDS=128*4*BITS/32;
    reg mc=0,pc=0,wc=0,run_pc=1,rst=1,request=0,re=0;
    reg [3:0] bank=0;
    wire ack,mr,underflow;wire [20:0] address;wire [BITS-1:0] pixel;
    reg [7:0] valid_pipe=0;reg [31:0] data_pipe[0:7];
    integer j,i,k,clears=0,releases=0,first_index;
    wire [1:0] phase;wire prefetched;wire [BITS-1:0] tail;
    always #12.5 mc=~mc;always #18.5185 if(run_pc) pc=~pc;always #10 wc=~wc;
    function [BITS-1:0] color(input integer id,input integer index);
        color=BITS==16 ? (id*16'h1300)^(index*17+16'h5a31) : (id*24'h130000)^(index*257+24'h5a317c);
    endfunction
    function [31:0] memory_word(input integer addr);
        integer idx,id;reg [23:0] a,b,c,d;
        begin
            id=addr/4096;idx=addr%4096;
            if(BITS==16) memory_word={color(id,idx*2),color(id,idx*2+1)};
            else begin
                a=color(id,(idx/3)*4);b=color(id,(idx/3)*4+1);c=color(id,(idx/3)*4+2);d=color(id,(idx/3)*4+3);
                case(idx%3) 0:memory_word={a,b[23:16]};1:memory_word={b[15:0],c[23:8]};default:memory_word={c[7:0],d};endcase
            end
        end
    endfunction
    frame_read_write #(.READ_DATA_BITS(BITS),.WRITE_DATA_BITS(BITS),.FRAME_WIDTH(128),.FRAME_HEIGHT(4),
      .BURST_SIZE(32),.ZOOM_ENABLE(1),.EXPLICIT_ZOOM(1)) dut(
      .rst(rst),.mem_clk(mc),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
      .App_rd_en(mr),.App_rd_addr(address),.Sdr_rd_en(valid_pipe[7]),.Sdr_rd_dout(data_pipe[7]),
      .read_clk(pc),.read_req(request),.read_req_ack(ack),.read_finish(),
      .read_addr_0(21'd0),.read_addr_1(21'd4096),.read_addr_2(21'd8192),.read_addr_3(21'd12288),
      .read_addr_4(21'd16384),.read_addr_5(21'd20480),.read_addr_6(21'd24576),.read_addr_7(21'd28672),.read_addr_8(21'd32768),
      .read_addr_index(bank),.read_len(WORDS),.read_en(re),.read_data(pixel),
      .App_wr_en(),.App_wr_addr(),.App_wr_din(),.App_wr_dm(),.write_clk(wc),.write_req(1'b0),.write_req_ack(),.write_finish(),
      .write_addr_0(21'd0),.write_addr_1(21'd4096),.write_addr_2(21'd8192),.write_addr_3(21'd12288),
      .write_addr_4(21'd16384),.write_addr_5(21'd20480),.write_addr_6(21'd24576),.write_addr_7(21'd28672),.write_addr_8(21'd32768),
      .write_addr_index(4'd0),.write_len(WORDS),.write_en(1'b0),.write_data({BITS{1'b0}}),.write_v_flip(1'b0),
      .write_overflow(),.read_underflow(underflow),.write_ready(),
      .slide_active(1'b0),.slide_offset(19'd0),.slide_bank(4'd0),
      .zoom_active(1'b0),.zoom_size(8'd32),.zoom_left(10'd0),.zoom_top(10'd0),.zoom_width(10'd128),.zoom_height(10'd4));
    generate if(BITS==16) begin
        assign phase={1'b0,dut.unpack_rgb565.phase};assign prefetched=dut.unpack_rgb565.word_valid;assign tail=dut.unpack_rgb565.tail;
    end else begin
        assign phase=dut.unpack_rgb888.phase;assign prefetched=dut.unpack_rgb888.word_valid;assign tail=dut.unpack_rgb888.tail;
    end endgenerate
    always @(posedge mc) begin
        if(rst) valid_pipe<=0;else valid_pipe<={valid_pipe[6:0],mr};
        if(mr) data_pipe[0]<=memory_word(address);
        for(j=1;j<8;j=j+1) data_pipe[j]<=data_pipe[j-1];
    end
    // The checks observe real controller-generated clears; no internal forcing.
    always @(posedge dut.read_clear_async) begin
        #1;
        if(dut.unpack_reset!==1 || pixel!==0 || phase!==0 || prefetched!==0 || tail!==0)
            $fatal(1,"RGB%0d FIFO clear did not assert pixel reset asynchronously",BITS);
        clears=clears+1;
    end
    always @(negedge dut.read_clear_async) begin
        for(k=1;k<=3;k=k+1) begin
            @(posedge pc);#1;
            if(dut.unpack_reset!==(k<3)) $fatal(1,"RGB%0d unpack reset release edge%0d",BITS,k);
            if(pixel!==0 || phase!==0 || prefetched!==0 || tail!==0) $fatal(1,"RGB%0d stale unpack state during reset release",BITS);
        end
        releases=releases+1;
    end
    task begin_read(input integer selected_bank);
        begin
            @(negedge pc);re=0;bank=selected_bank;request=1;
            wait(ack);#1;if(dut.unpack_reset!==1 || pixel!==0) $fatal(1,"RGB%0d frame ack did not clear unpacker",BITS);
            @(negedge pc);request=0;wait(!ack);repeat(1000) @(negedge pc);
            if(dut.read_reset || dut.unpack_reset || underflow || dut.zoom_reader.display_x!=0 || dut.zoom_reader.display_y!=0)
                $fatal(1,"RGB%0d frame start state",BITS);
        end
    endtask
    task pixels(input integer count);
        integer p;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge pc);re=1;@(posedge pc);#1;
                if(pixel!==color(bank,p) || underflow) $fatal(1,"RGB%0d bank%0d stale/shifted pixel%0d got%h expected%h",BITS,bank,p,pixel,color(bank,p));
            end
            @(negedge pc);re=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge pc);#3;rst=0;
        for(i=1;i<=3;i=i+1) begin
            @(posedge pc);#1;
            if(dut.read_reset!==(i<3) || underflow || dut.zoom_reader.display_x!==0 || dut.zoom_reader.display_y!==0)
                $fatal(1,"RGB%0d global read reset release edge%0d",BITS,i);
        end
        // Interrupt all packed-pixel phases, then prove every pixel of new bank.
        for(i=1;i<=3;i=i+1) begin begin_read(i);pixels(i);begin_read(i+3);pixels(512);end
        begin_read(8);pixels(512);
        @(negedge pc);re=1;@(posedge pc);#1;
        if(!underflow) $fatal(1,"RGB%0d underflow reset coverage was not exercised",BITS);
        @(negedge pc);re=0;
        @(negedge pc);run_pc=0;#2;rst=1;#1;
        if(!dut.read_reset || !dut.unpack_reset || pixel!==0 || phase!==0 || tail!==0 || prefetched!==0 || underflow ||
           dut.zoom_reader.display_x!==0 || dut.zoom_reader.display_y!==0 || dut.zoom_reader.previous_read!==0)
            $fatal(1,"RGB%0d stopped-clock asynchronous reset",BITS);
        repeat(8) @(negedge mc);rst=0;#90;
        if(!dut.read_reset || !dut.unpack_reset || pixel!==0) $fatal(1,"RGB%0d released with read clock stopped",BITS);
        run_pc=1;
        for(i=1;i<=3;i=i+1) begin @(posedge pc);#1;if(dut.read_reset!==(i<3)) $fatal(1,"RGB%0d restarted clock release",BITS);end
        begin_read(0);pixels(512);
        if(clears<9 || releases<10) $fatal(1,"RGB%0d clear coverage %0d/%0d",BITS,clears,releases);
        $display("PASS RGB%0d async assert/three read-clock release: reset with stopped pixel clock and latched underflow, all unpack phases aborted, no stale pixels across frame clears, new bank full pixel sequence",BITS);
        done=1;
    end
endmodule
module tb_hdmi576_reset;
    wire done16,done24;
    hdmi576_reset_case #(.BITS(16)) rgb565(done16);
    hdmi576_reset_case #(.BITS(24)) rgb888(done24);
    initial begin wait(done16 && done24);$display("PASS native pixel reset CDC contracts in both RGB565 and RGB888");$finish;end
    initial begin #2000000;$fatal(1,"pixel reset timeout");end
endmodule
