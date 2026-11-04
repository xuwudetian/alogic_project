# 50 MHz inference, 66.6667/333.3333 MHz video and independent 100 MHz memory.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name video_clk -source [get_ports {clk}] -master_clock clk [get_pins {u_video_pll/pll_inst.clkc[0]}]
rename_clock -name serial_clk -source [get_ports {clk}] -master_clock clk [get_pins {u_video_pll/pll_inst.clkc[1]}]
rename_clock -name preview_mem -source [get_ports {clk}] -master_clock clk [get_pins {u_video_pll/pll_inst.clkc[2]}]
rename_clock -name preview_forward -source [get_ports {clk}] -master_clock clk [get_pins {u_video_pll/pll_inst.clkc[3]}]
# Forwarded SDRAM clock leads preview_mem by 2 ns, compensating SIP clock pads.
# Keep its clock related to memory logic so both directions retain full STA.
create_generated_clock -name preview_sdram_clk -source [get_pins {u_video_pll/pll_inst.clkc[3]}] -divide_by 1 [get_pins {preview/frame_store/memory_phy/sdram.clk}]
# TD's SIP model uses 5.0ns tAC; EM638325 slow-grade CL3 specifies 5.4ns.
# DQ is latched on the next rising memory edge (12ns after the
# SDRAM launch edge), then pipelined into the controller at the rising edge.
# Reserve the extra 0.4ns on the real 12ns read window; retain hold checks.
set_max_delay -from [get_clocks {preview_sdram_clk}] -to [get_clocks {preview_mem}] 11.6
# Register table uses a 24 MHz module oscillator and nominal 48 MHz DVP PCLK.
# Constrain at 50 MHz to cover oscillator tolerance. Verify PCLK on the board.
create_clock -name cam_pclk -period 20 -waveform {0 10} [get_ports {cam_pclk}]
# Do not cut the entire camera clock group: the new FIFO Gray buses must have
# a real bounded datapath delay. Only first-stage token synchronizers are cut.
set_false_path -from [get_clocks {clk}] -to [get_regs {camera/config_sync[0] roi/ack_sync[0]}]
set_false_path -from [get_clocks {preview_mem}] -to [get_regs {preview/frame_store/camera_ack_sync[0] preview/frame_store/init_sync[0]}]
set_false_path -from [get_clocks {cam_pclk}] -to [get_regs {roi/req_sync[0] preview/frame_store/camera_done_sync[0]}]
# camera_good is bundled with camera_done and immutable until ACK returns.
# Bound metadata delivery before the synchronized token permits its sampling.
set_max_delay -from [get_regs {preview/frame_store/camera_good}] -to [get_regs {preview/frame_store/done_good}] -datapath_only 20
set_max_delay -from [get_regs {preview/frame_store/camera_fifo/write_gray[*]}] -to [get_regs {preview/frame_store/camera_fifo/write_gray_r1[*]}] -datapath_only 10
set_max_delay -from [get_regs {preview/frame_store/camera_fifo/read_gray[*]}] -to [get_regs {preview/frame_store/camera_fifo/read_gray_w1[*]}] -datapath_only 10
# The video-domain line request is a bundled-data handshake. Fields are held
# until acknowledgement; only the first token stage is exempt, and metadata
# must physically arrive before the two-stage token permits its capture.
set_false_path -from [get_clocks {video_clk}] -to [get_regs {preview/frame_store/line_request_sync[0] preview/frame_store/display_ack_sync[0]}]
set_false_path -from [get_clocks {preview_mem}] -to [get_regs {preview/publish_sync[0] preview/line_ack_sync[0]}]
set_max_delay -from [get_regs {preview/line_row[*] preview/line_cache preview/line_frame_bank}] -to [get_regs {preview/frame_store/fetch_row[*] preview/frame_store/fetch_cache preview/frame_store/fetch_bank}] -datapath_only 20
# DVP changes data on PCLK falling edge and is sampled on the rising edge.
# Provisional external propagation budget; verify the module timing on the board.
set_input_delay -clock cam_pclk -clock_fall -max 4.0 [get_ports {cam_data[*] cam_href cam_vsync}]
set_input_delay -clock cam_pclk -clock_fall -min 0.5 [get_ports {cam_data[*] cam_href cam_vsync}]
set_false_path -from [get_ports {rst_n}]
# The video reset is an asynchronous request to local serial-domain release
# synchronizers. Their register-to-register and released reset paths stay timed.
set_false_path -through [get_nets {hdmi/rst_n}] -to [get_regs {hdmi/sr/serial_reset[*] hdmi/sg/serial_reset[*] hdmi/sb/serial_reset[*] hdmi/sc/serial_reset[*]}]
# SCCB data is asynchronous to clk and sampled at a 250 kHz bus midpoint.
set_false_path -from [get_ports {cam_sda}]
# Acknowledge is a CDC token sampled by ack_sync[0], then ack_sync[1].
# Only the video->50 MHz token input to the FIRST synchronizer is exempt.
# The second stage, payload bus and all video/serializer paths remain timed.
# The source holds its payload until this two-stage acknowledgement returns.
set_false_path -from [get_clocks {video_clk}] -through [get_nets {result_display/acknowledge}] -to [get_clocks {clk}]

