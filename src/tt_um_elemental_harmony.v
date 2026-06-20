/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_elemental_harmony (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    input  wire       ena,      
    input  wire       rst_n,
    input  wire       clk,
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe    // IOs: Enable path
);

    wire internal_rst_n;
    assign internal_rst_n = rst_n & ena;

    wire [3:0] h_pos;
    wire [2:0] h_pat;
    assign h_pos = ui_in[3:0];
    assign h_pat = ui_in[6:4];

    reg start_prev;
    wire start_pulse;

    // --- Switched to internal_rst_n and async reset to match pipeline slices ---
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin
            start_prev <= 1'b0;
        end else begin
            start_prev <= ui_in[7]; 
        end
    end

    assign start_pulse = ui_in[7] && !start_prev; // Edge Event Detection

    // --- Interconnect Wires ---
    wire [7:0] uo_out_data;   
    wire [4:0] uio_out_int;
    wire [1:0] uio_oe_int;

    // --- Boundary Register Pipeline Slice (uo_out) ---
    reg [7:0] uo_out_reg;
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin
            uo_out_reg <= 8'h00;
        end else begin
            uo_out_reg <= uo_out_data;
        end
    end

    assign uo_out = uo_out_reg;
    
    // --- Boundary Register Pipeline Slice (uio_out) ---
    reg [4:0] uio_out_reg;
    always @(posedge clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin
            uio_out_reg <= 5'b00000;
        end else begin
            uio_out_reg <= uio_out_int;
        end
    end

    // --- Core Instantiation ---
    harmony_core dut_core (
      .clk(clk), 
      .rst_n(internal_rst_n),
      .h_pos(h_pos),
      .h_pat(h_pat),
      .start(start_pulse),
      .uo_out(uo_out_data),
      .uio_out_int(uio_out_int),
      .uio_oe_int(uio_oe_int)
    );

    // --- Structural Bidirectional IO Mapping ---
    assign uio_out[4:0] = uio_out_reg; 
    assign uio_out[7:5] = 3'b000;

    
    assign uio_oe[1:0] = uio_oe_int;  
    assign uio_oe[4:2] = 3'b111;      // Hardcoded active-high to expose the rest of curr_state
    assign uio_oe[7:5] = 3'b000;      // Unused pins remain safe inputs

    wire _unused_ok;
    assign _unused_ok = &{uio_in, 1'b0};

endmodule
