// mem_recoil: the recoil from the game's memory, by rules (recoil_db.sv: the entry's layout; tools/recoil_db.py).
// Watches the CPU's writes into its work RAM, as a 68000 bus gives them: a word address, both byte lanes and their
// strobes (the NES feeds its byte writes as a lane: an even address the upper byte, an odd one the lower).
//
// The entry's state variables keep the game's last value written at their address (0 before); each gives a condition,
// (value & mask) == value field (e.g. "not in the attract mode's demo", "in a flying phase"), and a value (e.g. the
// weapon in use, which picks the pulse's length in the entry's table). A rule fires a recoil pulse on its player's gun
// when its event happens at its address while its conditions hold:
//   1 dec     the value one less, from more than 0 (signed): a shot, not an empty gun (0 -> FF) nor a reload
//   2 digit   a decimal digit (0..9) one less, 0 -> 9 included: the units of a count kept as digits
//   3 bcd     a BCD byte one less (30 -> 29)
//   4 becomes the value written is the rule's value, and was not before
//   5 trigger no event: while its conditions hold, the gun's trigger makes the recoil (e.g. an unlimited cannon)
// A player with a rule (other than trigger) is active: its trigger recoil is off, except while a trigger rule holds.
//
// The sequencer reads the entry's pairs 2..15 one a clock (the states, the table, then the rules), and scans again and
// again: a scan takes a CPU write if one is pending (a write is taken once, on its strobes' rise), else it only
// refreshes the conditions. 16 clocks a scan, a pending write kept: a write every 16 clocks at most on average (the
// NES CPU: one every 24 clk_analogizer clocks at most).
// All in clk; cfg_valid / cfg_entry come from clk_74a (quasi-static, cfg_valid synchronised here).
module mem_recoil (
	input  wire        clk,
	input  wire        cfg_valid,              // (clk_74a)
	input  wire  [4:0] cfg_entry,              // (clk_74a, static while cfg_valid)
	output reg   [8:0] rd_addr = 9'd0,         // the database: {entry, pair}
	input  wire [63:0] rd_data,                //   (1 clock after rd_addr)
	input  wire        ram_wr,                 // a write into the work RAM, held while it lasts
	input  wire [15:1] ram_wa,
	input  wire [15:0] ram_wd,
	input  wire  [1:0] ram_wbe,                // {upper, lower}
	output reg   [1:0] active = 2'b00,         // the player's recoil comes from here
	output reg   [1:0] trig_en = 2'b00,        // ... and also from its trigger (a trigger rule holds)
	output reg   [1:0] shot = 2'b00,           // one clock a shot
	output reg   [7:0] pulse1_ms = 8'd0, pulse2_ms = 8'd0   // the pulse's length of the last shot
);
	reg  [2:0] v_s = 3'd0;
	always @(posedge clk) v_s <= {v_s[1:0], cfg_valid};
	wire       valid = v_s[2];

	// the write, taken once on its strobes' rise (a 68000 bus gives the strobes only for the clock the RAM is written)
	wire       wrx = ram_wr && ram_wbe != 2'b00;
	reg        wr_d = 1'b0;
	always @(posedge clk) wr_d <= wrx;
	wire       wr = wrx && !wr_d;
	reg        pend = 1'b0;
	reg [15:1] pwa = 15'd0;  reg [15:0] pwd = 16'd0;  reg [1:0] pwbe = 2'b00;

	// the value written at a watched address: {hit, value} (a byte: the address's byte lane; a word: both lanes)
	function automatic [16:0] take(input [31:0] cfg, input [15:1] wa, input [15:0] wd, input [1:0] wbe);
		if (!cfg[25] || wa != cfg[15:1]) take = 17'd0;
		else if (cfg[24]) take = {&wbe, wd};
		else if (!cfg[0]) take = {wbe[1], 8'd0, wd[15:8]};
		else take = {wbe[0], 8'd0, wd[7:0]};
	endfunction
	function automatic [7:0] bcd_less(input [7:0] v);     // v - 1 in BCD (v > 0)
		bcd_less = v[3:0] == 4'd0 ? {v[7:4] - 4'd1, 4'd9} : {v[7:4], v[3:0] - 4'd1};
	endfunction
	function automatic fired(input [3:0] ev, input [15:0] nv, input [15:0] ov, input word, input [7:0] val);
		case (ev)
			4'd1: fired = word ? (!ov[15] && ov != 16'd0 && nv == ov - 16'd1)
			                   : (!ov[7] && ov[7:0] != 8'd0 && nv[7:0] == ov[7:0] - 8'd1);
			4'd2: fired = nv[7:0] <= 8'd9 && ov[7:0] <= 8'd9 && (ov[3:0] == 4'd0 ? nv[3:0] == 4'd9 : nv[3:0] == ov[3:0] - 4'd1);
			4'd3: fired = ov[7:0] != 8'd0 && ov[3:0] <= 4'd9 && nv[7:0] == bcd_less(ov[7:0]);
			4'd4: fired = nv[7:0] == val && ov[7:0] != val;
			default: fired = 1'b0;
		endcase
	endfunction

	// the scan: pair ip issued, pair ep evaluated two clocks later
	reg        scan = 1'b0, cur_w = 1'b0;
	reg [15:1] cwa = 15'd0;  reg [15:0] cwd = 16'd0;  reg [1:0] cwbe = 2'b00;
	reg  [3:0] ip = 4'd0, ip1 = 4'd0, ep = 4'd0;
	reg  [1:0] iv = 2'b00;                     // a pair issued 1 / 2 clocks ago
	reg [15:0] stv [0:3];                      // the states' values
	reg  [3:0] cond = 4'd0;
	reg [63:0] tbl = 64'd0;
	reg [15:0] old [0:8];
	reg  [8:0] seen = 9'd0;
	reg  [1:0] acc_act = 2'b00, acc_trig = 2'b00;
	integer i;
	initial for (i = 0; i < 4; i++) stv[i] = 16'd0;

	wire [31:0] ha = rd_data[63:32], lo = rd_data[31:0];
	wire [16:0] t = take(ha, cwa, cwd, cwbe);
	wire        hit = cur_w && t[16];
	wire  [1:0] si = ep[1:0] - 2'd2;           // the state's index (pairs 2..5)
	wire [15:0] snew = hit ? t[15:0] : stv[si];
	wire  [3:0] r = ep - 4'd7;                 // the rule's index (pairs 7..15)
	wire  [3:0] ev = lo[31:28];
	wire        guard = ((cond & lo[15:12]) == lo[15:12]) && ((cond & lo[11:8]) == 4'd0);
	wire  [2:0] tix = stv[lo[25:24]][2:0];
	wire  [7:0] pms = lo[26] ? tbl[8 * (7 - tix) +: 8] : lo[23:16];
	wire        r_act = ha[25] && ev != 4'd0 && ev != 4'd5;
	wire        r_trg = ha[25] && ev == 4'd5 && guard;

	always @(posedge clk) begin
		shot <= 2'b00;
		if (wr) begin pend <= 1'b1; pwa <= ram_wa; pwd <= ram_wd; pwbe <= ram_wbe; end
		if (!valid) begin
			scan <= 1'b0; iv <= 2'b00; seen <= 9'd0; cond <= 4'd0; active <= 2'b00; trig_en <= 2'b00; pend <= 1'b0;
			for (i = 0; i < 4; i++) stv[i] <= 16'd0;
		end else begin
			// issue
			if (!scan) begin
				scan <= 1'b1; rd_addr <= {cfg_entry, 4'd2}; iv[0] <= 1'b1; ip1 <= 4'd2; ip <= 4'd3;
				acc_act <= 2'b00; acc_trig <= 2'b00;
				if (pend) begin cur_w <= 1'b1; cwa <= pwa; cwd <= pwd; cwbe <= pwbe; pend <= wr; end   // (the older one)
				else if (wr) begin cur_w <= 1'b1; cwa <= ram_wa; cwd <= ram_wd; cwbe <= ram_wbe; pend <= 1'b0; end
				else cur_w <= 1'b0;
			end else if (ip != 4'd0) begin
				rd_addr <= {cfg_entry, ip}; iv[0] <= 1'b1; ip1 <= ip; ip <= ip + 4'd1;   // (15 + 1 = 0: the last issued)
			end else iv[0] <= 1'b0;
			iv[1] <= iv[0]; ep <= ip1;
			// evaluate pair ep (rd_data: its words)
			if (iv[1]) begin
				if (ep <= 4'd5) begin
					stv[si] <= snew;
					cond[si] <= ha[25] && ((snew & lo[31:16]) == lo[15:0]);
				end else if (ep == 4'd6) tbl <= rd_data;
				else begin
					if (r_trg) acc_trig[lo[27]] <= 1'b1;
					if (r_act) begin
						acc_act[lo[27]] <= 1'b1;
						if (hit) begin
							if (seen[r] && guard && fired(ev, t[15:0], old[r], ha[24], lo[7:0])) begin
								shot[lo[27]] <= 1'b1;
								if (lo[27]) pulse2_ms <= pms; else pulse1_ms <= pms;
							end
							old[r] <= t[15:0]; seen[r] <= 1'b1;
						end
					end
				end
				if (ep == 4'd15) begin                 // the scan's end
					active <= acc_act | {r_act && lo[27], r_act && !lo[27]};
					trig_en <= acc_trig | {r_trg && lo[27], r_trg && !lo[27]};
					scan <= 1'b0;
				end
			end
		end
	end
endmodule
