`default_nettype none

module harmony_core (
    input wire clk,
    input wire rst_n,
    input wire start,     
    input wire [3:0] h_pos,     
    input wire [2:0] h_pat,     
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

    // =========================================================================
    // FANOUT SPLIT: STRUCTURAL RESET DOMAIN DUPLICATION
    // =========================================================================
    (* keep *) wire rst_n_fsm   = rst_n;
    (* keep *) wire rst_n_game  = rst_n;
    (* keep *) wire rst_n_board = rst_n;
    (* keep *) wire rst_n_score = rst_n;
    (* keep *) wire rst_n_out   = rst_n;

    // --- Declarations of Internal Signals ---
    reg [3:0]  curr_state;
    reg [3:0]  nxt_state;
    reg [2:0]  board [0:15];     
    reg [15:0] occ;            
    reg signed [7:0] hscorefinal, dscorefinal; 
    reg signed [7:0] nxt_dscorefinal, nxt_hscorefinal;
    reg signed [7:0] nxt_acc_hscore, nxt_acc_dscore;
    reg [4:0]  uio_out_int_q;
    reg [1:0]  uio_oe_int_q;
    reg [15:0] lfsr;
    reg [4:0]  fill_count; 
    reg [7:0]  uo_out_data;
    reg [3:0]  c_h_pos;
    reg [2:0]  c_h_pat;
    reg [2:0]  design_pat;
    reg        design_strat_mode; 
    
    // Pipeline & Latency Control Registers
    reg signed [7:0] parallel_fitness_q [0:15]; 
    reg        strat_cycle; 

    wire [7:0] occ_msb;
    wire [7:0] occ_lsb;
    wire last;
    wire [2:0] next_design_pat;
    
    reg [3:0] lfsr_pos;
    wire [3:0] lfsr_lookahead;
    reg signed [7:0] acc_dscore_reg; 
    reg [4:0] clear_idx; 
    reg signed [7:0] acc_hscore_reg; 
    
    reg [7:0] uo_out_r;
    reg [4:0] uio_out_int_r;
    reg [1:0] uio_oe_int_r;
    
    assign lfsr_lookahead = lfsr[3:0];
    assign occ_msb        = occ[15:8];
    assign occ_lsb        = occ[7:0];
    assign last           = (fill_count == 5'd16);

    // =========================================================================
    // PARALLEL DECOUPLED NEIGHBOR LOOKUP NETWORKS (HUMAN)
    // =========================================================================
    wire [3:0] h_idx_n = c_h_pos - 4;
    wire [3:0] h_idx_s = c_h_pos + 4;
    wire [3:0] h_idx_w = c_h_pos - 1;
    wire [3:0] h_idx_e = c_h_pos + 1;

    wire h_has_n = (c_h_pos >= 4)          && occ[h_idx_n];
    wire h_has_s = (c_h_pos <= 11)         && occ[h_idx_s];
    wire h_has_w = (c_h_pos[1:0] != 2'b00) && occ[h_idx_w];
    wire h_has_e = (c_h_pos[1:0] != 2'b11) && occ[h_idx_e];

    wire [2:0] h_pat_n = (c_h_pos >= 4)          ? board[h_idx_n] : 3'b0;
    wire [2:0] h_pat_s = (c_h_pos <= 11)         ? board[h_idx_s] : 3'b0;
    wire [2:0] h_pat_w = (c_h_pos[1:0] != 2'b00) ? board[h_idx_w] : 3'b0;
    wire [2:0] h_pat_e = (c_h_pos[1:0] != 2'b11) ? board[h_idx_e] : 3'b0;

    // =========================================================================
    // PARALLEL DECOUPLED NEIGHBOR LOOKUP NETWORKS (DESIGN / PIPELINE STABLE)
    // =========================================================================
    wire [3:0] d_idx_n = lfsr_pos - 4;
    wire [3:0] d_idx_s = lfsr_pos + 4;
    wire [3:0] d_idx_w = lfsr_pos - 1;
    wire [3:0] d_idx_e = lfsr_pos + 1;

    wire d_has_n = (lfsr_pos >= 4)          && occ[d_idx_n];
    wire d_has_s = (lfsr_pos <= 11)         && occ[d_idx_s];
    wire d_has_w = (lfsr_pos[1:0] != 2'b00) && occ[d_idx_w];
    wire d_has_e = (lfsr_pos[1:0] != 2'b11) && occ[d_idx_e];

    wire [2:0] d_pat_n = (lfsr_pos >= 4)          ? board[d_idx_n] : 3'b0;
    wire [2:0] d_pat_s = (lfsr_pos <= 11)         ? board[d_idx_s] : 3'b0;
    wire [2:0] d_pat_w = (lfsr_pos[1:0] != 2'b00) ? board[d_idx_w] : 3'b0;
    wire [2:0] d_pat_e = (lfsr_pos[1:0] != 2'b11) ? board[d_idx_e] : 3'b0;

    // --- Pairwise Score LUT ---
    function signed [3:0] get_pair_score;
        input [2:0] p1;
        input [2:0] p2;
        reg [5:0] pair;
        begin
            pair = (p1 < p2) ? {p1, p2} : {p2, p1};
            if (p1 == p2) get_pair_score = 4'sd0; 
            else begin
                case (pair)
                    6'b000_001, 6'b010_011, 6'b100_101, 6'b110_111: get_pair_score =  4'sd1;
                    6'b000_101, 6'b000_111, 6'b001_010, 6'b001_100, 
                    6'b001_111, 6'b010_101, 6'b010_110, 6'b010_111, 
                    6'b011_101, 6'b011_110, 6'b011_111, 6'b100_111, 
                                                        6'b101_111: get_pair_score =  4'sd2;
                    
                    6'b000_010, 6'b000_011, 6'b000_100, 6'b000_110, 
                    6'b001_011, 6'b001_101, 6'b001_110, 6'b010_100, 
                                6'b011_100, 6'b100_110, 6'b101_110: get_pair_score = -4'sd4;
                               default: get_pair_score =  4'sd0;
                endcase
            end
        end
    endfunction

    // --- Balanced Compressed Adder Tree ---
    function signed [7:0] calc_move_value;
        input [2:0] pat;
        input       has_n, has_s, has_w, has_e;
        input [2:0] pat_n, pat_s, pat_w, pat_e;
        reg signed [7:0] s_n, s_s, s_w, s_e;
        reg signed [7:0] sum_ns, sum_we;
        begin
            s_n = has_n ? 8'($signed(get_pair_score(pat, pat_n))) : 8'sd0;
            s_s = has_s ? 8'($signed(get_pair_score(pat, pat_s))) : 8'sd0;
            s_w = has_w ? 8'($signed(get_pair_score(pat, pat_w))) : 8'sd0;
            s_e = has_e ? 8'($signed(get_pair_score(pat, pat_e))) : 8'sd0;
            
            sum_ns = s_n + s_s;
            sum_we = s_w + s_e;

            if (!has_n && !has_s && !has_w && !has_e) begin
                calc_move_value = 8'sd2; 
            end else begin
                calc_move_value = sum_ns + sum_we;
            end
        end
    endfunction

    function [2:0] get_positional_weight;
        input [3:0] idx;
        begin
            case (idx)
                4'd0, 4'd3, 4'd12, 4'd15:                          get_positional_weight = 3'd2; 
                4'd1, 4'd2, 4'd4, 4'd7, 4'd8, 4'd11, 4'd13, 4'd14: get_positional_weight = 3'd3; 
                default:                                           get_positional_weight = 3'd4; 
            endcase
        end
    endfunction

    // =========================================================================
    // PIPELINE STAGE 1: PARALLEL MASKED EVALUATOR GENERATE ARRAY (WIRES)
    // =========================================================================
    wire signed [7:0] parallel_fitness [0:15];

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_parallel_mac
            wire [3:0] n_idx = i - 4;
            wire [3:0] s_idx = i + 4;
            wire [3:0] w_idx = i - 1;
            wire [3:0] e_idx = i + 1;

            wire cell_has_n = (i >= 4)         && occ[n_idx];
            wire cell_has_s = (i <= 11)        && occ[s_idx];
            wire cell_has_w = (i % 4 != 0)     && occ[w_idx];
            wire cell_has_e = (i % 4 != 3)     && occ[e_idx];

            wire [2:0] cell_pat_n = cell_has_n ? board[n_idx] : 3'b0;
            wire [2:0] cell_pat_s = cell_has_s ? board[s_idx] : 3'b0;
            wire [2:0] cell_pat_w = cell_has_w ? board[w_idx] : 3'b0;
            wire [2:0] cell_pat_e = cell_has_e ? board[e_idx] : 3'b0;

            wire [2:0] active_pat = occ[i] ? 3'b000 : next_design_pat;

            wire signed [7:0] raw_harmony = calc_move_value(active_pat, cell_has_n, cell_has_s, cell_has_w, cell_has_e, cell_pat_n, cell_pat_s, cell_pat_w, cell_pat_e);
            wire [2:0] pos_weight         = get_positional_weight(i);

            reg signed [7:0] calculated_mac;
            always_comb begin
                case (pos_weight)
                    3'd2:    calculated_mac = raw_harmony << 1;
                    3'd3:    calculated_mac = (raw_harmony << 1) + raw_harmony;
                    3'd4:    calculated_mac = raw_harmony << 2;
                    default: calculated_mac = raw_harmony;
                endcase
            end

            assign parallel_fitness[i] = occ[i] ? 8'sh80 : calculated_mac;
        end
    endgenerate

    // --- PIPELINE REGISTER BOUNDARY ---
    integer k;
    always_ff @(posedge clk or negedge rst_n_score) begin
        if (!rst_n_score) begin
            for (k = 0; k < 16; k = k + 1) begin
                parallel_fitness_q[k] <= 8'sh80;
            end
        end else begin
            for (k = 0; k < 16; k = k + 1) begin
                parallel_fitness_q[k] <= parallel_fitness[k];
            end
        end
    end

    // =========================================================================
    // PIPELINE STAGE 2: COMBINATIONAL BINARY MAX-TREE REDUCTION
    // =========================================================================
    // Driven safely by completely stable parallel_fitness_q registers
    wire signed [7:0] L1_score [0:7];
    wire [3:0]        L1_idx   [0:7];
    wire signed [7:0] L2_score [0:3];
    wire [3:0]        L2_idx   [0:3];
    wire signed [7:0] L3_score [0:1];
    wire [3:0]        L3_idx   [0:1];
    wire signed [7:0] final_strategic_score;
    wire [3:0]        final_strategic_idx;

    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_l1
            assign L1_score[i] = (parallel_fitness_q[2*i] >= parallel_fitness_q[2*i+1]) ? parallel_fitness_q[2*i] : parallel_fitness_q[2*i+1];
            assign L1_idx[i]   = (parallel_fitness_q[2*i] > parallel_fitness_q[2*i+1]) ? (2*i) :
                                 (parallel_fitness_q[2*i+1] > parallel_fitness_q[2*i]) ? (2*i+1) : (lfsr[0] ? (2*i) : (2*i+1));
        end
    endgenerate

    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_l2
            assign L2_score[i] = (L1_score[2*i] >= L1_score[2*i+1]) ? L1_score[2*i] : L1_score[2*i+1];
            assign L2_idx[i]   = (L1_score[2*i] > L1_score[2*i+1]) ? L1_idx[2*i] :
                                 (L1_score[2*i+1] > L1_score[2*i]) ? L1_idx[2*i+1] : (lfsr[1] ? L1_idx[2*i] : L1_idx[2*i+1]);
        end
    endgenerate

    generate
        for (i = 0; i < 2; i = i + 1) begin : gen_l3
            assign L3_score[i] = (L2_score[2*i] >= L2_score[2*i+1]) ? L2_score[2*i] : L2_score[2*i+1];
            assign L3_idx[i]   = (L2_score[2*i] > L2_score[2*i+1]) ? L2_idx[2*i] :
                                 (L2_score[2*i+1] > L2_score[2*i]) ? L2_idx[2*i+1] : (lfsr[2] ? L2_idx[2*i] : L2_idx[2*i+1]);
        end
    endgenerate

    assign final_strategic_score = (L3_score[0] >= L3_score[1]) ? L3_score[0] : L3_score[1];
    assign final_strategic_idx   = (L3_score[0] > L3_score[1]) ? L3_idx[0] :
                                   (L3_score[1] > L3_score[0]) ? L3_idx[1] : (lfsr[3] ? L3_idx[0] : L3_idx[1]);

    // =========================================================================
    // CONTROL STATE MACHINE (Pipelined Stall Logic Included)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n_fsm) begin
        if (!rst_n_fsm) curr_state <= ST_IDLE;
        else             curr_state <= nxt_state;
    end

    always_comb begin
        nxt_state = curr_state;
        case (curr_state)
            ST_IDLE:       if (start) nxt_state = ST_VALIDATE;
            ST_VALIDATE:   nxt_state = (!occ[c_h_pos]) ? ST_HUMANPLAY : ST_ERROR_1;
            ST_HUMANPLAY:  nxt_state = ST_DESIGNPLAY;
            ST_DESIGNPLAY: begin
                if (design_strat_mode == 1'b1) begin
                    // Wait for the 2-cycle pipelined calculation loop to resolve
                    nxt_state = (strat_cycle == 1'b1) ? ST_DESIGNREST : ST_DESIGNPLAY;
                end else begin
                    if (!occ[lfsr_lookahead]) 
                        nxt_state = ST_DESIGNREST; 
                    else 
                        nxt_state = ST_DESIGNPLAY; 
                end
            end
            ST_DESIGNREST: nxt_state = (fill_count == 5'd16) ? ST_FINAL : ST_IDLE;
            ST_ERROR_1:    nxt_state = ST_ERROR_2;
            ST_ERROR_2:    nxt_state = ST_ERROR_3;
            ST_ERROR_3:    nxt_state = ST_IDLE;
            ST_FINAL:      nxt_state = ST_IDLE;
            default:       nxt_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // DATA LAYER DECOUPLING & REGISTRATION DOMAINS
    // =========================================================================
    assign next_design_pat = (lfsr[6:4] == 3'b000) ? (lfsr[15:13] | 3'b001) : lfsr[6:4];

    // --- 3A. Game Tracking, LFSR, & Pipeline Latency Synchronization ---
    always_ff @(posedge clk or negedge rst_n_game) begin
        if (!rst_n_game) begin
            fill_count        <= 5'd0;
            lfsr              <= 16'hACE1;
            lfsr_pos          <= 4'b0;
            clear_idx         <= 5'd0;
            c_h_pos           <= 4'b0;
            c_h_pat           <= 3'b0;
            design_strat_mode <= 1'b0;
            strat_cycle       <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            
            if (curr_state == ST_HUMANPLAY) begin
                design_strat_mode <= lfsr[8];
            end

            case (curr_state)
                ST_IDLE: begin
                    if (clear_idx < 5'd16) begin
                        clear_idx <= clear_idx + 1'b1;
                    end
                    if (start) begin
                        c_h_pos <= h_pos;
                        c_h_pat <= h_pat;
                    end
                end
                ST_HUMANPLAY: begin
                    fill_count <= fill_count + 1'b1;
                end
                ST_DESIGNPLAY: begin
                    if (design_strat_mode == 1'b1) begin
                        if (strat_cycle == 1'b0) begin
                            strat_cycle <= 1'b1; // Cycle 1: Parallel Fitness loads into registers
                        end else begin
                            lfsr_pos    <= final_strategic_idx; // Cycle 2: Max-Tree output updates safely
                            fill_count  <= fill_count + 1'b1;
                            strat_cycle <= 1'b0;
                        end
                    end else begin
                        if (!occ[lfsr_lookahead]) begin
                            lfsr_pos   <= lfsr_lookahead;         
                            fill_count <= fill_count + 1'b1;
                        end
                    end
                end
                default: begin
                    strat_cycle <= 1'b0;
                end
            endcase
        end
    end  

    // --- 3B. Board Fabric State Domain ---
    always_ff @(posedge clk or negedge rst_n_board) begin
        if (!rst_n_board) begin
            occ        <= 16'h0;
            design_pat <= 3'b0;
        end else begin
            case (curr_state)
                ST_IDLE: begin
                    if (clear_idx < 5'd16) begin
                        board[clear_idx[3:0]] <= 3'b0;
                    end
                end
                ST_HUMANPLAY: begin
                    board[c_h_pos] <= c_h_pat;
                    occ[c_h_pos]   <= 1'b1;
                end
                ST_DESIGNPLAY: begin
                    design_pat <= next_design_pat;
                    
                    if (design_strat_mode == 1'b1) begin
                        if (strat_cycle == 1'b1) begin // Commit only on the safe valid pipeline boundary
                            board[final_strategic_idx] <= next_design_pat;
                            occ[final_strategic_idx]   <= 1'b1;
                        end
                    end else begin
                        if (!occ[lfsr_lookahead]) begin
                            board[lfsr_lookahead] <= next_design_pat;
                            occ[lfsr_lookahead]   <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    // --- 3C. Pipeline Calculation & Score Accumulators Domain ---
    always_ff @(posedge clk or negedge rst_n_score) begin
        if (!rst_n_score) begin
            hscorefinal    <= 8'sd0;
            dscorefinal    <= 8'sd0;
            acc_dscore_reg <= 8'sd0;
            acc_hscore_reg <= 8'sd0;
        end else begin
            case (curr_state)
                ST_VALIDATE: begin
                    acc_hscore_reg <= calc_move_value(c_h_pat, h_has_n, h_has_s, h_has_w, h_has_e, h_pat_n, h_pat_s, h_pat_w, h_pat_e);
                end
                ST_HUMANPLAY: begin
                    hscorefinal <= hscorefinal + acc_hscore_reg;
                end
                ST_DESIGNREST: begin
                    dscorefinal    <= nxt_dscorefinal;
                    acc_dscore_reg <= nxt_acc_dscore;
                end
            endcase
        end
    end

    // --- 4. Mathematical Optimization Block (Combinational Core) ---
    wire [2:0] d_weight = get_positional_weight(lfsr_pos);
    wire signed [7:0] d_base_val = calc_move_value(design_pat, d_has_n, d_has_s, d_has_w, d_has_e, d_pat_n, d_pat_s, d_pat_w, d_pat_e);
    reg signed [7:0] d_weighted_val;

    always_comb begin
        case (d_weight)
            3'd2:    d_weighted_val = d_base_val << 1;
            3'd3:    d_weighted_val = (d_base_val << 1) + d_base_val;
            3'd4:    d_weighted_val = d_base_val << 2;
            default: d_weighted_val = d_base_val;
        endcase
    end

    always_comb begin
        nxt_dscorefinal = dscorefinal;
        nxt_hscorefinal = hscorefinal;
        nxt_acc_hscore  = 8'sd0;
        nxt_acc_dscore  = 8'sd0;
        uio_out_int_q   = {curr_state, 1'b0}; 
        uio_oe_int_q    = 2'b11;       

        case (curr_state)
            ST_HUMANPLAY: begin
                nxt_acc_hscore  = acc_hscore_reg; 
                nxt_hscorefinal = hscorefinal + nxt_acc_hscore;
            end
            ST_DESIGNPLAY: begin
                uio_out_int_q[0] = design_strat_mode; 
            end
            ST_DESIGNREST: begin
                uio_out_int_q[0] = 1'b1; 
                nxt_acc_dscore  = design_strat_mode ? d_weighted_val : d_base_val;
                nxt_dscorefinal = dscorefinal + nxt_acc_dscore;
            end
            default: begin
                nxt_dscorefinal = dscorefinal;
                nxt_hscorefinal = hscorefinal;
                nxt_acc_hscore  = 8'sd0;
                nxt_acc_dscore  = 8'sd0;
                uio_out_int_q   = {curr_state, 1'b0}; 
                uio_oe_int_q    = 2'b11;
            end
        endcase
    end

    // --- 5. Output Bus Multiplexing (Combinational Core) ---
    always_comb begin
        uo_out_data = 8'h00; 
        case (curr_state)
            ST_IDLE:       uo_out_data = 8'h00;
            ST_HUMANPLAY:  uo_out_data = nxt_acc_hscore;
            ST_DESIGNPLAY: uo_out_data = design_strat_mode ? {1'b1, next_design_pat, final_strategic_idx} :
                                                             {1'b0, next_design_pat, lfsr_lookahead};
            ST_DESIGNREST: uo_out_data = nxt_acc_dscore;
            ST_ERROR_1:    uo_out_data = {fill_count[4:0], 3'h1};
            ST_ERROR_2:    uo_out_data = occ_msb;
            ST_ERROR_3:    uo_out_data = occ_lsb;
            ST_FINAL:      uo_out_data = {7'b0, last};
            default:       uo_out_data = 8'h00;
        endcase
    end

    // --- 6. Clean Synchronous Output Boundary ---
    always_ff @(posedge clk or negedge rst_n_out) begin
        if (!rst_n_out) begin
            uo_out_r      <= 8'h00;
            uio_out_int_r <= 5'b0;
            uio_oe_int_r  <= 2'b0;
        end else begin
            uo_out_r      <= uo_out_data;
            uio_out_int_r <= uio_out_int_q;
            uio_oe_int_r  <= uio_oe_int_q;
        end
    end

    assign uo_out      = uo_out_r;
    assign uio_out_int = uio_out_int_r;
    assign uio_oe_int  = uio_oe_int_r;

endmodule
