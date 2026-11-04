`timescale 1ns/1ps
// Streaming RIFF parser. Chunk lengths, not a fixed 44-byte header, locate PCM.
module wav_pcm_parser(
    input clk,input rst,input start,input [31:0] file_size,
    input valid,input [7:0] data,input [31:0] offset,input file_end,
    output reg sample_valid,output reg [15:0] sample,
    output reg accepted,output reg complete,output reg [7:0] error
);
    localparam RIFF=0,HEADER=1,BODY=2,PAD=3,END=4,BAD=5;
    reg [2:0] state;
    reg [3:0] count;
    reg [31:0] riff_size,chunk_id,chunk_size,remaining,body_index;
    reg [15:0] format_tag,channels,align;
    reg [31:0] rate,byte_rate;
    reg [7:0] bits_lo,pcm_lo;
    reg fmt_ok,data_seen,data_finished,odd;
    wire [31:0] length_now={data,chunk_size[23:0]};
    task reject;
        input [7:0] code;
        begin error<=code;state<=BAD;accepted<=0;end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=END;count<=0;riff_size<=0;chunk_id<=0;chunk_size<=0;
            remaining<=0;body_index<=0;format_tag<=0;channels<=0;align<=0;
            rate<=0;byte_rate<=0;bits_lo<=0;pcm_lo<=0;fmt_ok<=0;
            data_seen<=0;data_finished<=0;odd<=0;
            sample_valid<=0;sample<=0;accepted<=0;complete<=0;error<=0;
        end else begin
            sample_valid<=0;complete<=0;
            if(start) begin
                state<=RIFF;count<=0;error<=0;accepted<=0;fmt_ok<=0;
                data_seen<=0;data_finished<=0;riff_size<=0;chunk_size<=0;
                if(file_size<44) reject(8'h51);
            end else if(valid) case(state)
                RIFF: begin
                    count<=count+1'b1;
                    case(count)
                        0:if(data!="R") reject(8'h51);
                        1:if(data!="I") reject(8'h51);
                        2,3:if(data!="F") reject(8'h51);
                        4:riff_size[7:0]<=data;
                        5:riff_size[15:8]<=data;
                        6:riff_size[23:16]<=data;
                        7:if({data,riff_size[23:0]}!=file_size-8) reject(8'h51);
                        8:if(data!="W") reject(8'h51);
                        9:if(data!="A") reject(8'h51);
                        10:if(data!="V") reject(8'h51);
                        11:if(data!="E") reject(8'h51);
                           else begin state<=HEADER;count<=0;end
                    endcase
                end
                HEADER: begin
                    count<=count+1'b1;
                    case(count)
                        0:chunk_id[7:0]<=data;
                        1:chunk_id[15:8]<=data;
                        2:chunk_id[23:16]<=data;
                        3:chunk_id[31:24]<=data;
                        4:chunk_size[7:0]<=data;
                        5:chunk_size[15:8]<=data;
                        6:chunk_size[23:16]<=data;
                        7:begin
                            remaining<=length_now;body_index<=0;odd<=length_now[0];
                            count<=0;state<=length_now==0 ? (offset==file_size-1 ? END : HEADER) : BODY;
                            if(offset>=file_size || length_now>file_size-offset-1 ||
                               (length_now[0] && length_now==file_size-offset-1))
                                reject(8'h51);
                            else if(chunk_id==32'h20746d66) begin
                                if(fmt_ok || length_now<16 || data_seen) reject(8'h52);
                            end else if(chunk_id==32'h61746164) begin
                                if(!fmt_ok || data_seen || length_now==0 || length_now[0])
                                    reject(8'h52);
                                else begin accepted<=1;data_seen<=1;end
                            end
                        end
                    endcase
                end
                BODY: begin
                    remaining<=remaining-1'b1;body_index<=body_index+1'b1;
                    if(chunk_id==32'h20746d66) case(body_index)
                        0:format_tag[7:0]<=data;
                        1:format_tag[15:8]<=data;
                        2:channels[7:0]<=data;
                        3:channels[15:8]<=data;
                        4:rate[7:0]<=data;
                        5:rate[15:8]<=data;
                        6:rate[23:16]<=data;
                        7:rate[31:24]<=data;
                        8:byte_rate[7:0]<=data;
                        9:byte_rate[15:8]<=data;
                        10:byte_rate[23:16]<=data;
                        11:byte_rate[31:24]<=data;
                        12:align[7:0]<=data;
                        13:align[15:8]<=data;
                        14:bits_lo<=data;
                        15:begin
                            fmt_ok<=format_tag==1 && channels==1 && rate==48000 &&
                                    byte_rate==96000 && align==2 && {data,bits_lo}==16;
                        end
                    endcase
                    if(chunk_id==32'h61746164) begin
                        if(!body_index[0]) pcm_lo<=data;
                        else begin sample<={data,pcm_lo};sample_valid<=1;end
                    end
                    if(remaining==1) begin
                        state<=odd ? PAD : (offset==file_size-1 ? END : HEADER);
                        count<=0;
                        if(chunk_id==32'h61746164) data_finished<=1;
                    end
                end
                PAD: begin state<=offset==file_size-1 ? END : HEADER;count<=0;end
                default:begin end
            endcase
            if(file_end) begin
                complete<=1;
                if(error==0 && !(data_finished && state==END)) reject(8'h53);
            end
        end
    end
endmodule
