`timescale 1ns/1ps
module tb_uart_telemetry;
    localparam CPB=564;
    reg clk=0,rst=1,rx=1;
    wire tx;
    reg [127:0] status_payload=128'hffdd430201090ac409031234e1024142;
    reg [127:0] captured_status;
    reg [7:0] received[0:511];
    integer count=0,i,base;
    reg [7:0] value,check_crc;
    player_uart_status #(.CLK_HZ(65000000),.BAUD(115200)) dut(.*);
    // 65 MHz, matching the production video/UART clock.
    always #7.692 clk=~clk;
    function [7:0] crc;
        input [7:0] c,d;
        reg [7:0] v;
        integer k;
        begin
            v=c^d;
            for(k=0;k<8;k=k+1) v=v[7] ? (v<<1)^8'h07 : v<<1;
            crc=v;
        end
    endfunction
    task send_byte;
        input [7:0] data;
        integer bit_no;
        begin
            @(negedge clk);rx=0;repeat(CPB) @(negedge clk);
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin
                rx=data[bit_no];repeat(CPB) @(negedge clk);
            end
            rx=1;repeat(CPB) @(negedge clk);
        end
    endtask
    task request;
        input [7:0] seq,cmd;
        input bad;
        begin
            send_byte(8'ha5);send_byte(8'h5a);send_byte(0);
            send_byte(seq);send_byte(cmd);send_byte(crc(crc(0,seq),cmd)^{7'd0,bad});
        end
    endtask
    task verify;
        input integer start;
        input [7:0] seq;
        input [127:0] payload;
        input [15:0] errors;
        integer j;
        reg [7:0] c;
        begin
            wait(count>=start+25);
            if(received[start]!=8'ha5 || received[start+1]!=8'h5a || received[start+2]!=19 ||
                received[start+3]!=seq || received[start+4]!=8'h82 || received[start+5]!=0)
                $fatal(1,"response header or sequence mismatch");
            for(j=0;j<16;j=j+1)
                if(received[start+6+j]!==payload[j*8+:8]) $fatal(1,"snapshot mismatch at byte %0d",j);
            if({received[start+23],received[start+22]}!==errors) $fatal(1,"error count mismatch");
            c=0;for(j=2;j<24;j=j+1) c=crc(c,received[start+j]);
            if(c!==received[start+24]) $fatal(1,"CRC mismatch");
        end
    endtask
    // Independently sample start/data/stop bits from the physical TX line.
    initial forever begin
        @(negedge tx);
        repeat(CPB+CPB/2) @(posedge clk);
        for(i=0;i<8;i=i+1) begin
            value[i]=tx;repeat(CPB) @(posedge clk);
        end
        if(tx!==1) $fatal(1,"TX stop bit invalid");
        received[count]=value;count=count+1;
    end
    initial begin
        repeat(10) @(negedge clk);rst=0;
        captured_status=status_payload;
        request(8'h17,8'h02,0);
        wait(count==1);status_payload=~status_payload;
        // An overlapping request must not change the in-flight sequence/data.
        request(8'h18,8'h02,0);
        verify(0,8'h17,captured_status,0);
        repeat(CPB*20) @(negedge clk);
        if(count!=25) $fatal(1,"overlapping request generated unwanted response");
        request(8'h19,8'h02,1);
        repeat(CPB*15) @(negedge clk);
        if(count!=25) $fatal(1,"bad CRC accepted");
        request(8'h20,8'h10,0);
        repeat(CPB*15) @(negedge clk);
        if(count!=25) $fatal(1,"unsupported command accepted");
        send_byte(8'ha5);send_byte(8'h5a);
        repeat(CPB*16) @(negedge clk);
        request(8'h21,8'h02,0);
        verify(25,8'h21,status_payload,2);
        // A held-low input is one framing error, not an error per clock.
        repeat(CPB*3) @(negedge clk);
        rx=0;repeat(CPB*15) @(negedge clk);rx=1;
        repeat(CPB*3) @(negedge clk);
        request(8'h22,8'h02,0);
        verify(50,8'h22,status_payload,3);
        repeat(CPB*3) @(negedge clk);
        dut.rx_errors=16'hfffe;
        request(8'h23,8'h02,1);
        request(8'h24,8'h02,1);
        request(8'h25,8'h02,0);
        verify(75,8'h25,status_payload,16'hffff);
        repeat(CPB*2) @(negedge clk);rst=1;
        repeat(10) @(negedge clk);rst=0;
        request(8'h26,8'h02,0);
        verify(100,8'h26,status_payload,0);
        $writememh("uart_frames.hex", received, 0, count-1);
        $display("PASS uart_status: 115200 framing, compact snapshot, CRC, busy sequence, timeout, framing error, saturated error count, reset");
        $finish;
    end
    initial begin #40000000; $fatal(1,"UART test timeout");end
endmodule
