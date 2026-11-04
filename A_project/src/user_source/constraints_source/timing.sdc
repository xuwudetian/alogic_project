# The PLL wrappers define the physical frequencies. Never override them to
# disguise timing failures. SDRAM and its phase-shifted clock remain related.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {mem_shift_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
# ADC divider toggles on the pixel clock falling edge; target the retained hard IP clock pin.
create_generated_clock -name mic_adc_clk -source [get_pins {video_pll_m0/pll_inst.clkc[0]}] -edges {4 8 12} [get_pins {microphone/converter.clk}]
# Pixel/serializer clocks operate concurrently; there is no exclusive group.
# Vendor asynchronous FIFO Gray-pointer max-delay constraints are loaded by build.ps1.

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

# Single-bit alarm crossing; only the first synchronizer stage is exempt.
set_false_path -to [get_regs {network_alarm_sync[0]}]

# Raw system reset has only reset-synchronizer SR loads. A through-only cut
# also covers TD's replicated falling-edge release register. It cannot cut
# stage-to-stage data or the separately named, synchronously released outputs.
set_false_path -through [get_nets {system_reset_async}]

# Frame clear and WAV restart assert asynchronously, then release in each
# destination domain. Restrict each exception to that raw net and the reset
# synchronizers; their D paths and released-reset fanout stay timed.
set_false_path -through [get_nets {frame_read_write_m0/rst}] -to [get_regs {frame_read_write_m0/read_reset_sync[*]}]
set_false_path -through [get_nets {frame_read_write_m0/read_clear_async}] -to [get_regs {frame_read_write_m0/unpack_reset_sync[*] frame_read_write_m0/read_buf/asy_w_rst0 frame_read_write_m0/read_buf/asy_w_rst1 frame_read_write_m0/read_buf/asy_r_rst0 frame_read_write_m0/read_buf/asy_r_rst1}]
set_false_path -through [get_nets {storage/wav/read_reset_async}] -to [get_regs {storage/wav/read_reset_sync[*] storage/wav/audio_fifo/asy_w_rst0 storage/wav/audio_fifo/asy_w_rst1 storage/wav/audio_fifo/asy_r_rst0 storage/wav/audio_fifo/asy_r_rst1}]

# The 27 MHz video PLL and the system PLL have independent phase. Only the
# first flip-flop of each audited single-bit synchronizer is exempt; no clock
# groups, second-stage paths, or arbitrary functional endpoints are cut.
set_false_path -from [get_clocks {video_clk}] -to [get_regs {storage/next_sync[0] storage/auto_sync[0] storage/ack_sync[0] storage/browse_sync[0] storage/pause_sync[0] storage/run_auto_sync[0] storage/select_sync[0] storage/audio_request_sync[0] storage/wav/under_sync[0] diagnostics/request_target frame_read_write_m0/frame_fifo_read_m0/read_req_d0}]
set_false_path -from [get_clocks {sd_card_clk}] -to [get_regs {transition/req_sync[0] debug_toggle_sync[0] auto_sync[0] no_signal_sync[0] preview_request_sync[0] storage/audio_ack_sync[0] storage/wav/accept_sync[0] storage/wav/end_sync[0] storage/wav/disable_sync[0] diagnostics/ack_sync[0]}]
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_regs {video_timing_data_m0/ack_sync[0]}]

# Bundled picture metadata is held until the synchronized commit ACK. The
# three-stage request token follows the two-stage data capture before use.
# Bound the asynchronous data path to 20 ns, below one destination period.
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {transition/bank_meta[*] transition/pic_meta[*] transition/scale_meta transition/resolution_meta[*] transition/auto_meta preview_picture_meta[*]}] -datapath_only 20

# Frame geometry changes at a frame boundary; video_timing_data waits 32
# pixel clocks before issuing the read request. Only the first metadata
# stages receive a datapath bound; the subsequent capture remains timed.
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_read_m0/read_addr_index_d0[*] frame_read_write_m0/frame_fifo_read_m0/read_len_d0[*] frame_read_write_m0/frame_fifo_read_m0/zoom_meta frame_read_write_m0/frame_fifo_read_m0/zoom_size_meta[*] frame_read_write_m0/frame_fifo_read_m0/zoom_width_meta[*] frame_read_write_m0/frame_fifo_read_m0/zoom_height_meta[*] frame_read_write_m0/frame_fifo_read_m0/slide_meta frame_read_write_m0/frame_fifo_read_m0/offset_meta[*] frame_read_write_m0/frame_fifo_read_m0/next_meta[*]}] -datapath_only 20

# UI selection/period metadata and status samples pass through two-stage
# capture before event/frame-boundary use. Keep each first-stage bus bounded.
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {storage/period_meta[*] storage/index_meta[*]}] -datapath_only 20
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {error_meta[*] state_meta[*] debug_meta[*] ready_meta[*] failed_meta[*] available_meta[*] audio_meta[*]}] -datapath_only 20

# Mailbox payloads are immutable from request through acknowledge. Target
# capture is permitted only after the request has crossed its synchronizer.
set_max_delay -from [get_regs {storage/audio_select_hold[*]}] -to [get_regs {storage/audio_select_sd[*]}] -datapath_only 20
set_max_delay -from [get_regs {diagnostics/held[*]}] -to [get_regs {diagnostics/held_target[*]}] -datapath_only 20

# XGA HDMI uses another related output of the same video PLL.



# Pixel reset asserts immediately; the serial reset releases on its own clock.
set_false_path -through [get_nets {u_hdmi2phy_wrapper/I_rst}] -to [get_regs {u_hdmi2phy_wrapper/serial_reset_sync[*]}]
