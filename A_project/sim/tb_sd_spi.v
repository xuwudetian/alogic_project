`timescale 1ns/1ps
module tb_sd_spi;
    wire hc_done,sc_done,echo_done,ocr_done;
    sd_spi_case #(.BLOCK_ADDRESSING(1)) hc(hc_done);
    sd_spi_case #(.BLOCK_ADDRESSING(0)) sc(sc_done);
    sd_spi_init_case #(.BAD_ECHO(1)) echo_error(echo_done);
    sd_spi_init_case #(.BAD_ECHO(0)) ocr_error(ocr_done);
    initial begin
        wait(hc_done && sc_done && echo_done && ocr_done);
        $display("PASS SD SPI: SDHC/SDSC, payload/CRC/token/command errors, CMD8/OCR checks, exact normal/retry SCLK");
        $finish;
    end
endmodule

module sd_spi_case(output reg finished=0);
    parameter integer BLOCK_ADDRESSING=1;
    reg clk=0,rst=1,request=0,slow=0;
    always #10 clk=~clk;
    reg [31:0] lba=0;
    wire cs,sclk,mosi,miso,ready,valid,done;
    wire [7:0] data,error;
    integer count=0,checked=0,n;
    reg [15:0] crc;
    time falling_edge=0;
    sd_card_top #(.SPI_LOW_SPEED_DIV(2)) dut(
        .clk(clk),.rst(rst),.SD_nCS(cs),.SD_DCLK(sclk),.SD_MOSI(mosi),.SD_MISO(miso),
        .sd_init_done(ready),.sd_sec_read(request),.sd_sec_read_addr(lba),
        .sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(),.sd_sec_write_end(),.read_slow(slow),.sd_sec_read_error(error));
    sd_spi_card_model #(.BLOCK_ADDRESSING(BLOCK_ADDRESSING)) card(rst,cs,sclk,mosi,miso);
    always @(negedge sclk) falling_edge=$time;
    always @(posedge sclk) if(!rst && !cs && ready && falling_edge!=0)
        if($time-falling_edge!=(slow ? 200 : 80))
            $fatal(1,"wrong physical SCLK half-period: %0t",$time-falling_edge);
    always @(posedge clk) if(!rst && valid) begin
        if(!request || count>=512) $fatal(1,"unexpected SD data valid");
        if(data!==card.disk_byte(lba,count))
            $fatal(1,"SPI payload mismatch LBA=%0d byte=%0d got=%h expected=%h",
                   lba,count,data,card.disk_byte(lba,count));
        count=count+1;checked=checked+1;
    end
    task read_sector;
        input [31:0] address;
        input [7:0] expected_error;
        input integer expected_bytes;
        begin
            @(negedge clk);lba=address;count=0;request=1;
            wait(done);@(negedge clk);
            if(count!=expected_bytes) $fatal(1,"sector ended with %0d bytes",count);
            if(error!=expected_error) $fatal(1,"SD driver error %h expected %h",error,expected_error);
            request=0;
            repeat(12) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        crc=0;
        for(n=1;n<=9;n=n+1) crc=dut.sd_card_cmd_m0.crc16_byte(crc,"0"+n);
        if(crc!=16'h31c3) $fatal(1,"CRC16 check vector 123456789");
        wait(ready);
        read_sector(0,0,512);read_sector(2048,0,512);read_sector(2055,0,512);
        card.corrupt_crc=1;read_sector(16,8'h14,512);card.corrupt_crc=0;
        card.bad_token=1;read_sector(17,8'h15,0);card.bad_token=0;
        card.reject_read=1;read_sector(18,8'h13,0);card.reject_read=0;
        slow=1;repeat(12) @(negedge clk);
        read_sector(2048,0,512);
        if(card.reads!=7) $fatal(1,"duplicate sector request");
        $display("PASS SD SPI case: block_addressing=%0d, 7 requests, %0d payload bytes",BLOCK_ADDRESSING,checked);
        finished=1;
    end
    initial begin
        #20000000;
        if(!finished) $fatal(1,"SD SPI timeout: commands=%0d reads=%0d",card.commands,card.reads);
    end
endmodule

module sd_spi_init_case(output reg finished=0);
    parameter integer BAD_ECHO=1;
    reg clk=0,rst=1;
    always #10 clk=~clk;
    wire cs,sclk,mosi,miso,ready;
    wire [7:0] error;
    sd_card_top #(.SPI_LOW_SPEED_DIV(2)) dut(
        .clk(clk),.rst(rst),.SD_nCS(cs),.SD_DCLK(sclk),.SD_MOSI(mosi),.SD_MISO(miso),
        .sd_init_done(ready),.sd_sec_read(1'b0),.sd_sec_read_addr(32'd0),
        .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
        .read_slow(1'b0),.sd_sec_read_error(error));
    sd_spi_card_model card(rst,cs,sclk,mosi,miso);
    initial begin
        card.bad_echo=BAD_ECHO;card.bad_ocr=!BAD_ECHO;
        repeat(5) @(negedge clk);rst=0;
        wait(error!=0);
        repeat(20) @(negedge clk);
        if(error!=8'h12 || ready || card.reads!=0)
            $fatal(1,"invalid CMD8/OCR was accepted");
        finished=1;
    end
    initial begin
        #2000000;
        if(!finished) $fatal(1,"invalid initialization response timeout");
    end
endmodule
