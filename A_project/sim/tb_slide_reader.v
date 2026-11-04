`timescale 1ns/1ps
module tb_slide_reader;
    reg clk=0,rst=1,request=0,sliding=0;
    reg [18:0] offset=0;reg [2:0] old_bank=0,new_bank=1;
    wire en,ack,finish,clear,busy;wire [20:0] addr;
    reg [8:0] returned=0;reg [9:0] phase=0;
    reg [9:0] level=0;
    integer sent=0,total_received=0,expected,n,boundary,old_base,new_base;
    wire refresh=phase[7:0]<8;wire writer_busy=phase[7:0]>=128 && phase[7:0]<140;
    frame_fifo_read #(.BURST_SIZE(128),.SLIDE_ENABLE(1)) dut(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(refresh),
        .Sdr_busy(1'b0),.Sdr_rd_en(returned[8]),.App_wr_busy(writer_busy),.O_rd_busy(busy),
        .App_rd_en(en),.App_rd_addr(addr),.read_req(request),.read_req_ack(ack),
        .read_finish(finish),.read_addr_0(21'd0),.read_addr_1(21'd307200),
        .read_addr_2(21'd614400),.read_addr_3(21'd921600),.read_addr_4(21'd1228800),
        .read_addr_5(21'd1536000),.read_addr_index(old_bank),.read_len(21'd307200),
        .fifo_aclr(clear),.wrusedw(level),.slide_active(sliding),.slide_offset(offset),.slide_bank(new_bank));
    always #12.5 clk=~clk;
    always @(posedge clk) begin
        if(rst) begin returned<=0;phase<=0;end
        else begin returned<={returned[7:0],en};phase<=phase+1'b1;end
        if(!rst && en) begin
            expected=sent<boundary ? old_base+sent : new_base+sent-boundary;
            if(addr!==expected) $fatal(1,"slide address step=%0d pixel=%0d got=%0d expected=%0d",n,sent,addr,expected);
            if(sent>=307200) $fatal(1,"extra frame commands");
            sent=sent+1;
        end
        if(!rst && returned[8]) total_received=total_received+1;
    end
    task render(input integer step);begin
        sent=0;total_received=0;sliding=step!=0;offset=step*10240;
        old_bank=step%6;new_bank=(step+1)%6;
        boundary=307200-offset;old_base=old_bank*307200+offset;new_base=new_bank*307200;
        repeat(8) @(negedge clk);request=1;wait(ack);@(negedge clk);request=0;
        // Metadata is immutable for this frame even if next-frame controls change.
        repeat(12) @(negedge clk);offset=0;sliding=0;new_bank=0;old_bank=0;
        level=400;repeat(20) @(negedge clk);level=0;
        wait(finish);@(negedge clk);
        if(sent!=307200 || total_received!=307200) $fatal(1,"frame drain/count mismatch");
        repeat(8) @(negedge clk);
    end endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(n=0;n<30;n=n+1) render(n);
        $display("PASS slide reader: every pixel of 30 full frames, six bank pairs, aligned split, delayed returns, refresh/write/FIFO stalls, metadata held");$finish;
    end
    initial begin #400000000;$fatal(1,"slide reader timeout");end
endmodule
