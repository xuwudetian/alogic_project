
// Lightweight telemetry-only UART for the A-board emergency system.
// It accepts A5 5A LEN SEQ CMD CRC8 requests and answers CMD=02 (status)
// with a compact version-2, 19-byte response. Local/network/sensor controls
// remain entirely inside player_control and are not remote-controlled here.
module player_uart_status #(
    parameter integer CLK_HZ=65000000,
    parameter integer BAUD=115200
)(
    input clk,input rst,input rx,output tx,
    input [127:0] status_payload
);
    localparam integer CPB=(CLK_HZ+BAUD/2)/BAUD;
    wire [7:0] rx_data;
    wire rx_valid,rx_bad;
    reg tx_start,byte_prepared;
    reg [7:0] tx_data;
    wire tx_busy,tx_done;
    player_uart_status_rx #(.CLKS_PER_BIT(CPB)) receiver(
        .clk(clk),.rst(rst),.rx(rx),.data(rx_data),.valid(rx_valid),.framing_error(rx_bad));
    player_uart_status_tx #(.CLKS_PER_BIT(CPB)) transmitter(
        .clk(clk),.rst(rst),.start(tx_start),.data(tx_data),.tx(tx),.busy(tx_busy),.done(tx_done));

    function [7:0] crc_byte;
        input [7:0] crc,data;
        reg [7:0] value;
        integer n;
        begin
            value=crc^data;
            for(n=0;n<8;n=n+1) value=value[7] ? (value<<1)^8'h07 : value<<1;
            crc_byte=value;
        end
    endfunction

    reg [2:0] parse_state;
    reg [7:0] request_seq,rx_crc;
    reg status_command,response_pending,sending;
    reg [4:0] send_index;
    reg [7:0] response_crc;
    // Capture the compact payload once, then pipeline byte selection and CRC.
    // Byte rotation aligns the payload with send_index[3:0], avoiding an
    // index subtractor and the large load/shift mux of a full-frame register.
    reg [127:0] snapshot;
    reg [15:0] snapshot_errors;
    wire [7:0] status_byte=snapshot[send_index[3:0]*8 +: 8];
    reg [7:0] next_byte;
    always @* begin
        case(send_index)
            0:next_byte=8'ha5;
            1:next_byte=8'h5a;
            2:next_byte=8'd19;
            3:next_byte=request_seq;
            4:next_byte=8'h82;
            5:next_byte=8'h00;
            22:next_byte=snapshot_errors[7:0];
            23:next_byte=snapshot_errors[15:8];
            24:next_byte=response_crc;
            default:next_byte=status_byte;
        endcase
    end
    reg [15:0] rx_errors;
    localparam GAP_MAX=CPB*12, GAP_BITS=$clog2(GAP_MAX+1);
    reg [GAP_BITS-1:0] rx_gap;
    wire timed_out=parse_state!=0 && rx_gap==GAP_MAX-1;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            parse_state<=0;request_seq<=0;rx_crc<=0;status_command<=0;
            response_pending<=0;sending<=0;send_index<=0;response_crc<=0;
            tx_start<=0;tx_data<=0;byte_prepared<=0;snapshot<=0;snapshot_errors<=0;rx_errors<=0;rx_gap<=0;
        end else begin
            tx_start<=0;
            if(rx_valid || parse_state==0) rx_gap<=0;
            else if(!timed_out) rx_gap<=rx_gap+1'b1;
            if(rx_bad || timed_out) begin
                parse_state<=0;status_command<=0;
                if(rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
            end
            // Drop overlapping requests without modifying the reply sequence.
            else if(rx_valid && !sending && !response_pending) begin
                case(parse_state)
                    0: if(rx_data==8'hA5) parse_state<=1;
                    1: if(rx_data==8'h5A) begin parse_state<=2;rx_crc<=0;end
                       else if(rx_data!=8'hA5) parse_state<=0;
                    2: if(rx_data==0) begin rx_crc<=crc_byte(0,rx_data);parse_state<=3;end
                       else parse_state<=0;
                    3: begin request_seq<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);parse_state<=4;end
                    4: begin status_command<=rx_data==8'h02;rx_crc<=crc_byte(rx_crc,rx_data);parse_state<=5;end
                    5: begin
                        parse_state<=0;
                        if(rx_crc==rx_data && status_command && !response_pending && !sending)
                            response_pending<=1;
                        if(rx_crc!=rx_data && rx_errors!=16'hffff) rx_errors<=rx_errors+1'b1;
                    end
                    default: parse_state<=0;
                endcase
            end
            if(!sending && response_pending) begin
                response_pending<=0;sending<=1;send_index<=0;response_crc<=0;
                snapshot<={status_payload[79:0],status_payload[127:80]};
                snapshot_errors<=rx_errors;byte_prepared<=0;
            end else if(sending && !tx_busy && !tx_start) begin
                if(!byte_prepared) begin
                    tx_data<=next_byte;byte_prepared<=1;
                end else begin
                    tx_start<=1;byte_prepared<=0;
                    if(send_index>=2 && send_index<=23) response_crc<=crc_byte(response_crc,tx_data);
                    if(send_index==24) sending<=0;
                    else send_index<=send_index+1'b1;
                end
            end
        end
    end
endmodule

module player_uart_status_rx #(parameter integer CLKS_PER_BIT=217)(
    input clk,input rst,input rx,output reg [7:0] data,
    output reg valid,output reg framing_error
);
    localparam BITS=$clog2(CLKS_PER_BIT+1);
    (* async_reg="true" *) reg [1:0] sync;
    reg [BITS-1:0] count;
    reg [2:0] state,bit_index;
    reg [7:0] shift;
    always @(posedge clk or posedge rst) begin
        if(rst) begin sync<=3;count<=0;state<=0;bit_index<=0;shift<=0;data<=0;valid<=0;framing_error<=0;end
        else begin
            sync<={sync[0],rx};valid<=0;framing_error<=0;
            case(state)
                0: if(!sync[1]) begin count<=CLKS_PER_BIT/2-1;state<=1;end
                1: if(count!=0) count<=count-1'b1;
                   else if(sync[1]) state<=0;
                   else begin count<=CLKS_PER_BIT-1;bit_index<=0;state<=2;end
                2: if(count!=0) count<=count-1'b1;
                   else begin shift<={sync[1],shift[7:1]};count<=CLKS_PER_BIT-1;
                       if(bit_index==7) state<=3;else bit_index<=bit_index+1'b1;end
                3: if(count!=0) count<=count-1'b1;
                   else if(sync[1]) begin data<=shift;valid<=1;state<=0;end
                   else begin framing_error<=1;state<=4;end
                4: if(sync[1]) state<=0;
                default: state<=0;
            endcase
        end
    end
endmodule

module player_uart_status_tx #(parameter integer CLKS_PER_BIT=217)(
    input clk,input rst,input start,input [7:0] data,
    output tx,output reg busy,output reg done
);
    localparam BITS=$clog2(CLKS_PER_BIT+1);
    reg [BITS-1:0] count;
    reg [9:0] shift;
    reg [3:0] bits_left;
    assign tx=shift[0];
    always @(posedge clk or posedge rst) begin
        if(rst) begin count<=0;shift<=10'h3ff;bits_left<=0;busy<=0;done<=0;end
        else begin
            done<=0;
            if(!busy) begin
                if(start) begin shift<={1'b1,data,1'b0};count<=CLKS_PER_BIT-1;bits_left<=10;busy<=1;end
            end else if(count!=0) count<=count-1'b1;
            else begin
                count<=CLKS_PER_BIT-1;shift<={1'b1,shift[9:1]};bits_left<=bits_left-1'b1;
                if(bits_left==1) begin busy<=0;done<=1;end
            end
        end
    end
endmodule
