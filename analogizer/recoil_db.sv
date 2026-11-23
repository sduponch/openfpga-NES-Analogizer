// recoil_db: the recoil database (data slot "Recoil DB", recoil_db.bin, bridge 0x51000000, up to 4 KB) and the entry of
// the game loaded. Built by tools/recoil_db.py. (From the Genesis Analogizer core's recoil_db.sv.)
// The game is found by a fingerprint of the whole ROM file (an iNES header has no checksum): h = rotl(h, 5) + word
// (mod 2^32) over its 32-bit big-endian words from the first, and its size in bytes (rom_load: the cartridge slot's
// writes only: the custom palette is loaded at the same bridge address).
//
// An entry is 16 pairs of big-endian words (128 bytes), up to 32 entries; a key word 0 of 0 ends the list:
//   pairs 0, 1    the ROM's key: {fingerprint, size in bytes}, {0, 0}
//   pairs 2..5    the state variables 0..3: {flags[31:24], address[23:0]}, {mask[15:0], value[15:0]}
//                 flags bit 1 used, bit 0 a word (else a byte at the address); the game's last value written there is
//                 kept, and the state's condition is (value & mask) == value field
//   pair  6       the pulse table: 8 lengths in ms (byte 0 = index 0), for rules that take their pulse from a state
//   pairs 7..15   the rules 0..8: {flags[31:24], address[23:0]},
//                 {event[31:28], player[27], pulse from the table[26], table index state[25:24], pulse ms[23:16],
//                  conditions required true[15:12], required false[11:8], value[7:0]}
//                 events: 1 the value one less (from more than 0), 2 a decimal digit one less (0 -> 9 included),
//                 3 a BCD byte one less, 4 the value becomes `value`, 5 the gun's trigger (its recoil allowed)
// mem_recoil.sv runs the rules, reading the entry's pairs through the second port (clk, 1 clock latency).
// The search runs when APF has loaded every slot (dataslot_allcomplete); cfg_* are then static until the next ROM
// load starts (its first word). cfg_* are read in clk as quasi-static data (clk_74a is asynchronous to it).
module recoil_db (
	input  wire        clk_74a,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_addr,
	input  wire [31:0] bridge_wr_data,
	input  wire        allcomplete,
	input  wire        rom_load,               // the cartridge slot is being loaded (clk_74a)
	output reg         cfg_valid = 1'b0,       // the game is in the database
	output reg   [4:0] cfg_entry = 5'd0,       // its entry
	input  wire        clk,                    // mem_recoil's clock
	input  wire  [8:0] rd_addr,                // {entry, pair}
	output reg  [63:0] rd_data
);
	// the database, as pairs of words: even words, odd words; port A clk_74a (the bridge's writes, the search), port B clk
	reg  [31:0] db_e [0:511];
	reg  [31:0] db_o [0:511];
	wire        db_wr = bridge_wr && bridge_addr[31:24] == 8'h51 && bridge_addr[23:12] == 12'd0;
	reg   [8:0] sa = 9'd0;
	reg  [31:0] qa_e, qa_o;
	always @(posedge clk_74a) begin
		if (db_wr && !bridge_addr[2]) db_e[bridge_addr[11:3]] <= bridge_wr_data;
		qa_e <= db_e[sa];
	end
	always @(posedge clk_74a) begin
		if (db_wr && bridge_addr[2]) db_o[bridge_addr[11:3]] <= bridge_wr_data;
		qa_o <= db_o[sa];
	end
	always @(posedge clk) rd_data <= {db_e[rd_addr], db_o[rd_addr]};

	// the ROM's fingerprint, taken as the ROM is loaded (bridge 0x10000000 + file offset, words in order)
	reg  [31:0] fp = 32'd0, size = 32'd0;
	wire        rom_wr = bridge_wr && bridge_addr[31:28] == 4'h1 && rom_load;
	always @(posedge clk_74a) if (rom_wr) begin
		if (bridge_addr[27:2] == 26'd0) begin fp <= bridge_wr_data; size <= 32'd4; end
		else begin fp <= {fp[26:0], fp[31:27]} + bridge_wr_data; size <= size + 32'd4; end
	end

	// the search: entry e's key at pairs {e, 0}, {e, 1}
	reg   [1:0] ac = 2'b00;
	reg   [5:0] e = 6'd0;
	reg         k = 1'b0;
	reg   [1:0] st = 2'd0;
	localparam S_IDLE = 2'd0, S_READ = 2'd1, S_WAIT = 2'd2, S_CMP = 2'd3;
	always @(posedge clk_74a) begin
		ac <= {ac[0], allcomplete};
		if (rom_wr && bridge_addr[27:2] == 26'd0) begin cfg_valid <= 1'b0; st <= S_IDLE; end   // (a new ROM)
		else case (st)
			S_IDLE: if (ac == 2'b01) begin cfg_valid <= 1'b0; e <= 6'd0; k <= 1'b0; st <= S_READ; end
			S_READ: begin sa <= {e[4:0], 3'd0, k}; st <= S_WAIT; end
			S_WAIT: st <= S_CMP;                                         // (the RAM's read)
			default: begin
				if (!k && qa_e == 32'd0) st <= S_IDLE;                  // the list's end: not in it
				else if (!k && {qa_e, qa_o} == {fp, size}) begin k <= 1'b1; st <= S_READ; end
				else if (k && {qa_e, qa_o} == 64'd0) begin cfg_entry <= e[4:0]; cfg_valid <= 1'b1; st <= S_IDLE; end
				else if (e == 6'd31) st <= S_IDLE;
				else begin e <= e + 6'd1; k <= 1'b0; st <= S_READ; end
			end
		endcase
	end
endmodule
