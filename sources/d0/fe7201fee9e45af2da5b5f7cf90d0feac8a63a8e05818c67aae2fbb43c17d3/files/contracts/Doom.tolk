tolk 1.4.2

// Doom on TON: a wall-only 1-bit renderer of Doom E1M1 running inside TVM.
//
// Every external "tick" message carries a batch of player inputs. For each input the contract
// moves the player (noclip), renders the view with the level's BSP tree and emits the frame as an
// external-out message (FrameEvent). State is committed after every frame so that running out of
// gas in the middle of a batch keeps the frames already rendered.
//
// The integer math mirrors tools/render.py bit for bit. The hot column loops are generated TVM
// assembly (tools/asmgen.py, verified against tools/render.py with tools/stacksim.py).

import "@stdlib/gas-payments"
import "render-asm"

contract Doom {
    author: "ton-doom"
    version: "0.2.0"
    description: "Doom E1M1 rendered on-chain; frames are external-out messages"
    storage: Storage
    incomingExternal: Tick
    emittedEvents: FrameEvent
}

// ---------------------------------------------------------------------------------------------
// Screen / fixed point constants
// ---------------------------------------------------------------------------------------------
const W = 80;                     // columns
const H = 120;                    // rows (multiple of 8); render-asm.tolk is generated for this H
const ASPECT_Y = 2;               // rows per column unit: the viewer shows each row at half height (4:3)
const CX = W / 2;
const CY = H / 2;
const FOCAL = W / 2;              // 90 degree horizontal FOV
const FULL = (1 << H) - 1;        // all rows
const FULLW = (1 << W) - 1;       // all columns
const OPEN_ALL = FULL << H;       // framebuffer column: pixels = 0, opening = all rows
const COLS_PER_CELL = 1023 / H;   // columns packed per output cell
const ANGLES = 512;
const ANGLE_MASK = ANGLES - 1;
const QUARTER = ANGLES / 4;
const VIEWHEIGHT = 41;
const SPEED_FWD = 8;              // map units per frame per input unit
const SPEED_SIDE = 6;
const SIN_PER_LEAF = 56;
const SIN_BITS = 18;
const INPUT_BITS = 32;            // turn:int8 fwd:int8 side:int8 flags:uint8 (bit 0: fire)
const MAX_INPUTS = 29;            // per external message (op:32 batchId:32 count:8 + 29 x 32 bits fit in one cell)
const MAX_BATCH_SKIP = 64;        // a batch id may run at most this far ahead of lastBatch (lost batches are skipped)
const HELD_MAX = 3;               // reorder buffer: when a 4th batch is waiting, or the oldest waited HELD_MAX_AGE
const HELD_MAX_AGE = 2;           // seconds, the batches before it are declared lost and skipped
const GAS_BUDGET = 900000;        // hard stop for rendering work (leaves ~100k: weapon overlay ~18k, pack, emit, save, continue)
const GAS_PER_SPRITE_COL = 800;   // a target sprite column (Tolk loop in drawMonster)
const GAS_NODE_MARGIN = 25000;    // a node/subsector visit may add this much before the next check
// (the per-run column guard, 2600 gas per column and the same budget, is baked into the generated seg drawers:
//  regenerate render-asm.tolk when GAS_BUDGET changes)
const CONT_VALUE = 100000000;     // 0.1 TON attached to each self-continuation (buys the 1M gas limit)
const MIN_CHAIN_BALANCE = 400000000; // keep the chain going only while the balance is above 0.4 TON
const SEG_TAIL_BITS = 66;         // bits of a seg record after kind + 4 coords
const SHADE_UNIT2 = 2 * 96 << 16; // (d1 + d2) in 16.16 divided by this gives the shade level step (96 map units)

// dither patterns: 8-row byte (4-row nibble with each bit doubled for ASPECT_Y = 2) replicated over the
// column; even / odd column phases
const REP = FULL / 255;                    // 0x01 0x01 ... (H/8 bytes)
const PAT_L2_0 = 0b11001100 * REP;         // 25 %    (floor, far walls)
const PAT_L2_1 = 0;
const PAT_L3_0 = 0b11001100 * REP;         // 50 %
const PAT_L3_1 = 0b00110011 * REP;
const PAT_L4_0 = 0b11001100 * REP;         // 75 %
const PAT_L4_1 = 0b11111111 * REP;
const PAT_L5_0 = FULL;                     // 100 %
const PAT_L5_1 = FULL;
const FLOOR01 = PAT_L2_0 | (PAT_L2_1 << H); // floor pattern pair packed for the asm seg drawers

// Doom checkcoord table packed: nibble per boxpos = x1sel y1sel x2sel y2sel (1 = right / bottom)
const CHECKCOORD = 9 | (8 << 4) | (12 << 8) | (1 << 16) | (14 << 24) | (3 << 32) | (7 << 36) | (6 << 40);

// wanderer AI (mirrors tools/ai.py)
const AI_TURN_RATE = 6;           // angle units per frame while turning on the spot
const AI_STEER_RATE = 3;          // while walking away from a wall
const AI_PROBE_NEAR = 24;         // map units ahead that must be free to walk
const AI_PROBE_FAR = 72;          // if blocked: steer
const AI_PROBE_SIDE = 48;         // whiskers at +-45 degrees
const AI_SIDE_ANGLE = ANGLES / 8;

// Weapon overlay (tools/sprites.py): the pistol bobs while walking (rows down by frameNo & 15, 2 bits per
// entry) and fires now and then: a muzzle flash for GUN_FLASH_FRAMES frames when (rnd >> 20) & 63 == 0.
const GUN_BOB_TABLE = 0x05AFFA50;   // [0,0,1,1,2,2,3,3,3,3,2,2,1,1,0,0]
const GUN_FLASH_FRAMES = 2;

// Shootable targets (tools/monsters.py): imps standing still; a shot hits the nearest living one within
// MON_HIT_RADIUS of the view axis and not behind a wall. Sprites (tools/sprites.py monster_sprites) come in
// MON_LEVELS scales; level k is used when the projected idle height (rows) >= (MON_LEVEL_MIN >> (8*k)) & 255.
const MON_MAX = 6;
const MON_REF_PX = 52;            // idle sprite height above the floor, px; projected rows = 52 * ASPECT_Y * FOCAL / depth
const MON_MIN_DEPTH = 16;         // map units: nearer sprites are not drawn
const MON_MIN_ROWS = 5;           // smaller projected sprites are not drawn
// level by projected idle height (rows52, capped at 127): a nibble per value, two 256-bit tables
const MON_LEVEL_LO = 0x6666666666666555555555555555544444444444333333332222211100000000;
const MON_LEVEL_HI = 0x8888888888888888888888888888877777777777777777777777666666666666;
const MON_HIT_RADIUS = 20;
const MON_HIT_RANGE = 2048;
const MON_PAIN_FRAMES = 4;
const MON_DEATH_TICS = 4;         // frames per death animation frame
const MON_DEATH_FRAMES = 5;       // sprite frames 2..6; 6 = the corpse
const MON_IDLE = 0;
const MON_PAIN = 1;
const MON_DYING = 2;
const MON_DEAD = 3;
const BLOCK_SHIFT = 7;            // 128-unit blockmap cells (tools/blockmap.py)
const BLOCK_TREE_DEPTH = 5;
const CHAIN_STALE_SECONDS = 4;    // START re-kicks the chain if no frame was rendered for this long

