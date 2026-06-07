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
        # Score LUT
        self.lut = np.array([
            [ 0,  1, -2, -2, -2,  2, -2,  2], # 0
            [ 1,  0,  2, -2,  2, -2, -2,  2], # 1
            [-2,  2,  0,  1, -2,  2,  2,  2], # 2
            [-2, -2,  1,  0, -2,  2,  2,  2], # 3
            [-2,  2, -2, -2,  0,  1, -2,  2], # 4
            [ 2, -2,  2,  2,  1,  0, -2,  2], # 5
            [-2, -2,  2,  2, -2, -2,  0,  1], # 6
            [ 2,  2,  2,  2,  2,  2,  1,  0]  # 7
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
        if neighbor_count == 0: delta = 2
        self.board[row, col] = pattern
        return delta

    def check_score(self, actual, expected, player_type="Human"):
        if actual != expected:
            self.total_mismatches += 1
            if player_type == "Human": self.human_mismatches += 1
            else: self.design_mismatches += 1
            self.log.error(f"MISMATCH [{player_type}]: Expected {expected}, Got {actual}")
            return False
        return True

@cocotb.test()
async def test_harmony_final(dut):
    # --- 1. SETUP ---
    # Method 1 of seed #seed = int(os.environ.get('TESTSEED', 1212))
    # Method 1 of seed #random.seed(seed)
    # Method 2 of seed #seed = int(os.urandom(4).hex(), 16)
    
    # --- LINK TO REGRESSION SCRIPT ---
    # We look for the 'TESTSEED' environment variable.
    # The regression script will change this value for every run.
    env_seed = os.environ.get('TESTSEED')
    
    if env_seed is not None:
        seed = int(env_seed)
        dut._log.info(f"Regression Mode: Using Seed from environment: {seed}")
    else:
        seed = random.randint(0, 99999)
        dut._log.info(f"Standalone Mode: Using locally generated Seed: {seed}")
    
    random.seed(seed)
    # ---------------------------------
    
    dut._log.info(f"SIMULATION START - Seed: {seed}")

    scoreboard = HardwareScoreboard(dut._log)
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    # --- 2. RESET ---
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    def get_state():
        # return dut.uio_out.value[3:1].to_unsigned()
        return (int(dut.uio_out.value) >> 1) & 0x7 # Change for Blackbox, also removed debug logic below

    total_h, total_d = 0, 0
    
    # --- 3. MAIN GAME LOOP (8 ROUNDS) ---
    for r_idx in range(1, 9):
        dut._log.info(f"\n--- ROUND {r_idx} ---")
        my_pos = random.randint(0, 15)
        my_pat = random.randint(1, 7)
        move_accepted = False

        # --- A. HUMAN MOVE SUBMISSION ---
        occ_msb, occ_lsb = 0, 0 # Initialize to prevent NameError
        available_slots = []
        while not move_accepted:
            # 1. IMPORTANT: Advance time to clear any ReadOnly phase from the previous round
            await RisingEdge(dut.clk)
            
            # 2. Drive the target move
            dut.ui_in.value = (my_pat << 4) | my_pos
            await RisingEdge(dut.clk)
            
            # 3. Pulse the START bit high
            dut.ui_in.value = (1 << 7) | (my_pat << 4) | my_pos
            await RisingEdge(dut.clk)
            
            # 4. Release START pulse
            dut.ui_in.value = (my_pat << 4) | my_pos
            
            # 5. Monitor the FSM for the result of THIS specific move
            while True:
                await RisingEdge(dut.clk)
                await ReadOnly()
                # Check BOTH buses for X/Z values (Crucial for GLS)
                if not (dut.uio_out.value.is_resolvable and dut.uo_out.value.is_resolvable): # Change for Blackbox X testing if signal resolvable/not
                    continue
                
                curr_s = get_state()
                if curr_s == 2: # ST_HUMANPLAY: Success!
                    move_accepted = True
                    break 

                elif curr_s == 7: # ST_ERROR_3: Collision!
                    # Capture occupancy from pins to choose a valid retry
                    occ_lsb = int(dut.uo_out.value)
                    recovered_occ = (occ_msb << 8) | occ_lsb
                    
                    dut._log.info(f"Collision at Pos {my_pos}. Hardware rejected move.")
                    
                    # Choose a guaranteed-empty slot for the next attempt
                    # available_slots = [i for i in range(16) if not ((recovered_occ >> i) & 1)]
                    available_slots = [i for i in range(16) if scoreboard.board.flatten()[i] == -1] # CHange for Blackbox testing
                    
                    if not available_slots:
                        dut._log.error("Black-box Error: Scoreboard thinks board is full!")
                        return 
                    
                    my_pos = random.choice(available_slots)
                    dut._log.info(f"Collision at {my_pos}. Retrying...")

                    # --- CRITICAL: Wait for FSM to return to IDLE (0) before restarting loop ---
                    while True:
                        await RisingEdge(dut.clk)
                        await ReadOnly()
                        if dut.uio_out.value.is_resolvable and get_state() == 0:
                            break
                    
                    # Exit the 'While True' monitor to restart the 'While not move_accepted' loop
                    break 

                elif curr_s == 6: # Shift out MSB for occ
                    occ_msb = int(dut.uo_out.value)

        # --- B. SAMPLE HUMAN SCORE ---
        # At this point, move_accepted is True, and the FSM is in State 2 (HUMANPLAY)
        # We sample the score BEFORE the next rising edge.
        h_round_score = dut.uo_out.value.to_signed()
        expected_h = scoreboard.get_score_and_update(my_pat, my_pos)
        scoreboard.check_score(h_round_score, expected_h, "Human")
        total_h += h_round_score
        dut._log.info(f"Human Move: Pos {my_pos}, Pat {my_pat} | Round Score: {h_round_score}")

        # --- C. SAMPLE DESIGN MOVE AND SCORE ---
        design_pos, design_pat, d_round_score = None, None, None
        timeout = 0
        max_timeout = 2000 # Safety limit: 2000 clock cycles
        
        while d_round_score is None:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if not dut.uio_out.value.is_resolvable: continue
            
            curr_s = get_state()          
            # If we see State 3, capture the move data. 
            # We don't break yet because we need the score from State 4.
            if curr_s == 3:
                uo_val = dut.uo_out.value.to_unsigned()
                design_pos = uo_val & 0xF
                design_pat = (uo_val >> 4) & 0x7
            
            # If we see State 4, capture the score and EXIT the loop.
            elif curr_s == 4:
                d_round_score = dut.uo_out.value.to_signed()
                # If we missed State 3 but hit State 4, we must have jumped quickly.
                # In GLS, this is common.
                if design_pos is None:
                    dut._log.warning("Missed ST_DESIGNPLAY (3) sampling but caught ST_DESIGNREST (4).")
                break
            
            # Safety exit if hardware jumps past play states to IDLE or FINAL
            elif curr_s in [0, 8] and timeout > 10:
                dut._log.error(f"FSM bypassed Design states! Current State: {curr_s}")
                break
            
            timeout += 1
            if timeout > max_timeout:
                dut._log.error("Simulation Hang: Timeout waiting for Design Move (ST_DESIGNPLAY/REST)")
                break

        # Only update scoreboard if we actually captured a move
        if d_round_score is not None and design_pos is not None:
            expected_d = scoreboard.get_score_and_update(design_pat, design_pos)
            scoreboard.check_score(d_round_score, expected_d, "Design")
            total_d += d_round_score
            dut._log.info(f"Design Move: Pos {design_pos}, Pat {design_pat} | Round Score: {d_round_score}")
        else:
            dut._log.error("Failed to capture valid Design Move data.")

        # --- D. HANDSHAKE (Wait for Reset to IDLE or FINAL) ---
        # We sample state AFTER the edge to ensure we see the transition out of State 4
        handshake_timeout = 0
        while True:
            # Check current state first (we might already be in 0 or 8)
            if get_state() in [0, 8]:
                break
            await RisingEdge(dut.clk)
            await ReadOnly()
            handshake_timeout += 1
            if handshake_timeout > 100:
                dut._log.error("Handshake Hang: FSM stuck in State 4 or didn't return to IDLE/FINAL")
                break
    # --- 4. FINAL RESULTS ---
    dut._log.info("\n" + "="*45)
    dut._log.info(f"FINAL SCORE - Human: {total_h} | Design: {total_d}")
    dut._log.info("-" * 45)
    winner = "HUMAN" if total_h > total_d else ("DESIGN" if total_d > total_h else "DRAW")
    dut._log.info(f"WINNER: {winner}")
    dut._log.info("-" * 45)
    dut._log.info(f"Human Mismatches: {scoreboard.human_mismatches}")
    dut._log.info(f"Design Mismatches: {scoreboard.design_mismatches}")
    dut._log.info("="*45 + "\n")

    await ClockCycles(dut.clk, 20)
    assert scoreboard.total_mismatches == 0
