// MobileNet-V1 micro INT8; six spatial outputs x eight output channels.
// Three-phase prefetch sustains 48 products every three clocks using two RAM
// replicas. No changes to external load/start/done or model arithmetic.
// Verilog-2001. Partial right-edge groups write only valid output pixels.
module damage_mobilenet_int8 #(
    parameter REFINE = 0,
    parameter TAIL_CHANNELS = 32,
    parameter REFINE_KERNEL = 3,
    parameter WEIGHTS_FILE = "model/weights.hex",
    parameter BIAS_FILE = "model/bias.hex",
    parameter SHIFTS_FILE = "model/shifts.hex"
) (
    input wire clk,
    input wire rst_n,
    input wire load_valid,
    output wire load_ready,
    input wire [11:0] load_addr,
    input wire [23:0] load_rgb,
    input wire start,
    output reg busy,
    output reg done,
    output reg [1:0] class_id,
    output reg signed [31:0] logits0,
    output reg signed [31:0] logits1,
    output reg signed [31:0] logits2,
    output reg [31:0] cycle_count
);
    localparam ST_IDLE=0, ST_SETUP=1, ST_BIAS=2, ST_READ=3,
        ST_MAC=4, ST_QUANT=5, ST_WRITE=6, ST_GAP_CLEAR=7,
        ST_GAP_READ=8, ST_GAP_ADD=9, ST_GAP_SAVE=10, ST_ARGMAX=11, ST_FETCH=12;
    reg [3:0] state;
    localparam FC_LAYER=REFINE ? 9 : 7;
    localparam LAST_CONV=REFINE ? 8 : 6;
    localparam TAIL=REFINE ? TAIL_CHANNELS : 32;
    localparam TAIL_GROUPS=TAIL/8;
    localparam TAIL_LOG_GROUPS=(TAIL==64) ? 3 : 2;
    localparam REFINE_WEIGHT_BASE=170+TAIL_GROUPS*32;
    localparam REFINE_BIAS_BASE=14+TAIL_GROUPS;
    localparam REFINE_TAPS=(REFINE_KERNEL==1)?1:9;
    localparam FINAL_PW_WEIGHT_BASE=REFINE_WEIGHT_BASE+TAIL_GROUPS*REFINE_TAPS;
    localparam FINAL_PW_BIAS_BASE=REFINE_BIAS_BASE+TAIL_GROUPS;
    localparam FC_WEIGHT_BASE=FINAL_PW_WEIGHT_BASE+TAIL_GROUPS*TAIL;
    localparam FC_BIAS_BASE=FINAL_PW_BIAS_BASE+TAIL_GROUPS;
    reg [3:0] layer;
    reg [5:0] out_x, out_y;
    reg [2:0] out_group;
    reg [6:0] input_channel;
    reg [1:0] kernel_x, kernel_y;
    reg [6:0] tap_index;
    reg [3:0] gap_pixel;
    reg [2:0] gap_group;
    reg [7:0] gap_vector [0:TAIL-1];

    // Two read replicas: each holds 12 KiB RGB + 8 KiB A + 2 KiB B.
    // A pixel stores consecutive groups of 8 channels in a 64-bit word.
    // Explicit M32K input storage frees M9K blocks for the wider tail ROM.
    // Four blocks hold two 4096x16 planes; the upper plane uses eight bits.
    (* ram_style = "bram" *) reg [63:0] feature_a [0:1023];
    (* ram_style = "bram" *) reg [63:0] feature_b [0:255];
    (* ram_style = "bram" *) reg [63:0] feature_a_second [0:1023];
    (* ram_style = "dram" *) reg [63:0] feature_b_second [0:255];
    localparam WEIGHT_WORDS=REFINE ? FC_WEIGHT_BASE+TAIL : 330;
    localparam BIAS_WORDS=REFINE ? FC_BIAS_BASE+1 : 19;
    (* force_ram, ram_style = "bram", rom_style = "bram" *) reg [63:0] weights_rom [0:2047];
    (* force_ram, ram_style = "bram", rom_style = "bram" *) reg [255:0] bias_rom [0:63];
    reg [7:0] shifts_rom [0:FC_LAYER];
    integer init_address;
    initial begin
        for(init_address=0;init_address<2048;init_address=init_address+1) weights_rom[init_address]=0;
        for(init_address=0;init_address<64;init_address=init_address+1) bias_rom[init_address]=0;
        $readmemh(WEIGHTS_FILE, weights_rom, 0, WEIGHT_WORDS-1);
        $readmemh(BIAS_FILE, bias_rom, 0, BIAS_WORDS-1);
        $readmemh(SHIFTS_FILE, shifts_rom);
    end

    wire [23:0] input_q;
    wire [15:0] input_high_q;
    wire [23:0] input_second_q;
    wire [15:0] input_second_high_q;
    reg [63:0] feature_a_q, feature_b_q, weights_q;
    reg [63:0] feature_a_second_q, feature_b_second_q;
    reg [255:0] bias_q;
    reg padding_q, padding_second_q;
    localparam PIXELS=6;
    reg [63:0] quantized [0:PIXELS-1];
    reg [2:0] write_index;
    wire [63:0] quantized_word=quantized[write_index];
    reg [63:0] prefetched [0:3];
    reg [6:0] mac_input_channel;
    wire [6:0] activation_channel=mac_input_channel;
    reg [6:0] read_out_x;
    reg last_tap;
    reg [11:0] input_read_addr;
    reg [11:0] input_second_read_addr;
    reg [9:0] feature_read_addr, feature_write_addr;
    reg [9:0] feature_second_read_addr;
    reg [10:0] weight_read_addr;
    reg [5:0] bias_read_addr;
    reg padding, padding_second;
    assign load_ready = !busy;
    video_frame_ram #(.WORDS(4096),.BANKS(2)) input_low_ram(
        .write_clk(clk),.write_enable(load_valid && load_ready),
        .write_address({3'd0,load_addr}),.write_data(load_rgb[15:0]),
        .read_clk(clk),.read_enable(1'b1),.read_address({3'd0,input_read_addr}),.read_data(input_q[15:0]));
    video_frame_ram #(.WORDS(4096),.BANKS(2)) input_high_ram(
        .write_clk(clk),.write_enable(load_valid && load_ready),
        .write_address({3'd0,load_addr}),.write_data({8'd0,load_rgb[23:16]}),
        .read_clk(clk),.read_enable(1'b1),.read_address({3'd0,input_read_addr}),.read_data(input_high_q));
    assign input_q[23:16]=input_high_q[7:0];
    video_frame_ram #(.WORDS(4096),.BANKS(2)) input_second_low_ram(
        .write_clk(clk),.write_enable(load_valid && load_ready),
        .write_address({3'd0,load_addr}),.write_data(load_rgb[15:0]),
        .read_clk(clk),.read_enable(1'b1),.read_address({3'd0,input_second_read_addr}),.read_data(input_second_q[15:0]));
    video_frame_ram #(.WORDS(4096),.BANKS(2)) input_second_high_ram(
        .write_clk(clk),.write_enable(load_valid && load_ready),
        .write_address({3'd0,load_addr}),.write_data({8'd0,load_rgb[23:16]}),
        .read_clk(clk),.read_enable(1'b1),.read_address({3'd0,input_second_read_addr}),.read_data(input_second_high_q));
    assign input_second_q[23:16]=input_second_high_q[7:0];

    // No reset loop on memory arrays: they infer embedded synchronous RAM.
    always @(posedge clk) begin
        feature_a_q <= feature_a[feature_read_addr];
        feature_b_q <= feature_b[feature_read_addr[7:0]];
        feature_a_second_q <= feature_a_second[feature_second_read_addr];
        feature_b_second_q <= feature_b_second[feature_second_read_addr[7:0]];
        weights_q <= weights_rom[weight_read_addr];
        bias_q <= bias_rom[bias_read_addr];
        padding_q <= padding;
        padding_second_q <= padding_second;
        if (state == ST_WRITE && !layer[0]) begin
            feature_a[feature_write_addr] <= quantized_word;
            feature_a_second[feature_write_addr] <= quantized_word;
        end
        if (state == ST_WRITE && layer[0]) begin
            feature_b[feature_write_addr[7:0]] <= quantized_word;
            feature_b_second[feature_write_addr[7:0]] <= quantized_word;
        end
    end

    reg depthwise;
    reg [6:0] in_size, out_size;
    reg [6:0] in_channels;
    reg [3:0] out_groups;
    reg [2:0] in_log_size, out_log_size;
    reg [1:0] in_log_groups, out_log_groups;
    reg [6:0] taps_per_group;
    reg [10:0] weight_base;
    reg [5:0] bias_base;
    always @* begin
        depthwise=0; in_size=64; out_size=32; in_channels=3;
        out_groups=1; in_log_size=6; out_log_size=5;
        in_log_groups=0; out_log_groups=0; taps_per_group=27;
        weight_base=0; bias_base=0;
        case (layer)
            1: begin depthwise=1; in_size=32; out_size=16; in_channels=8;
                in_log_size=5; out_log_size=4; taps_per_group=9;
                weight_base=27; bias_base=1; end
            2: begin in_size=16; out_size=16; in_channels=8; out_groups=2;
                in_log_size=4; out_log_size=4; out_log_groups=1;
                taps_per_group=8; weight_base=36; bias_base=2; end
            3: begin depthwise=1; in_size=16; out_size=8; in_channels=16; out_groups=2;
                in_log_size=4; out_log_size=3; in_log_groups=1; out_log_groups=1;
                taps_per_group=9; weight_base=52; bias_base=4; end
            4: begin in_size=8; out_size=8; in_channels=16; out_groups=4;
                in_log_size=3; out_log_size=3; in_log_groups=1; out_log_groups=2;
                taps_per_group=16; weight_base=70; bias_base=6; end
            5: begin depthwise=1; in_size=8; out_size=4; in_channels=32; out_groups=4;
                in_log_size=3; out_log_size=2; in_log_groups=2; out_log_groups=2;
                taps_per_group=9; weight_base=134; bias_base=10; end
            6: begin in_size=4; out_size=4; in_channels=32; out_groups=TAIL_GROUPS;
                in_log_size=2; out_log_size=2; in_log_groups=2; out_log_groups=TAIL_LOG_GROUPS;
                taps_per_group=32; weight_base=170; bias_base=14; end
            7: begin in_size=1; out_size=1; in_channels=32; out_groups=1;
                in_log_size=0; out_log_size=0; taps_per_group=32;
                weight_base=298; bias_base=18;
                if(REFINE) begin depthwise=1;in_size=4;out_size=4;in_channels=TAIL;out_groups=TAIL_GROUPS;
                    in_log_size=2;out_log_size=2;in_log_groups=TAIL_LOG_GROUPS;out_log_groups=TAIL_LOG_GROUPS;taps_per_group=REFINE_TAPS;
                    weight_base=REFINE_WEIGHT_BASE;bias_base=REFINE_BIAS_BASE;end
                end
            8: begin in_size=4;out_size=4;in_channels=TAIL;out_groups=TAIL_GROUPS;
                in_log_size=2;out_log_size=2;in_log_groups=TAIL_LOG_GROUPS;out_log_groups=TAIL_LOG_GROUPS;
                taps_per_group=TAIL;weight_base=FINAL_PW_WEIGHT_BASE;bias_base=FINAL_PW_BIAS_BASE;end
            9: begin in_size=1;out_size=1;in_channels=TAIL;out_groups=1;
                in_log_size=0;out_log_size=0;taps_per_group=TAIL;
                weight_base=FC_WEIGHT_BASE;bias_base=FC_BIAS_BASE;end
            default: begin end
        endcase
    end

    reg signed [7:0] source_x, source_y, source_second_x;
    reg [11:0] source_pixel, source_second_pixel, output_pixel;
    reg [10:0] group_weight_offset;
    always @* begin
        if (layer == 0 || depthwise) begin
            source_x = $signed({read_out_x[5:0],1'b0}) + $signed({6'd0,kernel_x}) - 8'sd1;
            source_y = $signed({1'b0,out_y,1'b0}) + $signed({6'd0,kernel_y}) - 8'sd1;
            if(REFINE && layer==7) begin
                source_x=$signed({1'b0,read_out_x})+$signed({6'd0,kernel_x})-8'sd1;
                source_y=$signed({2'd0,out_y})+$signed({6'd0,kernel_y})-8'sd1;
                if(REFINE_KERNEL==1) begin
                    source_x=$signed({1'b0,read_out_x});
                    source_y=$signed({2'd0,out_y});
                end
            end
        end else begin
            source_x = $signed({1'b0,read_out_x});
            source_y = $signed({2'd0,out_y});
        end
        padding = source_x < 0 || source_y < 0 ||
            source_x >= $signed({1'b0,in_size}) || source_y >= $signed({1'b0,in_size});
        source_second_x = source_x + ((layer == 0 || depthwise) ? 8'sd2 : 8'sd1);
        if (REFINE && layer == 7) source_second_x = source_x + 8'sd1;
        padding_second = source_second_x < 0 || source_y < 0 ||
            source_second_x >= $signed({1'b0,in_size}) || source_y >= $signed({1'b0,in_size});
        case(in_log_size)
            6: begin source_pixel={source_y[5:0],source_x[5:0]};source_second_pixel={source_y[5:0],source_second_x[5:0]};end
            5: begin source_pixel={2'd0,source_y[4:0],source_x[4:0]};source_second_pixel={2'd0,source_y[4:0],source_second_x[4:0]};end
            4: begin source_pixel={4'd0,source_y[3:0],source_x[3:0]};source_second_pixel={4'd0,source_y[3:0],source_second_x[3:0]};end
            3: begin source_pixel={6'd0,source_y[2:0],source_x[2:0]};source_second_pixel={6'd0,source_y[2:0],source_second_x[2:0]};end
            2: begin source_pixel={8'd0,source_y[1:0],source_x[1:0]};source_second_pixel={8'd0,source_y[1:0],source_second_x[1:0]};end
            default: begin source_pixel=0;source_second_pixel=0;end
        endcase
        output_pixel = ({6'd0,out_y} << out_log_size) + {6'd0,out_x} + {9'd0,write_index};
        input_read_addr = padding ? 12'd0 : source_pixel;
        input_second_read_addr = padding_second ? 12'd0 : source_second_pixel;
        feature_read_addr = (source_pixel << in_log_groups) |
            (depthwise ? {7'd0,out_group} : {7'd0,input_channel[5:3]});
        feature_second_read_addr = (source_second_pixel << in_log_groups) |
            (depthwise ? {7'd0,out_group} : {7'd0,input_channel[5:3]});
        if (state >= ST_GAP_CLEAR && state <= ST_GAP_SAVE)
            feature_read_addr = ({6'd0,gap_pixel} << TAIL_LOG_GROUPS) + {7'd0,gap_group};
        feature_write_addr = (output_pixel << out_log_groups) + {7'd0,out_group};
        // Only shifts and adds: the address generator consumes no multipliers.
        case (taps_per_group)
            1: group_weight_offset = {8'd0,out_group};
            8: group_weight_offset = {5'd0,out_group,3'd0};
            9: group_weight_offset = {5'd0,out_group,3'd0} + {8'd0,out_group};
            16: group_weight_offset = {4'd0,out_group,4'd0};
            32: group_weight_offset = {3'd0,out_group,5'd0};
            64: group_weight_offset = {2'd0,out_group,6'd0};
            default: group_weight_offset = 0; // first conv has one output group
        endcase
        weight_read_addr = weight_base + group_weight_offset + {4'd0,tap_index};
        bias_read_addr = bias_base + {3'd0,out_group};
    end

    reg [63:0] activation_bus, activation_second_bus, weight_bus;
    reg [255:0] bias_bus;
    reg [63:0] source_word, source_second_word;
    reg signed [7:0] scalar_activation, scalar_second_activation;
    reg mac_enable, bias_load;
    always @* begin
        source_word = layer[0] ? feature_a_q : feature_b_q;
        source_second_word = layer[0] ? feature_a_second_q : feature_b_second_q;
        scalar_activation = $signed(source_word[activation_channel[2:0]*8 +: 8]);
        scalar_second_activation = $signed(source_second_word[activation_channel[2:0]*8 +: 8]);
        if (layer == 0) begin
            case (activation_channel)
                0: scalar_activation = $signed({1'b0,input_q[23:17]}) - 8'sd64;
                1: scalar_activation = $signed({1'b0,input_q[15:9]}) - 8'sd64;
                default: scalar_activation = $signed({1'b0,input_q[7:1]}) - 8'sd64;
            endcase
            case (activation_channel)
                0: scalar_second_activation = $signed({1'b0,input_second_q[23:17]}) - 8'sd64;
                1: scalar_second_activation = $signed({1'b0,input_second_q[15:9]}) - 8'sd64;
                default: scalar_second_activation = $signed({1'b0,input_second_q[7:1]}) - 8'sd64;
            endcase
        end
        if (layer == FC_LAYER) scalar_activation = $signed(gap_vector[activation_channel[5:0]]);
        activation_bus = depthwise ? source_word : {8{scalar_activation}};
        activation_second_bus = depthwise ? source_second_word : {8{scalar_second_activation}};
        if (padding_q && layer != FC_LAYER) activation_bus = 64'd0;
        if (padding_second_q) activation_second_bus = 64'd0;
        weight_bus = weights_q;
        bias_bus = bias_q;
        mac_enable = state == ST_MAC || state == ST_GAP_ADD;
        bias_load = state == ST_BIAS || state == ST_GAP_CLEAR;
        if (state == ST_GAP_CLEAR) bias_bus = 256'd0;
        if (state == ST_GAP_ADD) begin
            activation_bus = feature_a_q;
            weight_bus = 64'h0101010101010101;
        end
    end
    wire [255:0] accumulator_bus;
    wire [255:0] accumulators [0:PIXELS-1];
    assign accumulator_bus=accumulators[0];
    genvar pix,lane;
    generate for(pix=0;pix<PIXELS;pix=pix+1) begin: pixels
        wire [63:0] selected_activation=(pix<4)?prefetched[pix]:((pix==4)?activation_bus:activation_second_bus);
        wire [63:0] mac_activation=(pix==0 && state==ST_GAP_ADD)?activation_bus:selected_activation;
        for(lane=0;lane<8;lane=lane+1) begin: lanes
            damage_mac_lane mac(.clk(clk),.rst_n(rst_n),
                .load_bias((state==ST_BIAS && (pix==0 || layer!=FC_LAYER)) || (pix==0 && state==ST_GAP_CLEAR)),
                .enable((state==ST_MAC && (pix==0 || layer!=FC_LAYER)) || (pix==0 && state==ST_GAP_ADD)),
                .activation(mac_activation[lane*8 +: 8]),.weight(weight_bus[lane*8 +: 8]),
                .bias(bias_bus[lane*32 +: 32]),.accumulator(accumulators[pix][lane*32 +: 32]));
        end
    end endgenerate

    function [7:0] relu_quantize;
        input signed [31:0] value;
        input [7:0] shift;
        reg signed [31:0] shifted;
        begin
            shifted = value >>> shift;
            if (shifted < 0) relu_quantize=0;
            else if (shifted > 127) relu_quantize=127;
            else relu_quantize=shifted[7:0];
        end
    endfunction
    reg signed [31:0] best_logit;
    reg [1:0] best_class;
    // Only the three trained lanes participate; padded lanes must not win.
    reg [1:0] compare_index;
    wire signed [31:0] candidate_logit=(compare_index==1)?logits1:logits2;

    integer i,j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=ST_IDLE; busy<=0; done<=0; class_id<=0;
            logits0<=0; logits1<=0; logits2<=0; cycle_count<=0;
            layer<=0; out_x<=0; out_y<=0; out_group<=0; input_channel<=0;
            kernel_x<=0; kernel_y<=0; tap_index<=0; gap_pixel<=0; gap_group<=0;
            for(j=0;j<PIXELS;j=j+1) quantized[j]<=0;
            for(j=0;j<4;j=j+1) prefetched[j]<=0;
            write_index<=0;last_tap<=0;mac_input_channel<=0;read_out_x<=0;
            best_logit<=0;best_class<=0;compare_index<=0;
        end else begin
            done<=0;
            mac_input_channel<=input_channel; // Match synchronous RAM/ROM read latency without a state mux.
            if (busy) cycle_count<=cycle_count+1'b1;
            case (state)
                ST_IDLE: if (start) begin
                    busy<=1; cycle_count<=0; layer<=0; out_x<=0; out_y<=0; out_group<=0;
                    state<=ST_SETUP;
                end
                ST_SETUP: begin
                    read_out_x<={1'b0,out_x};
                    input_channel<=0; kernel_x<=0; kernel_y<=0; tap_index<=0;
                    write_index<=0;
                    state<=ST_BIAS;
                end
                ST_BIAS: begin read_out_x<={1'b0,out_x}+7'd2;state<=ST_READ;end
                ST_READ: begin
                    read_out_x<={1'b0,out_x}+7'd4;
                    prefetched[0]<=activation_bus;prefetched[1]<=activation_second_bus;
                    state<=ST_FETCH;
                end
                ST_FETCH: begin
                    read_out_x<={1'b0,out_x};
                    prefetched[2]<=activation_bus;prefetched[3]<=activation_second_bus;
                    last_tap<=(tap_index==taps_per_group-1'b1);
                    // Advance address one cycle before MAC. RAM/ROM outputs still
                    // carry the current final pair at the MAC edge; the next
                    // pair-zero read overlaps the 48 parallel multiplications.
                    if(tap_index!=taps_per_group-1'b1) begin
                        tap_index<=tap_index+1'b1;
                        if(layer==0 || depthwise) begin
                            if(kernel_x==2) begin
                                kernel_x<=0;
                                if(kernel_y==2) begin kernel_y<=0;input_channel<=input_channel+1'b1;end
                                else kernel_y<=kernel_y+1'b1;
                            end else kernel_x<=kernel_x+1'b1;
                        end else input_channel<=input_channel+1'b1;
                    end
                    state<=ST_MAC;
                end
                ST_MAC: begin read_out_x<={1'b0,out_x}+7'd2;state<=last_tap?ST_QUANT:ST_READ;end
                ST_QUANT: begin
                    if (layer==FC_LAYER) begin
                        logits0<=$signed(accumulator_bus[31:0]);
                        logits1<=$signed(accumulator_bus[63:32]);
                        logits2<=$signed(accumulator_bus[95:64]);
                        best_logit<=$signed(accumulator_bus[31:0]);best_class<=0;
                        compare_index<=1;state<=ST_ARGMAX;
                    end else begin
                        for(j=0;j<PIXELS;j=j+1) for(i=0;i<8;i=i+1)
                            quantized[j][i*8 +: 8]<=relu_quantize($signed(accumulators[j][i*32 +: 32]),shifts_rom[layer]);
                        state<=ST_WRITE;
                    end
                end
                ST_WRITE: begin
                    if (write_index<5 && {1'b0,out_x}+{4'd0,write_index}+1<out_size) write_index<=write_index+1'b1;
                    else if (out_group == out_groups-1'b1) begin
                        out_group<=0;
                        if ({1'b0,out_x} + 7'd6 >= out_size) begin
                            out_x<=0;
                            if (out_y == out_size-1'b1) begin
                                out_y<=0;
                                if (layer==LAST_CONV) begin
                                    gap_group<=0; gap_pixel<=0; state<=ST_GAP_CLEAR;
                                end else begin layer<=layer+1'b1; state<=ST_SETUP; end
                            end else begin out_y<=out_y+1'b1; state<=ST_SETUP; end
                        end else begin out_x<=out_x+3'd6; state<=ST_SETUP; end
                    end else begin out_group<=out_group+1'b1; state<=ST_SETUP; end
                end
                ST_GAP_CLEAR: begin gap_pixel<=0; state<=ST_GAP_READ; end
                ST_GAP_READ: state<=ST_GAP_ADD;
                ST_GAP_ADD: begin
                    if (gap_pixel==15) state<=ST_GAP_SAVE;
                    else begin gap_pixel<=gap_pixel+1'b1; state<=ST_GAP_READ; end
                end
                ST_GAP_SAVE: begin
                    for (i=0; i<8; i=i+1)
                        gap_vector[gap_group*8+i] <= accumulator_bus[i*32+4 +: 8];
                    if (gap_group==TAIL_GROUPS-1) begin layer<=FC_LAYER; out_group<=0; state<=ST_SETUP; end
                    else begin gap_group<=gap_group+1'b1; state<=ST_GAP_CLEAR; end
                end
                ST_ARGMAX: begin
                    if(candidate_logit>best_logit) begin best_logit<=candidate_logit;best_class<=compare_index;end
                    if(compare_index==2) begin
                        class_id<=(candidate_logit>best_logit)?compare_index:best_class;
                        busy<=0;done<=1;state<=ST_IDLE;
                    end else compare_index<=compare_index+1'b1;
                end
                default: begin state<=ST_IDLE; busy<=0; end
            endcase
        end
    end
endmodule