const OP_TICK = 0x444F4F4D;     // "DOOM"  external: enqueue inputs
const OP_CONT = 0x434F4E54;     // "CONT"  internal from self: render the next queued input
const OP_RESET = 0x52534554;    // "RSET"  external: teleport the player back to the level start, drop the queue
const OP_START = 0x53545254;    // "STRT"  external: let the on-chain AI walk by itself (self-sustaining chain)
const OP_STOP = 0x53544F50;     // "STOP"  external: stop the AI (the chain ends when the queue is empty)

const ERR_BAD_OP = 130;
const ERR_BAD_COUNT = 131;
const ERR_OLD_BATCH = 132;

// ---------------------------------------------------------------------------------------------
// Storage & messages
// ---------------------------------------------------------------------------------------------
struct Storage {
    frameNo: uint32
    px: int32          // 16.16 fixed point map units
    py: int32
    angle: uint16      // 0..ANGLES-1
    lastBatch: uint32  // id of the last batch appended to the queue
    qpos: uint8        // inputs already consumed from the head queue cell
    queue: cell?       // FIFO of inputs: cells [count:8, count x (turn:int8 fwd:int8 side:int8 flags:uint8)], ref0 = next
    held: cell?        // reorder buffer: batches that arrived ahead of lastBatch+1, sorted by id (see heldInsert)
    owner: address     // may withdraw the balance (internal message with op WDRW)
    auto: bool         // the wanderer AI drives the player when the queue is empty
    turnDir: int8      // AI: current turning episode direction (-1, 0, +1)
    rnd: uint32        // AI: LCG state
    lastStep: uint32   // unix time of the last rendered frame (chain liveness)
    gun: uint8         // muzzle flash frames left
    monsters: cell     // targets: count:4 then per monster x:int16 y:int16 z:int16 hp:uint8 state:uint4 timer:uint8
    level: cell        // see tools/level_encode.py
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// external-in body: op:32 batchId:32 count:8 then count x (turn:int8 forward:int8 strafe:int8 flags:uint8, bit 0 = fire)
struct (0x444F4F4D) Tick {
    batchId: uint32
    count: uint8
    inputs: RemainingBitsAndRefs
}

struct (0x4652414D) FrameEvent {   // "FRAM"
    frameNo: uint32
    w: uint16
    h: uint16
    px: int32
    py: int32
    angle: uint16
    viewz: int16
    flags: uint8       // bit 0: partial frame (gas budget hit before the BSP walk finished)
    queued: uint16     // inputs still queued after this frame
    kills: uint8       // dead targets so far
    pixels: cell       // chain of cells, COLS_PER_CELL columns of H bits each, next cell in ref 0
}

struct (0x434F4E54) Continue {     // "CONT" internal self-message
    hop: uint32
}

struct (0x57445257) Withdraw {     // "WDRW" internal from the owner: send the whole balance back
}

type InternalMsg = Continue | Withdraw

// ---------------------------------------------------------------------------------------------
// TVM helpers
// ---------------------------------------------------------------------------------------------
@pure
fun ubitSize(x: int): int
    asm "UBITSIZE"

@pure
fun slice.refAt(self, idx: int): cell
    asm "PLDREFVAR"

// ---------------------------------------------------------------------------------------------
// Frame-global state
// ---------------------------------------------------------------------------------------------
global gFb: array<int>;   // W entries: pixels | (opening << H)
global gSolid: int;       // W-bit mask of fully closed columns
global gPats: array<int>; // wall patterns: [lvl*2] even columns, [lvl*2+1] odd columns, lvl 0 (near) .. 4 (far)
global gRows: array<int>; // gRows[n] = mask of the top n rows, n in 0..H
global gPartial: bool;    // set when the gas budget stopped the BSP walk
global gMonX: array<int>;   // targets for this frame (map units) ...
global gMonY: array<int>;
global gMonZ: array<int>;
global gMonFrame: array<int>;   // ... and their sprite frame
global gSprites: cell;    // monster sprite tree (tools/sprites.py encode_monster_sprites)
global gViewSS: int;      // subsector index of the viewer

const DEBUG = false;
global gProfNodes: int;
global gProfSegs: int;
global gProfSegsDrawn: int;
global gProfCols: int;
global gProfGasCols: int;
global gProfGasSegs: int;
global gProfGasCulled: int;
global gProfGasSetup: int;
global gProfGasSprites: int;
global gProfSprites: int;

struct (0x50524F46) ProfEvent {   // "PROF"
    gasInit: uint32
    gasBsp: uint32
    gasPack: uint32
    gasTotal: uint32
    gasCols: uint32
    gasSegs: uint32
    gasCulled: uint32
    gasSetup: uint32
    nodes: uint16
    segs: uint16
    segsDrawn: uint16
    cols: uint32
    gasSprites: uint32
    sprites: uint16
}

// ---------------------------------------------------------------------------------------------
// Trig table
// ---------------------------------------------------------------------------------------------
@inline_ref
fun sinAt(table: cell, a: int): int {
    val leaf = a / SIN_PER_LEAF;
    val off = (a - leaf * SIN_PER_LEAF) * SIN_BITS;
    val branch = table.beginParse().refAt(leaf >> 2);
    val leafCell = branch.beginParse().refAt(leaf & 3);
    var s = leafCell.beginParse();
    s.skipBits(off);
    return s.preloadInt(SIN_BITS);
}

// ---------------------------------------------------------------------------------------------
// Camera: (px, py) 16.16 position, (sn, cs) 16.16 sin/cos of the view angle, vz integer view z
// ---------------------------------------------------------------------------------------------
struct Cam {
    px: int
    py: int
    sn: int
    cs: int
    vz: int
}

@inline
fun project(s: int, d: int): int {
    return ((CX << 16) + mulDivFloor(s * FOCAL, 1 << 16, d) + (1 << 15)) >> 16;
}

@inline
fun colMask(x1: int, x2: int): int {
    return ((1 << (x2 - x1)) - 1) << x1;
}

// R_PointOnSide: 0 = front (child 0), 1 = back (child 1)
@inline
fun pointOnSide(px: int, py: int, nx: int, ny: int, ndx: int, ndy: int): int {
    return ((py - (ny << 16)) * ndx < ndy * (px - (nx << 16))) ? 0 : 1;
}

// floor height of the subsector containing (px, py), integer map units
// Subsector cell header: ssIndex:12 nmon:4 (nmon x id:4) floor:int16 ceil:int16 nsegs:4 ...
fun floorAt(root: cell, rootIsSS: bool, px: int, py: int): (int, int) {
    var c = root;
    var isSS = rootIsSS;
    while (!isSS) {
        var s = c.beginParse();
        val flags = s.loadUint(6);
        val nx = s.loadInt(16);
        val ny = s.loadInt(16);
        val ndx = s.loadInt(16);
        val ndy = s.loadInt(16);
        val side = pointOnSide(px, py, nx, ny, ndx, ndy);
        c = s.refAt(side);
        isSS = ((flags >> (side * 3)) & 1) == 1;
    }
    var h = c.beginParse();
    val ssIndex = h.loadUint(12);
    val nmon = h.loadUint(4);
    h.skipBits(nmon * 4);
    return (h.preloadInt(16), ssIndex);
}

// Doom R_CheckBBox in view space. bbox = (top, bottom, left, right) in map units.
@inline_ref
fun checkBBox(top: int, bottom: int, left: int, right: int, cam: Cam): bool {
    val vx = cam.px >> 16;
    val vy = cam.py >> 16;
    val boxx = vx <= left ? 0 : (vx < right ? 1 : 2);
    val boxy = vy >= top ? 0 : (vy > bottom ? 1 : 2);
    val boxpos = boxy * 4 + boxx;
    if (boxpos == 5) {
        return true;
    }
    val sel = (CHECKCOORD >> (boxpos * 4)) & 15;
    val x1 = ((sel & 8) != 0) ? right : left;
    val y1 = ((sel & 4) != 0) ? bottom : top;
    val x2 = ((sel & 2) != 0) ? right : left;
    val y2 = ((sel & 1) != 0) ? bottom : top;
    val dx1 = (x1 << 16) - cam.px;
    val dy1 = (y1 << 16) - cam.py;
    val s1 = (dx1 * cam.sn - dy1 * cam.cs) >> 16;
    val d1 = (dx1 * cam.cs + dy1 * cam.sn) >> 16;
    val dx2 = (x2 << 16) - cam.px;
    val dy2 = (y2 << 16) - cam.py;
    val s2 = (dx2 * cam.sn - dy2 * cam.cs) >> 16;
    val d2 = (dx2 * cam.cs + dy2 * cam.sn) >> 16;
    if (s1 * d2 - d1 * s2 > 0) {
        return true;   // spans >= 180 degrees: viewer on the box edge line
    }
    val in1 = (s1 + d1 >= 0) & (s1 <= d1);
    val in2 = (s2 + d2 >= 0) & (s2 <= d2);
    if (!in1 & !in2) {
        val lIn = (s1 + d1 <= 0) & (s2 + d2 >= 0);
        val rIn = (s1 <= d1) & (s2 >= d2);
        if (!lIn & !rIn) {
            return false;
        }
    }
    val cx1 = in1 ? project(s1, d1) : 0;
    val cx2 = in2 ? project(s2, d2) : W;
    if (cx1 >= cx2) {
        return false;
    }
    return (colMask(cx1, cx2) & ~gSolid) != 0;
}

// ---------------------------------------------------------------------------------------------
// BSP traversal
// ---------------------------------------------------------------------------------------------
@inline_ref
fun renderNode(c: cell, isSS: bool, cam: Cam): void {
    if (getGasConsumedAtTheMoment() > GAS_BUDGET - GAS_NODE_MARGIN) {
        gPartial = true;
        return;
    }
    if (isSS) {
        renderSubsector(c, cam);
        return;
    }
    var s = c.beginParse();
    if (DEBUG) { gProfNodes += 1; }
    val flags = s.loadUint(6);   // d0:3 d1:3, see tools/level_encode.py
    val nx = s.loadInt(16);
    val ny = s.loadInt(16);
    val ndx = s.loadInt(16);
    val ndy = s.loadInt(16);
    val side = pointOnSide(cam.px, cam.py, nx, ny, ndx, ndy);
    val d = (flags >> (side * 3)) & 7;   // bit0: near is subsector, bit1: far is subsector, bit2: test far bbox
    renderNode(s.refAt(side), (d & 1) == 1, cam);
    if ((gSolid == FULLW) | gPartial) {
        return;   // screen full (or out of gas): nothing behind can be visible
    }
    val far = side ^ 1;
    val farIsSS = (d & 2) == 2;
    if ((d & 4) == 0) {
        renderNode(s.refAt(far), farIsSS, cam);   // small subtree: not worth a bbox test
        return;
    }
    // bbox of the far child: bbox0 at bit 70, bbox1 at bit 134
    if (far == 1) {
        s.skipBits(64);
    }
    val top = s.loadInt(16);
    val bottom = s.loadInt(16);
    val left = s.loadInt(16);
    val right = s.loadInt(16);
    if (checkBBox(top, bottom, left, right, cam)) {
        renderNode(s.refAt(far), farIsSS, cam);
    }
}

@inline_ref
fun renderSubsector(c: cell, cam: Cam): void {
    var s = c.beginParse();
    val ssIndex = s.loadUint(12);
    val nmon = s.loadUint(4);
    if (nmon > 0) {
        renderSubsectorTargets(s, ssIndex, nmon, cam);
        return;
    }
    s.skipBits(32);
    val n = s.loadUint(4);
    repeat (n) {
        if (DEBUG) {
            val gasA = getGasConsumedAtTheMoment();
            drawSeg(mutate s, cam);
            gProfGasSegs += getGasConsumedAtTheMoment() - gasA;
        } else {
            drawSeg(mutate s, cam);
        }
    }
    if (s.remainingRefsCount() > 0) {
        renderSegs(s.loadRef().beginParse(), cam);
    }
}

// Seg records: floor ceil nsegs then the segs; ref0 = continuation cell with the same layout.
@inline_ref
fun renderSegs(cs: slice, cam: Cam): void {
    var s = cs;
    s.skipBits(32);
    val n = s.loadUint(4);
    repeat (n) {
        if (DEBUG) {
            val gasA = getGasConsumedAtTheMoment();
            drawSeg(mutate s, cam);
            gProfGasSegs += getGasConsumedAtTheMoment() - gasA;
        } else {
            drawSeg(mutate s, cam);
        }
    }
    if (s.remainingRefsCount() > 0) {
        renderSegs(s.loadRef().beginParse(), cam);
    }
}

// A subsector with targets in it. The viewer inside: every seg of the subsector is behind the targets,
// draw them first; otherwise its front-facing segs are all in front of them, draw them after the segs.
@inline_ref
fun renderSubsectorTargets(cs: slice, ssIndex: int, nmon: int, cam: Cam): void {
    var s = cs;
    val ids = s.loadUint(nmon * 4);
    if (ssIndex == gViewSS) {
        drawMonsters(ids, nmon, cam);
        renderSegs(s, cam);
    } else {
        renderSegs(s, cam);
        drawMonsters(ids, nmon, cam);
    }
}

// Nearest first, so that a nearer sprite closes its rows before a farther one is drawn.
@inline_ref
fun drawMonsters(ids: int, nmon: int, cam: Cam): void {
    if (nmon == 1) {
        if (getGasConsumedAtTheMoment() > GAS_BUDGET - GAS_NODE_MARGIN) {
            gPartial = true;
            return;
        }
        drawMonster(ids, cam);
        return;
    }
    var rest = ids;
    var n = nmon;
    while (n > 0) {
        // pick the nearest of the remaining ids (n <= 3 in practice)
        var bestId = -1;
        var bestD = 1 << 62;
        var bestPos = 0;
        var i = 0;
        var t = rest;
        repeat (n) {
            val id = t & 15;
            t >>= 4;
            val dx = (gMonX.get(id) << 16) - cam.px;
            val dy = (gMonY.get(id) << 16) - cam.py;
            val d = (dx * cam.cs + dy * cam.sn) >> 16;
            if (d < bestD) {
                bestD = d;
                bestId = id;
                bestPos = i;
            }
            i += 1;
        }
        // remove the chosen nibble
        val lowMask = (1 << (bestPos * 4)) - 1;
        rest = (rest & lowMask) | ((rest >> ((bestPos + 1) * 4)) << (bestPos * 4));
        n -= 1;
        if (getGasConsumedAtTheMoment() > GAS_BUDGET - GAS_NODE_MARGIN) {
            gPartial = true;
            return;
        }
        if (DEBUG) {
            val gasM = getGasConsumedAtTheMoment();
            drawMonster(bestId, cam);
            gProfGasSprites += getGasConsumedAtTheMoment() - gasM;
            gProfSprites += 1;
        } else {
            drawMonster(bestId, cam);
        }
    }
}

// refs 0..2 = items, ref 3 = the rest (tools/sprites.py encode_tree)
@inline_ref
fun treeAt(root: cell, index: int): cell {
    var c = root;
    var i = index;
    while (i >= 3) {
        c = c.beginParse().refAt(3);
        i -= 3;
    }
    return c.beginParse().refAt(i);
}

// Mirrors tools/monsters.py draw_monster.
@inline_ref
fun drawMonster(id: int, cam: Cam): void {
    val frame = gMonFrame.get(id);
    val dx = (gMonX.get(id) << 16) - cam.px;
    val dy = (gMonY.get(id) << 16) - cam.py;
    val sv = (dx * cam.sn - dy * cam.cs) >> 16;
    val d = (dx * cam.cs + dy * cam.sn) >> 16;
    if (d < (MON_MIN_DEPTH << 16)) {
        return;
    }
    val rows52 = (MON_REF_PX * ASPECT_Y * (FOCAL << 16)) / d;
    if (rows52 < MON_MIN_ROWS) {
        return;
    }
    val r127 = min(rows52, 127);
    val level = r127 < 64 ? (MON_LEVEL_LO >> (4 * r127)) & 15 : (MON_LEVEL_HI >> (4 * (r127 - 64))) & 15;
    val xc = project(sv, d);
    val scale24 = (FOCAL << 40) / d;
    val worldbottom = (gMonZ.get(id) - cam.vz) * ASPECT_Y;
    val bot = ((CY << 24) - worldbottom * scale24) >> 24;   // screen row of the feet
    var mip = treeAt(treeAt(gSprites, frame), level).beginParse();
    val rows = mip.loadUint(8);
    val cols = mip.loadUint(8);
    val xoff = mip.loadUint(8);
    if ((bot < 0) | (bot - rows + 1 >= H)) {
        return;
    }
    // only the on-screen columns: skip the leading off-screen ones in the chain, stop at the right edge
    val x0 = xc - xoff;
    val skip = x0 < 0 ? -x0 : 0;
    val count = min(cols, W - x0) - skip;
    if (count <= 0) {
        return;
    }
    if (getGasConsumedAtTheMoment() + count * GAS_PER_SPRITE_COL > GAS_BUDGET - GAS_NODE_MARGIN) {
        gPartial = true;   // not enough budget left for this sprite
        return;
    }
    var chain = mip.loadRef().beginParse();
    val perCell = 1023 / (2 * rows);
    val cellSkip = skip / perCell;
    repeat (cellSkip) {
        chain = chain.preloadRef().beginParse();
    }
    chain.skipBits((skip - cellSkip * perCell) * 2 * rows);
    var fb = gFb;
    var x = x0 + skip;
    // per column (pixels are a subset of the mask, and pixel bits of open rows are 0):
    //   drawn = mask' & open; e += pix' & open; e -= drawn << H   (' = shifted to the feet row)
    val sh = H - 1 - bot;
    if (sh >= 0) {
        repeat (count) {
            if (chain.remainingBitsCount() == 0) {
                chain = chain.loadRef().beginParse();
            }
            val pix = chain.loadUint(rows);
            val mask = chain.loadUint(rows);
            val e = fb.get(x);
            val open = e >> H;
            fb.set(e + ((pix << sh) & open) - (((mask << sh) & open) << H), x);
            x += 1;
        }
    } else {
        val rs = -sh;   // feet below the screen bottom: the sprite is shifted down
        repeat (count) {
            if (chain.remainingBitsCount() == 0) {
                chain = chain.loadRef().beginParse();
            }
            val pix = chain.loadUint(rows);
            val mask = chain.loadUint(rows);
            val e = fb.get(x);
            val open = e >> H;
            fb.set(e + ((pix >> rs) & open) - (((mask >> rs) & open) << H), x);
            x += 1;
        }
    }
    gFb = fb;
}

// Reads one seg record from `s` and draws it. Transform / clipping / projection here (early exits for
// culled segs); the run and column loops are in render-asm.tolk.
@inline_ref
fun drawSeg(mutate s: slice, cam: Cam): void {
    val gasE = getGasConsumedAtTheMoment();
    if (DEBUG) { gProfSegs += 1; }
    val kind = s.loadUint(2);
    val x1w = s.loadInt(16);
    val y1w = s.loadInt(16);
    val x2w = s.loadInt(16);
    val y2w = s.loadInt(16);
    val dx1 = (x1w << 16) - cam.px;
    val dy1 = (y1w << 16) - cam.py;
    // back-face test in world space: cross(v2 - v1, p - v1) >= 0 means facing away / edge-on
    if ((x2w - x1w) * (-dy1) - (y2w - y1w) * (-dx1) >= 0) {
        s.skipBits(SEG_TAIL_BITS);
        if (DEBUG) { gProfGasCulled += getGasConsumedAtTheMoment() - gasE; }
        return;
    }
    val dx2 = (x2w << 16) - cam.px;
    val dy2 = (y2w << 16) - cam.py;
    val s1 = (dx1 * cam.sn - dy1 * cam.cs) >> 16;
    val d1 = (dx1 * cam.cs + dy1 * cam.sn) >> 16;
    val s2 = (dx2 * cam.sn - dy2 * cam.cs) >> 16;
    val d2 = (dx2 * cam.cs + dy2 * cam.sn) >> 16;
    val C = s1 * d2 - d1 * s2;
    if ((C >= 0) | ((d1 <= 0) & (d2 <= 0))) {   // edge-on after rounding, or entirely behind
        s.skipBits(SEG_TAIL_BITS);
        return;
    }
    var x1 = 0;
    if (d1 > 0) {
        if (s1 > d1) {
            s.skipBits(SEG_TAIL_BITS);
            return;
        }
        if (s1 + d1 >= 0) {
            x1 = project(s1, d1);
        }
    }
    var x2 = W;
    if (d2 > 0) {
        if (s2 + d2 < 0) {
            s.skipBits(SEG_TAIL_BITS);
            return;
        }
        if (s2 <= d2) {
            x2 = project(s2, d2);
        }
    }
    if (x1 >= x2) {
        s.skipBits(SEG_TAIL_BITS);
        return;
    }
    val cols = colMask(x1, x2) & ~gSolid;
    if (cols == 0) {
        s.skipBits(SEG_TAIL_BITS);
        return;
    }
    if (DEBUG) { gProfSegsDrawn += 1; gProfGasSetup += getGasConsumedAtTheMoment() - gasE; }
    val worldbottom = (s.loadInt(16) - cam.vz) * ASPECT_Y;
    val worldtop = (s.loadInt(16) - cam.vz) * ASPECT_Y;
    val lightAdj = s.loadInt(2);
    val worldlow = (s.loadInt(16) - cam.vz) * ASPECT_Y;
    val worldhigh = (s.loadInt(16) - cam.vz) * ASPECT_Y;

    val dd = d2 - d1;
    val negC = -C;
    // scale24 at column i: (numBase - i*dd2) * 2^39 / negC
    val numBase = 2 * FOCAL * (s2 - s1) + (2 * CX - 1) * dd;
    val dd2 = 2 * dd;
    val step24 = (dd << 40) / C;
    val topstep = -worldtop * step24;
    val botstep = -worldbottom * step24;

    // shade from the mean endpoint depth (map units): level 0 (near) .. 4 (far), then sector light
    var lvl = min(4, ubitSize(max(d1 + d2, 2) / SHADE_UNIT2));
    lvl = min(4, max(0, lvl - lightAdj));
    val pats = gPats;
    val w01 = pats.get(lvl * 2) | (pats.get(lvl * 2 + 1) << H);

    val gasB = getGasConsumedAtTheMoment();
    if (DEBUG) { gProfGasSetup += gasB - gasE; }
    var fb2: array<int> = [];
    var solidAdd = 0;
    var partial = 0;
    if (kind == 0) {
        (fb2, solidAdd, partial) = drawSegSolid(gRows, w01, FLOOR01, topstep, botstep, worldtop, worldbottom, numBase, dd2, negC, gFb, cols);
    } else if (kind == 1) {
        (fb2, solidAdd, partial) = drawSegUpper(gRows, w01, FLOOR01, topstep, botstep, -worldhigh * step24, worldtop, worldbottom, worldhigh, numBase, dd2, negC, gFb, cols);
    } else if (kind == 2) {
        (fb2, solidAdd, partial) = drawSegLower(gRows, w01, FLOOR01, topstep, botstep, -worldlow * step24, worldtop, worldbottom, worldlow, numBase, dd2, negC, gFb, cols);
    } else {
        (fb2, solidAdd, partial) = drawSegBoth(gRows, w01, FLOOR01, topstep, botstep, -worldhigh * step24, -worldlow * step24, worldtop, worldbottom, worldhigh, worldlow, numBase, dd2, negC, gFb, cols);
    }
    gFb = fb2;
    gSolid |= solidAdd;
    if (partial != 0) {
        gPartial = true;
    }
    if (DEBUG) { gProfGasCols += getGasConsumedAtTheMoment() - gasB; }
}

// ---------------------------------------------------------------------------------------------
// Collisions: blockmap of blocking lines (tools/blockmap.py)
// ---------------------------------------------------------------------------------------------
// bm: blockmap root cell (ox:int16 oy:int16 cols:uint8 rows:uint8, ref0 = 4-ary tree of block cells).
// Move (px,py) -> (nx,ny) in 16.16; true if it crosses a line that blocks in that direction.
// Does the move (px,py) -> (nx,ny) cross a blocking line? Returns the direction (dx, dy) of the first such
// line in blockmap order, or (0, 0) if the move is free.
@inline_ref
fun hitLine(bm: cell, px: int, py: int, nx: int, ny: int): (int, int) {
    var h = bm.beginParse();
    val ox = h.loadInt(16);
    val oy = h.loadInt(16);
    val cols = h.loadUint(8);
    val rows = h.loadUint(8);
    val tree = h.preloadRef();
    val x0 = px >> 16;
    val y0 = py >> 16;
    val x1 = nx >> 16;
    val y1 = ny >> 16;
    val bxa = max((min(x0, x1) - ox) >> BLOCK_SHIFT, 0);
    val bxb = min((max(x0, x1) - ox) >> BLOCK_SHIFT, cols - 1);
    val bya = max((min(y0, y1) - oy) >> BLOCK_SHIFT, 0);
    val byb = min((max(y0, y1) - oy) >> BLOCK_SHIFT, rows - 1);
    val mx = nx - px;
    val my = ny - py;
    var by = bya;
    while (by <= byb) {
        var bx = bxa;
        while (bx <= bxb) {
            // tree lookup: 2 bits per level, top bits first
            val idx = by * cols + bx;
            var c = tree;
            var shift = 2 * (BLOCK_TREE_DEPTH - 1);
            repeat (BLOCK_TREE_DEPTH) {
                c = c.beginParse().refAt((idx >> shift) & 3);
                shift -= 2;
            }
            // lines of this block (with continuation cells)
            var more = true;
            while (more) {
                var s = c.beginParse();
                val n = s.loadUint(4);
                repeat (n) {
                    val lx1 = s.loadInt(16);
                    val ly1 = s.loadInt(16);
                    val lx2 = s.loadInt(16);
                    val ly2 = s.loadInt(16);
                    val flags = s.loadUint(2);   // bit1: blockFront, bit0: blockBack
                    val dx = lx2 - lx1;
                    val dy = ly2 - ly1;
                    val c1 = dx * (py - (ly1 << 16)) - dy * (px - (lx1 << 16));
                    val c2 = dx * (ny - (ly1 << 16)) - dy * (nx - (lx1 << 16));
                    if ((c1 != 0) & (c2 != 0) & ((c1 < 0) != (c2 < 0))) {
                        val e1 = mx * ((ly1 << 16) - py) - my * ((lx1 << 16) - px);
                        val e2 = mx * ((ly2 << 16) - py) - my * ((lx2 << 16) - px);
                        if ((e1 != 0) & (e2 != 0) & ((e1 < 0) != (e2 < 0))) {
                            if (c1 < 0 ? (flags & 2) != 0 : (flags & 1) != 0) {
                                return (dx, dy);
                            }
                        }
                    }
                }
                if (s.remainingRefsCount() > 0) {
                    c = s.loadRef();
                } else {
                    more = false;
                }
            }
            bx += 1;
        }
        by += 1;
    }
    return (0, 0);
}

@inline
fun blocked(bm: cell, px: int, py: int, nx: int, ny: int): bool {
    val (dx, dy) = hitLine(bm, px, py, nx, ny);
    return (dx | dy) != 0;
}

// ---------------------------------------------------------------------------------------------
// Wanderer AI (mirrors tools/ai.py ai_step). Returns (turn, fwd) and updates rnd / turnDir.
// ---------------------------------------------------------------------------------------------
@inline
fun probe(bm: cell, sinTable: cell, x: int, y: int, a: int, dist: int, da: int): bool {
    val aa = (a + da) & ANGLE_MASK;
    return blocked(bm, x, y, x + dist * sinAt(sinTable, (aa + QUARTER) & ANGLE_MASK), y + dist * sinAt(sinTable, aa));
}

fun aiStep(mutate st: Storage, bm: cell, sinTable: cell): (int, int) {
    val x = st.px;
    val y = st.py;
    val a = st.angle;
    val near = probe(bm, sinTable, x, y, a, AI_PROBE_NEAR, 0);
    val left = probe(bm, sinTable, x, y, a, AI_PROBE_SIDE, AI_SIDE_ANGLE);
    val right = probe(bm, sinTable, x, y, a, AI_PROBE_SIDE, ANGLES - AI_SIDE_ANGLE);
    val coin = ((st.rnd >> 16) & 1) == 1 ? 1 : -1;
    if (near) {
        if (st.turnDir == 0) {
            st.turnDir = (left != right) ? (right ? 1 : -1) : coin;
        }
        return (st.turnDir * AI_TURN_RATE, 0);
    }
    st.turnDir = 0;
    var turn = 0;
    if (left != right) {
        turn = right ? AI_STEER_RATE : -AI_STEER_RATE;
    } else if (probe(bm, sinTable, x, y, a, AI_PROBE_FAR, 0)) {
        turn = coin * AI_STEER_RATE;
    } else if (((st.rnd >> 12) & 3) == 0) {
        turn = ((st.rnd >> 8) % 3) - 1;   // rare gentle drift
    }
    val a2 = (a + turn) & ANGLE_MASK;
    val nx = x + SPEED_FWD * sinAt(sinTable, (a2 + QUARTER) & ANGLE_MASK);
    val ny = y + SPEED_FWD * sinAt(sinTable, a2);
    if (blocked(bm, x, y, nx, ny)) {
        st.turnDir = coin;
        return (st.turnDir * AI_TURN_RATE, 0);
    }
    return (turn, 1);
}

// ---------------------------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------------------------
// Draw the weapon over the rendered columns: per column pixels := (pixels & ~mask) | sprite, both shifted
// down by `bob` rows. Sprite cell: x0:8 w:8, ref0 = idle columns, ref1 = flash columns (pix:H mask:H each,
// COLS_PER_CELL per cell, ref0 = next).
fun overlayGun(sprite: cell, flash: bool, bob: int) {
    var s = sprite.beginParse();
    val x0 = s.loadUint(8);
    val w = s.loadUint(8);
    val idle = s.loadRef();
    var cols = (flash ? s.loadRef() : idle).beginParse();
    var fb = gFb;
    var x = x0;
    repeat (w) {
        if (cols.remainingBitsCount() == 0) {
            cols = cols.loadRef().beginParse();
        }
        val pix = cols.loadUint(H) >> bob;
        val mask = cols.loadUint(H) >> bob;
        fb.set((fb.get(x) & ~mask) | pix, x);
        x += 1;
    }
    gFb = fb;
}

fun renderFrame(root: cell, rootIsSS: bool, cam: Cam, gun: cell, flash: bool, bob: int): cell {
    val gas0 = getGasConsumedAtTheMoment();
    var fb: array<int> = [];
    repeat (W) {
        fb.push(OPEN_ALL);
    }
    gFb = fb;
    gSolid = 0;
    gPartial = false;
    var rows: array<int> = [];
    var m = 0;
    repeat (H + 1) {
        rows.push(m);
        m = (m >> 1) | (1 << (H - 1));
    }
    gRows = rows;
    gPats = [PAT_L5_0, PAT_L5_1, PAT_L4_0, PAT_L4_1, PAT_L3_0, PAT_L3_1, PAT_L2_0, PAT_L2_1, PAT_L2_0, PAT_L2_1];
    if (DEBUG) { gProfNodes = 0; gProfSegs = 0; gProfSegsDrawn = 0; gProfCols = 0; gProfGasCols = 0; gProfGasSegs = 0; gProfGasCulled = 0; gProfGasSetup = 0; gProfGasSprites = 0; gProfSprites = 0; }
    val gas1 = getGasConsumedAtTheMoment();
    renderNode(root, rootIsSS, cam);
    overlayGun(gun, flash, bob);
    val gas2 = getGasConsumedAtTheMoment();
    // pack columns into a cell chain, built from the last cell backwards
    fb = gFb;
    var next: cell? = null;
    var x = W;
    while (x > 0) {
        val start = max(x - COLS_PER_CELL, 0);
        var b = beginCell();
        var i = start;
        repeat (x - start) {
            b.storeUint(fb.get(i) & FULL, H);
            i += 1;
        }
        if (next != null) {
            b.storeRef(next);
        }
        next = b.endCell();
        x = start;
    }
    if (DEBUG) {
        val gas3 = getGasConsumedAtTheMoment();
        val prof = createExternalLogMessage({
            dest: createAddressNone(),
            body: ProfEvent {
                gasInit: gas1 - gas0, gasBsp: gas2 - gas1, gasPack: gas3 - gas2, gasTotal: gas3,
                gasCols: gProfGasCols, gasSegs: gProfGasSegs, gasCulled: gProfGasCulled, gasSetup: gProfGasSetup,
                nodes: gProfNodes, segs: gProfSegs, segsDrawn: gProfSegsDrawn, cols: gProfCols,
                gasSprites: gProfGasSprites, sprites: gProfSprites,
            },
        });
        prof.send(SEND_MODE_REGULAR);
    }
    return next!;
}

fun emitFrame(st: Storage, viewz: int, pixels: cell, queued: int, kills: int) {
    val msg = createExternalLogMessage({
        dest: createAddressNone(),
        body: FrameEvent {
            frameNo: st.frameNo,
            w: W,
            h: H,
            px: st.px,
            py: st.py,
            angle: st.angle,
            viewz: viewz,
            flags: gPartial ? 1 : 0,
            queued: queued,
            kills: kills,
            pixels: pixels,
        },
    });
    msg.send(SEND_MODE_REGULAR);
}

// ---------------------------------------------------------------------------------------------
// Input queue
// ---------------------------------------------------------------------------------------------
// Append a batch cell [count:8, inputs...] at the tail of the queue (rebuilds the spine).
// Reorder buffer: a sorted linked list of cells [id:32 at:32] ref0 = batch, ref1 = next. Returns (list, dup).
fun heldInsert(held: cell?, id: int, at: int, batch: cell): (cell, bool) {
    if (held == null) {
        return (beginCell().storeUint(id, 32).storeUint(at, 32).storeRef(batch).endCell(), false);
    }
    var s = held!.beginParse();
    val hid = s.loadUint(32);
    val hat = s.loadUint(32);
    val hbatch = s.loadRef();
    val next: cell? = s.remainingRefsCount() > 0 ? s.loadRef() : null;
    if (id == hid) {
        return (held, true);
    }
    if (id < hid) {
        return (beginCell().storeUint(id, 32).storeUint(at, 32).storeRef(batch).storeRef(held).endCell(), false);
    }
    val (rest, dup) = heldInsert(next, id, at, batch);
    return (beginCell().storeUint(hid, 32).storeUint(hat, 32).storeRef(hbatch).storeRef(rest).endCell(), dup);
}

fun heldCount(held: cell?): int {
    var n = 0;
    var c = held;
    while (c != null) {
        var s = c!.beginParse();
        s.skipBits(64);
        s.loadRef();
        c = s.remainingRefsCount() > 0 ? s.loadRef() : null;
        n += 1;
    }
    return n;
}

// Move held batches that are next in line into the queue; first skip the gap in front of the oldest held
// batch if the buffer is full or the batch waited too long (its predecessors were lost in the mempool).
fun drainHeld(mutate st: Storage, now: int) {
    if (st.held == null) {
        return;
    }
    var s = st.held!.beginParse();
    val hid = s.loadUint(32);
    val hat = s.loadUint(32);
    if ((hid > st.lastBatch + 1) & ((heldCount(st.held) > HELD_MAX) | (now - hat >= HELD_MAX_AGE))) {
        st.lastBatch = hid - 1;
    }
    var more = true;
    while (more & (st.held != null)) {
        var h = st.held!.beginParse();
        val id = h.loadUint(32);
        h.skipBits(32);
        if (id == st.lastBatch + 1) {
            st.queue = appendBatch(st.queue, h.loadRef());
            st.lastBatch = id;
            st.held = h.remainingRefsCount() > 0 ? h.loadRef() : null;
        } else {
            more = false;
        }
    }
}

fun appendBatch(queue: cell?, batch: cell): cell {
    if (queue == null) {
        return batch;
    }
    var s = queue.beginParse();
    val tail = s.remainingRefsCount() > 0 ? appendBatch(s.loadRef(), batch) : batch;
    return beginCell().storeSlice(s).storeRef(tail).endCell();
}

// Number of inputs left in the queue (bounded walk; the queue is short).
fun queuedCount(queue: cell?, qpos: int): int {
    var n = 0;
    var c = queue;
    var first = true;
    while (c != null) {
        var s = c.beginParse();
        n += s.loadUint(8) - (first ? qpos : 0);
        first = false;
        c = s.remainingRefsCount() > 0 ? s.loadRef() : null;
    }
    return n;
}

// Pop one input. Returns (turn, fwd, side, found).
fun popInput(mutate st: Storage): (int, int, int, bool, bool) {
    if (st.queue == null) {
        return (0, 0, 0, false, false);
    }
    var s = st.queue.beginParse();
    val count = s.loadUint(8);
    s.skipBits(st.qpos * INPUT_BITS);
    val turn = s.loadInt(8);
    val fwd = s.loadInt(8);
    val side = s.loadInt(8);
    val fire = (s.loadUint(8) & 1) == 1;
    st.qpos += 1;
    if (st.qpos >= count) {
        st.qpos = 0;
        st.queue = s.remainingRefsCount() > 0 ? s.loadRef() : null;
    }
    return (turn, fwd, side, fire, true);
}

// ---------------------------------------------------------------------------------------------
// Targets (mirrors tools/monsters.py)
// ---------------------------------------------------------------------------------------------
// Loads the monsters into the frame globals, applies one animation tick and (if `shot`) a shot along the
// view axis. Returns (updated monsters cell, kills).
fun updateMonsters(monsters: cell, shot: bool, bm: cell, px: int, py: int, sn: int, cs: int): (cell, int) {
    var s = monsters.beginParse();
    val n = s.loadUint(4);
    var xs: array<int> = [];
    var ys: array<int> = [];
    var zs: array<int> = [];
    var hps: array<int> = [];
    var states: array<int> = [];
    var timers: array<int> = [];
    repeat (n) {
        xs.push(s.loadInt(16));
        ys.push(s.loadInt(16));
        zs.push(s.loadInt(16));
        hps.push(s.loadUint(8));
        states.push(s.loadUint(4));
        timers.push(s.loadUint(8));
    }
    if (shot) {
        var best = -1;
        var bestD = MON_HIT_RANGE << 16;
        var i = 0;
        repeat (n) {
            if (states.get(i) <= MON_PAIN) {
                val dx = (xs.get(i) << 16) - px;
                val dy = (ys.get(i) << 16) - py;
                val sv = (dx * sn - dy * cs) >> 16;
                val d = (dx * cs + dy * sn) >> 16;
                if ((d > 0) & (abs(sv) <= (MON_HIT_RADIUS << 16)) & (d < bestD)) {
                    best = i;
                    bestD = d;
                }
            }
            i += 1;
        }
        if ((best >= 0) && !blocked(bm, px, py, xs.get(best) << 16, ys.get(best) << 16)) {
            val hp = hps.get(best) - 1;
            hps.set(hp, best);
            if (hp == 0) {
                states.set(MON_DYING, best);
                timers.set(0, best);
            } else {
                states.set(MON_PAIN, best);
                timers.set(MON_PAIN_FRAMES, best);
            }
        }
    }
    var frames: array<int> = [];
    var kills = 0;
    var b = beginCell().storeUint(n, 4);
    var i = 0;
    repeat (n) {
        var state = states.get(i);
        var timer = timers.get(i);
        if (state == MON_PAIN) {
            timer -= 1;
            if (timer == 0) {
                state = MON_IDLE;
            }
        } else if (state == MON_DYING) {
            timer += 1;
            if (timer >= MON_DEATH_TICS * MON_DEATH_FRAMES) {
                state = MON_DEAD;
                timer = 0;
            }
        }
        frames.push(state == MON_IDLE ? 0 : (state == MON_PAIN ? 1 : (state == MON_DYING ? 2 + timer / MON_DEATH_TICS : 6)));
        if (state == MON_DEAD) {
            kills += 1;
        }
        b.storeInt(xs.get(i), 16).storeInt(ys.get(i), 16).storeInt(zs.get(i), 16).storeUint(hps.get(i), 8).storeUint(state, 4).storeUint(timer, 8);
        i += 1;
    }
    gMonX = xs;
    gMonY = ys;
    gMonZ = zs;
    gMonFrame = frames;
    return (b.endCell(), kills);
}

// Render one input (queued, or produced by the AI when the queue is empty and auto is on) and keep the
// chain going while there is more to do.
fun step(mutate st: Storage, hop: int) {
    var lvl = st.level.beginParse();
    val rootIsSS = lvl.loadUint(1) == 1;
    val root = lvl.loadRef();
    val sinTable = lvl.loadRef();
    val blockmap = lvl.loadRef();
    var assets = lvl.loadRef().beginParse();
    val gun = assets.loadRef();
    gSprites = assets.loadRef();
    var (turn, fwd, side, fire, found) = popInput(mutate st);
    if (!found & !st.auto) {
        return;
    }
    // per-frame bookkeeping shared by both paths (tools/ai.py frame_begin)
    st.rnd = (st.rnd * 1103515245 + 12345) & 0xFFFFFFFF;
    st.frameNo += 1;
    st.gun = st.gun > 0 ? st.gun - 1 : 0;
    if (found) {
        if (fire) {
            st.gun = GUN_FLASH_FRAMES;
        }
    } else {
        if (((st.rnd >> 20) & 63) == 0) {
            st.gun = GUN_FLASH_FRAMES;   // the AI shoots now and then
        }
        (turn, fwd) = aiStep(mutate st, blockmap, sinTable);
        side = 0;
    }
    val angle = (st.angle + turn) & ANGLE_MASK;
    val sn = sinAt(sinTable, angle);
    val cs = sinAt(sinTable, (angle + QUARTER) & ANGLE_MASK);
    var px = st.px + fwd * SPEED_FWD * cs + side * SPEED_SIDE * sn;
    var py = st.py + fwd * SPEED_FWD * sn - side * SPEED_SIDE * cs;
    if (found & ((px != st.px) | (py != st.py))) {
        // player input: collide with the blockmap and slide along the wall that was hit, like Doom
        // (the AI checks its own moves)
        val (hdx, hdy) = hitLine(blockmap, st.px, st.py, px, py);
        if ((hdx | hdy) != 0) {
            val dot = (px - st.px) * hdx + (py - st.py) * hdy;
            val len2 = hdx * hdx + hdy * hdy;
            val sx = st.px + dot * hdx / len2;
            val sy = st.py + dot * hdy / len2;
            if (((sx != st.px) | (sy != st.py)) & !blocked(blockmap, st.px, st.py, sx, sy)) {
                px = sx;
                py = sy;
            } else {
                px = st.px;
                py = st.py;
            }
        }
    }
    val moving = (px != st.px) | (py != st.py);
    st.angle = angle;
    st.px = px;
    st.py = py;
    // a shot (this frame's flash) may hit a target; then the targets animate one frame
    var kills = 0;
    (st.monsters, kills) = updateMonsters(st.monsters, st.gun == GUN_FLASH_FRAMES, blockmap, px, py, sn, cs);
    val (floor, viewSS) = floorAt(root, rootIsSS, px, py);
    val viewz = floor + VIEWHEIGHT;
    gViewSS = viewSS;
    val cam: Cam = { px, py, sn, cs, vz: viewz };
    val bob = moving ? (GUN_BOB_TABLE >> ((st.frameNo & 15) * 2)) & 3 : 0;
    val pixels = renderFrame(root, rootIsSS, cam, gun, st.gun > 0, bob);
    val queued = queuedCount(st.queue, st.qpos);
    emitFrame(st, viewz, pixels, queued, kills);
    st.lastStep = blockchain.now();
    if (((queued > 0) | st.auto) & (contract.getOriginalBalance() > MIN_CHAIN_BALANCE)) {
        sendContinue(hop + 1);
    }
}

// The self-continuation is bounceable: if a frame transaction ever fails (out of gas), the bounce lands in
// onBouncedMessage, which nudges the state and keeps the chain alive instead of letting it die silently.
fun sendContinue(hop: int) {
    val cont = createMessage({
        bounce: true,
        value: CONT_VALUE,
        dest: contract.getAddress(),
        body: Continue { hop },
    });
    cont.send(SEND_MODE_REGULAR);
}

// ---------------------------------------------------------------------------------------------
// Entrypoints
// ---------------------------------------------------------------------------------------------
fun onBouncedMessage(in: InMessageBounced) {
    if (in.senderAddress != contract.getAddress()) {
        return;
    }
    var st = Storage.load();
    // the failed frame is skipped: drop its input, or (AI) turn a little so the retry renders another view
    val (_, _, _, _, found) = popInput(mutate st);
    if (!found) {
        if (!st.auto) {
            return;
        }
        st.angle = (st.angle + AI_TURN_RATE) & ANGLE_MASK;
        st.turnDir = 0;
    }
    st.rnd = (st.rnd * 1103515245 + 12345) & 0xFFFFFFFF;
    st.frameNo += 1;
    st.lastStep = blockchain.now();
    if (((queuedCount(st.queue, st.qpos) > 0) | st.auto) & (contract.getOriginalBalance() > MIN_CHAIN_BALANCE)) {
        sendContinue(0);
    }
    st.save();
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;   // plain top-up
    }
    val op = in.body.preloadUint(32);
    if ((op == OP_TICK) | (op == OP_START) | (op == OP_STOP) | (op == OP_RESET)) {
        // a command relayed by an input contract (see Relay.tolk): same body as the external form. The
        // attached value buys the gas limit and stays here. Invalid / old batches are ignored (never
        // thrown: the sender is a contract).
        handleCommand(in.body, false);
        return;
    }
    val msg = lazy InternalMsg.fromSlice(in.body);
    match (msg) {
        Continue => {
            if (in.senderAddress != contract.getAddress()) {
                return;
            }
            var st = Storage.load();
            step(mutate st, msg.hop);
            st.save();
        }
        Withdraw => {
            val st = lazy Storage.load();
            if (in.senderAddress != st.owner) {
                return;
            }
            val back = createMessage({ bounce: false, value: 0, dest: st.owner, body: Withdraw {} });
            back.send(SEND_MODE_CARRY_ALL_BALANCE);
        }
        else => {
            // unknown internal message: ignore (keep the value)
        }
    }
}

