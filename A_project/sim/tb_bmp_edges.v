`timescale 1ns/1ps
module tb_bmp_edges;
    reg clk=0,rst=1,start=0,valid=0,finish=0;
    reg [31:0] size=78,offset=0;
    reg [7:0] data=0;
    wire accepted,pv,commit,done;
    wire [7:0] error;
    wire [59:0] detail;
    reg [7:0] bytes[0:77];
    integer i,m,count;
    always #5 clk=~clk;
    bmp24_decoder #(.EXPECTED_WIDTH(4),.EXPECTED_HEIGHT(2)) dut(
        .clk(clk),.rst_n(!rst),.file_start(start),.file_size(size),.file_valid(valid),
        .file_byte(data),.file_byte_offset(offset),.file_end(finish),.upstream_error(8'd0),
        .header_accepted(accepted),.pixel_valid(pv),.frame_commit(commit),.bmp_done(done),
        .bmp_error(error),.error_detail(detail));
    always @(negedge clk) if(pv) count=count+1;
    initial begin
        for(i=0;i<78;i=i+1) bytes[i]=0;
        bytes[0]="B";bytes[1]="M";bytes[2]=78;bytes[10]=54;bytes[14]=40;
        bytes[18]=4;bytes[22]=2;bytes[26]=1;bytes[28]=24;
        for(i=54;i<78;i=i+1) bytes[i]=i;
        repeat(3) @(negedge clk);rst=0;
        for(m=0;m<4;m=m+1) begin
            start=1;count=0;size=78;bytes[2]=m==1 ? 77 : 78;
            @(negedge clk);start=0;
            for(i=0;i<(m==2 ? 77 : 78);i=i+1) begin
                valid=1;data=bytes[i];offset=(m==3 && i==70) ? 71 : i;
                finish=i==(m==2 ? 76 : 77);
                @(negedge clk);valid=0;finish=0;
                repeat(2) @(negedge clk);
            end
            if(m==0) begin
                if(error!=0 || count!=8 || !accepted) $fatal(1,"last byte/end coincidence lost pixel");
            end else if(error!=8'h37) $fatal(1,"bad BMP accepted m=%0d E%h",m,error);
            if(m==1 && detail[27:18]!=2) $fatal(1,"header size reason missing");
            if(m==2 && detail[27:18]!=6) $fatal(1,"short stream reason missing");
            if(m==3 && detail[27:18]!=5) $fatal(1,"byte gap reason missing");
        end
        $display("PASS BMP edges: coincident EOF/last pixel, header mismatch, actual short file, offset gaps");
        $finish;
    end
    always @(posedge clk) if(commit && m!=0) $fatal(1,"invalid frame committed");
endmodule
