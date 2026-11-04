`timescale 1ns/1ps
module tb_bmp_transaction;
    reg clk=0,rst=1,start=0,valid=0,finish=0;
    reg [31:0] offset=0;
    reg [7:0] data=0;
    wire done,commit;
    wire [7:0] error;
    wire [59:0] detail;
    integer completions=0,i;
    reg [7:0] bytes[0:77];
    always #5 clk=~clk;
    bmp24_decoder #(.EXPECTED_WIDTH(4),.EXPECTED_HEIGHT(2)) dut(
        .clk(clk),.rst_n(!rst),.file_start(start),.file_size(32'd78),
        .file_valid(valid),.file_byte(data),.file_byte_offset(offset),
        .file_end(finish),.upstream_error(8'd0),.bmp_done(done),
        .frame_commit(commit),.bmp_error(error),.error_detail(detail));
    always @(posedge clk) if(done) completions=completions+1;
    initial begin
        for(i=0;i<78;i=i+1) bytes[i]=0;
        bytes[0]="B";bytes[1]="M";bytes[2]=78;bytes[10]=54;bytes[14]=40;
        bytes[18]=4;bytes[22]=2;bytes[26]=1;bytes[28]=24;
        repeat(3) @(negedge clk);rst=0;
        finish=1;repeat(4) @(negedge clk);finish=0;
        repeat(3) @(negedge clk);
        if(completions!=0 || error!=0) $fatal(1,"idle EOF generated E%h / %0d completions",error,completions);
        start=1;finish=1;@(negedge clk);start=0;finish=0;
        for(i=0;i<78;i=i+1) begin
            valid=1;offset=i;data=bytes[i];finish=i==77;@(negedge clk);
        end
        valid=0;finish=1;repeat(5) @(negedge clk);finish=0;
        repeat(3) @(negedge clk);
        if(completions!=1 || error!=0) $fatal(1,"repeated EOF or start priority E%h count%0d",error,completions);
        start=1;@(negedge clk);start=0;
        finish=1;@(negedge clk);finish=0;repeat(4) @(negedge clk);
        if(completions!=2 || error!=8'h37 || detail[27:18]!=7)
            $fatal(1,"real empty transaction must still report E37/N007");
        $display("PASS BMP transaction: idle/repeated EOF ignored, start priority, genuine empty file remains E37/N007");
        $finish;
    end
    initial begin #100000;$fatal(1,"transaction timeout");end
endmodule
