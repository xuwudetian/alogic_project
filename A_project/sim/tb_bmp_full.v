`timescale 1ns/1ps
module tb_bmp_full;
    reg clk=0,rst_n=0,start=0,valid=0,finish=0;
    reg [31:0] size,offset;
    reg [7:0] data;
    reg [7:0] bytes[0:3686453];
    wire accepted,pv,commit,done,topdown,scale;
    wire [23:0] rgb;
    wire [15:0] x,y;
    wire [7:0] error;
    integer fd,length,j,count,n,width,stride,twice,negative,expected_y,k,r,g,b;
    integer row,column,a0,a1,a2,a3;
    reg [255:0] filename;
    bmp24_decoder #(.ALLOW_2X_SOURCE(1)) dut(
        .clk(clk),.rst_n(rst_n),.file_start(start),.file_size(size),.file_valid(valid),
        .file_byte(data),.file_byte_offset(offset),.file_end(finish),.upstream_error(8'd0),
        .header_accepted(accepted),.pixel_valid(pv),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
        .frame_commit(commit),.bmp_done(done),.bmp_error(error),.top_down(topdown),
        .source_scale_2x(scale),.pixel_ready(1'b1));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(n=1;n<=4;n=n+1) begin
            case(n)
                1:filename="doc/tf_demo/PIC1.BMP";
                2:filename="doc/tf_demo/PIC2.BMP";
                3:filename="doc/tf_demo/PIC3.BMP";
                4:filename="doc/tf_demo/PIC4.BMP";
            endcase
            fd=$fopen(filename,"rb");
            if(fd==0) $fatal(1,"missing BMP fixture");
            length=$fread(bytes,fd);$fclose(fd);
            twice=n>=3;negative=n==2 || n==4;width=twice ? 1280 : 640;stride=width*3;
            size=length;count=0;
            @(negedge clk);start=1;@(negedge clk);start=0;
            for(j=0;j<length;j=j+1) begin
                valid=1;data=bytes[j];offset=j;
                @(posedge clk);#1;
                if(pv) begin
                    row=count/640;column=count%640;expected_y=negative ? row : 479-row;
                    if(x!=column || y!=expected_y) $fatal(1,"full-size pixel coordinates");
                    a0=54+(twice ? row*2 : row)*stride+(twice ? column*2 : column)*3;
                    if(twice) begin
                        a1=a0+3;a2=a0+stride;a3=a2+3;
                        r=(bytes[a0+2]+bytes[a1+2]+bytes[a2+2]+bytes[a3+2]+2)/4;
                        g=(bytes[a0+1]+bytes[a1+1]+bytes[a2+1]+bytes[a3+1]+2)/4;
                        b=(bytes[a0]+bytes[a1]+bytes[a2]+bytes[a3]+2)/4;
                    end else begin r=bytes[a0+2];g=bytes[a0+1];b=bytes[a0];end
                    if(rgb!=={r[7:0],g[7:0],b[7:0]}) $fatal(1,"full-size RGB image%d pixel%d",n,count);
                    count=count+1;
                end
                @(negedge clk);
            end
            valid=0;repeat(3) @(negedge clk);finish=1;repeat(2) @(posedge clk);#1;
            if(!commit || error!=0 || count!=307200) $fatal(1,"full-size frame integrity");
            @(negedge clk);finish=0;
            $display("PASS full BMP PIC%0d: 307200 checked RGB pixels, scale=%0d, top_down=%0d",n,twice,negative);
        end
        $finish;
    end
endmodule
