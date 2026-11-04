`timescale 1ns/1ps
module tb_rgb332_geometry;
    reg clk=0;
    always #10 clk=~clk;
    tri1 scl,sda,mdio;
    reg [9:0] left_probe=0,top_probe=0,width_probe=0,height_probe=0;
    integer i,expected_left,expected_top,expected_width,expected_height;
    reg [43:0] previous_geometry;
    top #(.BOOT_HOLD_CYCLES(8)) dut(.clk(clk),.rst_n(1'b1),
        .key1(1'b1),.key2(1'b1),.key3(1'b1),.sw(4'd0),.sd_miso(1'b1),
        .sensor_scl(scl),.sensor_sda(sda),.eth_rx_clk(1'b0),
        .eth_rx_ctl(1'b0),.eth_rxd(4'd0),.eth_mdio(mdio));
    initial begin
        force dut.logical_left=left_probe;
        force dut.logical_top=top_probe;
        force dut.logical_width=width_probe;
        force dut.logical_height=height_probe;
        wait(dut.rst_video===1'b0);
        repeat(4) @(negedge dut.video_clk);
        for(i=0;i<1024;i=i+1) begin
            previous_geometry={dut.native_left,dut.native_top,dut.native_width,dut.native_height};
            // Independent permutations exhaust every 10-bit coordinate and
            // dimension, exposing swapped/cross-wired arithmetic as well.
            left_probe=i;top_probe=1023-i;
            width_probe=(i*5+3)&1023;height_probe=(i*9+7)&1023;
            #1;
            if({dut.native_left,dut.native_top,dut.native_width,dut.native_height}!==previous_geometry)
                $fatal(1,"geometry changed before its registering clock");
            @(negedge dut.video_clk);
            // Exact original division/rounding is the reference, including
            // SDRAM word alignment; it is not the new reciprocal multiply.
            expected_left=(left_probe*8+4)/5;
            expected_top=(top_probe*8+4)/5;
            expected_width=((width_probe*8)/5)&~3;
            expected_height=(height_probe*8)/5;
            if(dut.native_left!==expected_left || dut.native_top!==expected_top ||
               dut.native_width!==expected_width || dut.native_height!==expected_height)
                $fatal(1,"geometry mismatch at vector %0d",i);
            if({dut.previews.native_left,dut.previews.native_top,dut.previews.native_width,dut.previews.native_height}!==
               {dut.native_left,dut.native_top,dut.native_width,dut.native_height})
                $fatal(1,"preview/SDRAM geometry mismatch at vector %0d",i);
        end
        $display("PASS actual-top geometry: 4096 exact coordinate/dimension checks, all 10-bit inputs, original rounding and word alignment, registered boundary preserved");
        $finish;
    end
    initial begin #1000000;$fatal(1,"geometry timeout");end
endmodule
