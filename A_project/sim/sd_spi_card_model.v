`timescale 1ns/1ps
// Pin-level SPI slave. Commands and data are clocked by the DUT's actual SCLK.
module sd_spi_card_model #(
    parameter integer BLOCK_ADDRESSING=1,
    parameter integer MISO_DELAY_NS=8,
    parameter integer FILESYSTEM=0
) (
    input rst,input cs,input sclk,input mosi,output reg miso=1
);
    reg [7:0] queue[0:4095];
    integer head=0,tail=0,rx_bits=0,tx_bits=0,command_bytes=0;
    integer init_attempts=0,reads=0,commands=0,crc_faults=0,data_faults=0;
    reg [7:0] rx=0,tx=8'hff;
    reg [47:0] command=0;
    reg ready=0,corrupt_crc=0,bad_signature=0;
    reg bad_echo=0,bad_ocr=0,reject_read=0,bad_token=0;
    reg [31:0] last_lba=0;
    function [7:0] disk_byte;
        input [31:0] lba;
        input integer offset;
        integer base,physical;
        begin
            disk_byte=(offset ^ (offset>>8) ^ lba ^ (lba>>8));
            if(offset==510) disk_byte=bad_signature ? 8'h00 : 8'h55;
            if(offset==511) disk_byte=bad_signature ? 8'h00 : 8'haa;
            if(FILESYSTEM!=0) begin
                base=FILESYSTEM==1 ? 2048 : 0;
                disk_byte=0;
                if(FILESYSTEM==1 && lba==0) case(offset)
                    450:disk_byte=8'h0c;455:disk_byte=8'h08;
                    510:disk_byte=bad_signature ? 0 : 8'h55;
                    511:disk_byte=bad_signature ? 0 : 8'haa;
                endcase
                else if(lba==base) case(offset)
                    0:disk_byte=8'heb;12:disk_byte=2;13:disk_byte=2;
                    14:disk_byte=32;16:disk_byte=1;
                    32:disk_byte=8'ha0;33:disk_byte=8'h86;34:disk_byte=1;
                    37:disk_byte=2;44:disk_byte=2;
                    510:disk_byte=bad_signature ? 0 : 8'h55;
                    511:disk_byte=bad_signature ? 0 : 8'haa;
                endcase
                else if(lba==base+32) disk_byte=offset%4==3 ? 8'h0f : 8'hff;
                else if(lba==base+544 && offset<32) case(offset)
                    0:disk_byte="P";1:disk_byte="I";2:disk_byte="C";3:disk_byte="1";
                    4,5,6,7:disk_byte=" ";8:disk_byte="B";9:disk_byte="M";10:disk_byte="P";
                    11:disk_byte=8'h20;26:disk_byte=4;28:disk_byte=78;
                endcase
                else if(lba==base+548) begin
                    case(offset)
                        0:disk_byte="B";1:disk_byte="M";2:disk_byte=78;10:disk_byte=54;
                        14:disk_byte=40;18:disk_byte=3;22:disk_byte=2;26:disk_byte=1;28:disk_byte=24;
                        default:begin
                            physical=(offset-54)%12;
                            if(offset>=54 && offset<78 && physical<9)
                                disk_byte=physical%3==0 ? 20 : physical%3==1 ? 80 : 240;
                        end
                    endcase
                end
            end
        end
    endfunction
    function [15:0] crc16;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] c;
        integer b;
        begin
            c=previous;
            for(b=7;b>=0;b=b-1)
                c={c[14:0],1'b0} ^ ((c[15]^value[b]) ? 16'h1021 : 16'h0000);
            crc16=c;
        end
    endfunction
    task enqueue;
        input [7:0] value;
        begin
            if(tail>=4096) $fatal(1,"card response queue overflow");
            queue[tail]=value;tail=tail+1;
        end
    endtask
    task execute;
        input [47:0] packet;
        integer n;
        reg [31:0] arg;
        reg [15:0] crc;
        begin
            commands=commands+1;
            arg=packet[39:8];
            enqueue(8'hff);
            case(packet[45:40])
                0:begin ready=0;init_attempts=0;enqueue(8'h01);end
                8:begin
                    enqueue(8'h01);enqueue(0);enqueue(0);enqueue(1);
                    enqueue(bad_echo ? 8'hab : 8'haa);
                end
                55:enqueue(ready ? 8'h00 : 8'h01);
                41:begin
                    init_attempts=init_attempts+1;
                    if(init_attempts>=2) ready=1;
                    enqueue(ready ? 8'h00 : 8'h01);
                end
                58:begin
                    enqueue(ready ? 8'h00 : 8'h01);
                    enqueue(bad_ocr ? 8'h00 : (BLOCK_ADDRESSING ? 8'hc0 : 8'h80));
                    enqueue(8'hff);enqueue(8'h80);enqueue(0);
                end
                16:begin
                    if(arg!=512) $fatal(1,"unexpected CMD16 block length");
                    enqueue(0);
                end
                17:begin
                    if(!ready) $fatal(1,"CMD17 before card initialized");
                    if(!BLOCK_ADDRESSING && arg[8:0]!=0)
                        $fatal(1,"SDSC received a sector address instead of a byte address");
                    last_lba=BLOCK_ADDRESSING ? arg : arg>>9;
                    reads=reads+1;
                    if(reject_read) enqueue(8'h20);
                    else begin
                        enqueue(0);enqueue(8'hff);enqueue(8'hff);
                        if(bad_token) enqueue(8'h08);
                        else begin
                            enqueue(8'hfe);
                            crc=0;
                            for(n=0;n<512;n=n+1) begin
                                enqueue(disk_byte(last_lba,n) ^ ((n==511 && data_faults>0) ? 8'h01 : 8'h00));
                                crc=crc16(crc,disk_byte(last_lba,n));
                            end
                            if(data_faults>0) data_faults=data_faults-1;
                            if(corrupt_crc || crc_faults>0) begin
                                crc=crc^16'h0001;
                                if(crc_faults>0) crc_faults=crc_faults-1;
                            end
                            enqueue(crc[15:8]);enqueue(crc[7:0]);
                        end
                    end
                end
                default:$fatal(1,"unsupported host command %0d",packet[45:40]);
            endcase
        end
    endtask
    always @(posedge cs or posedge rst) begin
        head=0;tail=0;rx_bits=0;tx_bits=0;command_bytes=0;rx=0;tx=8'hff;miso=1;
        if(rst) begin ready=0;init_attempts=0;reads=0;commands=0;end
    end
    always @(negedge sclk) if(!cs && !rst) begin
        if(tx_bits==0) begin
            if(head<tail) begin tx=queue[head];head=head+1;end
            else tx=8'hff;
        end
        miso <= #(MISO_DELAY_NS) tx[7];
        tx={tx[6:0],1'b1};
        tx_bits=(tx_bits+1)%8;
    end
    always @(posedge sclk) if(!cs && !rst) begin
        rx={rx[6:0],mosi};
        if(rx_bits==7) begin
            rx_bits=0;
            if(command_bytes==0) begin
                if(rx[7:6]==2'b01) begin command={40'd0,rx};command_bytes=1;end
            end else begin
                command={command[39:0],rx};
                if(command_bytes==5) begin command_bytes=0;execute(command);end
                else command_bytes=command_bytes+1;
            end
        end else rx_bits=rx_bits+1;
    end
endmodule
