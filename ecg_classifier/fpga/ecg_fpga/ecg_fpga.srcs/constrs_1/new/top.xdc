## Nexys A7-100T — ECG Arrhythmia Classifier
## All I/O: LVCMOS33 (3.3 V bank)

# ─── System clock: 100 MHz ───────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name sys_clk [get_ports clk]

# ─── Reset: CPU_RESETN (active-low pushbutton) ───────────────────────────────
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports cpu_resetn]
set_false_path -from [get_ports cpu_resetn]

# ─── Pmod JA — Digilent Pmod AD1 (AD7476A, SPI Mode 0) ──────────────────────
# Pmod AD1 pin layout (upper row): D0=1, D1=2, SCK=3, CS_n=4
# Pmod JA upper row: JA1=C17, JA2=D18, JA3=E18, JA4=G17
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports ad1_miso]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports ad1_sck]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports ad1_csn]

set_input_delay  -clock sys_clk -max 4.0 [get_ports ad1_miso]
set_input_delay  -clock sys_clk -min 1.0 [get_ports ad1_miso]
set_output_delay -clock sys_clk -max 4.0 [get_ports {ad1_sck ad1_csn}]
set_output_delay -clock sys_clk -min 1.0 [get_ports {ad1_sck ad1_csn}]

# ─── VGA (Nexys A7 on-board resistor DAC) ────────────────────────────────────
set_property -dict {PACKAGE_PIN A3  IOSTANDARD LVCMOS33} [get_ports {vga_r[0]}]
set_property -dict {PACKAGE_PIN B4  IOSTANDARD LVCMOS33} [get_ports {vga_r[1]}]
set_property -dict {PACKAGE_PIN C5  IOSTANDARD LVCMOS33} [get_ports {vga_r[2]}]
set_property -dict {PACKAGE_PIN A4  IOSTANDARD LVCMOS33} [get_ports {vga_r[3]}]

set_property -dict {PACKAGE_PIN C6  IOSTANDARD LVCMOS33} [get_ports {vga_g[0]}]
set_property -dict {PACKAGE_PIN A5  IOSTANDARD LVCMOS33} [get_ports {vga_g[1]}]
set_property -dict {PACKAGE_PIN B6  IOSTANDARD LVCMOS33} [get_ports {vga_g[2]}]
set_property -dict {PACKAGE_PIN A6  IOSTANDARD LVCMOS33} [get_ports {vga_g[3]}]

set_property -dict {PACKAGE_PIN B7  IOSTANDARD LVCMOS33} [get_ports {vga_b[0]}]
set_property -dict {PACKAGE_PIN C7  IOSTANDARD LVCMOS33} [get_ports {vga_b[1]}]
set_property -dict {PACKAGE_PIN D7  IOSTANDARD LVCMOS33} [get_ports {vga_b[2]}]
set_property -dict {PACKAGE_PIN D8  IOSTANDARD LVCMOS33} [get_ports {vga_b[3]}]

set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports vga_hs]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports vga_vs]

# VGA signals are output-only; relax timing relative to pixel-clock enable (÷4)
set_output_delay -clock sys_clk -max 2.0 [get_ports {vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]

# ─── LEDs ────────────────────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

set_output_delay -clock sys_clk -max 2.0 [get_ports {led[*]}]
set_output_delay -clock sys_clk -min 0.0 [get_ports {led[*]}]

# ─── Bitstream / configuration ────────────────────────────────────────────────
set_property BITSTREAM.GENERAL.COMPRESS TRUE          [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33           [current_design]
set_property CONFIG_VOLTAGE 3.3                       [current_design]
set_property CFGBVS VCCO                              [current_design]
