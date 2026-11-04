`timescale 1ns/1ps
module tb_media_error;
    reg clk=0,rst=1;
    wire [7:0] status;
    wire [23:0] pcm;
    always #5 clk=~clk;
    media_wav dut(.clk(clk),.rst(rst),.enable(1'b0),.found(1'b0),.cluster(32'd0),.size(32'd0),
        .spc(8'd1),.fat_lba(32'd0),.data_lba(32'd0),.max_cluster(32'd100),.sector_busy(1'b0),
        .sector_valid(1'b0),.sector_byte(8'd0),.byte_index(9'd0),.sector_done(1'b0),.sector_error(8'd0),
        .audio_clk(clk),.audio_rst(rst),.tick(1'b1),.tone(24'h123400),.volume(4'd8),.mute(1'b0),.pcm(pcm),.status(status));
    initial begin
        repeat(3) @(negedge clk);rst=0;
        force dut.file_done=1;force dut.file_error=8'h26;
        @(negedge clk);release dut.file_done;release dut.file_error;
        force dut.parse_error=8'h53;repeat(10) @(negedge clk);
        if(status!=8'h54 || pcm!=24'h123400) $fatal(1,"transport root cause overwritten or fallback broken");
        release dut.parse_error;rst=1;repeat(3) @(negedge clk);rst=0;
        force dut.parse_error=8'h51;repeat(3) @(negedge clk);
        if(status!=8'h51) $fatal(1,"format errors hidden");
        release dut.parse_error;
        $display("PASS media error: W54 survives secondary W53, tone fallback, independent format error retained");$finish;
    end
endmodule
