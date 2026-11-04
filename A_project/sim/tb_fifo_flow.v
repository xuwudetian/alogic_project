`timescale 1ns/1ps
module tb_fifo_flow;
    reg mem_clk=0,write_clk=0,read_clk=0,rst=1;
    reg memory_busy=1,write_req=0,read_req=0,produce=0,consume=0;
    reg write_enable=0,read_enable=0;
    reg [31:0] write_data=0;
    wire write_ack,read_ack,write_finish,read_finish,overflow,underflow;
    wire mem_write,mem_read;
    wire [20:0] write_address,read_address;
    wire [31:0] memory_data,read_data;
    wire [3:0] mask;
    reg [7:0] read_pipe=0;
    wire return_valid=read_pipe[7];
    integer sent=0,stored=0,read_count=0,stalls=0,round=0,read_commands=0;
    wire ready;
    always #12.5 mem_clk=~mem_clk;
    always #10 write_clk=~write_clk;
    always #20 read_clk=~read_clk;
    frame_read_write #(.BURST_SIZE(128),.FRAME_WIDTH(128),.FRAME_HEIGHT(12)) dut(
        .rst(rst),.mem_clk(mem_clk),.Sdr_init_done(!rst),.Sdr_init_ref_vld(1'b0),
        .Sdr_busy(memory_busy),.App_rd_en(mem_read),.App_rd_addr(read_address),
        .Sdr_rd_en(return_valid),.Sdr_rd_dout(32'h12345678),
        .read_clk(read_clk),.read_req(read_req),.read_req_ack(read_ack),.read_finish(read_finish),
        .read_addr_0(21'd0),.read_addr_1(21'd1536),.read_addr_2(21'd3072),.read_addr_3(21'd4608),
        .read_addr_4(21'd6144),.read_addr_5(21'd7680),
        .read_addr_index(round[2:0]),.read_len(21'd1536),.read_en(read_enable),.read_data(read_data),
        .App_wr_en(mem_write),.App_wr_addr(write_address),.App_wr_din(memory_data),.App_wr_dm(mask),
        .write_clk(write_clk),.write_req(write_req),.write_req_ack(write_ack),
        .write_finish(write_finish),.write_addr_0(21'd0),.write_addr_1(21'd1536),
        .write_addr_2(21'd3072),.write_addr_3(21'd4608),
        .write_addr_4(21'd6144),.write_addr_5(21'd7680),.write_addr_index(round[2:0]),.write_len(21'd1536),
        .write_en(write_enable),.write_data(write_data),.write_v_flip(1'b0),
        .write_overflow(overflow),.read_underflow(underflow),.write_ready(ready));
    always @(negedge write_clk) begin
        write_enable=0;
        if(!rst && produce && sent<1536) begin
            if(ready) begin write_enable=1;write_data=32'habc00000+sent;sent=sent+1;end
            else stalls=stalls+1;
        end
    end
    always @(negedge read_clk) begin
        read_enable=consume && !dut.read_empty && read_count<1536;
        if(read_enable) read_count=read_count+1;
    end
    always @(posedge mem_clk) begin
        if(rst) read_pipe<=0;
        else read_pipe<={read_pipe[6:0],mem_read};
        if(!rst && mem_read && mem_write) $fatal(1,"simultaneous read/write");
        if(!rst && mem_read) begin
            if(read_address!==round*1536+read_commands) $fatal(1,"six-slot read base/sequence");
            read_commands=read_commands+1;
        end
        if(!rst && mem_write) begin
            if(memory_data!==(32'habc00000+stored) || write_address!==round*1536+stored)
                $fatal(1,"FIFO data/address mismatch at%0d: %h @%0d",stored,memory_data,write_address);
            stored=stored+1;
        end
        if(!rst && overflow) $fatal(1,"E40 overflow");
    end
    task reset_and_write;
        input enable_reader;
        begin
            rst=1;write_req=0;read_req=0;produce=0;consume=0;memory_busy=1;
            repeat(8) @(negedge write_clk);
            sent=0;stored=0;stalls=0;read_count=0;read_commands=0;rst=0;
            repeat(8) @(negedge write_clk);
            write_req=1;wait(write_ack);@(negedge write_clk);write_req=0;
            wait(!write_ack);repeat(8) @(negedge write_clk);
            if(enable_reader) begin
                read_req=1;wait(read_ack);@(negedge read_clk);read_req=0;wait(!read_ack);
            end
            produce=1;
            repeat(1400) @(negedge write_clk);
            if(sent>=1536 || stalls==0 || overflow) $fatal(1,"backpressure did not stop producer");
            @(negedge mem_clk);memory_busy=0;consume=enable_reader;
            wait(write_finish);
            repeat(8) @(negedge write_clk);
            if(stored!=1536 || sent!=1536 || overflow) $fatal(1,"incomplete frame");
            if(enable_reader) begin
                wait(read_count==1536);
                repeat(20) @(negedge mem_clk);
            end
            produce=0;consume=0;
        end
    endtask
    initial begin
        reset_and_write(0);
        for(round=1;round<6;round=round+1) reset_and_write(1);
        $display("PASS FIFO flow: official dual-clock FIFOs, six distinct read/write slot addresses, backpressure, idle-reader progress, display contention, warm resets, ordered1536word frames");
        $finish;
    end
    initial begin #1000000;$fatal(1,"FIFO starvation stored%0d sent%0d readstate%0d",stored,sent,dut.frame_fifo_read_m0.state);end
endmodule
