// Asynchronous assertion, synchronous release in each receiving clock domain.
module reset_release(input clk,input arst_n,output rst_n);
  (* async_reg="true" *) reg [2:0] sync;
  always @(posedge clk or negedge arst_n)
    if(!arst_n) sync<=0; else sync<={sync[1:0],1'b1};
  assign rst_n=sync[2];
endmodule
