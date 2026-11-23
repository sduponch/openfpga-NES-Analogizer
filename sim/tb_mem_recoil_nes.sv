// Bench of analogizer/recoil_db.sv and analogizer/mem_recoil.sv as the NES Analogizer wires them
// (openFPGA_Pocket_Analogizer.v): the ROM file loaded through the APF bridge (its fingerprint), the custom palette at
// the same bridge address (not the ROM: rom_load low), the database, then the CPU's internal RAM writes of Duck Hunt
// ($00BA: the shots left) as rtl/nes.v gives them: ram_wr held for the cart_pre window (several clocks), the data
// valid all along, and the 6502's read-modify-write (DEC zp writes the old value, then the new one). Prints ALL PASS or
// SOME FAILED.
//   vlog -sv ../analogizer/recoil_db.sv ../analogizer/mem_recoil.sv tb_mem_recoil_nes.sv
//   vsim -c tb_mem_recoil_nes +DB=<recoil_db.bin> +ROM=<Duck Hunt.nes> +ROM2=<another .nes> -do "run -all"
`timescale 1ns/1ps
module tb_mem_recoil_nes;
reg clk74 = 0, clk = 0;
always #6.734 clk74 = ~clk74;
always #11.64 clk = ~clk;          // clk_analogizer, 42.95 MHz
reg bridge_wr = 0, allcomplete = 0, rom_load = 0; reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
wire valid; wire [4:0] entry; wire [8:0] rd_addr; wire [63:0] rd_data;
recoil_db rdb (.clk_74a(clk74), .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
  .allcomplete(allcomplete), .rom_load(rom_load), .cfg_valid(valid), .cfg_entry(entry), .clk(clk), .rd_addr(rd_addr),
  .rd_data(rd_data));
reg nes_ram_wr = 0; reg [10:0] nes_ram_wa = 0; reg [7:0] nes_ram_wd = 0;
wire [1:0] active, trig_en, shot; wire [7:0] p1ms, p2ms;
mem_recoil mr (.clk(clk), .cfg_valid(valid), .cfg_entry(entry), .rd_addr(rd_addr), .rd_data(rd_data),
  .ram_wr(nes_ram_wr), .ram_wa({5'd0, nes_ram_wa[10:1]}), .ram_wd({nes_ram_wd, nes_ram_wd}),
  .ram_wbe(nes_ram_wa[0] ? 2'b01 : 2'b10), .active(active), .trig_en(trig_en), .shot(shot), .pulse1_ms(p1ms),
  .pulse2_ms(p2ms));
integer last_p1 = 0, last_p2 = 0;
always @(posedge clk) begin if (shot[0]) last_p1 = p1ms; if (shot[1]) last_p2 = p2ms; end

integer f = 0, n1 = 0, n2 = 0;
always @(posedge clk) begin if (shot[0]) n1 = n1 + 1; if (shot[1]) n2 = n2 + 1; end
task automatic bw(input [31:0] a, input [31:0] d);
  @(posedge clk74) #1; bridge_addr = a; bridge_wr_data = d; bridge_wr = 1; @(posedge clk74) #1; bridge_wr = 0;
endtask
// a CPU write: nes.v's ram_wr = prg_write (mw_int && cart_pre) in $0000-$1FFF: up for the cart_pre window (a PPU
// tick: 8 clk_analogizer clocks here), address and data steady; then the rest of the CPU cycle
task automatic cw(input [15:0] a, input [7:0] d);
  @(posedge clk) #1; nes_ram_wa = a[10:0]; nes_ram_wd = d; nes_ram_wr = (a[15:13] == 3'b000);
  repeat (8) @(posedge clk); #1 nes_ram_wr = 0; repeat (16) @(posedge clk); #1 nes_ram_wd = 8'hxx;
endtask
task automatic dec_zp(input [15:0] a, input [7:0] old);   // DEC zp: the dummy write of the old value, then the new
  cw(a, old); cw(a, old - 8'd1);
endtask
task automatic expect_shots(input integer e1, input integer e2, input string what);
  repeat (4) @(posedge clk);
  if (n1 != e1 || n2 != e2) begin f++; $display("FAIL %s: shots P1 %0d P2 %0d (want %0d %0d)", what, n1, n2, e1, e2); end
  else $display("ok   %s", what);
endtask
reg [7:0] db [0:4095]; reg [7:0] rom [0:524287]; string path; integer fd, i, n;
task automatic load_rom(input string p);
  for (i = 0; i < 524288; i++) rom[i] = 8'h00;
  fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "no %s", p); n = $fread(rom, fd); $fclose(fd);
  rom_load = 1;
  for (i = 0; i < (n + 3) / 4; i++) bw(32'h1000_0000 + 4 * i, {rom[4*i], rom[4*i+1], rom[4*i+2], rom[4*i+3]});
  rom_load = 0;
endtask
initial begin
  if (!$value$plusargs("DB=%s", path)) path = "recoil_db.bin";
  fd = $fopen(path, "rb"); i = $fread(db, fd); $fclose(fd);
  repeat (5) @(posedge clk74);
  // the loader's order: the ROM, the palette (slot 11, also at 0x10000000), the database (slot 25), then allcomplete
  if (!$value$plusargs("ROM=%s", path)) path = "dh.nes";
  load_rom(path);
  for (i = 0; i < 48; i++) bw(32'h1000_0000 + 4 * i, 32'h1234_5678 * i);
  for (i = 0; i < 1024; i++) bw(32'h5100_0000 + 4 * i, {db[4*i], db[4*i+1], db[4*i+2], db[4*i+3]});
  @(posedge clk74) allcomplete = 1; repeat (2000) @(posedge clk74);
  if (!valid || entry != 5'd0) begin f++; $display("FAIL: Duck Hunt not found (%b %0d)", valid, entry); end
  else $display("ok   Duck Hunt found: entry %0d", entry);
  repeat (10) @(posedge clk);
  if (active != 2'b01) begin f++; $display("FAIL: only P1 active (%b)", active); end
  // a duck: the gun loaded with 3 shots (STA $BA), then the shots (DEC $BA)
  cw(16'h00BA, 8'd3); expect_shots(0, 0, "the reload to 3 is no shot");
  dec_zp(16'h00BA, 8'd3); expect_shots(1, 0, "a shot (DEC: 3, then 2)");
  cw(16'h00BB, 8'd1); cw(16'h00B9, 8'd1); cw(16'h01BA, 8'd1); expect_shots(1, 0, "the neighbours, $01BA: not the counter");
  dec_zp(16'h08BA, 8'd2); expect_shots(2, 0, "a shot through the mirror $08BA");
  dec_zp(16'h00BA, 8'd1); expect_shots(3, 0, "the last shot (1, then 0)");
  dec_zp(16'h00BA, 8'd0); expect_shots(3, 0, "an empty gun (0, then FF) is no shot");
  cw(16'h80BA, 8'hFE); expect_shots(3, 0, "a write to $80BA (the cartridge) is ignored");
  cw(16'h00BA, 8'd3); dec_zp(16'h00BA, 8'd3); dec_zp(16'h00BA, 8'd2); expect_shots(5, 0, "the next duck: two shots");
  // another game: not in the database
  allcomplete = 0; repeat (4) @(posedge clk74);
  if (!$value$plusargs("ROM2=%s", path)) path = "other.nes";
  load_rom(path);
  @(posedge clk74) allcomplete = 1; repeat (2000) @(posedge clk74); repeat (10) @(posedge clk);
  if (valid || active != 2'b00) begin f++; $display("FAIL: another game is not in the database (%b %b)", valid, active); end
  else $display("ok   another game: not found");
  cw(16'h00BA, 8'd3); cw(16'h00BA, 8'd2); expect_shots(5, 0, "no recoil from memory for it");
  // Operation Wolf: the bullets in BCD digits, $51 tens, $50 units (an ammo "decimal digit", 0 -> 9 a shot), as MAME
  // shows the game writing them: the stage's start ($CFD3: $50 = 0, $51 = 2), each shot ($D54C: $50, then $51)
  allcomplete = 0; repeat (4) @(posedge clk74);
  if (!$value$plusargs("ROM3=%s", path)) path = "ow.nes";
  load_rom(path);
  @(posedge clk74) allcomplete = 1; repeat (2000) @(posedge clk74); repeat (10) @(posedge clk);
  if (!valid || entry != 5'd9) begin f++; $display("FAIL: Operation Wolf not found (%b %0d)", valid, entry); end
  else $display("ok   Operation Wolf found: entry %0d", entry);
  n1 = 0;
  cw(16'h0050, 8'd0); cw(16'h0051, 8'd2); expect_shots(0, 0, "OW: the stage's start (20 bullets)");
  cw(16'h0050, 8'd9); cw(16'h0051, 8'd1); expect_shots(1, 0, "OW: 20 -> 19 (units 0 -> 9)");
  for (i = 8; i >= 0; i--) begin cw(16'h0050, i[7:0]); cw(16'h0051, 8'd1); end
  expect_shots(10, 0, "OW: 19 -> 10");
  cw(16'h0050, 8'd9); cw(16'h0051, 8'd0); expect_shots(11, 0, "OW: 10 -> 9");
  for (i = 8; i >= 0; i--) cw(16'h0050, i[7:0]);
  expect_shots(20, 0, "OW: 9 -> 0");
  cw(16'h0051, 8'd2); expect_shots(20, 0, "OW: a magazine (the tens only)");
  cw(16'h0050, 8'd9); expect_shots(21, 0, "OW: the new magazine's first shot");
  cw(16'h0050, 8'd7); cw(16'h0050, 8'd0); cw(16'h0050, 8'd0); expect_shots(21, 0, "OW: 9 -> 7, 7 -> 0, 0 -> 0: no shot");
  // Gumshoe: the bullets a BCD byte ($E3), as MAME shows the game writing it: the shot ($D2F3, one less in decimal),
  // the balloons' bonus ($D2CE, one more)
  allcomplete = 0; repeat (4) @(posedge clk74);
  if (!$value$plusargs("ROM4=%s", path)) path = "gs.nes";
  load_rom(path);
  @(posedge clk74) allcomplete = 1; repeat (2000) @(posedge clk74); repeat (10) @(posedge clk);
  if (!valid || entry != 5'd12) begin f++; $display("FAIL: Gumshoe not found (%b %0d)", valid, entry); end
  else $display("ok   Gumshoe found: entry %0d", entry);
  n1 = 0;
  cw(16'h00E3, 8'h50); cw(16'h00E3, 8'h51); cw(16'h00E3, 8'h52); expect_shots(0, 0, "GS: the start, a bonus (50 -> 52)");
  cw(16'h00E3, 8'h51); cw(16'h00E3, 8'h50); cw(16'h00E3, 8'h49); expect_shots(3, 0, "GS: 52 -> 49 (50 -> 49 in BCD)");
  cw(16'h00E3, 8'h48); cw(16'h00E3, 8'h4F); cw(16'h00E3, 8'h47); expect_shots(4, 0, "GS: 49 -> 48, not 48 -> 4F (binary)");
  cw(16'h00E3, 8'h01); cw(16'h00E3, 8'h00); cw(16'h00E3, 8'h99); expect_shots(5, 0, "GS: 01 -> 00, not 00 -> 99");
  // the rules: a test entry (sim/recoil_db_test.json, keyed to ROM5): s0 "not in the demo" ($69 & 02 == 0), s1 "flying"
  // ($80 == 03), s2 the weapon ($90); rules: dec $068C (40 ms) if s0 and not s1; dec $006E (table by s2) if s0 and s1;
  // trigger if s0 and s1; P2: becomes $A0 = 05 (77 ms)
  allcomplete = 0; repeat (4) @(posedge clk74);
  if (!$value$plusargs("ROM5=%s", path)) path = "te.nes";
  load_rom(path);
  @(posedge clk74) allcomplete = 1; repeat (2000) @(posedge clk74); repeat (40) @(posedge clk);
  if (!valid || entry != 5'd13) begin f++; $display("FAIL: the test entry not found (%b %0d)", valid, entry); end
  else $display("ok   the test entry found: entry %0d", entry);
  if (active != 2'b11 || trig_en != 2'b00) begin f++; $display("FAIL: active %b trig_en %b (want 11 00: s1 false at 0)", active, trig_en); end
  n1 = 0; n2 = 0;
  cw(16'h0069, 8'h02); repeat (40) @(posedge clk);                       // the demo
  if (trig_en != 2'b00) begin f++; $display("FAIL: the demo: trig_en %b", trig_en); end
  cw(16'h068C, 8'd99); cw(16'h068C, 8'd98); expect_shots(0, 0, "rules: the demo's pistol shot: none");
  cw(16'h0069, 8'h00); cw(16'h068C, 8'd97); expect_shots(1, 0, "rules: a pistol shot in the game");
  if (last_p1 != 40) begin f++; $display("FAIL: the pistol's pulse %0d (want 40)", last_p1); end
  cw(16'h006E, 8'd40); cw(16'h006E, 8'd39); expect_shots(1, 0, "rules: a missile on the ground (s1 false): none");
  cw(16'h0080, 8'h03); repeat (40) @(posedge clk);                        // flying
  if (trig_en != 2'b01) begin f++; $display("FAIL: flying: trig_en %b (want 01)", trig_en); end
  cw(16'h0090, 8'd2); cw(16'h006E, 8'd38); expect_shots(2, 0, "rules: a missile flying, weapon 2");
  if (last_p1 != 30) begin f++; $display("FAIL: the missile's pulse %0d (want the table's [2] = 30)", last_p1); end
  cw(16'h068C, 8'd96); expect_shots(2, 0, "rules: the pistol flying (not s1 false): none");
  cw(16'h00A0, 8'h04); cw(16'h00A0, 8'h05); cw(16'h00A0, 8'h05); expect_shots(2, 1, "rules: P2 becomes 05, once");
  if (last_p2 != 77) begin f++; $display("FAIL: P2's pulse %0d (want 77)", last_p2); end
  // a write every 24 clocks (the NES CPU's fastest): none lost
  for (i = 37; i > 20; i--) begin
    @(posedge clk) #1; nes_ram_wa = 11'h06E; nes_ram_wd = i[7:0]; nes_ram_wr = 1;
    repeat (8) @(posedge clk); #1 nes_ram_wr = 0; repeat (15) @(posedge clk);
    @(posedge clk) #1; nes_ram_wa = 11'h1FF; nes_ram_wd = 8'h55; nes_ram_wr = 1;
    repeat (8) @(posedge clk); #1 nes_ram_wr = 0; repeat (15) @(posedge clk);
  end
  expect_shots(19, 1, "rules: 17 missiles, a CPU write every 24 clocks");
  if (f) $display("SOME FAILED"); else $display("ALL PASS");
  $finish;
end
endmodule
