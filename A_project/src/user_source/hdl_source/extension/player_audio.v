`timescale 1ns/1ps
// Fractional clock enable: exactly 48000 samples per 25000000 pixel clocks.
// Audio and its waveform tap use the same sample, gain and mute state.
module player_audio #(
    parameter integer NO_SIGNAL_TONE_ENABLE=0,
    parameter integer CLK_HZ=25000000
)(
    input clk,input rst,input [3:0] picture,
    input [3:0] volume,input mute,
    output reg valid,output reg [23:0] left,output [23:0] right,
    output reg acr_valid,output [19:0] acr_cts,output [19:0] acr_n
);
    reg [$clog2(CLK_HZ+48000)-1:0] rate;
    reg [31:0] phase;
    reg [6:0] packet_count;
    reg signed [15:0] amplitude;
    reg signed [20:0] product;
    reg [31:0] increment;
    assign right=left;
    assign acr_cts=CLK_HZ/1000;
    assign acr_n=20'd6144;
    function signed [15:0] sine;
        input [3:0] a;
        begin
            case(a)
                0,8: sine=0;
                1,7: sine=4592;
                2,6: sine=8485;
                3,5: sine=11087;
                4: sine=12000;
                9,15: sine=-4592;
                10,14: sine=-8485;
                11,13: sine=-11087;
                12: sine=-12000;
            endcase
        end
    endfunction
    always @* begin
        case(picture)
            0: increment=32'd39370534; // 440Hz
            1: increment=32'd49213167; // 550Hz
            2: increment=32'd59055800; // 660Hz
            3: increment=32'd78741067; // 880Hz
            4: increment=32'd98426334; // 1100Hz
            5: increment=32'd118111601; // 1320Hz
            6: increment=32'd137796867; // 1540Hz
            7: increment=32'd157482134; // 1760Hz
            8: increment=32'd177167401; // 1980Hz
            // A reserves slot 15 for the missing-card test tone. Other users
            // retain the original invalid-slot fallback unless opted in.
            15: increment=NO_SIGNAL_TONE_ENABLE!=0 ? 32'd89478485 : 32'd39370534; // 1000Hz / 440Hz
            default: increment=32'd39370534; // invalid slot: safe 440Hz fallback
        endcase
        amplitude=sine(phase[31:28]);
        product=amplitude*$signed({1'b0,volume});
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin rate<=0; phase<=0; packet_count<=0; valid<=0; left<=0; acr_valid<=0; end
        else begin
            valid<=0; acr_valid<=0;
            if(rate>=CLK_HZ-48000) begin
                rate<=rate-(CLK_HZ-48000);
                phase<=phase+increment; valid<=1;
                left<=mute ? 24'd0 : {product[18:3],8'd0};
                packet_count<=packet_count+1'b1;
                if(packet_count==0) acr_valid<=1;
            end else rate<=rate+48000;
        end
    end
endmodule
