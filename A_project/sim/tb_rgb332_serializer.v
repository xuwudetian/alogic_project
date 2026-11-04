`timescale 1ns/1ps
module glbl;
    reg gsrn=1;
endmodule
module tb_rgb332_serializer;
    reg pc=0,sc=0,rst=1;
    reg [9:0] symbol=10'h155;
    wire q;
    integer cycles=0,last_load=-1,loads=0,bits=0,position=0,received=0;
    reg [9:0] expected[0:1023];
    reg [1:0] start_pipe=0;
    reg started=0;
    always #7.6923075 pc=~pc;
    always #1.5384615 sc=~sc;
    always @(negedge pc) if(!rst) symbol<={symbol[8:0],symbol[9]^symbol[6]};
    lane_lvds_10_1 dut(.I_pixel_clk(pc),.I_serial_clk(sc),.I_rst(rst),.I_data_in(symbol),.O_serial_out(q),.I_serial_rst(rst));
    always @(posedge sc) begin
        cycles=cycles+1;
        if(rst) begin start_pipe=0;started=0;last_load=-1;loads=0;end
        else begin
            if(start_pipe[1]) begin started=1;position=0;end
            start_pipe={start_pipe[0],dut.S_load_en_2d};
            if(dut.S_load_en_2d) begin
                if(last_load>=0 && cycles-last_load!=5) $fatal(1,"serializer symbol cadence %0d",cycles-last_load);
                last_load=cycles;expected[loads]=symbol;loads=loads+1;
            end
            #0.5;
            if(started) begin
                if(q!==expected[received][9-position]) $fatal(1,"DDR positive bit word%0d bit%0d",received,position);
                position=position+1;bits=bits+1;
            end
        end
    end
    always @(negedge sc) begin
        #0.5;
        if(!rst && started) begin
            if(q!==expected[received][9-position]) $fatal(1,"DDR negative bit word%0d bit%0d",received,position);
            position=position+1;bits=bits+1;
            if(position==10) begin
                started=0;received=received+1;
                if(received==512) begin
                    if(bits!=5120) $fatal(1,"serializer bit count");
                    $display("PASS production lane serializer + vendor ODDR: 512 symbols / 5120 exact DDR bits at 65/325MHz, no drops/reorder, 650Mb/s logical stream");$finish;
                end
            end
        end
    end
    initial begin #203;rst=0;#20000;$fatal(1,"serializer timeout");end
endmodule
