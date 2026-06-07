`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
 */
module tb ();

  // Waveform dump
  initial begin
    $dumpfile("tb_FINAL.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Standard TinyTapeout Signals
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  
  // Instantiate the user project
  tt_um_elemental_harmony user_project (
      .ui_in   (ui_in),    // [7]:Start, [6:4]:Pat, [3:0]:Pos
      .uo_out  (uo_out),   // 8-bit Score/Error/Occupancy stream
      .uio_in  (uio_in),
      .uio_out (uio_out),
      .uio_oe  (uio_oe),
      .ena     (ena),
      .clk     (clk),
      .rst_n   (rst_n)
  );

endmodule
