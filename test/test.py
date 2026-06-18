import cocotb
import random
import os
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

# --- GLOBAL SCOREBOARD CLASS ---
class HardwareScoreboard:
    def __init__(self, log):
        self.log = log
        self.board = np.full((4, 4), -1, dtype=int)
        self.human_mismatches = 0
        self.design_mismatches = 0
        self.total_mismatches = 0
        self.lfsr = 0xACE1
        
        # Exact 8x8 Pairwise Score Matrix tuned with -4 Fair Play Clashes
        self.lut = np.array([
            [ 0,  1, -4, -4, -4,  2, -4,  2], # AB (0)
            [ 1,  0,  2, -4,  2, -4, -4,  2], # AG (1)
            [-4,  2,  0,  1, -4,  2,  2,  2], # WD (2)
            [-4, -4,  1,  0, -4,  2,  2,  2], # WR (3)
            [-4,  2, -4, -4,  0,  1, -4,  2], # FB (4)
            [ 2, -4,  2,  2,  1,  0, -4,  2], # FS (5)
            [-4, -4,  2,  2, -4, -4,  0,  1], # EG (6)
            [ 2,  2,  2,  2,  2,  2,  1,  0]  # EP (7)
        ])

    def get_score_and_update(self, pattern, position):
        row, col = divmod(position, 4)
        delta = 0
        neighbor_count = 0
        for dr, dc in [(-1, 0), (1, 0), (0, 1), (0, -1)]:
            nr, nc = row + dr, col + dc
            if 0 <= nr < 4 and 0 <= nc < 4:
                neighbor_pat = self.board[nr, nc]
                if neighbor_pat != -1:
                    delta += self.lut[pattern, neighbor_pat]
                    neighbor_count += 1
        if neighbor_count == 0: 
            delta = 2
        self.board[row, col] = pattern
        return delta

    def get_positional_weight(self, idx):
        if idx in [0, 3, 12, 15]: return 2
        elif idx in [1, 2, 4, 7, 8, 11, 13, 14]: return 3
        else: return 4

    def check_score(self, actual, expected, player_type="Human"):
        if actual != expected:
            self.total_mismatches += 1
            if player_type == "Human": self.human_mismatches += 1
            else: self.design_mismatches += 1
            self.log.error(f"MISMATCH [{player_type}]: Expected {expected}, Got {actual}")
            return False
        return True

async def lfsr_shadow_runner(dut, scoreboard):
    while True:
        await RisingEdge(dut.clk)
        try:
            if not dut.rst_n.value.is_resolvable or not dut.ena.value.is_resolvable or dut.rst_n.value == 0 or dut.ena.value == 0:
                scoreboard.lfsr = 0xACE1
            else:
                b15 = (scoreboard.lfsr >> 15) & 1
                b13 = (scoreboard.lfsr >> 13) & 1
                b12 = (scoreboard.lfsr >> 12) & 1
                b10 = (scoreboard.lfsr >> 10) & 1
                fb_bit = b15 ^ b13 ^ b12 ^ b10
                scoreboard.lfsr = ((scoreboard.lfsr << 1) & 0xFFFF) | fb_bit
        except ValueError:
            scoreboard.lfsr = 0xACE1

