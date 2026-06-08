/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

// Code your design here

`default_nettype none

//`timescale 1ns/1ps #as it gave lint error LE


/////////////////////////////////////////

////////////// Top Wrapper //////////////

/////////////////////////////////////////

module tt_um_elemental_harmony (

  input wire  [7:0] ui_in,    

  output wire [7:0] uo_out, 

  input wire  [7:0] uio_in,  

  input wire        ena,      

  input wire        rst_n,

  input wire 	    clk,

  output wire [7:0] uio_out,  

  output wire [7:0] uio_oe

);

   

    assign uio_oe[7:2]  = 6'b000000;

    assign uio_out[7:5] = 3'b000;

  

    wire internal_rst_n;

    assign internal_rst_n = rst_n & ena;

  

    wire [3:0] h_pos;

    wire [2:0] h_pat;

    assign h_pos = ui_in[3:0];

    assign h_pat = ui_in[6:4];

  

    reg start_prev;

    wire start_pulse;



    always @(posedge clk) begin

        if (!rst_n) begin

            start_prev <= 1'b0;

        end else begin

            start_prev <= ui_in[7]; 

        end

    end



    assign start_pulse = ui_in[7] && !start_prev;





    harmony_core dut_core (

      .clk(clk), 

      .rst_n(internal_rst_n),

      .h_pos(h_pos),

      .h_pat(h_pat),

      .start(start_pulse),

      .uo_out(uo_out),

      .uio_out_int(uio_out[4:0]),

      .uio_oe_int(uio_oe[1:0])

    );

  

    wire _unused_ok;

    assign _unused_ok = &{uio_in, 1'b0};

  

endmodule



/////////////////////////////////////////

////////////// FSM Core /////////////////

/////////////////////////////////////////

`default_nettype none



module harmony_core (
    input reg clk,
    input reg rst_n,
    input wire start,     
    input reg [3:0] h_pos,     
    input reg [2:0] h_pat,     
    output wire [7:0] uo_out,
    output wire [4:0] uio_out_int,
    output wire [1:0] uio_oe_int
);

    // --- FSM States ---

    localparam ST_IDLE       = 4'd0;

    localparam ST_VALIDATE   = 4'd1;

    localparam ST_HUMANPLAY  = 4'd2;

    localparam ST_DESIGNPLAY = 4'd3;
  
    localparam ST_DESIGNREST = 4'd4;

    localparam ST_ERROR_1    = 4'd5; 

    localparam ST_ERROR_2    = 4'd6; 

    localparam ST_ERROR_3    = 4'd7; 

    localparam ST_FINAL      = 4'd8;



    // --- Declarations of Internal Signals ---

    reg [3:0]  curr_state;

    reg [3:0]  nxt_state;

    reg [2:0]  board [0:15];     

    reg [15:0] occ;        

    reg signed [7:0] hscorefinal, dscorefinal; 

    reg signed [7:0] nxt_dscorefinal, nxt_hscorefinal;

    reg signed [7:0] nxt_acc_dscore, nxt_acc_hscore;

    reg        [4:0] uio_out_int_q;
    
    reg        [1:0] uio_oe_int_q;


                    

    reg [15:0] lfsr;

    reg [4:0]  fill_count; 

    reg [7:0] uo_out_data;

    reg [3:0]  c_h_pos;

    reg [2:0]  c_h_pat;
   
    reg [2:0] design_pat;


    wire [7:0] occ_msb;

    wire [7:0] occ_lsb;

    wire last;
    
    reg [3:0] lfsr_pos;
    
    wire [3:0] lfsr_lookahead;
    
    assign lfsr_lookahead = lfsr[3:0];

    assign occ_msb = occ[15:8];

    assign occ_lsb = occ[7:0];

    assign last = (fill_count == 5'd16);



    // --- Pairwise Score LUT (Signed 3-bit) ---

    function signed [2:0] get_pair_score;

        input [2:0] p1;

        input [2:0] p2;

        reg [5:0] pair;

        begin

            pair = (p1 < p2) ? {p1, p2} : {p2, p1};

            if (p1 == p2) get_pair_score = 3'sd0; 

            else begin

                case (pair)

                    6'b000_001: get_pair_score =  3'sd1; // AB-AG

                    6'b000_010: get_pair_score = -3'sd2; // AB-WD

                    6'b000_011: get_pair_score = -3'sd2; // AB-WR

                    6'b000_100: get_pair_score = -3'sd2; // AB-FB

                    6'b000_101: get_pair_score =  3'sd2; // AB-FS

                    6'b000_110: get_pair_score = -3'sd2; // AB-EG

                    6'b000_111: get_pair_score =  3'sd2; // AB-EP

                    6'b001_010: get_pair_score =  3'sd2; // AG-WD

                    6'b001_011: get_pair_score = -3'sd2; // AG-WR

                    6'b001_100: get_pair_score =  3'sd2; // AG-FB

                    6'b001_101: get_pair_score = -3'sd2; // AG-FS

                    6'b001_110: get_pair_score = -3'sd2; // AG-EG

                    6'b001_111: get_pair_score =  3'sd2; // AG-EP

                    6'b010_011: get_pair_score =  3'sd1; // WD-WR

                    6'b010_100: get_pair_score = -3'sd2; // WD-FB

                    6'b010_101: get_pair_score =  3'sd2; // WD-FS

                    6'b010_110: get_pair_score =  3'sd2; // WD-EG

                    6'b010_111: get_pair_score =  3'sd2; // WD-EP

                    6'b011_100: get_pair_score = -3'sd2; // WR-FB

                    6'b011_101: get_pair_score =  3'sd2; // WR-FS

                    6'b011_110: get_pair_score =  3'sd2; // WR-EG

                    6'b011_111: get_pair_score =  3'sd2; // WR-EP

                    6'b100_101: get_pair_score =  3'sd1; // FB-FS

                    6'b100_110: get_pair_score = -3'sd2; // FB-EG

                    6'b100_111: get_pair_score =  3'sd2; // FB-EP

                    6'b101_110: get_pair_score = -3'sd2; // FS-EG

                    6'b101_111: get_pair_score =  3'sd2; // FS-EP

                    6'b110_111: get_pair_score =  3'sd1; // EG-EP

                    default:    get_pair_score =  3'sd0;

                endcase

            end

        end

    endfunction



    function signed [7:0] calc_move_value;

        input [3:0] pos;

        input [2:0] pat;

        reg signed [7:0] acc; 

        reg [2:0] neighbor_count; 

        acc = 8'sd0;

        neighbor_count = 3'b0;



        // Check North

        if (pos >= 4 && occ[pos-4]) begin      

            //acc = acc + get_pair_score(pat, board[pos-4]);

	    acc = acc + 8'($signed(get_pair_score(pat, board[pos-4])));
	    //acc = acc + $signed(get_pair_score(pat, board[pos-4]));

            neighbor_count = neighbor_count + 1;

        end

        // Check South

        if (pos <= 11 && occ[pos+4]) begin     

	    acc = acc + 8'($signed(get_pair_score(pat, board[pos+4])));
	  //acc = acc + $signed(get_pair_score(pat, board[pos+4]));

            neighbor_count = neighbor_count + 1;

        end

        // Check West

        if (pos % 4 != 0 && occ[pos-1]) begin  

	    acc = acc + 8'($signed(get_pair_score(pat, board[pos-1])));
            //acc = acc + $signed(get_pair_score(pat, board[pos-1]));
            neighbor_count = neighbor_count + 1;

        end

        // Check East

        if (pos % 4 != 3 && occ[pos+1]) begin  

	    acc = acc + 8'($signed(get_pair_score(pat, board[pos+1])));
	    //acc = acc + $signed(get_pair_score(pat, board[pos+1]));

            neighbor_count = neighbor_count + 1;

        end

        // If the cell is "lonely", give the +2 bonus

        if (neighbor_count == 3'b0) begin

            calc_move_value = 8'sd2; 

        end else begin

            calc_move_value = acc;

        end

    endfunction

    // 1. State Register

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) curr_state <= ST_IDLE;

        else        curr_state <= nxt_state;

    end

    // 2. Next State Logic (Combinational)

    always_comb begin

        nxt_state  = curr_state;

        case (curr_state)

            ST_IDLE:       if (start) nxt_state = ST_VALIDATE;

            ST_VALIDATE:   nxt_state = (!occ[c_h_pos]) ? ST_HUMANPLAY : ST_ERROR_1;

            ST_HUMANPLAY:  nxt_state = ST_DESIGNPLAY;
                    
            ST_DESIGNPLAY: begin
              
              if (!occ[lfsr_lookahead]) //since using lfsr[3:0] slice in if condition for the always comb gave error in cocotb
              //line 434 error: sorry: constant selects in always_* processes are not fully supported (the process will be sensitive to all bits in 'lfsr[15:0]').
        	    nxt_state = ST_DESIGNREST; // Go here to show the score next
              else 
                    nxt_state = ST_DESIGNPLAY;
            end

            ST_DESIGNREST: begin

              nxt_state = (fill_count == 5'd16) ? ST_FINAL : ST_IDLE;

            end


            ST_ERROR_1:    nxt_state = ST_ERROR_2;

            ST_ERROR_2:    nxt_state = ST_ERROR_3;

            ST_ERROR_3:    nxt_state = ST_IDLE;//then again from idle, the new position is taken for retry, never goes to HUMANPLAY directly from ERROR_3 state

            ST_FINAL:      nxt_state = ST_IDLE;
            
            default:	   nxt_state = ST_IDLE;

        endcase

    end

    // 3. Data Path & Scoring (Sequential - Non-Blocking)

    integer i;
    
    wire [2:0] next_design_pat;
    assign next_design_pat = (lfsr[6:4] == 3'b000) ? (lfsr[15:13] | 3'b001) : lfsr[6:4];
    

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            occ          <= 16'h0;

            fill_count   <= 5'd0;

            hscorefinal  <= 8'sd0;

            dscorefinal  <= 8'sd0;

            lfsr         <= 16'hACE1;
            
            lfsr_pos     <= 4'b0;
			
            design_pat   <= 3'b0;
            
            for (i=0; i<16; i=i+1) board[i] <= 3'b0;

        end else begin

            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

            case (curr_state)

                ST_IDLE: begin

                    if (start) begin

                        c_h_pos <= h_pos;

                        c_h_pat <= h_pat;

                    end

                end

                ST_HUMANPLAY: begin

                    board[c_h_pos] <= c_h_pat;

                    occ[c_h_pos]   <= 1'b1;

                    fill_count     <= fill_count + 1'b1;

                    hscorefinal    <= nxt_hscorefinal;

                end 
                            
                ST_DESIGNPLAY: begin
                      if (!occ[lfsr_lookahead]) begin
                        // --- THE FIX: SNAPSHOT THE MOVE ---
                        lfsr_pos         <= lfsr_lookahead;         // Lock the winning position
                        design_pat       <= next_design_pat;   // Lock the winning pattern

                        // Commit to board using the locked values
                        board[lfsr[3:0]] <= next_design_pat;
                        occ[lfsr[3:0]]   <= 1'b1;
                        fill_count       <= fill_count + 1'b1;
                      end
                end

                ST_DESIGNREST: begin
                  
                      // Atomic Score Update
                      // After the board was updated in the previous cycle, 
                      // we now commit the calculated score to the total.
                      dscorefinal <= nxt_dscorefinal;
                  
                end

                default: begin

                    // board[lfsr[3:0]]  <= board[lfsr[3:0]]; //removed for the synthesis warning of unclocked registers

                    // occ[lfsr[3:0]]    <= occ[lfsr[3:0]];

                    fill_count       <= fill_count;

                    dscorefinal      <= dscorefinal;

		end

            endcase

        end

    end  

    always@(*) begin

        nxt_dscorefinal = 8'sd0;

        nxt_hscorefinal = 8'sd0;

        nxt_acc_hscore  = 8'sd0;

        nxt_acc_dscore  = 8'sd0;

        // Base defaults for your tracking bits

        //uio_out_int_q[0]   = 1'b0;
        uio_out_int_q = {curr_state, 1'b0}; // Map state directly to MSB debugging pins
        uio_oe_int_q    = 2'b11;       // Pin 0 is an output (strobe)

       // uio_oe_int_q[1]    = 1'b1;       // Pin 1 is an output (state visibility flag)

        case (curr_state)

			ST_HUMANPLAY: begin
                nxt_acc_hscore  = calc_move_value(c_h_pos, c_h_pat);
                nxt_hscorefinal = hscorefinal + nxt_acc_hscore;
                //uio_out_int 	= 1'b1;// Tell the TB: "Sample this now!" //dont use for human play score recording, use only for design round score recording

            end

          ST_DESIGNPLAY: begin
                // Move is being made; strobe is LOW.
		        uio_out_int_q[0] = 1'b0;
          end

          ST_DESIGNREST: begin

          // Move is finished; strobe is HIGH.
                  uio_out_int_q[0]  = 1'b1; 

          // Calculate score based on the move just committed to the board
                  nxt_acc_dscore  = calc_move_value(lfsr_pos, design_pat);
                  nxt_dscorefinal = dscorefinal + nxt_acc_dscore;
          end

          default: begin

          	          nxt_dscorefinal = '0;

        	          nxt_hscorefinal = '0;

                          nxt_acc_hscore  = 8'sd0;

                          nxt_acc_dscore  = 8'sd0;

                          uio_out_int_q  = {curr_state, 1'b0}; 

                          uio_oe_int_q   = 2'b11;

          end

        endcase
			
    end

	
    always_comb begin

      uo_out_data = 8'h00; 

      case (curr_state)

          ST_IDLE: begin

              uo_out_data = 8'h00;

          end

          ST_HUMANPLAY: begin

              uo_out_data = nxt_acc_hscore;

          end

        
          ST_DESIGNPLAY: begin
            
          // Phase 1: Send Move Data (Pattern and Position)
          // Bits: [7] unused, [6:4] pattern, [3:0] position
          //   uo_out_data = {1'b0, design_pat, lfsr_pos};
              uo_out_data = {1'b0, next_design_pat, lfsr_lookahead};
          end

          ST_DESIGNREST: begin
            
          // Phase 2: Send Result Data (The Score)
              uo_out_data = nxt_acc_dscore;
            
          end

          ST_ERROR_1: begin

              uo_out_data = {fill_count[4:0], 3'h1};

          end

          ST_ERROR_2: begin

              uo_out_data = occ_msb;

          end

          ST_ERROR_3: begin

              uo_out_data = occ_lsb;

          end

          ST_FINAL: begin

              uo_out_data = {7'b0, last};

          end        

          default: begin

              uo_out_data = 8'h00;

          end

      endcase

	end

  assign uo_out = uo_out_data;
  assign uio_out_int = uio_out_int_q;
  assign uio_oe_int  = uio_oe_int_q;

endmodule

