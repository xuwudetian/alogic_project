`timescale 1ns/1ps
module tb_browser;
    reg clk=0,rst=1,tick=0,kn=1,ka=1,km=1;
    reg [5:0] ready=1,available=6'b001101;
    wire view,sel,nt,at;
    wire [2:0] focus,index;
    integer held,mask,current,direction,offset,candidate,expected;
    always #5 clk=~clk;
    player_control dut(.clk(clk),.rst(rst),.frame_tick(tick),.key_next(kn),.key_auto(ka),
        .key_menu(km),.switches(4'd0),.available(available),.thumbnail_valid(ready),
        .browse(view),.focus(focus),.select_toggle(sel),.select_index(index),
        .next_toggle(nt),.auto_toggle(at),.auto_active(1'b0));
    defparam dut.a.CYCLES=2;
    defparam dut.b.CYCLES=2;
    defparam dut.c.CYCLES=2;
    defparam dut.c.LONG_CYCLES=20;
    task frame;begin tick=1;@(negedge clk);tick=0;@(negedge clk);end endtask
    task menu_key;input integer duration;
        begin km=0;repeat(duration) @(negedge clk);km=1;repeat(8) @(negedge clk);end
    endtask
    always @(negedge clk)
        if(!rst && dut.c.tap && dut.c.hold) $fatal(1,"tap and hold on one release");
    initial begin
        repeat(3) @(negedge clk);rst=0;
        kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);frame;
        ka=0;repeat(8) @(negedge clk);ka=1;repeat(8) @(negedge clk);
        if(view || sel) $fatal(1,"non-frame-atomic view");
        frame;
        if(!view || sel || dut.menu!=0) $fatal(1,"long press fired tap");
        menu_key(8);
        if(focus!=0 || nt) $fatal(1,"focus not atomic or normal key leaked");
        frame;if(focus!=2) $fatal(1,"missing slot not skipped");
        menu_key(30);frame;
        if(!view || sel) $fatal(1,"unready preview accepted");
        ready=15;menu_key(30);
        if(!view || sel) $fatal(1,"selection not frame atomic");
        frame;
        if(view || !sel || index!=2 || at) $fatal(1,"direct selection");
        kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);frame;
        kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);frame;
        if(view || !sel) $fatal(1,"cancel created selection");
        // Exercise actual tap/hold UI through slots 5 and 6, then wrap to 1.
        rst=1;repeat(3) @(negedge clk);rst=0;available=6'h3f;ready=6'h3f;
        kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);frame;
        ka=0;repeat(8) @(negedge clk);ka=1;repeat(8) @(negedge clk);frame;
        if(!view || focus!=0) $fatal(1,"six-slot preview entry");
        for(current=1;current<=5;current=current+1) begin
            menu_key(8);frame;if(focus!=current) $fatal(1,"six-slot tap order %0d",current);
        end
        menu_key(30);frame;
        if(view || index!=5 || !sel) $fatal(1,"sixth image long-press selection");
        kn=0;repeat(8) @(negedge clk);kn=1;repeat(8) @(negedge clk);frame;
        ka=0;repeat(8) @(negedge clk);ka=1;repeat(8) @(negedge clk);frame;
        menu_key(8);frame;if(focus!=0) $fatal(1,"sixth-to-first preview wrap");
        // Independent circular-walk oracle for every availability mask,
        // current slot and direction, including empty and single-entry sets.
        for(mask=0;mask<64;mask=mask+1) begin
            available=mask;#1;
            for(current=0;current<6;current=current+1)
                for(direction=0;direction<2;direction=direction+1) begin
                    expected=current;
                    for(offset=5;offset>=1;offset=offset-1) begin
                        candidate=(current+(direction ? 6-offset : offset))%6;
                        if((mask>>candidate)&1) expected=candidate;
                    end
                    if(dut.step_focus(current,direction)!==expected[2:0])
                        $fatal(1,"focus oracle mask=%h current=%0d direction=%0d",mask,current,direction);
                end
        end
        for(held=16;held<=26;held=held+1) begin
            rst=1;repeat(3) @(negedge clk);rst=0;menu_key(held);frame;
        end
        $display("PASS browser: tap/hold separation, frame-atomic view/focus/select, sparse slots, ready gating, preserved playback");
        $finish;
    end
endmodule
