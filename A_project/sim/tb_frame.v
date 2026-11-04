`timescale 1ns/1ps
module tb_frame;
    reg clk=0,rst=1,request=0,flip=0;
    reg [9:0] level=256;
    reg [2:0] bank=0;
    wire ack,finish,clear,en,busy;
    wire [20:0] addr;
    integer count=0,expected,i;
    frame_fifo_write #(.BURST_SIZE(128),.FRAME_WIDTH(640),.FRAME_HEIGHT(480)) dut(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),
        .Sdr_busy(1'b0),.App_rd_busy(1'b0),.O_wr_busy(busy),.App_wr_en(en),.App_wr_addr(addr),
        .write_req(request),.write_req_ack(ack),.write_finish(finish),
        .write_addr_0(21'd0),.write_addr_1(21'd307200),.write_addr_2(21'd614400),.write_addr_3(21'd921600),
        .write_addr_4(21'd1228800),.write_addr_5(21'd1536000),
        .write_addr_index(bank),.write_v_flip(flip),.write_len(21'd307200),.fifo_aclr(clear),.rdusedw(level));
    always #5 clk=~clk;
    always @(posedge clk) if(!rst && en) begin
        expected=bank*307200+(flip ? (479-count/640)*640+count%640 : count);
        if(addr!=expected) $fatal(1,"address %d expected %d at %d",addr,expected,count);
        count=count+1;
    end
    task run_frame;
        input f;
        begin
            count=0;flip=f;
            @(negedge clk);request=1;
            wait(ack);@(negedge clk);request=0;
            wait(finish);#1;
            if(count!=307200) $fatal(1,"frame length %d",count);
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(i=0;i<6;i=i+1) begin bank=i;run_frame(0);run_frame(1);end
        $display("PASS frame writer: all 307200 addresses in six banks, both orientations, bank isolation, exact burst completion");
        $finish;
    end
    initial begin #100000000;$fatal(1,"frame timeout");end
endmodule
