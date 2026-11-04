// Signed INT8 multiplier and INT32 accumulation. All arithmetic is integer.
module damage_mac_lane (
    input wire clk,
    input wire rst_n,
    input wire load_bias,
    input wire enable,
    input wire signed [7:0] activation,
    input wire signed [7:0] weight,
    input wire signed [31:0] bias,
    output reg signed [31:0] accumulator
);
    (* use_dsp = "yes", multstyle = "dsp" *)
    wire signed [15:0] product = activation * weight;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) accumulator <= 32'sd0;
        else if (load_bias) accumulator <= bias;
        else if (enable) accumulator <= accumulator + {{16{product[15]}}, product};
    end
endmodule
