`timescale 1ns/1ps
module tb_reader;
    reg clk=0,rst=1,request=0,response=0,refresh=1;
    wire en,ack,finish,clear,busy;
    wire [20:0] addr;
    integer sent=0,received=0,i;
    frame_fifo_read #(.BURST_SIZE(128)) dut(
        .rst(rst),.mem_clk(clk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(refresh),
        .Sdr_busy(1'b0),.Sdr_rd_en(response),.App_wr_busy(1'b0),.O_rd_busy(busy),
        .App_rd_en(en),.App_rd_addr(addr),.read_req(request),.read_req_ack(ack),
        .read_finish(finish),.read_addr_0(21'd0),.read_addr_1(21'd307200),
        .read_addr_2(21'd614400),.read_addr_3(21'd921600),
        .read_addr_4(21'd1228800),.read_addr_5(21'd1536000),.read_addr_index(3'd1),
        .read_len(21'd128),.fifo_aclr(clear),.wrusedw(10'd0));
    always #5 clk=~clk;
    always @(posedge clk) if(en) begin
        if(addr!=307200+sent || refresh) $fatal(1,"read address / refresh");
        sent=sent+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;request=1;
        wait(ack);@(negedge clk);request=0;
        repeat(20) @(negedge clk);
        if(sent!=0) $fatal(1,"read while refreshing");
        refresh=0;
        wait(sent==128);
        repeat(30) @(negedge clk);
        if(!busy || finish) $fatal(1,"did not wait for real returned data");
        for(i=0;i<127;i=i+1) begin
            response=1;@(negedge clk);response=0;@(negedge clk);
        end
        repeat(30) @(negedge clk);
        if(!busy || finish) $fatal(1,"lost final response");
        response=1;@(negedge clk);response=0;
        wait(finish);
        if(sent!=128) $fatal(1,"extra commands");
        $display("PASS reader: refresh gating, exact 128 addresses, outstanding-response drain");
        $finish;
    end
    initial begin #100000;$fatal(1,"reader timeout");end
endmodule