fun onExternalMessage(inBody: slice) {
    handleCommand(inBody, true);
}

// Commands (TICK / START / STOP / RESET) from an external message or relayed by an internal one. For
// externals, checks happen before ACCEPT so that rejected messages are free; for relayed commands the
// same checks silently drop the command instead of throwing.
fun handleCommand(inBody: slice, isExternal: bool) {
    var body = inBody;
    val op = body.loadUint(32);
    val batchId = body.loadUint(32);
    var st = Storage.load();
    // ordering, like a game over UDP: batch lastBatch+1 is appended right away; batches ahead of it (same
    // block, random order; or their predecessor is late) wait in a small reorder buffer; when the buffer
    // is full or the oldest waited HELD_MAX_AGE seconds, the batches before it are declared lost in the
    // mempool and skipped (a late arrival is then rejected as old), so a lost batch costs its own inputs,
    // not a stall. Old / duplicate ids are rejected before ACCEPT (free).
    val ahead = batchId - st.lastBatch;
    if (!((ahead >= 1) & (ahead <= MAX_BATCH_SKIP))) {
        assert (!isExternal) throw ERR_OLD_BATCH;
        return;
    }
    if ((op == OP_START) | (op == OP_STOP)) {
        if (isExternal) {
            acceptExternalMessage();
        }
        st.lastBatch = batchId;
        st.held = null;
        val wasAuto = st.auto;
        st.auto = op == OP_START;
        st.turnDir = 0;
        st.save();
        commitContractDataAndActions();
        // kick the chain if it is not already running
        if (st.auto & (!wasAuto | (blockchain.now() - st.lastStep > CHAIN_STALE_SECONDS))) {
            step(mutate st, 0);
            st.save();
        }
        return;
    }
    if (op == OP_RESET) {
        // body: op:32 batchId:32 px:int32 py:int32 angle:uint16 (16.16 map units)
        val px = body.loadInt(32);
        val py = body.loadInt(32);
        val angle = body.loadUint(16);
        if (isExternal) {
            acceptExternalMessage();
        }
        st.px = px;
        st.py = py;
        st.angle = angle & ANGLE_MASK;
        st.queue = null;
        st.held = null;
        st.qpos = 0;
        st.gun = 0;
        st.lastBatch = batchId;
        // the targets come back too (initial monsters from the level assets, ref3 -> ref2)
        st.monsters = st.level.beginParse().refAt(3).beginParse().refAt(2);
        st.save();
        return;
    }
    if (op != OP_TICK) {
        assert (!isExternal) throw ERR_BAD_OP;
        return;
    }
    val count = body.loadUint(8);
    if (!((count > 0) & (count <= MAX_INPUTS))) {
        assert (!isExternal) throw ERR_BAD_COUNT;
        return;
    }
    // the batch: [count:8, count x INPUT_BITS] (trailing bits, e.g. a resend nonce, are ignored)
    val batch = beginCell().storeUint(count, 8).storeSlice(body.getFirstBits(count * INPUT_BITS)).endCell();
    val now = blockchain.now();
    if (ahead == 1) {
        if (isExternal) {
            acceptExternalMessage();
        }
        st.queue = appendBatch(st.queue, batch);
        st.lastBatch = batchId;
    } else {
        // accept before touching the reorder buffer: rebuilding it does not fit the pre-accept gas credit
        // (a duplicate of a waiting batch, i.e. a resend, is therefore paid for, but changes nothing)
        if (isExternal) {
            acceptExternalMessage();
        }
        val (held, dup) = heldInsert(st.held, batchId, now, batch);
        if (dup) {
            return;
        }
        st.held = held;
    }
    drainHeld(mutate st, now);
    st.save();
    commitContractDataAndActions();
    step(mutate st, 0);
    st.save();
}

// ---------------------------------------------------------------------------------------------
// Get methods
// ---------------------------------------------------------------------------------------------
get fun frameNo(): int {
    val st = lazy Storage.load();
    return st.frameNo;
}

get fun player(): (int, int, int) {
    val st = Storage.load();
    return (st.px, st.py, st.angle);
}

get fun queued(): int {
    val st = Storage.load();
    return queuedCount(st.queue, st.qpos);
}

get fun lastBatch(): int {
    val st = Storage.load();
    return st.lastBatch;
}

get fun autoState(): (int, int, int) {
    val st = Storage.load();
    return (st.auto ? 1 : 0, st.turnDir, st.lastStep);
}

// (dead, alive, count)
get fun targets(): (int, int, int) {
    val st = lazy Storage.load();
    var s = st.monsters.beginParse();
    val n = s.loadUint(4);
    var dead = 0;
    var alive = 0;
    repeat (n) {
        s.skipBits(56);
        val state = s.loadUint(4);
        s.skipBits(8);
        if (state == MON_DEAD) {
            dead += 1;
        } else if (state <= MON_PAIN) {
            alive += 1;
        }
    }
    return (dead, alive, n);
}

get fun screen(): (int, int) {
    return (W, H);
}
