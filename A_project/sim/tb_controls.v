`timescale 1ns/1ps
module tb_controls;
    reg clk=0,rst=1,tick=0,kn=1,ka=1,km=1;
    reg [3:0] sw=0;
    wire nt,at;
    wire signed [8:0] bright;
    wire [8:0] contrast;
    wire [3:0] volume,interval_seconds,modes;
    wire [2:0] menu;
    wire directory,browse;
    integer n;
    player_control dut(.clk(clk),.rst(rst),.frame_tick(tick),.key_next(kn),.key_auto(ka),
        .key_menu(km),.switches(sw),.next_toggle(nt),.auto_toggle(at),.brightness(bright),
        .contrast(contrast),.volume(volume),.interval_seconds(interval_seconds),.menu(menu),
        .modes(modes),.available(6'h3f),.thumbnail_valid(6'h3f),.auto_active(1'b0),
        .directory(directory),.browse(browse));
    defparam dut.a.CYCLES=3;
    defparam dut.b.CYCLES=3;
    defparam dut.c.CYCLES=3;
    always #5 clk=~clk;
    task press;
        input integer key;
        begin
            @(negedge clk);
            case(key) 0:kn=0;1:ka=0;2:km=0;endcase
            repeat(10) @(negedge clk);
            kn=1;ka=1;km=1;
            repeat(10) @(negedge clk);
        end
    endtask
    task frame;
        begin tick=1;@(negedge clk);tick=0;@(negedge clk);end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        // A bounce shorter than the debounce window must not create an event.
        kn=0;@(negedge clk);kn=1;repeat(10) @(negedge clk);
        if(nt) $fatal(1,"bounce accepted");
        press(0);frame;if(!directory) $fatal(1,"directory key");
        press(1);frame;if(!browse || nt || at) $fatal(1,"preview confirmation");
        sw=8;repeat(5) @(negedge clk);
        press(0);press(2);press(2);press(1); // Preview -> directory -> settings
        press(0);
        if(bright!=0 || nt) $fatal(1,"uncommitted setting or key leakage");
        frame;
        if(bright!=4 || modes!=8) $fatal(1,"brightness frame commit");
        press(2);press(0);frame;
        if(contrast!=132) $fatal(1,"contrast control");
        press(2);press(1);frame;
        if(volume!=3) $fatal(1,"volume control");
        press(2);press(0);frame;
        if(interval_seconds!=4) $fatal(1,"interval control");
        repeat(4) press(2);frame;
        if(menu!==0) $fatal(1,"seven-field wrap to brightness");
        for(n=8;n<=252;n=n+4) begin
            press(0);frame;if(bright!==n) $fatal(1,"brightness increase %0d",n);
        end
        repeat(3) press(0);frame;if(bright!=255) $fatal(1,"brightness upper wrap");
        for(n=251;n>=-253;n=n-4) begin
            press(1);frame;if(bright!==n) $fatal(1,"brightness decrease %0d",n);
        end
        repeat(3) press(1);frame;if(bright!=-255) $fatal(1,"brightness lower wrap");
        press(0);frame;if(bright!=-251) $fatal(1,"brightness endpoint recovery");
        press(2);frame;
        for(n=136;n<=384;n=n+4) begin
            press(0);frame;if(contrast!==n) $fatal(1,"contrast increase %0d",n);
        end
        repeat(3) press(0);frame;if(contrast!=384) $fatal(1,"contrast upper wrap");
        for(n=380;n>=0;n=n-4) begin
            press(1);frame;if(contrast!==n) $fatal(1,"contrast decrease %0d",n);
        end
        repeat(3) press(1);frame;if(contrast!=0) $fatal(1,"contrast lower wrap");
        press(0);frame;if(contrast!=4) $fatal(1,"contrast endpoint recovery");
        rst=1;repeat(3) @(negedge clk);rst=0;frame;
        if(bright!=0 || contrast!=128) $fatal(1,"parameter reset defaults");
        $display("PASS controls: debounce, playback/edit routing, all four numeric parameters, frame-boundary application");
        $finish;
    end
endmodule
