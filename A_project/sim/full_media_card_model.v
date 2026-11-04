`timescale 1ns/1ps
// Sector-service model with real BMP fixture bytes and fragmented FAT32 chains.
// This model does not emulate SPI electrical timing or the user's physical card.
module sd_card_top #(parameter integer IMAGE_COUNT=4)(
    input clk,input rst,output SD_nCS,output SD_DCLK,output SD_MOSI,input SD_MISO,
    output sd_init_done,input sd_sec_read,input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,output reg sd_sec_read_data_valid,
    output reg sd_sec_read_end,input sd_sec_write,input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data,output sd_sec_write_data_req,
    output sd_sec_write_end,input read_slow,output [7:0] sd_sec_read_error
);
    localparam PARTITION=2048,RESERVED=32,FAT_SECTORS=256,SPC=8;
    localparam FAT=PARTITION+RESERVED,DATA=FAT+2*FAT_SECTORS;
    reg [7:0] sector[0:511];
    integer files[0:5],sizes[0:5],first[0:5];
    integer i,j,rc,slot,cluster,offset,entry,value,clusters,reads=0;
    integer index=0,state=0;
    reg [255:0] filename;
    assign SD_nCS=1;assign SD_DCLK=0;assign SD_MOSI=1;
    assign sd_init_done=!rst;
    assign sd_sec_write_data_req=0;assign sd_sec_write_end=0;assign sd_sec_read_error=0;
    task le32;
        input integer at,data;
        begin
            sector[at]=data;sector[at+1]=data>>8;
            sector[at+2]=data>>16;sector[at+3]=data>>24;
        end
    endtask
    initial begin
        first[0]=4;first[1]=4096;first[2]=8192;first[3]=12288;first[4]=16384;first[5]=20480;
        for(i=0;i<IMAGE_COUNT;i=i+1) begin
            case(i)
                0:filename="doc/tf_demo/PIC1.BMP";
                1:filename="doc/tf_demo/PIC2.BMP";
                2:filename="doc/tf_demo/PIC3.BMP";
                3:filename="doc/tf_demo/PIC4.BMP";
                4:filename="doc/tf_demo/PIC1.BMP"; // sixth-slot coverage reuses known fixture pixels
                5:filename="doc/tf_demo/PIC2.BMP";
            endcase
            files[i]=$fopen(filename,"rb");
            if(!files[i]) $fatal(1,"missing full-card fixture %s",filename);
            rc=$fseek(files[i],0,2);sizes[i]=$ftell(files[i]);
            if(sizes[i]!=((i<2 || i>=4) ? 921654 : 3686454)) $fatal(1,"fixture size changed");
        end
    end
    task load_sector;
        input integer lba;
        begin
            for(j=0;j<512;j=j+1) sector[j]=0;
            if(lba==0) begin
                sector[450]=8'h0c;le32(454,PARTITION);le32(458,240544);
                sector[510]=8'h55;sector[511]=8'haa;
            end else if(lba==PARTITION) begin
                sector[0]=8'heb;sector[12]=2;sector[13]=SPC;
                sector[14]=RESERVED;sector[16]=2;
                le32(32,240544);le32(36,FAT_SECTORS);le32(44,2);
                sector[510]=8'h55;sector[511]=8'haa;
            end else if(lba>=FAT && lba<DATA) begin
                for(entry=0;entry<128;entry=entry+1) begin
                    cluster=((lba-FAT)%FAT_SECTORS)*128+entry;value=0;
                    if(cluster<=2) value=32'h0fffffff;
                    for(slot=0;slot<IMAGE_COUNT;slot=slot+1) begin
                        clusters=(sizes[slot]+SPC*512-1)/(SPC*512);
                        offset=(cluster-first[slot])/2;
                        if(cluster>=first[slot] && !(cluster&1) && offset<clusters)
                            value=offset==clusters-1 ? 32'h0fffffff : cluster+2;
                    end
                    le32(entry*4,value);
                end
            end else if(lba==DATA) begin
                for(slot=0;slot<IMAGE_COUNT;slot=slot+1) begin
                    entry=slot*32;
                    sector[entry]="P";sector[entry+1]="I";sector[entry+2]="C";
                    sector[entry+3]="1"+slot;
                    for(j=4;j<8;j=j+1) sector[entry+j]=" ";
                    sector[entry+8]="B";sector[entry+9]="M";sector[entry+10]="P";
                    sector[entry+11]=8'h20;
                    sector[entry+26]=first[slot];sector[entry+27]=first[slot]>>8;
                    le32(entry+28,sizes[slot]);
                end
            end else if(lba>=DATA) begin
                cluster=2+(lba-DATA)/SPC;
                for(slot=0;slot<IMAGE_COUNT;slot=slot+1) begin
                    clusters=(sizes[slot]+SPC*512-1)/(SPC*512);
                    if(cluster>=first[slot] && !(cluster&1) && (cluster-first[slot])/2<clusters) begin
                        offset=(cluster-first[slot])/2*SPC*512+(lba-DATA)%SPC*512;
                        rc=$fseek(files[slot],offset,0);
                        rc=$fread(sector,files[slot],0,512);
                        if(rc<=0) $fatal(1,"invalid full-card sector %0d offset %0d",lba,offset);
                    end
                end
            end
        end
    endtask
    always @(posedge clk) begin
        sd_sec_read_data_valid<=0;sd_sec_read_end<=0;
        if(rst) begin state<=0;index<=0;sd_sec_read_data<=0;end
        else case(state)
            0:if(sd_sec_read) begin
                load_sector(sd_sec_read_addr);reads=reads+1;index<=0;state<=1;
            end
            1:begin
                sd_sec_read_data<=sector[index];sd_sec_read_data_valid<=1;
                if(index==511) state<=2;else index<=index+1;
            end
            2:begin sd_sec_read_end<=1;state<=3;end
            3:if(!sd_sec_read) state<=0;
        endcase
    end
endmodule
