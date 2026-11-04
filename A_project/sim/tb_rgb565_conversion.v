`timescale 1ns/1ps
// Exercise the real top-level wiring, covering every RGB565 colour code.
module tb_rgb565_conversion;
    reg clk=0;
    reg [23:0] sample=0;
    reg [15:0] packed_pixel=0;
    integer n,r,g,b;
    reg [23:0] expected;
    always #10 clk=~clk;
    top #(.BOOT_HOLD_CYCLES(10)) dut(.clk(clk),.rst_n(1'b0),
        .key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(4'd0),.sd_miso(1'b1),
        .uart_rx(1'b1),.eth_rx_clk(clk),.eth_rx_ctl(1'b0),.eth_rxd(4'd0));
    initial begin
        force dut.storage.rgb=sample;
        force dut.read_pixel565=packed_pixel;
        for(n=0;n<65536;n=n+1) begin
            r=n/2048;g=(n/32)%64;b=n%32;
            // Vary discarded low bits as well as every retained code.
            sample={8'(r*8+(n%8)),8'(g*4+(n%4)),8'(b*8+((n/8)%8))};
            packed_pixel=n;
            expected={8'(r*8+r/4),8'(g*4+g/16),8'(b*8+b/4)};
            #1;
            if(dut.write_data!==n[15:0]) $fatal(1,"BMP RGB565 quantization %h -> %h expected %h",sample,dut.write_data,n[15:0]);
            if(dut.read_data!==expected) $fatal(1,"RGB565 display expansion %h -> %h expected %h",packed_pixel,dut.read_data,expected);
            if(dut.thumbnail_rgb!==sample) $fatal(1,"thumbnail source changed");
        end
        release dut.storage.rgb;release dut.read_pixel565;
        $display("PASS RGB565 conversion: all 65536 codes, discarded low bits, channel order, full-range expansion, original thumbnail input");
        $finish;
    end
endmodule