@cocotb.test()
async def test_harmony_final(dut):
    env_seed = os.environ.get('TESTSEED')
    seed = int(env_seed) if env_seed is not None else random.randint(0, 99999)
    random.seed(seed)
    dut._log.info(f"SIMULATION START - Seed: {seed}")

    scoreboard = HardwareScoreboard(dut._log)
    cocotb.start_soon(lfsr_shadow_runner(dut, scoreboard))
    
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 20)

    def get_state():
        if not dut.uio_out.value.is_resolvable: return -1
        return (int(dut.uio_out.value) >> 1) & 0xF

    total_h, total_d = 0, 0
    
    for r_idx in range(1, 9):
        dut._log.info(f"\n--- ROUND {r_idx} ---")
        
        # --- OMNISCIENT PURE HARMONY MOVE SELECTION ---
        available_slots = [i for i in range(16) if scoreboard.board.flatten()[i] == -1]
        if not available_slots: break
        
        best_harmony = -999
        best_candidates = [] # Holds list of optimal (slot, pattern) pairs
        
        # Exhaustively check ALL empty positions for ALL possible patterns based on PURE HARMONY
        for slot in available_slots:
            for pat in range(1, 8):
                row, col = divmod(slot, 4)
                acc = 0
                n_count = 0
                for dr, dc in [(-1, 0), (1, 0), (0, 1), (0, -1)]:
                    nr, nc = row + dr, col + dc
                    if 0 <= nr < 4 and 0 <= nc < 4:
                        n_p = scoreboard.board[nr, nc]
                        if n_p != -1:
                            acc += scoreboard.lut[pat, n_p]
                            n_count += 1
                            
                raw_harmony = 2 if n_count == 0 else acc
                
                # Evaluation focuses strictly on raw harmony score, completely blind to positional weight
                if raw_harmony > best_harmony:
                    best_harmony = raw_harmony
                    best_candidates = [(slot, pat)]
                elif raw_harmony == best_harmony:
                    best_candidates.append((slot, pat))
        
        # Select best play; break ties randomly if multiple combinations yield max pure score
        my_pos, my_pat = random.choice(best_candidates)
        dut._log.info(f"   [HUMAN STATUS] Pure Strategy Active: Checked all positions. Max harmony: {best_harmony}")

        move_accepted = False

        # --- A. HUMAN MOVE SUBMISSION ---
        while not move_accepted:
            occ_msb = None  
            await RisingEdge(dut.clk)
            dut.ui_in.value = (my_pat << 4) | my_pos
            await RisingEdge(dut.clk)
            dut.ui_in.value = (1 << 7) | (my_pat << 4) | my_pos 
            await RisingEdge(dut.clk)
            dut.ui_in.value = (my_pat << 4) | my_pos            
            
            while True:
                await RisingEdge(dut.clk)
                await ReadOnly()
                if not (dut.uio_out.value.is_resolvable and dut.uo_out.value.is_resolvable): continue
                
                curr_s = get_state()
                if curr_s == 2: # ST_HUMANPLAY
                    h_round_score = dut.uo_out.value.to_signed()
                    expected_h = scoreboard.get_score_and_update(my_pat, my_pos)
                    scoreboard.check_score(h_round_score, expected_h, "Human")
                    total_h += h_round_score
                    dut._log.info(f"Human Move: Pos {my_pos}, Pat {my_pat} | Round Score: {h_round_score}")
                    move_accepted = True
                    break 

                elif curr_s == 6: # ST_ERROR_2
                    occ_msb = int(dut.uo_out.value)

                elif curr_s == 7: # ST_ERROR_3
                    if occ_msb is not None:
                        occ_lsb = int(dut.uo_out.value)
                        recovered_occ = (occ_msb << 8) | occ_lsb
                        dut._log.info(f"Collision at Pos {my_pos}. Retrying...")
                        available_slots = [i for i in range(16) if scoreboard.board.flatten()[i] == -1]
                        if not available_slots: return 
                        
                        # Fallback recovery re-runs optimal evaluation based on pure harmony exclusively on remaining open space
                        best_harmony = -999
                        best_candidates = []
                        for slot in available_slots:
                            for pat in range(1, 8):
                                row, col = divmod(slot, 4)
                                acc = 0
                                n_count = 0
                                for dr, dc in [(-1, 0), (1, 0), (0, 1), (0, -1)]:
                                    nr, nc = row + dr, col + dc
                                    if 0 <= nr < 4 and 0 <= nc < 4:
                                        n_p = scoreboard.board[nr, nc]
                                        if n_p != -1:
                                            acc += scoreboard.lut[pat, n_p]
                                            n_count += 1
                                raw_harmony = 2 if n_count == 0 else acc
                                if raw_harmony > best_harmony:
                                    best_harmony = raw_harmony
                                    best_candidates = [(slot, pat)]
                                elif raw_harmony == best_harmony:
                                    best_candidates.append((slot, pat))
                        
                        my_pos, my_pat = random.choice(best_candidates)
                        break

        # --- B. SAMPLE DESIGN PLAYER INTERFACE ---
        design_pos, design_pat, d_round_score = None, None, None
        strat_active = 0
        timeout = 0
        
        while d_round_score is None:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if not dut.uio_out.value.is_resolvable: continue
            
            curr_s = get_state()          
            if curr_s == 3: # ST_DESIGNPLAY
                uo_val = dut.uo_out.value.to_unsigned()
                strat_active = (uo_val >> 7) & 1 
                design_pat = (uo_val >> 4) & 0x7
                design_pos = uo_val & 0xF        
            
            elif curr_s == 4: # ST_DESIGNREST
                d_round_score = dut.uo_out.value.to_signed()
                break
            
            elif curr_s in [0, 8] and timeout > 10: break
            
            timeout += 1
            if timeout > 2000:
                dut._log.error("Simulation Timeout")
                break

        if d_round_score is not None and design_pos is not None:
            raw_delta = scoreboard.get_score_and_update(design_pat, design_pos)
            expected_d = raw_delta * scoreboard.get_positional_weight(design_pos) if strat_active else raw_delta
            scoreboard.check_score(d_round_score, expected_d, "Design")
            total_d += d_round_score
            dut._log.info(f"Design Move: Pos {design_pos}, Pat {design_pat} | Mode Bit: {strat_active} | Round Score: {d_round_score}")

        while True:
            if get_state() in [0, 8]: break
            await RisingEdge(dut.clk)
            await ReadOnly()

    dut._log.info("\n" + "="*45)
    dut._log.info(f"FINAL SCORE - Human: {total_h} | Design: {total_d}")
    dut._log.info("-" * 45)
    winner = "HUMAN" if total_h > total_d else ("DESIGN" if total_d > total_h else "DRAW")
    dut._log.info(f"WINNER: {winner}")
    dut._log.info("="*45 + "\n")

    await ClockCycles(dut.clk, 20)
    assert scoreboard.total_mismatches == 0