# 100BASE-TX only: 25 MHz nibble clock, 90 degree forwarded TX clock.
rename_clock -name net_mac -source [get_ports {clk}] -master_clock clk [get_pins {network/clocks/pll_inst.clkc[0]}]
rename_clock -name net_shift -source [get_ports {clk}] -master_clock clk [get_pins {network/clocks/pll_inst.clkc[1]}]
create_clock -name net_rx -period 40 -waveform {0 20} [get_ports {eth_rx_clk}]
# Exempt only raw asynchronous reset requests into the three reset synchronizers.
# Their inter-stage D paths and released reset fanout remain fully timed.
set_false_path -through [get_nets {network/reset_all}] -to [get_regs {network/sys_reset_sync[*] network/tx_reset_sync[*] network/rx_reset_sync[*]}]
# RXD changes at RXC rising edge; sample at falling edge (100 Mb/s duplicates
# each nibble). Budget covers both 0/2 ns strap delays and PCB skew.
set_input_delay -clock net_rx -max 3.0 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock net_rx -min -2.8 [get_ports {eth_rxd[*] eth_rx_ctl}]
create_generated_clock -name net_tx_pin -source [get_pins {network/clocks/pll_inst.clkc[1]}] -divide_by 1 [get_ports {eth_tx_clk}]
set_output_delay -clock net_tx_pin -max 2.0 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock net_tx_pin -min -2.0 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock net_tx_pin -clock_fall -add_delay -max 2.0 [get_ports {eth_txd[*] eth_tx_ctl}]
set_output_delay -clock net_tx_pin -clock_fall -add_delay -min -2.0 [get_ports {eth_txd[*] eth_tx_ctl}]
# Only asynchronous token first stages are exempt. Bundled payload must arrive
# within 20 ns, before the synchronized token allows capture.
set_false_path -to [get_regs {network/rx_box/req_sync[0] network/rx_box/ack_sync[0]}]
set_max_delay -from [get_regs {network/rx_box/held[*]}] -to [get_regs {network/rx_box/received_data[*]}] -datapath_only 20
# MDIO is sampled slowly, with a dedicated synchronizer.
# The only MDIO input load is the first synchronizer, which TD packs into the I/O pad.
set_false_path -from [get_ports {eth_mdio}]

# Request/ACK synchronizers also bridge independent system/network PLL domains.
# Exempt ONLY first stages; keep second stages timed and bound bundled data.
set_false_path -to [get_regs {network/tx_box/req_sync[0] network/tx_box/ack_sync[0] network/link_sync[0]}]
set_max_delay -from [get_regs {network/tx_box/held[*]}] -to [get_regs {network/tx_box/received_data[*]}] -datapath_only 20
