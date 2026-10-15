# 🎮 VHDL Maze Game on ZedBoard
An interactive, tilt-controlled 2D maze game implemented in **pure VHDL** for the **ZedBoard** FPGA platform. 

## 🚀 Key Features 
- **Video Output**: 640x480 @ 60Hz HDMI video generation via Analog Devices **ADV7511** transmitter (OSERDESE2/MMCME2 serializing).
- **Control Input**: Motion-based control using **MPU6050** accelerometer via custom I2C controller (`mpu6050_driver.vhd`).
- **Game Engine**: Real-time ball physics, 4-corner collision detection, and customizable mazes (Easy, Medium, Hard).
- **Game Modes**: FSM-driven levels, HUD countdown timer, and colorblind accessibility mode.

## 📁 Repository Structure 
- `src/`: VHDL source files (`game_top.vhd`, `FSM_game.vhd`, `create_maze.vhd`, `hdmi_adv7511.vhd`, `mpu6050_driver.vhd`, `Debounce.vhd`).
- `constraints/`: `zedboard.xdc` pin mapping file.
- `docs/`: Block diagrams and HDMI layout renders.

## 🛠️ Build &amp; Run Instructions
1. Open Xilinx Vivado (2020.1 or newer). 
2. Create a project targeting `xc7z020clg484-1` (ZedBoard).
3. Import all files from `src/` and `constraints/zedboard.xdc`.
4. Run **Synthesis**, **Implementation**, and **Generate Bitstream**.
5. Connect ZedBoard JTAG, PMOD MPU6050 (JA1), and HDMI output (J8), then program the device.
