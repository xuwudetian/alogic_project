`timescale 1ns/1ps
// Measure emitted PCM zero crossings, independently of the DDS increment table.
module tb_audio_pitch;
    reg clk=0,rst=1;
    reg [3:0] picture=0;
    wire valid;
    wire [23:0] left,right;
    integer frequencies[0:8];
    integer p,samples,rises;
    reg signed [23:0] previous;
    always #20 clk=~clk;
    player_audio dut(.clk(clk),.rst(rst),.picture(picture),.volume(4'd8),.mute(1'b0),
        .valid(valid),.left(left),.right(right));
    initial begin
        frequencies[0]=440;frequencies[1]=550;frequencies[2]=660;
        frequencies[3]=880;frequencies[4]=1100;frequencies[5]=1320;
        frequencies[6]=1540;frequencies[7]=1760;frequencies[8]=1980;
        for(p=0;p<9;p=p+1) begin
            @(negedge clk);rst=1;picture=p;
            repeat(3) @(negedge clk);rst=0;
            samples=0;rises=0;previous=0;
            while(samples<4800) begin
                @(negedge clk);
                if(valid) begin
                    if(left!==right || left[7:0]!==0 || (^left)===1'bx)
                        $fatal(1,"invalid PCM at picture %0d",p+1);
                    if(previous<=0 && $signed(left)>0) rises=rises+1;
                    previous=left;samples=samples+1;
                end
            end
            if(rises*10<frequencies[p]-10 || rises*10>frequencies[p]+10)
                $fatal(1,"picture %0d measured %0d Hz expected %0d Hz",p+1,rises*10,frequencies[p]);
            $display("PIC%0d measured %0d Hz over 4800 PCM samples",p+1,rises*10);
        end
        $display("PASS audio pitch: nine distinct picture tones, measured from 43200 output samples");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"audio pitch timeout");end
endmodule
