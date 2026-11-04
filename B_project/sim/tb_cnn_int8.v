`timescale 1ns/1ps
`include "model_status.vh"
module tb_cnn_int8;
    parameter REFINE=`MODEL_REFINE;
    parameter TAIL_CHANNELS=`MODEL_TAIL_CHANNELS;
    parameter REFINE_KERNEL=`MODEL_REFINE_KERNEL;
    localparam GAP_VALUES=REFINE ? TAIL_CHANNELS : 32;
    localparam FEATURE_WORDS=REFINE ? 2240+6*TAIL_CHANNELS : 2304;
    parameter MODEL_DIR="model";
    parameter VERIFY_DIR="sim/generated/trained";
    reg clk=0;
    always #10 clk=~clk; // 50 MHz
    reg rst_n=0, load_valid=0, start=0;
    reg [11:0] load_addr=0;
    reg [23:0] load_rgb=0;
    wire load_ready, busy, done;
    wire [1:0] class_id;
    wire signed [31:0] logits0,logits1,logits2;
    wire [31:0] cycle_count;
    damage_mobilenet_int8 #(
        .REFINE(REFINE),.REFINE_KERNEL(REFINE_KERNEL),
        .TAIL_CHANNELS(TAIL_CHANNELS),
        .WEIGHTS_FILE({MODEL_DIR,"/weights.hex"}),
        .BIAS_FILE({MODEL_DIR,"/bias.hex"}),
        .SHIFTS_FILE({MODEL_DIR,"/shifts.hex"})
    ) dut (clk,rst_n,load_valid,load_ready,load_addr,load_rgb,start,
        busy,done,class_id,logits0,logits1,logits2,cycle_count);

    reg [23:0] input_pixels [0:4095];
    reg [63:0] expected_features [0:FEATURE_WORDS-1];
    reg [7:0] expected_gap [0:GAP_VALUES-1];
    reg signed [31:0] expected_logits [0:2];
    integer offset [0:8];
    integer n, writes=0, index, best;
    initial begin
        $readmemh({VERIFY_DIR,"/input_rgb.hex"},input_pixels);
        $readmemh({VERIFY_DIR,"/expected_features.hex"},expected_features);
        $readmemh({VERIFY_DIR,"/expected_gap.hex"},expected_gap);
        $readmemh({VERIFY_DIR,"/expected_logits.hex"},expected_logits);
        offset[0]=0;offset[1]=1024;offset[2]=1280;offset[3]=1792;
        offset[4]=1920;offset[5]=2176;offset[6]=2240;
        offset[7]=2240+2*TAIL_CHANNELS;offset[8]=2240+4*TAIL_CHANNELS;
        repeat(5) @(negedge clk);
        rst_n=1;
        for(n=0;n<4096;n=n+1) begin
            @(negedge clk);
            if(!load_ready) $fatal(1,"load_ready unexpectedly low");
            load_valid=1;load_addr=n;load_rgb=input_pixels[n];
        end
        @(negedge clk);load_valid=0;start=1;
        @(negedge clk);start=0;
        wait(done); #1;
        if(writes!==FEATURE_WORDS) $fatal(1,"feature writes %0d != %0d",writes,FEATURE_WORDS);
        for(n=0;n<GAP_VALUES;n=n+1)
            if(dut.gap_vector[n]!==expected_gap[n])
                $fatal(1,"GAP channel %0d got=%0d expected=%0d",n,dut.gap_vector[n],expected_gap[n]);
        if(logits0!==expected_logits[0] || logits1!==expected_logits[1] ||
           logits2!==expected_logits[2])
            $fatal(1,"logits mismatch: %0d %0d %0d",logits0,logits1,logits2);
        best=0;
        for(n=1;n<3;n=n+1) if(expected_logits[n]>expected_logits[best]) best=n;
        if(class_id!==best[1:0]) $fatal(1,"class mismatch got=%0d expected=%0d",class_id,best);
        if(cycle_count>273000) $fatal(1,"Latency budget exceeded: %0d",cycle_count);
        $display("PASS: %0d feature words (%0d activations), %0d GAP values and 3 logits match.",FEATURE_WORDS,FEATURE_WORDS*8,GAP_VALUES);
        $display("RESULT cycles=%0d latency_us=%0d class=%0d logits=%0d,%0d,%0d",
            cycle_count,cycle_count/50,class_id,logits0,logits1,logits2);
        @(posedge clk); #1;
        if(done || busy || !load_ready) $fatal(1,"done pulse or idle handshake failed");
        $finish;
    end
    always @(posedge clk) begin
        if(rst_n && dut.state==6) begin
            index=offset[dut.layer]+dut.feature_write_addr;
            if(dut.quantized_word!==expected_features[index])
                $fatal(1,"Feature mismatch layer=%0d x=%0d y=%0d group=%0d address=%0d got=%016h expected=%016h",
                    dut.layer,dut.out_x,dut.out_y,dut.out_group,dut.feature_write_addr,
                    dut.quantized_word,expected_features[index]);
            writes=writes+1;
        end
        if(busy && load_ready) $fatal(1,"Load accepted during inference");
    end
    initial begin
        repeat(310000) @(posedge clk);
        $fatal(1,"Timeout");
    end
endmodule
