--This script will run on all levels when mod is active.
-- Teardown VR companion script (legacy single-player global mod, Lua 5.1).
--
-- Talks to the native part (dxgi.dll in the game folder) through one Lua table, TDVR_BRIDGE,
-- whose 256 numeric slots the native side finds in memory and reads/writes in place.
-- Slot numbers mirror src/td_bridge_slots.h (native index; Lua index = native + 1).
-- Rules that keep the bridge safe: the table is filled once with 256 numbers, only numbers are
-- ever stored in it, and no other keys are ever added (that would let Lua move the array).
-- Without the native part this script only increments a heartbeat and never touches the game.
--
-- PUC Lua 5.1 limits: at most 200 locals per function (the main chunk included) and 60 upvalues per
-- function, so newer state lives in a few tables and the big callbacks call global helpers.

local N = 256
local function I(native) return native + 1 end

-- header
local S_MAGIC0, S_MAGIC1, S_MAGIC2, S_PROTO, S_TBL_HI, S_TBL_LO, S_COUNT = I(0), I(1), I(2), I(3), I(4), I(5), I(6)
-- Lua -> native
local L_HEARTBEAT, L_ACK_SEQ, L_ACK_EYE, L_FLAGS = I(8), I(9), I(10), I(11)
local L_HFOV_USED, L_MEAS_TANH, L_MEAS_TANV = I(12), I(13), I(14)
local L_BASE_X, L_BASE_Y, L_BASE_Z, L_BASE_YAW, L_WORLD_SCALE = I(15), I(16), I(17), I(18), I(19)
local L_HAPTIC_SEQ_L, L_HAPTIC_AMP_L, L_HAPTIC_DUR_L = I(20), I(21), I(22)
local L_HAPTIC_SEQ_R, L_HAPTIC_AMP_R, L_HAPTIC_DUR_R = I(23), I(24), I(25)
local L_PLAYER_YAW, L_PLAYER_PITCH, L_LUA_VERSION, L_DRAW_COUNT, L_ERROR = I(26), I(27), I(28), I(29), I(30)
local L_UI_W, L_UI_H, L_AIM_ACTIVE, L_RENDER_CALLS = I(31), I(32), I(33), I(34)
local L_CNT_USETOOL, L_CNT_GRAB, L_CNT_INTERACT, L_CNT_LMB, L_CNT_RMB = I(35), I(36), I(37), I(38), I(39)
local L_TOOL_STATE, L_TOOL_DIST = I(40), I(41)
local LX = {   -- v0.4 Lua -> native slots (L_<name> in td_bridge_slots.h)
    ENGINE_STATE = I(42), TOOL_CODE = I(43), CAM_METHOD = I(44), CAM_STATE = I(45), CAM_ERR = I(46),
    AIM_ERR = I(47), UPDATES_PER_TICK = I(48), GAME_FPS = I(49), HANDS_STATE = I(50), HANDS_PICKHITS = I(51),
    HANDS_COUNT = I(52), OPTIONS = I(53), QUALITY_SCALE = I(54), TOOL_DIST2 = I(55), TOOL_DIST3 = I(56),
    AIM_TELEPORTS = I(57), TOOL_FRAME = I(58), PERF_ACK = I(59), LUA_MS = I(60), EYE_DRIFT = I(61),
    HANDS_NEAR = I(62),       -- v0.6 (read every frame by native input): bit0/1 left/right hand has a grabbable body in
                              -- reach, bit2/3 left/right hand holding one (native then keeps that grip off the mouse)
    GAME_INPUT = I(63),       -- v0.7 review (native F3/M2): the game's own input this tick, written every tick (also while
                              -- VR is inactive): bit0..6 InputDown up, down, left, right, jump, usetool, crouch (see
                              -- gameInputBits; 0 without InputDown). Native compares it with the keys it posted.
}
local L2 = {   -- v0.5 Lua -> native diagnostics block L2 (160..186, docs/V05_PLAN.md section 1; v0.6 adds 187..199)
    CAMDBG_WORST = I(160), CAMDBG_CTX = I(161), CAMDBG_AIMDELTA = I(162), CAMDBG_PC_AN = I(163),
    CAMDBG_GCT_C = I(164), CAMDBG_GCT_POS = I(165), CAMDBG_BAD = I(166), CAMDBG_N = I(167),
    EYE_SRC = I(168), EYE_FIT = I(169), TOOLF_SPREAD_C = I(170), TOOLF_SPREAD_P = I(171),
    TOOLF_SPREAD_F1 = I(172), TOOLF_SPREAD_E = I(173), TOOLF_K = I(174), TOOL_DIST4 = I(175),
    TOOL_FRAME2 = I(176), HAND_SIZE_R = I(177), HAND_SIZE_EXP = I(178), HAND_BOUNDS_ERR = I(179),
    HAND_MAPPING = I(180), OPT_WRITE = I(181),
    CAM_PSRC = I(185),        -- v0.5 review: frames whose offset was built on GetPlayerCameraTransform (x1000) + on
                              -- the analytic frame, over the camera spike window (camDbgFrame)
    TOOLF_SPREAD_M = I(182),  -- v0.5 review: spread (cm) of rendered camera^-1 * tool body ("override ignored"), -1 n/a
    TOOL_FIST_CM = I(183),    -- v0.5 review: tool handle tp_action_rh to the grip (cm), -1 n/a
    OPT_ORIG = I(184),        -- v0.5 review: the user's head bob / tool sway (headbob*100 + toolsway), -1 none stored
    HAND_VOXEL_MM = I(186),   -- v0.5 review: glove voxel size from GetShapeSize's 4th return (mm*10), -1 n/a
    CAM_PDEC = I(187),        -- v0.6: render's P choice in the window: raw pc *1000000 + pc minus the tick offset
                              -- *1000 + pc minus the previous render offset (frames, each at most 999; renderCameraFrame)
    JUMP = I(188),            -- v0.6: InputPressed("jump") count *1000 + assisted jumps (cumulative)
    HANDGRAB = I(189),        -- v0.6: hand grabs *1000 + throws (cumulative)
    TOOL_REPLICA = I(190),    -- v0.6: 0 off, 1 built, 2 failed (engine tool shown), +10 engine tool hidden this frame
    TOOL_REPLICA_N = I(191),  -- v0.6: shapes in the tool replica (a failed build: replica.failN, see buildToolReplica)
    WALK_YAW = I(192),        -- v0.6: player yaw minus head yaw (deg, signed) when last walking
    CAMDBG_TELE = I(193),     -- v0.6 review F2: camera spike window, frames of yaw teleport ticks: bad *1000 + measured
    CAMDBG_NOTELE = I(194),   -- v0.6 review F2: the same for the frames of ticks without a yaw teleport
    CAMDBG_OMAG = I(195),     -- v0.6 review F2: rotation (deg) of the offset O sent in the window's worst frame, -1 n/a
    REPLICA_PICK = I(196),    -- v0.6 review R2: ticks in which the game's pick / interact / grab body was the tool replica
                              -- (cumulative)
    HOLD_SLEEP = I(197),      -- v0.6 review M1: hold updates that found the held body asleep (cumulative)
    TOOL_CORR = I(198),       -- v0.6 review: length (cm) of the closed-loop tool correction (toolCorrUpdate), -1 n/a
                              -- (v0.7: also while the correction is off, TOOLF.CORR, the default)
    GRIP_ARM = I(199),        -- v0.6 review M2/N2: hand grabs armed by the native grip latch (N_GRIP_LATCH, cumulative)
}
local L3 = {   -- v0.8 Lua -> native diagnostics block L3 (200..215, docs/V08_PLAN.md section 5; 206..215 reserved)
    AIMCHK_YAWERR = I(200),   -- last SetPlayerTransformWithPitch self-check: yaw error (deg), -1 none yet (aimCheck)
    AIMCHK_PITCHERR = I(201), -- its pitch error (deg), -1 none yet
    AIMCHK_N = I(202),        -- checks *1000 + failed checks (cumulative, failures at most 999)
    TELE_REASON = I(203),     -- yaw teleports: in a precise situation *1000 + forced precise only (aim_update = precise
                              -- or the A/B-test bit; at most 999; cumulative, see setPlayerAim)
    GAME_INPUT_SEEN = I(204), -- ticks with InputDown("jump") *1000 + ticks with InputDown("crouch") (at most 999; cumulative)
    HAND_BODY = I(205),       -- glove / tool replica bodies in use: 0 dynamic, 1 static (handBodyStatic)
    -- v0.9 (docs/V09_PLAN.md section 4; 214-215 stay reserved)
    ATT_STATE = I(206),       -- camera method attach: state of the att machine (section 1.3), 0 not used
    ATT_VIEWERR = I(207),     -- rolling 30-frame median probe error while attach is active (deg), -1 none
    ATT_EYEDIFF = I(208),     -- median |model eye - GetPlayerCameraTransform().pos| over 30 attach frames (cm), -1 none
    AIM_VS_CAM = I(209),      -- median angle GetPlayerAimInfo direction vs the camera C's forward in attach (deg), -1 none
    PSEL = I(210),            -- offset mode P rotation source psel (1 analytic, 0 pc) + 10 * informative frames (max 99)
    PERR_PC = I(211),         -- EMA of the angle engine P vs pc (deg), -1 none (section 2)
    PERR_AN = I(212),         -- EMA of the angle engine P vs the analytic frame (deg), -1 none
    WALK_ERR = I(213),        -- median walk direction error vs the player yaw (deg, signed), -999 none (section 3)
    -- v0.22 (docs/V022_PLAN.md section 5; 214 / 215 were reserved 0): the attach gate and the body copy
    ATT_GATE = I(214),        -- gate reason (0-3, +4 flatFail) + 10 retries + 100 round(zoom * 100) + 1e5 gated frames +
                              -- 1e10 scope flag seen in 5 s + 1e11 scope clear (0 not needed, 1 held, 2 back every time)
    BODY_COPY = I(215),       -- built + 100 want + 1e4 source + 1e5 attachments dropped + 1e6 lagCode + 1e7 animated +
                              -- 1e8 fail + 1e9 place + 1e10 align cm + 1e11 dSpread cm + 1e12 / 1e13 / 1e14 rms0 / 1 / 2 cm
}
local L4 = {   -- v0.10 Lua -> native diagnostics block L4 (216..226, docs/V010_PLAN.md section 5; v0.11 fills 227.. as L5)
    TOOLBODIES = I(216),      -- foreign tool bodies found this tick + 100 * GetToolBody() among them + 10000 * our replicas
                              -- alive (section 1, see hideForeignTools)
    TOOLHID = I(217),         -- foreign tool shapes we currently keep hidden (section 1)
    HANDQ = I(218),           -- hand queries, QueryClosestPoint calls (cumulative, at most 99999; section 2, handQuery)
    HANDHIT = I(219),         -- hand queries that returned any shape (cumulative)
    HANDREJ_STATIC = I(220),  -- hand query candidates rejected as not dynamic / no mass (cumulative)
    HANDREJ_MASS = I(221),    -- ... as heavier than grab_max_mass (cumulative)
    HANDREJ_OTHER = I(222),   -- ... as a vehicle / a dynamic ground body / the engine grab body / behind a static line
                              -- (cumulative; a static ground body counts in _STATIC, v0.11 review LUA-HANDREJ-5)
    HAND_NEAREST = I(223),    -- nearest acceptable grab candidate over the last 5 s (cm), -1 none
    JUMP_A = I(224),          -- A edges seen by Lua (N_BUTTONS bit0) * 1000 + assists fired (each at most 999; section 3)
    JUMP_WHY = I(225),        -- why the last A edge got no assist: 0 fired, 1 the game jumped, 2 not grounded, 3
                              -- jump_assist off, 4 A not bound to jump, 5 VR inactive / vehicle, 6 still waiting; -1 none yet
    GROUND = I(226),          -- at the last A edge's decision: own ground probe (0/1) * 10 + IsPlayerGrounded (0 false, 1
                              -- true, 2 unavailable); -1 none yet
}
local L5 = {   -- v0.11 Lua -> native diagnostics block L5 (227..235, docs/V011_PLAN.md section 5; v0.12 fills 236.. as L6)
    HAND_ANYDIST = I(227),    -- hand probe: nearest hit of any physical body over the last 5 s (cm), -1 none (section 3)
    HAND_ANYKIND = I(228),    -- kind of that hit: 0 none, 1 static, 2 dynamic
    HAND_PALM_EYE = I(229),   -- right palm -> model eye (cm, now; -1 while the hand physics do not run)
    ENGTOOL_VIS = I(230),     -- draw frames with a GetToolBody() shape not tagged invisible while the replica was shown
                              -- (cumulative, at most 99999; section 4, see engineToolDraw)
    ENGTOOL_POS = I(231),     -- engine tool body in the render camera frame: right*1e6 + up*1e3 + forward, each part
                              -- clamp(round(cm) + 500, 0, 999); -1 none
    ENGTOOL_HAND = I(232),    -- engine tool body -> right grip (cm), -1 none
    THIRDPERSON = I(233),     -- game.thirdperson (0/1) + 10 * player animator + 100 * player rig
    PLAYERSHAPES = I(234),    -- player-animator shapes we keep hidden now (section 4, see hideForeignTools)
    -- v0.22 (docs/V022_PLAN.md section 5): 235 was LUA5_RES (reserved, 0)
    HSNAP = I(235),           -- hand snaps in 5 s: event + 100 geometric + 1e4 SNAP_NOW + 1e6 SNAP_T + 1e8 tele (each
                              -- <= 99) + 1e10 round(update order ratio * 100) (<= 999)
}
local L6 = {   -- v0.12 Lua -> native diagnostics block L6 (236..242, docs/V012_PLAN.md section 6; 243..247 reserved)
    ANIM_FOUND = I(236),      -- player-animator shapes the animator box query found this tick, hidden or not (section 1)
    -- v0.21 (docs/V021_PLAN.md section 9, no new slots): 237..239 were PROBE_STATE / PROBE_REF / PROBE_AXES (the v0.12
    -- engine tool frame probe, dead in the v0.19 / v0.20 flow); the kept probe keeps those values in diag.prb (probeState
    -- / probeRef / probeAxes, writeProbeStatus) and the slots carry the solid hands' diagnostics (writeDiag21):
    HCOL = I(237),            -- stR + 10 stL + 100 fail (2 digits) + 1e4 selftest + 1e5 impCode + 1e6 variant
    HCOL_ERR = I(238),        -- median mm * 1e6 + p95 mm * 1e3 + blocked % (each <= 999; FREE/BLOCKED steps, last 5 s)
    HCOL_EV = I(239),         -- snaps * 1e6 + ghost entries * 1e3 + static clamps (each <= 999, last 5 s)
    TOOL_ERR = I(240),        -- median over 30 placing ticks of |engine tool body - desired| (cm), -1 none
    JUMP_VMAX = I(241),       -- highest vertical velocity within 0.6 s after the last A edge (cm/s), -1 none yet (section 3)
    -- v0.22 (docs/V022_PLAN.md section 5): 242 was LUA6_RES (reserved, 0)
    PUNCH = I(242),           -- punches in 5 s + 100 max J (N*s) + 1e5 max vn (dm/s) + 1e8 gated + 1e10 round(gain * 10)
                              -- + 1e12 contact onsets in 5 s + 1e13 max vn over those onsets (dm/s)
}
local L7 = {   -- v0.13 Lua -> native diagnostics block L7 (243..247, docs/V013_PLAN.md section 4; v0.15: 248.. is L8)
    -- v0.21 (docs/V021_PLAN.md section 9): 243 was VOFS_STATE (the v0.13 visible-offset self-test, a fixed 3 since
    -- v0.14); the kept test keeps it in diag.prb.vofsState. Now the visible body (section 4, see bodyMode):
    BODY_VIS = I(243),        -- mode + 10 why (2 digits) + 1000 shown + 1e5 hidden + 1e7 fights/s (each <= 99) + 1e9
                              -- SetPlayerHidden called this tick (0/1) + 1e10 proxy shapes (<= 99) + 1e12 attachments
                              -- shown + 1e13 attachments hidden (each <= 9)
    SERVO_STATE = I(244),     -- engine tool servo: 0 off, 1 converging, 2 locked (median error < 4 cm over 30 ticks), 3
                              -- diverged recently (section 2, see servoTarget)
    SERVO_ERR = I(245),       -- median over 30 servo ticks of |previous desired - engine tool body| (cm), -1 none
    TOOL_SHOWN = I(246),      -- 0 the replica is the tool seen, 1 the engine tool (section 2: the servo's engine latch, v0.14
                              -- section 1, or no replica shown while a tool body exists)
    SERVO_ROTERR = I(247),    -- v0.14 (docs/V014_PLAN.md section 1; was L_LUA7_RES): median over 30 servo ticks of the
                              -- angle between the previous desired rotation and the engine tool body's (deg), -1 none
                              -- v0.15 (docs/V015_PLAN.md section 3): 244..247 report the v0.15 placement (actWrite):
                              -- SERVO_STATE 0 not placing, 1 placing (the replica shown), 2 the engine tool shown
}
local L8 = {   -- v0.15 Lua -> native diagnostics block L8 (248..255, docs/V015_PLAN.md section 3; the end of the array)
    ACT = I(248),             -- actuator 0 none / 1 SetToolTransform / 2 SetToolOffset + 10 * its frame (1 world, 2 player
                              -- yaw, 3 camera; actuator 2 only) + 100 * state (0 idle, 1 testing, 2 decided) (section 1)
    -- v0.17 (docs/V017_PLAN.md section 4): 249..251 were ACT_T1 / ACT_T2 / ACT_TRIALS (the v0.15 pulse responses: round(
    -- length cm) * 1000 + angle, -1 none; the trials), unused since v0.16; no slot is free, so v0.17 reuses them. Only
    -- the kept v0.15 / v0.16 paths (PRB.V015 / V016, their tests) still write the old values there (actWrite).
    -- v0.21 (docs/V021_PLAN.md section 9): 249 / 250 were ROTCTL / ROTCTL_AB (the v0.17 rotation control self-check,
    -- out of the flow since v0.19); the kept paths keep those values in diag.prb (rotctl / rotctlAb, actWrite). Now:
    BODY_COL = I(249),        -- stR + 10 stL + 100 reason + 1000 ground fights + 1e5 sole clearance cm (99 unknown) + 1e7
                              -- body turns (last 5 s) + 1e9 shin ghost entries (<= 99) + 1e11 shin snaps (<= 9) + 1e12
                              -- shin rotation source (0 none, 1 body, 2 aligned, 3 both; all the last 5 s) (writeDiag21)
    PHYS_PROBE = I(250),      -- probe bits + 1000 m0 (999 unknown) + 1e6 current mask (999) + 1e9 round(hand mass * 10)
                              -- (<= 99) + 1e11 GetPlayerBodies' shapes + 1e13 GetEntityChildren's shapes (99 unknown)
    JITTER = I(251),          -- median over 30 ticks of the frame-to-frame change of (tool body - hand) (mm), -1 none
    PLACE_ERR = I(252),       -- median position error of the placement over 30 ticks (cm), -1 none (section 2)
    PLACE_ROTERR = I(253),    -- median rotation error (deg), -1 none
    BASE_P = I(254),          -- the base estimate in the player-camera frame: right*1e6 + up*1e3 + forward, each part
                              -- clamp(round(cm) + 500, 0, 999) like L_ENGTOOL_POS, -1 none
    -- v0.18 (docs/V018_PLAN.md section 2): 255 was LUA8_RES (reserved, always 0); the teleport-timing predictor's choice
    TP_PRED = I(255),         -- 0 = A (the player frame after this tick's aim teleport), 1 = B (before it) + 10 * min(
                              -- teleport ticks scored, 99)
    -- v0.19 (docs/V019_PLAN.md section 3, no new slots): ACT's state 4 = the engine tool parked (SetToolOffset 10 m down
    -- while the replica is the tool seen), 2 = at the hand; ROTCTL 0 (the self-check is out of the flow); PLACE_ERR /
    -- PLACE_ROTERR / JITTER -1 while parked (they describe the engine tool at the hand only)
}
-- native -> Lua
local N_SEQ_BEGIN, N_NATIVE_HB, N_MODE, N_SEQ, N_EYE = I(64), I(65), I(66), I(67), I(68)
local N_EYE_P, N_HEAD_P, N_HFOV = I(69), I(76), I(83)
local N_LGRIP, N_LAIM, N_RGRIP, N_RAIM, N_HANDS_VALID = I(84), I(91), I(98), I(105), I(112)
local N_LSTICK_X, N_LSTICK_Y, N_RSTICK_X, N_RSTICK_Y = I(113), I(114), I(115), I(116)
local N_LTRIG, N_RTRIG, N_LSQUEEZE, N_RSQUEEZE, N_BUTTONS = I(117), I(118), I(119), I(120), I(121)
local N_AIM_MODE, N_YAW_CONTROL, N_TURN_MODE, N_SNAP_ANGLE, N_SMOOTH_SPEED = I(122), I(123), I(124), I(125), I(126)
local N_WORLD_SCALE, N_LASER, N_LEFT_HANDED, N_DEBUG, N_RECENTER_COUNT, N_DEADZONE = I(127), I(128), I(129), I(130), I(131), I(132)
local N_PAIR_ID, N_HOLD_BASE = I(133), I(134)
local NX = {   -- v0.4 native -> Lua slots (N_<name>), inside the seqlock; HAND_OFS_P/R are 3 slots each
    CAM_METHOD = I(135),      -- (v0.9: 4 = attach, docs/V09_PLAN.md section 1)
    PERF_FLAGS = I(136), AIM_UPDATE = I(137), HAND_STYLE = I(138), HAND_OFS_P = I(139),
    HAND_OFS_R = I(142), MSG = I(145), MSG_ARG = I(146), HAND_SKIN = I(147),   -- (hand_texture: 0 glove, 1 skin,
                                                                               -- v0.21 2 blocky)
    FIX_OPTIONS = I(148),     -- v0.5: bit0 force options.input.headbob = 0, bit1 options.input.toolsway = 0
    TOOL_FRAME = I(149),      -- v0.5: tool_frame 0 auto, 1 player+1.7 yaw, 2 eye, 3 player camera, 4 final camera
    MOVE_DIR = I(150),        -- v0.6: move_dir 0 hand (v0.5), 1 head (v0.8: native rotates the left stick by the head,
                              -- Lua no longer turns the player for it)
    TOOL_DISPLAY = I(151),    -- v0.6: tool_display 0 engine tool, 1 replica (our voxel copy at the hand)
    HAND_PHYSICS = I(152),    -- v0.6: bit0 hand grab, bit1 hand push, bit2 throw on release; v0.21 (docs/V021_PLAN.md
                              -- section 2): + 8 NHP_COLLIDE (hand_collision), + 16 NHP_BODY (body_collision), + 32 * k
                              -- NHP_STR (hand_strength: k 0 normal, 1 weak, 2 strong; see readNative); v0.22 + 128
                              -- NHP_PUNCH (hand_punch), + 256 NHP_STEADY (hand_steady)
    JUMP_ASSIST = I(153),     -- v0.6: 1 = add a jump when A was pressed and the game did not jump
    GRAB_MAX_MASS = I(154),   -- v0.6: kg; heavier bodies cannot be hand-grabbed (157 reserved)
    GRIP_LATCH = I(155),      -- v0.6 review M2/N2: bit0 / bit1 the left / right grip press in progress is latched by native
                              -- as suppressed (kept from the game: it belongs to that physical hand, see updatePhysHand)
    CAM_OPTS = I(156),       -- v0.6 review: bit0 tick also sends the camera offset while render() runs (legacy A/B,
                              -- camera_tick_offset), bit1 A is bound to the jump key (jump assist / guard act only then),
                              -- v0.10 bit2 NCO_HIDE_PLAYER (hide_player = yes: SetPlayerHidden in attach, see hidePlayer)
                              -- v0.21 bit3 NCO_SHOW_BODY (show_body, see bodyMode), bit4 NCO_BODY_TURN (body_turn,
                              -- see bodyTurn); v0.22 bit5 NCO_FLAT_SCOPE (scope_zoom = no, see flatScopeTick)
    HAND_BODY = I(157),       -- v0.8: hand_body 0 dynamic, 1 static glove / tool replica bodies (was reserved 0)
}
local N_SEQ_END = I(158)

local LUA_VERSION = 22        -- mod version 0.22 (the dll warns about any other value)
local BR_PROTOCOL = 3         -- bridge block layout (BR_PROTOCOL in src/td_bridge_slots.h; 2 = v0.4 slots, v0.5 adds
                              -- only previously reserved slots; 3 = v0.6: the native block ends at 158; v0.8 fills the
                              -- reserved 157 and adds the Lua block L3 200..215, same protocol; v0.9 fills 206..213 and
                              -- N_CAM_METHOD 4 = attach, same protocol; v0.10 adds the free slots 216..226 (L4) and the
                              -- N_CAM_OPTS bit2, same protocol; v0.11 the free slots 227..235 (L5), same protocol;
                              -- v0.12 the free slots 236..242 (L6), v0.13 the free slots 243..247 (L7), v0.14 gives
                              -- 247 a meaning (L_SERVO_ROTERR), v0.15 the free slots 248..255 (L8), same protocol;
                              -- v0.21 new bits / enum values in N_HAND_PHYSICS / N_CAM_OPTS / N_HAND_SKIN and new
                              -- meanings for the dead slots 237..239, 243, 249, 250, same protocol; v0.22 the four
                              -- reserved slots 214 / 215 / 235 / 242 and new N_HAND_PHYSICS / N_CAM_OPTS bits, same
                              -- protocol)
local MODE_MONO, MODE_STEREO = 2, 3

-- L_FLAGS bits
local LF_PAUSED, LF_MAP, LF_VEHICLE, LF_DEAD, LF_SCREEN, LF_UI_INTERACTIVE = 1, 2, 4, 8, 16, 32
local LF_THIRDPERSON, LF_CINEMATIC, LF_MENU_LEVEL, LF_PHOTOMODE = 64, 128, 256, 512
local LF_CAMERA_OVERRIDE, LF_ANIMATING, LF_NATIVE_ALIVE = 1024, 2048, 4096
-- N_PERF_FLAGS bits (automatic A/B performance test: skip one part of the per-frame work; v0.8: STATIC_HANDS = the
-- gloves and the tool replica are static bodies, as hand_body = static)
local PF = { NO_AIM = 1, NO_YAW = 2, NO_LASER = 4, NO_TOOL = 8, NO_HANDS = 16, PRECISE = 32, STATIC_HANDS = 64 }

local B = nil                 -- the bridge table
local nat = { valid = false } -- latest consistent snapshot of the native block
local heartbeat = 0
local drawCount = 0
local renderCalls = 0
local lastNativeHb = -1
local staleTicks = 1000
local active = false          -- Lua controls the view this frame
local appliedSeq = -1         -- seq of the pose applied this frame
local hist = {}               -- recent applied cameras { seq, eye, pos, rot, hfov, bx, by, bz, byaw }
local bodyYaw = 0             -- VR world heading (degrees), turned by the right stick
local headingSet = false      -- bodyYaw is seeded once per script load
local lastActiveYaw = nil     -- player yaw when VR control last stopped (pause, map, ...)
local vehicleYawOffset = 0
local lastVehicleBaseYaw = nil
local wasInVehicle = false
local cursorFrames = 1000     -- frames since game.cursor.enabled was last seen (held to avoid flicker)
local noInputFrames = 1000    -- frames since game.disableinput was last seen
local snapArmed = true
local lastRecenter = -1
local hapticSeq = { 0, 0 }
local lastGrab = 0
local useToolTimer = 0
local errorCode = 0
local toolTarget = nil        -- world position we asked the tool to be at this frame (diagnostics)
local laserTarget = nil       -- world point the laser hits this tick (nil = no laser)
local drawInRender = false    -- render() runs every frame: hands/laser are drawn there with its base
local renderCallsAtTick = 0
-- (v0.21, docs/V021_PLAN.md section 9: prb = the values the kept PRB.V013..V018 paths wrote to 237..239 / 243 / 249 /
-- 250 before those slots got their v0.21 meanings - probeState / probeRef / probeAxes (L_PROBE_*, writeProbeStatus),
-- vofsState (L_VOFS_STATE, writeServoStatus / actWrite), rotctl / rotctlAb (L_ROTCTL / _AB, actWrite); their tests read
-- them here)
local diag = { usetool = 0, grab = 0, interact = 0, lmb = 0, rmb = 0,
               prb = { probeState = 0, probeRef = 0, probeAxes = 0, vofsState = 0, rotctl = 0, rotctlAb = 0 } }
local ctl = nil               -- controller snapshot used for aim, tool, laser and hands (see snapshotControllers)
local perf = { updates = 0, winUpdates = 0, winTicks = 0, winTime = 0, ups = 0, lastDt = 0, optTimer = 1000,
               renderMs = 0, alive = false, clock = nil, updTotal = 0 }   -- render() time since the last tick;
                                                            -- native heartbeat alive; os.clock() at the start of
                                                            -- this tick (nil: none); update() calls since the start
-- teleTick: a yaw teleport this tick. v0.6 review (F2/F4, see setPlayerAim and updateAimAndTool): toolUse = the tool
-- is used this tick (toolInUse), since = seconds since the last yaw teleport, limited = yaw teleports deferred by the
-- rate limit (cumulative). (v0.8: the v0.6 head/laser blend is gone, nothing turns the player in lazy aim.)
-- v0.7 (docs/V07_PLAN.md section 2, see aimTeleport): trio = the yaw teleport uses the v0.6 trio (+8000 in
-- L_CAM_METHOD), check = { yaw, pitch, heartbeat } of the last SetPlayerTransformWithPitch to verify on the next tick,
-- fails = failed checks in a row, checks / passed = checks made / passed (cumulative). v0.7 review F2: check[4] = the
-- player was grounded at the teleport, trioLeft = seconds left of a fallback trio (nil: none, or for good without
-- SetPlayerTransformWithPitch), retries = fallbacks that ran out (WithPitch tried again; cumulative). v0.8
-- (docs/V08_PLAN.md section 2/5): yawErr / pitchErr = the last check's errors (deg, -1 none: L_AIMCHK_*), byPrecise /
-- byForced = yaw teleports in a precise situation / only by forced precise aim (L_TELE_REASON). v0.18
-- (docs/V018_PLAN.md section 2, the teleport-timing predictor, actPlace17): preYaw / prePitch = the player's yaw and
-- pitch as setPlayerAim found them this tick (before its SetPlayerPitch and teleport: the previous frame's), preAt = the
-- heartbeat they were read, teleAt = the heartbeat of the last yaw teleport (-1 none)
local aimState = { teleports = 0, preciseTimer = 0, teleTick = false, toolUse = false, since = 1000,
                   limited = 0, trio = false, check = nil, fails = 0, checks = 0, passed = 0, trioLeft = nil,
                   retries = 0, yawErr = -1, pitchErr = -1, byPrecise = 0, byForced = 0, preYaw = 0, prePitch = 0,
                   preAt = -1, teleAt = -1, byDrift = 0,    -- (byDrift: v0.18 review LUA18-STALE-AIM-BLOCKED-USE)
                   preciseTick = -1 }   -- (v0.21 section 4.3: the heartbeat of the last tick setPlayerAim ran precise)
-- v0.6 walking direction and jump (docs/V06_PLAN.md section 4, see updateJump and updateAimAndTool): jumps = ticks with
-- InputPressed("jump"), assists = assisted jumps, aDown = A (N_BUTTONS bit0) last tick, guard = seconds left of the
-- yaw teleport protection after an A press, wait = ticks left before the jump assist decides (0: none or the game
-- jumped), air = seconds in the air (IsPlayerGrounded false), blocked = yaw teleports skipped by the protection,
-- walkYaw = L_WALK_YAW. v0.8: gi = this tick's L_GAME_INPUT bits, seenJump / seenCrouch = ticks with the game's jump /
-- crouch input down (L_GAME_INPUT_SEEN). v0.9 (docs/V09_PLAN.md section 3): walkErrs = the last 30 walk direction
-- errors (L_WALK_ERR, see updateWalkErr). v0.10 (docs/V010_PLAN.md section 3): aEdges = A edges seen (L_JUMP_A), why =
-- L_JUMP_WHY of the last A edge (-1 none yet), ground = L_GROUND at its decision (-1 none yet). v0.12 (docs/V012_PLAN.md
-- section 3): vmax = L_JUMP_VMAX (cm/s, -1 none yet), vT = seconds since the last A edge while its 0.6 s window is open
-- (nil: closed)
-- v0.16 review LUA16-TELEPORT-JUMP-INPUT: jiDown = the game's own jump input (gi bit 16) was down last tick (its press
-- edge arms guard, whatever the jump is bound to; see updateJump).
local jump = { jumps = 0, assists = 0, aDown = false, guard = 0, wait = 0, air = 0, blocked = 0, walkYaw = 0, gi = 0,
               seenJump = 0, seenCrouch = 0, walkErrs = {}, aEdges = 0, why = -1, ground = -1, vmax = -1, vT = nil,
               jiDown = false }
-- v0.12 engine tool frame probe (docs/V012_PLAN.md section 2, see probeUpdate / probeStep / probePlace): state =
-- L_PROBE_STATE (0 none, 1 running, 2 honored + reference chosen, 3 not honored, 4 inconsistent, 5 honored, waiting for
-- a second run), result = the state of the last completed run (shown again after an abort), step = the override held now
-- (1..4 = O0..O3; 0 no run), hold = ticks it has been sent, at = heartbeat of the last probe tick, quiet = seconds the
-- main trigger and grip have been below 0.15, wait = seconds until a run may start, key = the tool the runs belong to
-- ("" none; v0.12 review LUA-PRB-3: the name only), body / p0 = the tool body and the player position at the start of
-- the run, T = the body transforms measured (index = step), R = the four reference frames at the O0 measurement, runs =
-- completed runs for this key, res = their results { ok, L = { L_R per reference }, krot }, ref = the chosen reference (0 none), L / krot =
-- its L_R and Krot (placement), axes = L_PROBE_AXES, errs = the last 30 placing ticks' |engine tool body - desired| (cm,
-- L_TOOL_ERR), idle = ticks in a row without a placement, rc = the camera draw() saw last frame (reference 3 of a
-- measurement: the camera the engine placed the measured body with). v0.12 review LUA-PRB-1: amb = runs that could not
-- tell the references apart (not counted toward RUNS; v0.13: none any more, see probeChoose). v0.12 review LUA-PRB-2:
-- lastRc = the rc the previous probe tick saw, turn = the camera's turn rate since then (deg/s). v0.12 review LUA-PRB-3:
-- key = the tool NAME only, cache[tool] = that tool's runs / results / chosen reference while another tool is selected
-- ({ ref, L, krot, runs, amb, res, result, axes; v0.13 def })
-- v0.13 (docs/V013_PLAN.md section 2): def = the reference was chosen by default (reference 1 after two runs that could
-- not tell the references apart; +100 in L_PROBE_REF). The v0.13 state lives in this table too (the main chunk is near
-- Lua 5.1's 200 locals):
-- vofs = the visible-offset self-test (section 1, see vofsUpdate): state = L_VOFS_STATE of the current tool body, phase =
-- 0 idle / 1 the offset sent (n = ticks of it) / 2 the wait after it (n = ticks waited), result = the measured outcome
-- (2 / 3) shown once the wait is over, key = the tool body the state belongs to (0 none; a tick without one keeps it),
-- cache[body] = { state, aborts, wait } of the other tool bodies, body / p0 / pp = the tool body, its position and the
-- player position at the start of the run, wait = seconds until a run may start (after an abort, or 30 s after
-- "inconclusive"), aborts = aborted runs for this key, last = the state before the running test (an abort shows it
-- again), sentAt = the heartbeat whose tick sent the offset (render() sends it again in that frame), calls =
-- SetToolOffset calls (cumulative), settle = seconds the servo still waits for a body the offset may have moved (v0.13
-- review LUA13-SERVO-SETTLE, see vofsSettle).
-- servo = the engine tool servo (section 2, see servoTarget): c = the integral correction (world, m), body / ref / L =
-- what it was built for (a change resets c), prev / at = the desired position and heartbeat of the last servo tick (the
-- hand's velocity for the lead), errs = the last 30 |D - M| (cm, L_SERVO_ERR), far = seconds in a row with |D - M| >
-- DIV, recent = seconds left of "diverged recently", diverged = divergence resets (cumulative), state =
-- L_SERVO_STATE as written last tick, shown = the engine tool is the one seen this tick (L_TOOL_SHOWN: a tool body and
-- no replica shown, also by the section 2 rule, see updateToolReplica). v0.13 review: held = the servo is waiting for
-- the visible-offset self-test (LUA13-SERVO-SETTLE: no integral, no window, c frozen), engine = the latched
-- "engine tool shown" decision and high = ticks in a row its window's median was above UNLOCK cm (SC-3 /
-- LUA13-SHOWN-HYST, see writeServoStatus).
-- v0.14 (docs/V014_PLAN.md section 1): key = the tool (name) the servo was built for (a switch resets it like a new
-- body), cw = the integral rotation correction (world rotation vector, radians), prevRot = the previous servo tick's
-- desired rotation, rerrs = the last 30 rotation errors (deg, L_SERVO_ROTERR). engine / high are now the v0.14 shown
-- latch (SHOW_CM + SHOW_DEG on, UNLOCK cm for UNLOCK_N ticks off).
-- v0.14 review: stall = seconds c or cw sat at its clamp with the error above UNLOCK cm (LUA14-SERVO-WINDUP), freeze =
-- ticks left with the integrals and windows frozen after a pose jump (LUA14-SERVO-JUMP-INTEGRAL).
-- v0.15 (docs/V015_PLAN.md sections 1-3; the v0.14 log: the override from our script is not honored, the engine tool
-- sits at its own first-person pose, SetToolOffset does move it): act = the actuator test and the placement with its
-- result (see actUpdate / actPlace), in this table too (the main chunk is near Lua 5.1's 200 locals). Test: key = the
-- tool (name) the state belongs to ("" none), body = its tool body, a = L_ACT's actuator (0 none / 1 SetToolTransform /
-- 2 SetToolOffset), f = actuator 2's frame (1 world, 2 player yaw, 3 camera), st = 0 idle / 1 testing / 2 decided,
-- pulse = the pulse under test (1 transform, 2 offset), phase = 0 between trials / 1 pulse ticks / 2 quiet ticks, n =
-- ticks in that phase, rel = seconds the main trigger and grip have been released, retry = seconds until actuator 0 is
-- tested again, tr / votes / angs = per pulse: trials, per frame the matching trials and their summed angles, code = L_ACT_T1 / T2 (-1 none), hist = the last body samples { hb, t, pos, rot, clean } (clean: the frame
-- before it had nothing of ours on the body), clock = seconds (dt sum, the sample times), pulsedAt / pulsedP = the
-- heartbeat whose tick sent a pulse and that pulse (render() sends it again), b0 / v = the trial's start sample and the
-- base velocity extrapolated over it, cache[tool] = a decided tool's result. Placement: c = the integral correction (world, m), errs / rerrs = the last 30 position (cm) /
-- rotation (deg) errors, engine = the shown latch (the engine tool seen, the replica hidden), high = ticks in a row with
-- the position median above UNLOCK cm, sentAt = the heartbeat whose frame got our last placement call, sentT = actuator
-- 1's T sent last, sentW = actuator 2's offset sent last as a world vector (F * o), sentP = the player-camera frame at
-- that call, dPrev = the desired transform of that call (no lead, no c), prevTw / prevAt = the previous placing tick's
-- desired transform and heartbeat (the lead), lead = { dp, dq } this tick's lead (render() adds it to its own desired
-- transform), base = the base estimate of this tick (render: of this frame; nil none), baseL = it in the player-camera
-- frame (see actPlace), good = that base was a real estimate (actPlace), at = the heartbeat of the last placing tick.
-- v0.15 review: inconc = offset trials in a row without a separated frame, wait = seconds no trial starts (after INCONC
-- of them), nets = safety-net retests of this tool (actRetest), clampAt / clampN = the heartbeat of the last call with
-- |o| clamped to TMAX and the placing ticks in a row with it, yawAt = the player yaw of a trial's last pulse tick
-- (actTrial's yaw axis).
-- v0.16 (docs/V016_PLAN.md section 1): run = the offset placement can run this tick (actCanRun, set by actUpdate; never
-- with PRB.V013 / V014 / V015) - the replica hidden, the player's aim precise.
-- v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK (see actHold): hold = seconds the placement stays off after it did not
-- converge in either frame (st 3, the replica shown; 0 none), vf = the offset frame in use without PRB.V015 (2 yaw, 4
-- yaw+pitch; an engine property, kept across tools), tried4 = frame 4 was tried since the last hold.
-- v0.17 (docs/V017_PLAN.md sections 1-4, see actPlace17; the main chunk is near Lua 5.1's 200 locals, so in act too):
-- bL = the base EMA in the player-camera frame (Transform, nil none yet), bN = samples in it (the warm-up), rejT =
-- seconds of samples rejected in a row,
-- R = the rotation control's rotation (the SetToolTransform sent; identity while off), sentO = the offset sent this
-- frame (render re-sends it and R unchanged), sentR = the R the last frame got (its sample's rotation is taken out),
-- prevE = the previous sample's body - target vector and its heartbeat (eAt), jit = the last JN frame-to-frame changes
-- (mm, L_JITTER), rc = the current tool's self-check { st = L_ROTCTL state, t = seconds of the window running, offP /
-- offR / onP / onR = the windows' position (cm) / rotation (deg) errors, offPm / offRm = the off window's medians, ab =
-- L_ROTCTL_AB }, rcCache[tool] = a decided tool's { st (3 / 4), ab }, rcN = tools decided.
-- v0.18 (docs/V018_PLAN.md section 2, tpScore18): tp = the last teleport tick's predictions to score on the next tick
-- ({ hb, pos = the eye of the frame's pose, rA / rB = the player-camera rotation after / before the teleport }, nil
-- none), tpEA / tpEB = the EMAs of the A / B scores (m), tpN = teleport ticks scored, tpB = B in use (an engine
-- property: kept across tools, actPlaceReset drops only tp), tpRB = this frame's B rotation when B placed it (nil: A).
-- v0.18 review LUA18-PRED-B-OFFSET-FRAME / V18-SPEC-TPPRED-OFFSET-FRAME: tp also { FA / FB = the offset frame after /
-- before the teleport }, tpEW = the EMA of the whole-frame-late score (W: base AND offset frame before), tpW = the
-- before-prediction in use is W (tpB true; false: B, the base only). LUA18-PRESS-ROT-LURCH: Rq = the base rotation R
-- was computed with. LUA18-2B-RESIDUAL-NOT-HANDLE: gL / gPrev = the grip of the last call (player-camera frame / world,
-- render's pose), rhS = its handle point, berrs = the body-origin errors (cm, actWrite's UNLOCK / actHold guard).
-- v0.19 (docs/V019_PLAN.md section 1, see use19 / mode19 / actPark19): u19 = seconds left of the current tool's "in use"
-- (the main trigger >= P19.USE or usetool down: P19.TAIL, counting down after both end), m19 = this tick's flow (0 the
-- v0.18 one: the engine tool at the hand whenever the placement runs - a tool without a replica, the kept paths; 1 the
-- replica seen, the engine tool parked; 2 the engine tool at the hand, the replica hidden), parkAt = the heartbeat of the
-- last parking call (-1 none).
-- v0.19 review V19-PARK-FRAME4-BOOKKEEPING (parkBase19): sentW2 / sentW4 = the last park's offset as a world vector in
-- the yaw / the yaw + pitch frame (nil: the last call was no park), fv19 / fvN19 = the frame the parked samples voted for
-- and the votes in a row (an engine property: kept across tools, like vf).
local probe = { state = 0, result = 0, step = 0, hold = 0, at = -1, quiet = 0, wait = 0, key = "", body = 0, p0 = nil,
                T = {}, R = nil, runs = 0, res = {}, ref = 0, L = nil, krot = nil, axes = 0, errs = {}, idle = 0, rc = nil,
                amb = 0, lastRc = nil, turn = 0, cache = {}, def = false,
                vofs = { state = 0, phase = 0, n = 0, result = 0, key = 0, cache = {}, body = 0, p0 = nil, pp = nil,
                         wait = 0, aborts = 0, last = 0, sentAt = -1, calls = 0, settle = 0 },
                servo = { c = { 0, 0, 0 }, body = 0, ref = 0, L = nil, prev = nil, at = -1, errs = {}, far = 0,
                          recent = 0, diverged = 0, state = 0, shown = false, held = false, engine = false, high = 0,
                          key = "", cw = { 0, 0, 0 }, prevRot = nil, rerrs = {}, stall = 0, freeze = 0 },
                act = { key = "", body = 0, a = 0, f = 0, st = 0, pulse = 1, phase = 0, n = 0, rel = 0, retry = 0,
                        tr = { 0, 0 }, votes = { {}, {} }, angs = { {}, {} }, code = { -1, -1 }, hist = {}, clock = 0,
                        pulsedAt = -1, pulsedP = 1, b0 = nil, v = nil, cache = {},
                        c = { 0, 0, 0 }, errs = {}, rerrs = {}, engine = false, high = 0, sentAt = -1, sentT = nil,
                        sentW = nil, sentP = nil, dPrev = nil, prevTw = nil, prevAt = -1, lead = nil, base = nil,
                        baseL = nil, good = false, at = -1, inconc = 0, wait = 0, nets = 0, clampAt = -1,
                        clampN = 0, run = false, hold = 0, vf = 2, tried4 = false,
                        bL = nil, rejT = 0, bN = 0, R = nil, sentO = nil, sentR = nil, prevE = nil, eAt = -1, jit = {},
                        rc = { st = 0, t = 0, offP = {}, offR = {}, onP = {}, onR = {}, ab = -1 }, rcCache = {},
                        rcN = 0, tp = nil, tpEA = 0, tpEB = 0, tpN = 0, tpB = false, tpRB = nil,
                        tpEW = 0, tpW = false, Rq = nil, gL = nil, gPrev = nil, rhS = nil, berrs = {},
                        u19 = 0, m19 = 0, parkAt = -1, sentW2 = nil, sentW4 = nil, fv19 = 0, fvN19 = 0 } }
-- Probe constants (section 2): O = the overrides O0..O3 (positions, m), HOLD = ticks each is held (measured on the last),
-- D = their length (m), HONOR = the body moved this far (m) for "honored", SMIN / SMAX = the allowed axis lengths,
-- ORTHO = the largest deviation from 90 degrees between two axes, QUIET / TRIG = how long (s) the main trigger and grip
-- must be below TRIG first, RETRY = seconds between runs and after an abort, MOVE = player movement (m) that aborts,
-- RUNS = runs per tool at most, AGREE_CM / AGREE_DEG = a reference's L_R agreement between the two most recent runs,
-- TIE = score margin (cm + deg) a later reference needs to win over an earlier one (references 1 and 4 differ by a
-- constant 1.7 m and always agree alike), N = the L_TOOL_ERR window (ticks). v0.12 review LUA-PRB-1 / L12-PROBE-
-- NONDISCRIMINATING: CLASS = the equivalence class of each reference (1 and 4 one class), SEP_CM / SEP_DEG = how far
-- (cm or deg, 2 x the agreement) every reference outside the winner's class must disagree between the two runs before
-- the winner is chosen. v0.12 review LUA-PRB-2: the player must be still: VEL = the largest player speed (m/s), STICK =
-- the largest right-stick x (no smooth / snap turn), ROT = the largest turn rate of the camera (deg/s)
-- v0.13 (docs/V013_PLAN.md section 2; the v0.12 headset log: the engine moved the tool only 61-79 % of the way within 4
-- ticks, it smooths the tool toward the override by roughly 25 % per tick): HOLD 4 -> 12 (1 - 0.75^12 = 97 %), SMIN /
-- SMAX 0.8 / 1.25 -> 0.45 / 1.3, ORTHO 15 -> 20 (the remaining smoothing shortens and skews the axes a little).
-- VOFS = the visible-offset self-test (section 1): OFS = the offset (m), TICKS = ticks it is sent (P1 measured on the
-- last), WAIT = ticks waited after it (the body settles back before a probe may measure it), FOLLOW = |P1 - P0 - OFS|
-- below this (m) means the offset moved the tool body, RETRY = seconds after an abort, ABORTS = aborts that make it
-- inconclusive, AGAIN = seconds until an inconclusive test runs again.
-- SERVO (section 2): K = integral gain per tick, CMAX = the largest |c| (m), LEAD = the lead (s) on the hand's velocity,
-- VMAX = the largest velocity (m/s) the lead takes (a pose jump is no velocity), DIV / DIV_T = an error above DIV (m)
-- for DIV_T seconds resets c, RECENT = seconds a divergence counts as recent, LOCK = the locked median (cm) over N ticks,
-- IDLE = ticks without a servo tick after which it is off (c and the window dropped). v0.13 review SC-3 /
-- LUA13-SHOWN-HYST: once the engine tool is shown (locked) it stays shown until the median is above UNLOCK cm (2 x
-- LOCK) for UNLOCK_N ticks in a row (or the servo is off / diverged): no swapping of the two tools around LOCK.
-- v0.13 review LUA13-SERVO-ONE-TICK / SC-1: LEAD is feed-forward only (the error is the hand against the body placed
-- for it, see servoTarget): with the engine's world smoothing f per tick the body lags a hand at speed v by v * dt *
-- (1 / f - 1) = v * 0.05 s at f = 0.25, 60 Hz, so this lead leaves c nothing to wind up at a steady speed (a frame-local
-- smoothing makes c settle at minus the lead instead; the error measured stays the real one either way).
-- v0.14 (docs/V014_PLAN.md section 1; the v0.13 headset log: the self-test needs ~1 s of standing still with the trigger
-- released and aborted again and again in play, the probe waited for it and the servo for the probe, so nothing ever
-- placed the engine tool; the one completed test said 3): V013 = false, the self-test and the probe are never started
-- (their code is kept; only the tests of that kept code set V013, which also restores the v0.13 servo's wait for a
-- probe reference). SERVO: KROT = the rotation integral's gain per tick, CWMAX = the largest |cw| (deg); the shown
-- latch (the engine tool cannot be hidden): on when the 30-tick medians are below SHOW_CM cm and SHOW_DEG deg, off after
-- UNLOCK_N ticks in a row above UNLOCK cm (UNLOCK 8 -> 12, UNLOCK_N 15 -> 10), the servo off or diverged.
-- v0.14 review SPECX-1 (the headset log: the game ticks at ~30 Hz, not 60): the lag above is v * dt * (1 / f - 1) per
-- tick's dt, so a fixed 0.05 s lead covered only half of it at 30 Hz. LEAD -> LEAD_TICKS = 3 (1 / f - 1 at f = 0.25 per
-- tick): the lead is LEAD_TICKS * dt s, dt capped at LEAD_DT (a hitch does not throw the target ahead); 0.05 s at 60 Hz
-- as before. The rotation gets the same lead (servoTarget). v0.14 review LUA14-SERVO-JUMP-INTEGRAL: FREEZE = ticks the
-- integrals and the windows stand still after a pose jump (the engine's catch-up is no bias to learn).
-- v0.15 (docs/V015_PLAN.md sections 1-2; the v0.14 log: servo diverged, 40-70 cm off - the override is not honored):
-- V014 = false, no SetToolTransformOverride while attach is in use (the v0.14 servo and its placement are kept; only the
-- tests of that kept code set V014 - V013 implies it). ACT: PULSE = the pulse (m, along X), TICKS = ticks a pulse is sent
-- (the response measured on the last), QUIET = ticks without a pulse after it, REL = seconds the main trigger and grip
-- must be released (below TRIG) first, ANG = the largest angle (deg) between a response and the expected axis, LMIN /
-- LMAX = the response length (m) that counts, TRIALS / WIN = trials per pulse, matching trials that decide, RETRY =
-- seconds until actuator 0 is tested again; placement: K / CMAX = the integral's gain and largest |c| (m), ILIM = a
-- residual (m) above which nothing is integrated (deviation: a pose jump or a stale base is no engine smoothing), TMAX =
-- the largest |T.pos| / |o| (m), SHOW_CM / SHOW_DEG = the shown latch's medians (deg: actuator 1 only), UNLOCK /
-- UNLOCK_N = back to the replica above UNLOCK cm for UNLOCK_N ticks, IDLE = ticks without a placing tick after which the
-- placement is off (windows, c and the latch dropped). LEAD_TICKS = the lead (ticks of the desired transform's motion,
-- the v0.14 tick-scaled lead's form, dt capped at SERVO.LEAD_DT). Deviation (the spec: "+ the v0.14 tick-scaled lead",
-- i.e. 3): 0. The base estimate (base = M * T_prev^-1 every tick) already takes whatever the engine has not applied yet
-- into the base and sends it again, a dead-beat loop on the engine's lag; the v0.14 lead on top (made for the
-- override's open 25 %/tick approach) overshoots. The mock, max error at a hand moving 0.5 m/s + 90 deg/s / walking 1.5
-- m/s + turning 90 deg/s, lead 0 / 1 / 3 ticks: an engine applying the call at once 0 / 2.2 / 6.5 cm and 0 / 4.3 / 12.8
-- cm, 50 %/tick 1.1 / 2.3 / 6.7 and 2.1 / 4.5 / 13.1 cm, 25 %/tick 2.7 / 3.6 / 7.3 and 5.4 / 7.0 / 14.4 cm.
-- v0.15 review LUA15-ACT-FRAME-AMBIGUOUS / V15-FRAME-AMBIG: SEP = how far (deg) every other frame's angle must lie above
-- the best frame's for an offset trial to vote (closer: the trial is inconclusive, not counted - an X pulse cannot tell
-- apart frames whose X axes coincide, e.g. world and yaw at yaw 0, yaw and camera when the head looks along the aim),
-- and how far apart the three X axes must lie for an offset trial to start at all (actFramesApart);
-- INCONC / PAUSE = after INCONC inconclusive trials in a row no trial starts for PAUSE s (the pulses are visible);
-- RETEST / CLAMP_N = a decided actuator 2 with the position median above UNLOCK cm for RETEST placing ticks in a row, or
-- |o| at TMAX for CLAMP_N, is tested again (a wrong frame diverges); NETS = after that many such retests of a tool
-- without the engine tool shown, actuator 0. v0.15 review LUA15-ACT-B1-OFFBYONE / V15-TRIAL-FRAMES: SETTLE = a trial
-- starts only more than SETTLE ticks after the last pulse (its base velocity not from a body still easing back: the
-- linear extrapolation of an engine's 25 %/frame return overshoots - the mock, the trial after a 27 cm reading with the
-- velocity samples 5-8 / 9-12 frames after the pulse: 30 / 28 cm; V15-TRIAL-FRAMES' TICKS + 8).
-- v0.15 review LUA15-PLACE-VMAX-WORLD / V15-VMAX-WALK: JUMP = a step of the desired position (m) in one tick that is a
-- pose jump (a teleport, a quickload; walking at 7 m/s or a swing is ~0.1-0.4 m per tick); SERVO.VMAX only caps the lead.
-- v0.16 (docs/V016_PLAN.md section 1; the v0.15 log: SetToolOffset works in the player-yaw frame for every tool, the
-- SetToolTransform responses were inconsistent, and the 0.4 m pulses were visible): V015 = false, no actuator test and
-- no pulse ever - actuator 2 in the yaw frame is fixed ("decided") for every tool (actUpdate), the replica is hidden
-- whenever the placement can run (actCanRun) and the player's aim follows the hand while it runs (preciseAim). The
-- v0.15 test, its cache, safety net and shown latch are kept; only the tests of that kept code set V015 (V013 / V014
-- take precedence: their kept paths do not place with the actuator at all).
-- v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: the v0.15 X pulses cannot tell the yaw frame from the player's yaw+pitch
-- frame (pitch turns about X), and with the wrong one the loop diverges above ~50 deg pitch (the mock: 35-370 cm at
-- -50..-72 deg, the only tool in view metres off the hand). A guard without pulses (actWrite, actHold): RETEST / CLAMP_N
-- as the v0.15 safety net -> first the yaw+pitch frame (frame 4) when |pitch| >= PITCH deg (below it both frames nearly
-- coincide), else / when that diverges too: no SetToolOffset and the replica for RETRY s (L_ACT state 3, 322).
-- v0.17 (docs/V017_PLAN.md sections 1-3; the v0.16 log: the tools wobble 5-7 cm, rotErr 8-72 deg): V016 = false, the
-- placement of actPlace17 (the base learnt as an EMA in the player-camera frame and predicted for this frame, one value
-- per frame re-sent by render, SetToolTransform(rotation only, sway 0), the rotation control with its self-check). The
-- v0.16 placement (base from the previous frame, the integral, render's own value, no SetToolTransform) is kept; only
-- the tests of that kept code set V016 (V015 / V014 / V013 take precedence). P17: EMA = the base EMA's weight of a new
-- sample, REJ = a sample farther than this (m) from the EMA is rejected, REJ_T = seconds of rejected samples in a row
-- after which the EMA restarts from the sample (deviation, see actLearn17), WARM = the EMA's warm-up samples (see
-- actLearn17), K = the integral's gain (section 1: "no
-- integral term, keep the code, gain 0"), WIN = the self-check's window length (s of placing ticks), GAIN = the
-- rotation control's slerp step toward its target per tick, RMAX = the largest |angle(R)| (deg), KEEP_ROT = rotErr_on
-- must be at most this share of rotErr_off, KEEP_CM = posErr_on at most posErr_off + this (cm), JN = the L_JITTER window
-- (ticks).
-- v0.18 (docs/V018_PLAN.md section 1): RMAX 90 -> 175 deg - the player's aim no longer follows the hand while a tool's
-- rotation control is kept (preciseAim), so R alone must turn the tool as far as the wrist does (shortest path; 175, not
-- 180: the sign of a half turn is undefined). P18 (section 2, the teleport-timing predictor, tpScore18): EMA = the
-- weight of a teleport tick's score, N = teleport ticks scored before B may be chosen, HYS = B is chosen when EMA_B <
-- HYS * EMA_A, A again when EMA_A < HYS * EMA_B.
-- v0.19 (docs/V019_PLAN.md sections 1-2; the v0.18 headset test: "every tool placement is wrong, they still wobble, they
-- do not rotate with my hand, the sledgehammer is too high" - seven versions of the engine tool in the hand never gave a
-- steady, correctly turned tool): V018 = false, a built-in tool with a replica is seen as the REPLICA while idle and the
-- engine tool is parked out of sight (actPark19); only a USE tool in use brings the engine tool to the hand (the v0.17
-- placement, precise aim, the replica hidden); a tool without a replica keeps the v0.18 placement; the rotation
-- control's self-check is out of the flow (R identity, L_ROTCTL 0); HANDLE tools are held by the handle (toolWorldOf).
-- The v0.18 flow (all of that off, the self-check and the aim-turned hold of every tool) is kept; only the tests of that
-- kept code set V018 (V013..V016 take precedence as before). P19: USE = the main trigger value that counts as "in use"
-- (below the 0.55 click: the engine tool is at the hand before the shot), TAIL = seconds it stays in use after the
-- trigger and usetool end, PARK = the parking offset (m, the player-yaw frame SetToolOffset is proven in: 10 m down),
-- PARKT = the PARK tools (no muzzle, their action follows the player's aim, not the tool body: never at the hand).
local PRB = { O = { { 0, 0, 0 }, { 0.3, 0, 0 }, { 0, 0.3, 0 }, { 0, 0, 0.3 } }, HOLD = 12, D = 0.3, HONOR = 0.15,
              SMIN = 0.45, SMAX = 1.3, ORTHO = 20, QUIET = 0.5, TRIG = 0.15, RETRY = 5, MOVE = 0.5, RUNS = 3,
              AGREE_CM = 3, AGREE_DEG = 3, TIE = 0.05, N = 30, CLASS = { 1, 2, 3, 1 }, SEP_CM = 6, SEP_DEG = 6,
              VEL = 0.05, STICK = 0.2, ROT = 15, V013 = false, V014 = false, V015 = false, V016 = false,
              P17 = { EMA = 0.2, REJ = 0.3, REJ_T = 0.5, WARM = 5, K = 0, WIN = 10, GAIN = 0.5, RMAX = 175, KEEP_ROT = 0.7,
                      KEEP_CM = 2, JN = 30,
                      -- (v0.17 review LUA17-PIVOT-LAG-UNTESTED: PCT rcStep17's P90 rule; PIV / PV_L / PV_Y / PV_MAX
                      -- pivotLearn17)
                      PCT = 0.9, PIV = true, PV_L = 1e-4, PV_Y = 0.15, PV_MAX = 1 },
              P18 = { EMA = 0.3, N = 5, HYS = 0.7,
                      -- (v0.18 review LUA18-STALE-AIM-BLOCKED-USE: TOUCH the trigger value that arms precise aim with the
                      -- control kept, DRIFT / DRIFT_T the lazy aim's drift bound, deg / s; preciseAim, setPlayerAim)
                      TOUCH = 0.15, DRIFT = 25, DRIFT_T = 1 },
              V018 = false,
              P19 = { USE = 0.15, TAIL = 0.3, PARK = { 0, -10, 0 }, PARKT = { sledge = true, plank = true },
                      -- (v0.19 review V19-PARK-FRAME4-BOOKKEEPING, parkBase19: BMAX = m from the eye a first-person
                      -- base can be, VOTES = parked samples in a row that set the offset frame)
                      BMAX = 1.5, VOTES = 5 },
              VOFS = { OFS = { 0, -50, 0 }, TICKS = 10, WAIT = 10, FOLLOW = 5, RETRY = 5, ABORTS = 3, AGAIN = 30 },
              SERVO = { K = 0.35, CMAX = 1.0, LEAD_TICKS = 3, LEAD_DT = 1 / 15, VMAX = 5, DIV = 1.5, DIV_T = 1,
                        RECENT = 5, LOCK = 4, IDLE = 30, UNLOCK = 12, UNLOCK_N = 10, KROT = 0.35, CWMAX = 45,
                        SHOW_CM = 6, SHOW_DEG = 8, FREEZE = 20 },
              ACT = { PULSE = 0.4, TICKS = 4, QUIET = 4, REL = 0.3, ANG = 25, LMIN = 0.25, LMAX = 0.6, TRIALS = 3, WIN = 2,
                      RETRY = 60, K = 0.2, CMAX = 0.3, ILIM = 0.5, TMAX = 3, SHOW_CM = 6, SHOW_DEG = 10, UNLOCK = 12,
                      UNLOCK_N = 10, IDLE = 30, LEAD_TICKS = 0, SEP = 15, INCONC = 10, PAUSE = 10, RETEST = 60,
                      CLAMP_N = 30, NETS = 3, SETTLE = 12, JUMP = 1, PITCH = 20 } }
-- Tool override frame (see measureToolDist): frame = in use (L_TOOL_FRAME), auto = the tool_frame=auto choice,
-- autoBy = what chose auto ("K" self-identification, "dist" the v0.4 distance rule, false nothing), forced =
-- N_TOOL_FRAME forces frame; sent = the override of the last tick and the candidate frames it was sent against;
-- samples = implied body offsets K per candidate (v0.5); body/tool: what the samples were taken with. v0.5 review:
-- idFrame = the frame the identification chose (0 none; byK = it locks the distance rule out, never set while
-- forced), loseRun = new samples in a row with its spread > LOSE (a full window releases it), kMean/kFrame = the
-- mean body offset K of idFrame that placeToolInHand takes out of the override, mSamples/spreadM = the "override
-- ignored" check, fist = L_TOOL_FIST_CM
local toolCal = { frame = 1, auto = 1, autoBy = false, forced = false, sent = nil, run = 0, runFrame = 0, body = 0,
                  tool = "", samples = {}, spread = { -1, -1, -1, -1 }, kLen = -1, idFrame = 0, byK = false,
                  loseRun = 0, kMean = nil, kFrame = 0, mSamples = {}, spreadM = -1, fist = -1,
                  corr = nil, corrFrame = 0 }   -- v0.6 review: closed-loop correction (frame corrFrame's axes, m; see
                                                -- toolCorrUpdate), nil none
-- Eye source (see updateEyeSource): src = L_EYE_SRC; off = world translation of the camera offset the engine
-- composed last (nil: none); latched = the eye is contaminated by exactly that offset; height = learned standing
-- eye height above the player position (nil until 30 samples). v0.5 review: tickOff = world translation of the
-- offset this tick sent; use/useOff = the source and the subtracted offset at the current call site (tick, or
-- render after eyeSourceRender); fb = the fallback source (2 or 3); bad/hi/lo = drift hysteresis; teleAt = yaw
-- teleport count when tick decided (a teleport after that skips source 1); rfit = render's fit (cm, -1 n/a)
local eyeSrc = { src = 0, off = nil, latched = false, run = 0, miss = 0, fit = -1, height = nil, heightN = 0,
                 tickOff = nil, use = 0, useOff = nil, fb = 2, bad = false, hi = 0, lo = 0, used = 0, teleAt = 0,
                 rfit = -1 }
-- v0.6 tool replica (docs/V06_PLAN.md section 5, see updateToolReplica): body = our static copy of the engine tool body
-- (0 none), key = the tool id and tool body handle it was built for ("" none), state = L_TOOL_REPLICA 0 off / 1 built /
-- 2 failed for that key (not retried until the key changes), n / shapes = its shapes, visible = they are untagged,
-- shown = displayed this tick (the engine tool hidden), hidden = engine tool shapes we tagged "invisible" (handle ->
-- true; untagged again when no longer hidden), cleaned = stale replicas of an earlier Lua state deleted.
-- v0.6 review: src = the source shape of each copy (same index; R4/R7), toolHid = source shapes the tool script itself
-- keeps hidden (handle -> true; R4, see hideEngineTool), shapeVis = each copy untagged (index -> true), placed = put at
-- the hand at least once since the build (R1: shown only then), picks = L_REPLICA_PICK, rayHit = a default-layer ray
-- from the eye hit it (R2, +100 in L_TOOL_REPLICA), failN = L_TOOL_REPLICA_N of a failed build (missed-1: -(model
-- voxel * 10000 + measured voxel), voxel sizes in 0.1 mm, measured 0 = the spawn gave no shapes; -1 another failure,
-- e.g. no model; see buildToolReplica). v0.7 (replica v2, spawned from TOOL_MODELS): src = the engine tool shape paired with each copy
-- (same index, only when the engine body has the same shapes in the same order; else empty), srcLt / ownLt = that
-- shape's and the copy's local transform at the build (an animated engine shape moves its copy by the same change),
-- animated = copy i was last set away from its build-time transform (index -> true). v0.7 review F1: wild = copy
-- updates skipped because the engine shape moved too far for a part animation (see placeToolReplica; cumulative)
-- v0.10 (docs/V010_PLAN.md section 1, see hideForeignTools): foreign = foreign tool shapes seen while attach hides them
-- (handle -> true: it was visible, we tagged it "invisible" and untag it later; false: it was already hidden, left alone),
-- fBodies / fEngine = foreign tool bodies / GetToolBody() among the last tick's query results, fReps = our replica bodies
-- alive (FindBodies "tdvr_tool") counted at phys.clock fRepAt (nil: not yet) (L_TOOLBODIES)
-- v0.11 (docs/V011_PLAN.md section 4): fPlayer = player-animator shapes among this tick's hidden ones (L_PLAYERSHAPES),
-- engVis = draw frames with an engine tool shape not tagged invisible while the replica was shown (L_ENGTOOL_VIS)
local replica = { body = 0, key = "", state = 0, n = 0, shapes = {}, visible = false, shown = false, hidden = {},
                  cleaned = false, src = {}, toolHid = {}, shapeVis = {}, placed = false, picks = 0, rayHit = false,
                  failN = -1, srcLt = {}, ownLt = {}, animated = {}, wild = 0,
                  park = nil,    -- v0.8: where the copy was last put (parkOwnBody holds it there while not shown)
                  foreign = {}, fBodies = 0, fEngine = 0, fReps = 0, fRepAt = nil, fPlayer = 0, engVis = 0 }
-- v0.6 physical hands (docs/V06_PLAN.md section 7, see updateHandPhysics): base / baseTick = the world base updateActive
-- used and the tick it did (hand poses are taken from it), near = L_HANDS_NEAR as published last tick, grabs / throws /
-- pushes = counters, clock = seconds (game dt), pushT = body -> clock of its last push. v0.6 review: ground = the body
-- the player stands on (GetPlayerGroundContact, 0 none; never grabbed or pushed, H1), sleep = L_HOLD_SLEEP (M1), arms =
-- L_GRIP_ARM (M2/N2). Per hand (l, r): on = grip (hysteresis), arm = seconds left in which this press may still grab
-- (-1: the press belongs to the game), wait = ticks left in which the native latch may still claim this press (M2/N2),
-- hold = the held body { body, lp = grab point (body space), rel = hand^-1 * body at the grab, mass, far / stuck =
-- seconds too far from the hand, orient = this hand also turns it }, hit = the reach query's closest body { body, point,
-- normal, dist }, cand = hit if grabbable, hist = recent play-space grip positions { t, p }, world / palm = the hand's
-- world transform and palm centre, vel = its world velocity (nil: unknown), rvel = the same without the player's
-- velocity (the hand's own motion), target = the hold target (the hand, capped per tick, see capHandStep), tgtRel =
-- target position minus the player position at that tick (L2: update() rebuilds it from the player's position then)
-- v0.10 (docs/V010_PLAN.md section 2, see handQuery): q / qHit = hand queries / those with any shape (L_HANDQ /
-- L_HANDHIT), rej = candidates rejected { static, mass, other } (L_HANDREJ_*), nearB = whole second of phys.clock ->
-- nearest acceptable grab candidate in it (m; L_HAND_NEAREST over the last 5 s)
-- v0.11 (docs/V011_PLAN.md section 3, see handProbe): probeAt = phys.clock of the last probe (nil: none yet), anyB =
-- whole second of phys.clock -> { dist (m), kind (1 static, 2 dynamic) } of the nearest probe hit in it (L_HAND_ANYDIST /
-- L_HAND_ANYKIND over the last 5 s), palmEye = right palm -> model eye (m, -1 none; L_HAND_PALM_EYE)
local phys = { base = nil, baseTick = -1, near = 0, grabs = 0, throws = 0, pushes = 0, clock = 0, pushT = {}, ground = 0,
               sleep = 0, arms = 0, q = 0, qHit = 0, rej = { 0, 0, 0 }, nearB = {}, probeAt = nil, anyB = {}, palmEye = -1,
               l = { on = false, arm = 0, wait = 0, hist = {} }, r = { on = false, arm = 0, wait = 0, hist = {} } }
-- Physical hand constants: PALM = palm centre (glove model frame, right hand; x mirrored for the left), REACH / PUSH_R =
-- query radii (m), REACH_OUT = the reach hysteresis (a hand near last tick stays near up to REACH + REACH_OUT), ARM =
-- how long a press near a body may still grab (s), LATCH_WAIT = ticks after a press in which the native latch may still
-- arm it, FAR / FAR_T and STUCK / STUCK_T = release when the grab point is that far from the hand (m) for that long (s),
-- ACC / FMAX = hold force per hand min(mass * ACC, FMAX) (N; heavier bodies are dragged, not lifted), VEL_MIN..VEL /
-- ANGVEL = constraint speed limits (m/s, rad/s; see holdHands), LEVER = torque arm of the hold force (m), BODY_R /
-- CARRY = while a held body's box overlaps the player (a vertical cylinder of radius BODY_R) its pull is at most CARRY
-- times its weight, JUMP + JUMP_V * dt / TURN = largest hold target step per tick (m, deg), VEL_WIN = hand velocity
-- window (s), HIST = samples kept, THROW_MIN / THROW_MAX = throw speeds (m/s), THROW_FULL = full throw speed up to this
-- share of grab_max_mass, PUSH_V / PUSH_GAP / PUSH_MASS / PUSH_K / PUSH_D = push threshold (approach speed into the
-- surface, m/s), interval per body (s), mass cap (kg), factor and contact distance (m). v0.10 (docs/V010_PLAN.md
-- section 2): REACH 0.09 -> 0.12, REACH_OUT 0.02 -> 0.03 (the v0.9 headset session never had a hand near anything);
-- QTRY = queries per hand query at most (each rejects the bodies the earlier ones found unusable, see handQuery)
local HP = { PALM = { -0.02, 0, 0 }, REACH = 0.12, REACH_OUT = 0.03, PUSH_R = 0.05, ARM = 0.25, LATCH_WAIT = 2, FAR = 0.6,
             FAR_T = 0.3, STUCK = 0.25, STUCK_T = 1, ACC = 40, FMAX = 1500, VEL_MIN = 0.5, VEL = 8, ANGVEL = 12,
             LEVER = 0.15, BODY_R = 0.3, CARRY = 1.2, JUMP = 0.1, JUMP_V = 10, TURN = 45, VEL_WIN = 0.1, HIST = 16,
             THROW_MIN = 1, THROW_MAX = 15, THROW_FULL = 0.25, PUSH_V = 0.5, PUSH_GAP = 0.1, PUSH_MASS = 30, PUSH_K = 0.3,
             PUSH_D = 0.02, QTRY = 4 }

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------
local function W(idx, v)       -- only ever store numbers
    if type(v) ~= "number" or v ~= v then v = 0 end
    B[idx] = v
end

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function angleDiff(a, b)     -- a - b wrapped to (-180, 180]
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

local function yawPitchOf(dir)     -- degrees; yaw 0 = -Z, positive = left turn
    local yaw = math.deg(math.atan2(-dir[1], -dir[3]))
    local pitch = math.deg(math.asin(clamp(dir[2], -1, 1)))
    return yaw, pitch
end

local function readPose(base)   -- 7 slots: px py pz qx qy qz qw
    return { nat.raw[base], nat.raw[base + 1], nat.raw[base + 2],
             nat.raw[base + 3], nat.raw[base + 4], nat.raw[base + 5], nat.raw[base + 6] }
end

local function localToWorld(base, p, ws)
    local lt = Transform(Vec(p[1] * ws, p[2] * ws, p[3] * ws), Quat(p[4], p[5], p[6], p[7]))
    return TransformToParentTransform(base, lt)
end

local function hasBit(flags, bit)
    return math.floor((flags or 0) / bit) % 2 == 1
end

local function qconj(q) return Quat(-q[1], -q[2], -q[3], q[4]) end

local function quatAngle(a, b)     -- degrees between two rotations
    local d = math.abs(a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4])
    return math.deg(2 * math.acos(clamp(d, 0, 1)))
end

local function yawPitchRot(yaw, pitch)
    return QuatRotateQuat(QuatAxisAngle(Vec(0, 1, 0), yaw), QuatAxisAngle(Vec(1, 0, 0), pitch))
end

local function median(list)        -- -1 for an empty list
    local n = #list
    if n == 0 then return -1 end
    local s = {}
    for i = 1, n do s[i] = list[i] end
    table.sort(s)
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) * 0.5
end

-- Reads the native block into `nat` if it is consistent (seqlock: begin == end). A block whose native heartbeat is
-- still 0 is the all-zero table of a new Lua state the native part has not found yet (v0.5 review O2): not valid.
local function readNative()
    local s1 = B[N_SEQ_BEGIN]
    if s1 ~= B[N_SEQ_END] or B[N_NATIVE_HB] == 0 then return end
    local raw = {}
    for i = N_SEQ_BEGIN, N_SEQ_END do raw[i] = B[i] end
    if B[N_SEQ_BEGIN] ~= s1 then return end   -- changed while copying
    nat.raw = raw
    nat.valid = true
    nat.hb = raw[N_NATIVE_HB]
    nat.mode = raw[N_MODE]
    nat.seq = raw[N_SEQ]
    nat.eye = raw[N_EYE]
    nat.hfov = raw[N_HFOV]
    nat.handsValid = raw[N_HANDS_VALID]
    nat.aimMode = raw[N_AIM_MODE]
    nat.yawControl = raw[N_YAW_CONTROL]
    nat.turnMode = raw[N_TURN_MODE]
    nat.snapAngle = raw[N_SNAP_ANGLE]
    nat.smoothSpeed = raw[N_SMOOTH_SPEED]
    nat.worldScale = raw[N_WORLD_SCALE]
    if nat.worldScale <= 0 then nat.worldScale = 1 end
    nat.laser = raw[N_LASER]
    nat.leftHanded = raw[N_LEFT_HANDED]
    nat.debug = raw[N_DEBUG]
    nat.recenter = raw[N_RECENTER_COUNT]
    nat.rstickX = raw[N_RSTICK_X]
    nat.rstickY = raw[N_RSTICK_Y]
    nat.pairId = raw[N_PAIR_ID]
    nat.holdBase = raw[N_HOLD_BASE]
    nat.camMethod = raw[NX.CAM_METHOD]
    nat.perf = raw[NX.PERF_FLAGS]
    nat.aimUpdate = raw[NX.AIM_UPDATE]
    nat.handStyle = raw[NX.HAND_STYLE]
    nat.handOfsP = { raw[NX.HAND_OFS_P], raw[NX.HAND_OFS_P + 1], raw[NX.HAND_OFS_P + 2] }
    nat.handOfsR = { raw[NX.HAND_OFS_R], raw[NX.HAND_OFS_R + 1], raw[NX.HAND_OFS_R + 2] }
    nat.msg = raw[NX.MSG]
    nat.msgArg = raw[NX.MSG_ARG]
    nat.handSkin = raw[NX.HAND_SKIN]
    nat.fixOptions = raw[NX.FIX_OPTIONS]
    nat.toolFrame = raw[NX.TOOL_FRAME]
    nat.moveDir = raw[NX.MOVE_DIR]
    nat.toolDisplay = raw[NX.TOOL_DISPLAY]
    nat.handPhysics = raw[NX.HAND_PHYSICS]
    nat.jumpAssist = raw[NX.JUMP_ASSIST]
    nat.grabMaxMass = raw[NX.GRAB_MAX_MASS]
    nat.camOpts = raw[NX.CAM_OPTS] or 0
    nat.gripLatch = raw[NX.GRIP_LATCH] or 0
    nat.handBody = raw[NX.HAND_BODY] or 0
    -- v0.21 (docs/V021_PLAN.md section 2): the new options travel in bits of existing slots (an older dll never sets
    -- them: every v0.21 part stays off, the v0.20 behaviour). hand_texture blocky is N_HAND_SKIN 2 (nat.handSkin).
    nat.handCollide = hasBit(nat.handPhysics, 8)           -- NHP_COLLIDE: hand_collision = yes
    nat.bodyCollide = hasBit(nat.handPhysics, 16)          -- NHP_BODY: body_collision = yes
    nat.handStrength = math.floor((nat.handPhysics or 0) / 32) % 4   -- NHP_STR * k: 0 normal, 1 weak, 2 strong
    nat.showBody = hasBit(nat.camOpts, 8)                  -- NCO_SHOW_BODY: show_body = yes
    nat.bodyTurn = hasBit(nat.camOpts, 16)                 -- NCO_BODY_TURN: body_turn = yes
    -- v0.22 (docs/V022_PLAN.md section C): 128 / 256 leave floor(bits / 32) % 4 above untouched (4 and 8 are 0 mod 4)
    nat.handPunch = hasBit(nat.handPhysics, 128)           -- NHP_PUNCH: hand_punch = yes
    nat.handSteady = hasBit(nat.handPhysics, 256)          -- NHP_STEADY: hand_steady = yes
    nat.flatScope = hasBit(nat.camOpts, 32)                -- NCO_FLAT_SCOPE: scope_zoom = no
end

-- Controller snapshot (grips, aims, triggers, squeezes, valid bits, buttons). The native part re-reads the
-- controllers on every frame, but the right eye of a stereo pair must show the hands, laser and tool exactly
-- where the left eye did, so eye 1 reuses the snapshot taken for eye 0 of the same pair (like heldBase).
local function snapshotControllers()
    if nat.eye == 1 and ctl and (nat.pairId or 0) > 0 and ctl.pair == nat.pairId then return end
    local raw = nat.raw
    ctl = { pair = (nat.eye == 0) and nat.pairId or -1,
            lgrip = readPose(N_LGRIP), laim = readPose(N_LAIM), rgrip = readPose(N_RGRIP), raim = readPose(N_RAIM),
            ltrig = raw[N_LTRIG] or 0, rtrig = raw[N_RTRIG] or 0, lsq = raw[N_LSQUEEZE] or 0, rsq = raw[N_RSQUEEZE] or 0,
            hv = raw[N_HANDS_VALID] or 0, buttons = raw[N_BUTTONS] or 0 }
end

-- ---------------------------------------------------------------------------------------------
-- callbacks
-- ---------------------------------------------------------------------------------------------
function init()
    B = {}
    for i = 1, N do B[i] = 0 end            -- array part of exactly 256 slots
    TDVR_BRIDGE = B                         -- global anchor (the key lives in _G, not in B)
    -- magic values are built at runtime (literal arithmetic would be constant-folded into the
    -- function's constant table, which is itself an array of TValues and would confuse the scan)
    B[S_MAGIC0] = tonumber("7340033.0625")
    B[S_MAGIC1] = tonumber("-2621447.5")
    B[S_MAGIC2] = tonumber("12345.6875")
    B[S_PROTO] = BR_PROTOCOL
    B[S_COUNT] = N
    local s = tostring(B)                   -- e.g. "table: 000001D2C3F4A5B0"
    local hex = string.match(s, "0x(%x+)") or string.match(s, ":%s*(%x+)")
    if hex and #hex <= 16 then
        hex = string.rep("0", 16 - #hex) .. hex
        B[S_TBL_HI] = tonumber(string.sub(hex, 1, 8), 16) or 0
        B[S_TBL_LO] = tonumber(string.sub(hex, 9, 16), 16) or 0
    else
        errorCode = 1
    end
    B[L_LUA_VERSION] = LUA_VERSION
    B[L_ACK_SEQ] = -1
    B[L_ACK_EYE] = 2
end

-- Legacy fixed-step callback (60 Hz, 0..n calls per frame): counted, to see how many simulation steps the engine
-- runs per frame (L_UPDATES_PER_TICK); v0.6: the bodies held by the physical hands are constrained here (holdHands).
-- v0.21 (docs/V021_PLAN.md section 6.4): then the solid hands' and shins' colliders (driveColliders).
-- v0.22: the body copy's player-frame ring (bodyCopyRing) and the scope flag (flatScopeTick).
function update(dt)
    perf.updates = perf.updates + 1
    perf.updTotal = perf.updTotal + 1   -- (never reset: the glove bounds check waits for a physics step)
    holdHands(dt)
    driveColliders(dt)
    bodyCopyRing()
    flatScopeTick("update", 0)
end

-- Per-tick bookkeeping for flags that other scripts set per frame (their order relative to us is
-- unknown, so a sighting is held for a few frames instead of being read raw).
local function updateFlagHolds()
    if GetBool("game.cursor.enabled") then cursorFrames = 0 else cursorFrames = cursorFrames + 1 end
    if GetBool("game.disableinput") then noInputFrames = 0 else noInputFrames = noInputFrames + 1 end
end

local function computeFlags()
    local f = 0
    if GetBool("game.paused") then f = f + LF_PAUSED end
    if GetBool("game.map.enabled") then f = f + LF_MAP end
    if GetPlayerVehicle() ~= 0 then f = f + LF_VEHICLE end
    if GetPlayerHealth() <= 0 then f = f + LF_DEAD end
    if GetPlayerScreen() ~= 0 then f = f + LF_SCREEN end
    -- interactive cursor UI without pause (sandbox spawn menu, tool tutorials, mod menus)
    if cursorFrames < 10 then f = f + LF_UI_INTERACTIVE end
    if GetBool("game.thirdperson") then f = f + LF_THIRDPERSON end
    -- cutscenes and other script-owned cameras (campaign intros, creative mode)
    if GetBool("level.cinematic.active") or GetBool("game.creative.enabled") or noInputFrames < 15 then
        f = f + LF_CINEMATIC
    end
    if GetString("game.levelid") == "menu" then f = f + LF_MENU_LEVEL end
    if GetInt("game.screenshot") ~= 0 then f = f + LF_PHOTOMODE end
    if GetBool("game.path.animating") then f = f + LF_ANIMATING end
    return f
end

-- The player's true eye position on foot, by the eye source updateEyeSource chose (L_EYE_SRC; in render() as
-- eyeSourceRender re-checked it): 0 the raw GetPlayerEyeTransform(), 1 the raw eye minus the world translation of
-- the offset it contains (the eye follows our own camera offset), 2 the player x/z with the eye height (v0.4
-- fallback), 3 the player position plus the learned standing eye height. After a yaw teleport in this tick source 1
-- is skipped (the engine may have rotated the offset in the eye with the new yaw: up to 2*|o|*sin(dYaw/2) wrong).
-- (v0.9: with the camera method attach the VR base does not use this, see attachEye; L_EYE_SRC then reports 4.)
function playerEyePos()
    local eye = GetPlayerEyeTransform().pos
    local s, o = eyeSrc.use, eyeSrc.useOff
    if s == 1 and aimState.teleports ~= eyeSrc.teleAt then s = eyeSrc.fb end
    if s == 1 then
        if o then return VecSub(eye, o) end
        return eye
    end
    if s == 0 then return eye end
    local p = GetPlayerTransform().pos
    if s == 3 and eyeSrc.height then return Vec(p[1], p[2] + eyeSrc.height, p[3]) end
    return Vec(p[1], eye[2], p[3])
end

-- World-space base of the VR origin: the player's eye (on foot see playerEyePos; v0.9: the model eye attachEye while
-- the camera method attach is in use, docs/V09_PLAN.md section 1.2), rotated by our VR heading.
local function computeBase(flags)
    local yaw = bodyYaw
    local pos
    if not hasBit(flags, LF_VEHICLE) then
        pos = attachEye() or playerEyePos()
    else
        pos = GetPlayerEyeTransform().pos
        local veh = GetPlayerVehicle()
        local vt = GetVehicleTransform(veh)
        local fwd = QuatRotateVec(vt.rot, Vec(0, 0, -1))
        local vyaw = yawPitchOf(VecNormalize(Vec(fwd[1], 0, fwd[3])))
        yaw = vyaw + vehicleYawOffset
        lastVehicleBaseYaw = yaw
    end
    return Transform(pos, QuatAxisAngle(Vec(0, 1, 0), yaw)), pos, yaw
end

-- Stereo pairs: the native part asks for the left eye on one frame and the right eye on the next,
-- both from one head pose. The right eye reuses the world base (player position + heading) that the
-- left eye was drawn with, so walking between the two frames does not pull the eyes apart.
local heldBase = nil   -- { pair = left seq, pos = Vec, yaw = deg }

-- Never held inside a vehicle (the cockpit moves with the player, so holding would split it between
-- the eyes) and never across a teleport/respawn (more than 1.5 m between the two frames).
local function pairedBase(flags)
    local base, bpos, byaw = computeBase(flags)
    if nat.holdBase == 1 and (nat.pairId or 0) > 0 and not hasBit(flags, LF_VEHICLE) then
        if nat.eye == 0 then
            heldBase = { pair = nat.pairId, pos = bpos, yaw = byaw }
        elseif nat.eye == 1 and heldBase and heldBase.pair == nat.pairId
            and VecLength(VecSub(bpos, heldBase.pos)) < 1.5 then
            return Transform(heldBase.pos, QuatAxisAngle(Vec(0, 1, 0), heldBase.yaw)), heldBase.pos, heldBase.yaw, true
        end
    end
    return base, bpos, byaw, false
end

-- The camera C we want for this frame (world space). Pure maths: applying it is submitCamera's job.
local function computeCamera(flags)
    local base, bpos, byaw, held = pairedBase(flags)
    local cam = localToWorld(base, readPose(N_EYE_P), nat.worldScale)
    -- remember what we asked for, for the ack and the self-calibration in draw()
    local e = hist[#hist]
    if not e or e.seq ~= nat.seq then
        e = {}
        hist[#hist + 1] = e
        if #hist > 8 then table.remove(hist, 1) end
    end
    e.seq, e.eye, e.pos, e.rot, e.hfov = nat.seq, nat.eye, cam.pos, cam.rot, nat.hfov
    e.bx, e.by, e.bz, e.byaw = bpos[1], bpos[2], bpos[3], byaw
    e.held = held                      -- (camera spike diagnostics, context bit 6)
    appliedSeq = nat.seq
    return cam, base, held
end

-- ---------------------------------------------------------------------------------------------
-- camera methods and their self-calibration
-- ---------------------------------------------------------------------------------------------
-- 1 "override": SetCameraTransform(C, hfov). The engine then runs its script-camera mode in which the
--   player is not interactive (no first-person tool, no tool use, grab or interact), so it is only used in
--   vehicles and as the last resort on foot.
-- 2 "offset": SetCameraFov + SetCameraOffsetTransform(O) and 3 "playeroffset": SetPlayerCameraOffsetTransform(O),
--   with O relative to the player camera P: local O = P^-1 * C, or the "world" variant
--   O = (C.pos - P.pos, C.rot * conj(P.rot)). Which one the engine honours, and how it composes it, is not
--   documented: with camera_method = auto, draw() measures the candidates in this order and locks the first
--   that puts the image where C says.
-- 4 "attach" (v0.9 default, docs/V09_PLAN.md section 1): AttachCameraTo(world body) + SetCameraOffsetTransform(W^-1 * C):
--   the camera is fixed to the world, not composed with the player camera P, so aim changes (the yaw teleport, the
--   pitch hand aim sets every tick) can no longer move the image (the v0.8 headset log: the engine composed our offset
--   with a P that GetPlayerCameraTransform() in render() did not show yet, the image jumped by the aim change). The att
--   state machine (attachTick / attachDraw) falls back to method 2 for this script instance if it hurts the view or the
--   tools.
local CAM_CANDIDATES = { { 2, false }, { 2, true }, { 3, false }, { 3, true } }
local PROBES = { { 0, 0, -0.6 }, { 0.15, 0.1, -0.6 }, { 0, 0, -20 }, { 4, -3, -20 } }   -- camera-local points
local cal = {
    mode = -1,                   -- N_CAM_METHOD this state was set up for
    state = 0,                   -- L_CAM_STATE: 1 calibrating, 2 locked OK, 3 locked fallback, 4 forced by ini
    cand = 0,                    -- index into CAM_CANDIDATES while calibrating
    method = 1, world = false,   -- method / composition for on-foot frames
    analyticP = false,           -- the last render's P was the analytic eye frame (no player camera candidate fit)
    sentO = nil, renderO = nil,  -- the offset sent last (tick or render) and by the last render (nil: none)
    tickO = nil,                 -- v0.6: the offset the last tick sent (nil: none); tickW / renderW: composed in world
    tickW = false, renderW = false,   -- space (else locally), as their own decontamination must undo them
    pPick = 1,                   -- v0.6: render's P candidate in use (1 pc, 2 minus tick, 3 minus render offset; 0 the
    pRun = { 0, 0, 0 },          -- analytic frame) and for how many frames in a row 2 / 3 qualified (renderCameraFrame)
    frames = 0, errs = {}, aimErrs = {}, aimWait = 0,
    aimUnverified = false,       -- passed without an informative aim sample (+2000 in L_CAM_METHOD)
    recent = {},                 -- last 30 frame errors -> L_CAM_ERR
    recentFar = {},              -- last 30 far-probe (rotation) errors while standing still, for the locked monitor
    aimRecent = {}, aimBad = 0,  -- informative aim errors while locked (> 3 deg: reported only, see monitorLocked)
    aimFar = 0,                  -- for how long their median has been > 10 deg (5 s: a re-calibration is due)
    aimPend = false, aimStill = 0,     -- v0.6 review F1: that re-calibration waits for 1 s of standing still
    lock = nil,                  -- { method, world, cand, aimUnverified } kept while it runs (restored when the player moves, or when
                                 -- no other candidate passes)
    aimOnly = false,             -- no other candidate passed: the method is kept, the aim error is a diagnostic only
                                 -- (+4000 in L_CAM_METHOD, no further aim re-calibration this level)
    badTime = 0, reruns = 0,
    stillTime = 0, retried3 = false,   -- one more calibration from state 3 after 10 s standing still
    airTime = 0, groundBroken = false, -- IsPlayerGrounded sanity (see playerStill)
    used = 0, usedWorld = false, inVehicle = false,   -- how this frame's camera was applied
    aimErr = -1, aimNear = false,      -- aimNear: this frame's aim sample was skipped (hit closer than 4 m)
    -- v0.9 (docs/V09_PLAN.md section 2, see renderCameraFrame / pselDraw): render's P rotation source in offset mode,
    -- psel 1 = the analytic rotation with pc's position, 0 = pc as v0.8 (with its P1/P2 candidates); pInf = informative
    -- frames seen, errPc / errAn = EMAs (deg) of the engine's P vs pc / vs the analytic frame (-1 none yet)
    psel = 1, pInf = 0, errPc = -1, errAn = -1,
}
-- v0.9 camera method attach (docs/V09_PLAN.md section 1.3, see attachTick / attachDraw / attachFail): state = L_ATT_STATE
-- (0 not used, 1 trial, 2 confirmed, 3 failed: view, 4 failed: tools, 5 API missing, 6 trial again after an
-- inconclusive tool failure); errs = the last 30 measured probe errors while attach is active, n = measured frames since
-- attach (re)started, bad = seconds the rolling median has been > 5 deg; dead = seconds the selected tool has not been
-- alive (tool check), ok = seconds of the confirm condition; blame = seconds of the blame check in method 2 (nil: none),
-- toolFails = tentative tool failures in this script instance; eyeDiffs / aimVsCam = the last 30 samples of L_ATT_EYEDIFF
-- (cm) / L_AIM_VS_CAM (deg); failErr = the view median that failed attach (state 3; nil otherwise). (One table: the main
-- chunk is near Lua 5.1's 200-local limit.)
-- v0.22 (docs/V022_PLAN.md section 4): state 7 = trial again after a view failure (the retry); viewFails = view failures
-- (attachFail(3)) in this script instance, retryT = s of clean ticks toward the next retry (ATT_RETRY), retries = retries
-- started; the gate (attachGate): gate = the reason of the last draw (0 none, 1 frustum, 2 zoom, 3 foreign camera), raw =
-- that draw's frustum / camera reason (1 / 3) even when the cap stopped it gating, gateN
-- = gated frames (cumulative), gateT = s of G1 / G3 without G2 in a row, capped = the cap ended the gate until a clean
-- frame, zoomEnd = HC.clock until which a zoom still gates (0.3 s after it), zoom = game.player.tool.zoom read last;
-- scope_zoom = no (flatScopeTick): tool / zoomTool = the tool selected and whether G2 fired since it was selected,
-- flatFail = SetToolAllowedZoom had no effect (calls stopped), flatBadT = s of that in a row, narrow = the last measured
-- frustum was > 3 % narrower (narrowOk: the last draw measured it), narrowBase = narrow at the first measurement after the
-- zoom tool was selected (nil: none yet; only ever cleared after that), scopeAt / heldAt / backAt = HC.clock the scope flag was last seen true / our clear held /
-- the flag was back, cleared = we cleared the flag since the last read.
local att = { state = 0, errs = {}, n = 0, bad = 0, dead = 0, ok = 0, blame = nil, toolFails = 0, eyeDiffs = {},
              aimVsCam = {}, failErr = nil,
              viewFails = 0, retryT = 0, retries = 0, gate = 0, raw = 0, gateN = 0, gateT = 0, capped = false, zoomEnd = -1,
              zoom = 0, tool = nil, zoomTool = false, flatFail = false, flatBadT = 0, narrow = false, narrowOk = false,
              narrowBase = nil, scopeAt = -1e9,
              heldAt = -1e9, backAt = -1e9, cleared = false }
ATT_GATE_MAX = 5                 -- v0.22 section 4.1: s of G1 / G3 (without G2) in a row after which the gate stops
ATT_RETRY = { 5, 15, 45 }        -- v0.22 section 4.2: s of clean ticks before the 1st / 2nd / 3rd retry after a view fail
-- v0.22 section 4.3: the tools with a zoom (data/tools_settings.xml target_zoom > 1): rifle 4, the others 1.2
ZOOM_TOOLS = { rifle = true, spraycan = true, extinguisher = true, blowtorch = true, shotgun = true, pipebomb = true,
               gun = true, bomb = true, rocket = true, explosive = true }

function offsetApi(method)
    if method == 2 then return SetCameraFov ~= nil and SetCameraOffsetTransform ~= nil end
    if method == 3 then return SetCameraFov ~= nil and SetPlayerCameraOffsetTransform ~= nil end
    return true
end

-- Forgets the measurements of the current candidate (it is measured again from its settle frames).
function resetMeasure()
    cal.frames, cal.errs, cal.aimErrs, cal.aimWait = 0, {}, {}, 0
end

-- Moves to the next candidate whose functions exist in this build; locks method 1 when none is left (v0.6 review F1:
-- an aim re-calibration (cal.lock) instead keeps the method it started from, see restoreLock).
function nextCandidate()
    resetMeasure()
    cal.recent, cal.recentFar, cal.aimRecent, cal.aimBad, cal.badTime, cal.aimUnverified = {}, {}, {}, 0, 0, false
    cal.aimFar = 0
    while true do
        cal.cand = cal.cand + 1
        local c = CAM_CANDIDATES[cal.cand]
        if not c then
            if cal.lock then restoreLock(true) return end
            cal.state, cal.method, cal.world = 3, 1, false
            return
        end
        if offsetApi(c[1]) then
            cal.method, cal.world = c[1], c[2]
            return
        end
    end
end

-- v0.6 review F1: ends an aim re-calibration with the method it started from locked again (state 2). aimOnly: no
-- other candidate passed (the aim error is reported only, never re-calibrated again this level); otherwise the player
-- moved (the re-calibration is tried again after the next second of standing still).
function restoreLock(aimOnly)
    local l = cal.lock
    cal.lock = nil
    cal.method, cal.world, cal.cand, cal.aimUnverified, cal.state = l[1], l[2], l[3], l[4], 2
    resetMeasure()
    cal.recent, cal.recentFar, cal.aimRecent, cal.aimBad, cal.aimFar, cal.aimStill = {}, {}, {}, 0, 0, 0
    if aimOnly then cal.aimOnly = true else cal.aimPend = true end
end

function startCalibration()
    cal.state, cal.cand, cal.badTime, cal.lock, cal.aimPend = 1, 0, 0, nil, false
    nextCandidate()
end

-- camera_method from the ini (0 auto, 1-3 forced); re-evaluated when it changes (F6 reload). v0.8 (docs/V08_PLAN.md
-- section 1): the ini default is offset (2): method 2 with the local composition, locked (state 4) with no calibration
-- and nothing that could fall back to the override on foot (in the v0.7 headset log auto calibration ended in method 1
-- after ~10 s, which disables the engine's tools). The probe errors and the camera spike diagnostics keep being measured
-- (measureCamera). auto (0) keeps the v0.7 calibration for experiments. v0.9 (docs/V09_PLAN.md section 1): 4 = attach,
-- forced (state 4) like the others, plus the att state machine: the first request starts the trial (att state 1); after
-- a failure of this script instance (att state 3/4/5) a request means method 2 (the next level / quickload runs a new
-- script instance and starts with attach again).
function updateCameraMode()
    -- v0.6 review F1: an aim re-calibration's candidate is never applied while the player moves (draw() would see it
    -- one frame later)
    if cal.state == 1 and cal.lock and (VecLength(GetPlayerVelocity()) >= 0.3 or playerGrounded() == false) then
        restoreLock(false)
    end
    local m = nat.camMethod or 0
    if m == cal.mode then return end
    cal.mode = m
    att.blame = nil
    if m == 4 then
        cal.state, cal.world, cal.lock, cal.aimPend = 4, false, nil, false
        cal.recent, cal.recentFar, cal.aimUnverified = {}, {}, false
        if att.state >= 3 and att.state <= 5 then
            cal.method = 2
        else
            if att.state == 0 then att.state = 1 end
            attachRestart()
        end
    elseif m >= 1 and m <= 3 then
        cal.state, cal.method, cal.world, cal.lock, cal.aimPend = 4, m, false, nil, false
        cal.recent, cal.recentFar, cal.aimUnverified = {}, {}, false
    else
        startCalibration()
    end
end

-- The analytic player camera: the true eye (playerEyePos) with the yaw/pitch rotation read back now. tick()
-- composes its offset with it (GetPlayerCameraTransform() is stale there); render() only when the player camera
-- cannot be used (renderCameraFrame). Also tool frame candidate 3.
function playerCameraFrame()
    return Transform(playerEyePos(), yawPitchRot(GetPlayerYaw(), GetPlayerPitch()))
end

-- How far frame b is from frame a: degrees of rotation + 100 per metre (1 cm ~ 1 degree at the near probes).
function frameErr(a, b)
    return quatAngle(a.rot, b.rot) + 100 * VecLength(VecSub(a.pos, b.pos))
end

-- GetPlayerCameraTransform() now, nil if it is missing, fails or returns no transform.
function readPlayerCamera()
    if not GetPlayerCameraTransform then return nil end
    local ok, pc = pcall(GetPlayerCameraTransform)
    if not ok or type(pc) ~= "table" or type(pc.pos) ~= "table" or type(pc.rot) ~= "table"
        or type(pc.pos[3]) ~= "number" or type(pc.rot[4]) ~= "number" then return nil end
    return pc
end

-- pc with one of our offsets o taken out: o was composed locally (pc = P * o) or in world space (world). The rotation
-- is normalised: P2 feeds back (its offset is taken out of the next pc), and the conjugate is the inverse only of a
-- unit quaternion, so rounding would otherwise grow by ~40 % per frame.
function stripOffset(pc, o, world)
    local t
    if world then t = Transform(VecSub(pc.pos, o.pos), QuatRotateQuat(qconj(o.rot), pc.rot))
    else t = TransformToParentTransform(pc, TransformToLocalTransform(o, Transform())) end
    local q = t.rot
    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if l > 1e-9 then t.rot = Quat(q[1] / l, q[2] / l, q[3] / l, q[4] / l) end
    return t
end

-- render(): the P its offset is composed with (v0.6 P decontamination, docs/V06_PLAN.md section 3, as revised by the
-- v0.6 review F6 / MISSED-1). As in v0.4/v0.5 it comes from GetPlayerCameraTransform() (pc), read before this render's
-- offset is sent: pc carries the engine's own camera motion (head bob, which the engine will not let us switch off,
-- shake, recoil, the landing dip, step and crouch smoothing), which then cancels, and the image is exactly C, the same
-- eye base the hands are placed from. So pc (P0) is used whenever it is plausible engine motion: within 45 degrees and
-- 1 m of the analytic frame (eye + read-back yaw/pitch), the v0.5 rule; after a frame that was not, only again within
-- 30 degrees and 0.6 m (hysteresis). Otherwise the analytic frame is used (pc is not the engine's camera base then).
-- The plan's premise "pc contains the offset this frame's tick sent while a tool is held" is unproven (the v0.5 scorer
-- already compared pc with exactly that and found 22-42 deg residuals, review MISSED-1), and tick no longer sends an
-- offset while render() runs (N_CAM_OPTS bit0 restores that, see submitCamera). The candidates that take one of our
-- offsets out of pc (P1 = pc minus the tick's offset, P2 = pc minus the previous render's) are therefore experimental:
-- one is used only when it explains pc clearly better than pc itself: within 3 degrees and 5 cm of the analytic frame,
-- P0's error (frameErr: degrees + 1 per cm) above 3 and its own below 0.3 of P0's, on 3 frames in a row (cal.pRun: a
-- head bob as large as a small offset can mimic it on single frames, review F3); once in use, it stays while P0's
-- error is above 1.5 and its own below 0.6 of P0's (hysteresis: the image cannot flip between them frame by frame).
-- Records in e: pSrc 1 pc (any candidate) / 2 analytic; pCand 0-2 the candidate used (nil: analytic); pcAn = the
-- rotation (deg) of pc that no candidate explains (P-source suspicion, context bit 9); pFlags = context bits 11
-- (analytic P), 12 (pc contained one of our offsets: P1 or P2 used, and pc itself > 2 deg/cm from the analytic frame)
-- and 13 (analytic P while pc is within 45 deg / 1 m and moves > 1 deg/cm on its own: the hysteresis band).
-- cal.pPick = the candidate used (0: the analytic frame).
-- v0.9 (docs/V09_PLAN.md section 2): that v0.8 choice is used only with psel 0. The v0.8 headset log showed the engine
-- composing our offset with a P that matches the analytic frame while pc still held the old aim (gct-C = pc-an in the
-- worst frames), so the default psel 1 takes the analytic rotation with pc's position (pc's head bob / landing dip
-- position still cancels; the analytic position when pc is >= 0.6 m away). The v0.8 choice keeps running in the shadow
-- (cal.pPick, cal.pRun) so a switch to psel 0 starts from its hysteresis state; e.pcRot / e.anRot = the two candidate
-- rotations for draw() to learn from (pselDraw).
function renderCameraFrame(analytic, e)
    local pc = readPlayerCamera()
    local last = cal.pPick
    cal.analyticP, cal.pPick = true, 0
    if e then e.pcRot, e.anRot = pc and pc.rot or nil, analytic.rot end
    if not pc then
        if e then e.pSrc, e.pCand, e.pcAn, e.pFlags = 2, nil, -1, 2048 end
        return analytic
    end
    local cands = { pc, false, false }
    if cal.tickO then cands[2] = stripOffset(pc, cal.tickO, cal.tickW) end
    if cal.renderO then cands[3] = stripOffset(pc, cal.renderO, cal.renderW) end
    local errs, tight, an = {}, {}, nil
    for i = 1, 3 do
        local c = cands[i]
        if c then
            local r = quatAngle(c.rot, analytic.rot)
            local d = VecLength(VecSub(c.pos, analytic.pos))
            errs[i], tight[i] = r + 100 * d, r < 3 and d < 0.05
            if not an or r < an then an = r end
        end
    end
    local k, run = nil, cal.pRun
    for i = 2, 3 do
        local q
        if last == i then q = tight[i] and errs[1] > 1.5 and errs[i] < 0.6 * errs[1]
        else q = tight[i] and errs[1] > 3 and errs[i] < 0.3 * errs[1] end
        run[i] = q and run[i] + 1 or 0
        if q and (last == i or run[i] >= 3) and (not k or last == i or (last ~= k and errs[i] < errs[k])) then k = i end
    end
    local plain, dist = quatAngle(pc.rot, analytic.rot), VecLength(VecSub(pc.pos, analytic.pos))
    if not k then
        local lim, limD = 45, 1
        if last == 0 then lim, limD = 30, 0.6 end
        if plain <= lim and dist <= limD then k = 1 end
    end
    local b = 0
    if cal.psel == 1 then
        -- (v0.9 psel 1: the analytic rotation; bit 13 = pc moves on its own, its rotation does not reach the image)
        if k then cal.pPick = k end
        b = 2048
        if errs[1] > 1 and plain <= 45 and dist <= 1 then b = b + 8192 end
        if e then e.pSrc, e.pCand, e.pcAn, e.pFlags = 2, nil, an, b end
        -- (v0.9 review lua-aim-1: the position from the candidate the shadow chose: when pc carries our previous offset
        -- (method 3 composes it into the player camera) P1/P2 take it out; raw pc would cancel part of the last offset
        -- every frame and the image would run a sawtooth of up to |O|)
        local src = (k and k > 1) and cands[k] or pc
        local d = VecLength(VecSub(src.pos, analytic.pos))
        return Transform(d < 0.6 and VecCopy(src.pos) or VecCopy(analytic.pos), analytic.rot)
    end
    if not k then b = b + 2048 end
    if k and k > 1 and frameErr(pc, analytic) > 2 then b = b + 4096 end
    if not k and errs[1] > 1 and plain <= 45 and dist <= 1 then b = b + 8192 end
    if e then e.pSrc, e.pCand, e.pcAn, e.pFlags = k and 1 or 2, k and (k - 1) or nil, an, b end
    if not k then return analytic end
    cal.analyticP, cal.pPick = false, k
    return cands[k]
end

-- v0.9 (docs/V09_PLAN.md section 2), draw() in offset mode: which P did the engine compose this frame's offset with?
-- e = this frame's record, c = GetCameraTransform(), strict = the record c matched exactly (nil: none). Only when the
-- offset of this frame was composed locally (e.O, method 2/3, not world) and render recorded both candidates (e.pcRot /
-- e.anRot), and not when c is an older record's camera (one-frame lag: c belongs to another offset). Peng = c * O^-1.
-- A frame is informative when pc and the analytic rotation differ by > 1 deg; then the EMAs (alpha 0.2, the first
-- sample as is) of Peng's angle to each are updated. After >= 10 informative frames psel switches to 0 (pc) only if
-- errPc < 0.7 * errAn, back to 1 (analytic) only if errAn < 0.7 * errPc (hysteresis: comparable errors keep it).
function pselDraw(e, c, strict)
    if not e or not e.O or e.world or not e.pcRot or not e.anRot or (cal.used ~= 2 and cal.used ~= 3) then return end
    if strict and strict ~= e then return end
    if quatAngle(e.pcRot, e.anRot) <= 1 then return end
    local peng = stripOffset(c, e.O, false)
    local ep, ea = quatAngle(peng.rot, e.pcRot), quatAngle(peng.rot, e.anRot)
    cal.pInf = cal.pInf + 1
    cal.errPc = (cal.errPc < 0) and ep or (cal.errPc + (ep - cal.errPc) * 0.2)
    cal.errAn = (cal.errAn < 0) and ea or (cal.errAn + (ea - cal.errAn) * 0.2)
    if cal.pInf < 10 then return end
    if cal.psel == 1 and cal.errPc < 0.7 * cal.errAn then cal.psel = 0
    elseif cal.psel == 0 and cal.errAn < 0.7 * cal.errPc then cal.psel = 1 end
end

-- Applies the camera C. On foot with an offset method this must run after the player's yaw/pitch for this
-- frame are final (P is read back from the engine). Vehicles always use the override. P and O are kept in
-- this frame's hist record (calibration checks that the frame can tell the hypotheses apart); the tick's O
-- too, to see how far render() moved it (camera spike diagnostics). The world translation of the offset the
-- engine will compose (render's, or the tick's when render() is not running) is kept for updateEyeSource, the
-- tick's for eyeSourceRender. v0.6 review F2: with render() running the tick computes its offset but does not send it
-- (unless N_CAM_OPTS bit0): no tick offset, no tick P/O in the record (render fills them), cal.tickO nil (no P1).
-- The override (method 1) is still sent from both.
-- v0.9 (docs/V09_PLAN.md section 1.1): method 4 (attach, on foot) is sent from tick AND render (render's replaces the
-- tick's; not quiet like method 2, so a frame always has the attach); it is recorded like method 2 (e.P = W, e.O = O,
-- local) for the probes and the camera spike diagnostics. If the attach API is missing or fails, this script instance
-- switches to method 2 (att state 5) and this frame already uses it.
function submitCamera(cam, flags, fromRender)
    local method, world = cal.method, cal.world
    cal.inVehicle = hasBit(flags, LF_VEHICLE)
    if cal.inVehicle or not offsetApi(method) then method, world = 1, false end
    local e = hist[#hist]
    local final = fromRender or not drawInRender
    if method == 4 then
        local o, w = attachSubmit(cam)
        if o then
            -- (nothing of ours is composed with the player camera: no offset in the eye, no P1/P2 candidates)
            if final then eyeSrc.off = nil end
            if not fromRender then eyeSrc.tickOff = nil end
            cal.sentO, cal.tickO, cal.renderO = o, nil, nil
            if e then
                -- (v0.9 review ATT-4 / SPEC-5: e.att marks the record: O = W^-1 * C is the camera itself, not an offset
                -- to P, so camdbg reports no |O| (L_CAMDBG_OMAG -1) and no "render moved the offset" (context bit 256)
                -- for it; the tick-to-render change of O is the head's motion; no tickO either, a render fallback to
                -- method 2 would compare its offset with the camera)
                e.P, e.O, e.world, e.pSrc, e.pCand, e.pcAn, e.pFlags, e.att = w, o, false, nil, nil, -1, 0, true
                if not fromRender then e.tickO = nil end
                e.oDiff = 0
            end
            cal.used, cal.usedWorld = 4, false
            return
        end
        attachFail(5)
        -- (v0.9 review SPEC-2: without the offset API this frame already takes method 1, as later frames do (line
        -- "not offsetApi(method)" above); method 2 would call a nil SetCameraFov / SetCameraOffsetTransform)
        method, world = offsetApi(2) and 2 or 1, false
    end
    if method == 1 then
        SetCameraTransform(cam, nat.hfov)
        if final then eyeSrc.off = nil end
        if not fromRender then eyeSrc.tickOff = nil end
        cal.sentO = nil
        if fromRender then cal.renderO = nil else cal.tickO = nil end
        if e then e.P, e.O, e.pSrc, e.pCand, e.pFlags, e.att = nil, nil, nil, nil, 0, nil end
    else
        local P = playerCameraFrame()
        if fromRender then P = renderCameraFrame(P, e) end
        local o
        if world then
            o = Transform(VecSub(cam.pos, P.pos), QuatRotateQuat(cam.rot, qconj(P.rot)))
        else
            o = TransformToLocalTransform(P, cam)
        end
        -- v0.6 review F2: while render() runs, tick sends no offset (only render's exists in the frame: nothing of
        -- ours can reach the player camera, the eye or the engine's aim before render); N_CAM_OPTS bit0 = the old way
        local quiet = not final and not hasBit(nat.camOpts, 1)
        local wo = world and VecCopy(o.pos) or QuatRotateVec(P.rot, o.pos)
        if quiet then
            eyeSrc.tickOff, cal.tickO = nil, nil
        else
            SetCameraFov(nat.hfov)
            if method == 2 then SetCameraOffsetTransform(o, false) else SetPlayerCameraOffsetTransform(o, false) end
            if final then eyeSrc.off = wo end
            if not fromRender then eyeSrc.tickOff = wo end
            cal.sentO = o
            if fromRender then cal.renderO, cal.renderW = o, world else cal.tickO, cal.tickW = o, world end
        end
        if e then
            e.att = nil   -- (v0.9 review ATT-4: a render fallback after a tick attach is an offset frame again)
            if quiet then e.P, e.O = nil, nil else e.P, e.O, e.world = P, o, world end
            if not fromRender then
                -- (pc is stale in tick: no P-source diagnostics from here; tickO also when not sent: render's change)
                e.tickO, e.oDiff, e.pSrc, e.pCand, e.pcAn, e.pFlags = o, 0, 2, nil, -1, 2048
            else
                e.oDiff = e.tickO and quatAngle(e.tickO.rot, o.rot) or 0
            end
        end
    end
    cal.used, cal.usedWorld = method, world
end

-- Worst angular error (degrees) of the probe points of camera record e as the engine projects them now
-- (UiWorldToPixel) vs where they must appear for e's camera and hfov; the UI covers the full image.
-- With `view` (a camera transform) the points are projected by pure maths as that camera would show them
-- (same hfov and aspect) instead. Second result: the worst of the far probes alone (rotation errors).
function probeError(e, view)
    local w, h = UiWidth(), UiHeight()
    if (not view and not UiWorldToPixel) or w <= 0 or h <= 0 or not e.hfov or e.hfov <= 0 then return -1, -1 end
    local tanH = math.tan(math.rad(e.hfov) * 0.5)
    local tanV = tanH * h / w
    local c = Transform(e.pos, e.rot)
    local worst, far = 0, 0
    for i = 1, #PROBES do
        local p = PROBES[i]
        local wp = TransformToParentPoint(c, Vec(p[1], p[2], p[3]))
        local x, y, dist
        if view then
            local l = TransformToLocalPoint(view, wp)
            dist = -l[3]
            if dist > 1e-6 then x, y = w * 0.5 * (1 + (l[1] / dist) / tanH), h * 0.5 * (1 - (l[2] / dist) / tanV) end
        else
            x, y, dist = UiWorldToPixel(wp)
        end
        local deg = 180
        if x and y and dist and dist > 0 then
            local ex = w * 0.5 * (1 + (p[1] / -p[3]) / tanH)
            local ey = h * 0.5 * (1 - (p[2] / -p[3]) / tanV)
            local px = math.sqrt((x - ex) * (x - ex) + (y - ey) * (y - ey))
            deg = math.deg(math.atan(px * tanH / (w * 0.5)))
        end
        if deg > worst then worst = deg end
        if p[3] < -1 and deg > far then far = deg end
    end
    return worst, far
end

-- Can calibration frame e tell the hypotheses apart? The camera the engine would show if it ignored the
-- offset (P) and the one it would show with the other composition of the O we sent must both be more than
-- 2 degrees (probe metric) away from C. Otherwise (e.g. player yaw/pitch ~0, or O ~ identity in mono with
-- head aim) a wrong candidate would pass: the frame is skipped, not failed.
function informativeFrame(e)
    if not e.P or not e.O then return false end
    local P, O = e.P, e.O
    local other
    if e.world then other = TransformToParentTransform(P, O)
    else other = Transform(VecAdd(P.pos, O.pos), QuatRotateQuat(O.rot, P.rot)) end
    return probeError(e, P) > 2 and probeError(e, other) > 2
end

-- Standing still on the ground (calibration and the locked-method monitor count only such frames: walking
-- adds head bob, which the near probes see). IsPlayerGrounded is used if present; if it keeps saying
-- "airborne" for 5 s while the player does not move at all, it is not usable here and is ignored. v0.6 review F7:
-- only out of water (treading water is legitimately "airborne"; the API has no ladder query, a ladder is covered by
-- the next rule), and the verdict is taken back as soon as IsPlayerGrounded says "grounded" again.
function playerStill(dt)
    if VecLength(GetPlayerVelocity()) >= 0.3 then return false end
    if IsPlayerGrounded then
        local ok, grounded = pcall(IsPlayerGrounded)
        if ok and grounded == true then cal.groundBroken = false end
        if ok and grounded == false and not cal.groundBroken then
            if not playerInWater() then cal.airTime = cal.airTime + dt end
            if cal.airTime >= 5 then cal.groundBroken = true end
            return false
        end
    end
    cal.airTime = 0
    return true
end

-- v0.6 review F7: the player's feet (1.2 m below the eye) are in water (IsPointInWater, guarded; false without it).
function playerInWater()
    if not IsPointInWater then return false end
    local ok, wet = pcall(IsPointInWater, VecSub(playerEyePos(), Vec(0, 1.2, 0)))
    return ok and wet == true
end

-- v0.6: IsPlayerGrounded() guarded: true / false, nil when it cannot tell (missing, failing, no boolean, or found
-- unusable by playerStill: "airborne" for 5 s while standing still, until it says "grounded" again, review F7).
function playerGrounded()
    if not IsPlayerGrounded then return nil end
    local ok, grounded = pcall(IsPlayerGrounded)
    if not ok or type(grounded) ~= "boolean" then return nil end
    if grounded then
        cal.groundBroken, cal.airTime = false, 0
        return true
    end
    if cal.groundBroken then return nil end
    return false
end

-- Angle (degrees) between the engine's aim ray (GetPlayerAimInfo from the eye) and the look direction we
-- set (yaw/pitch read back). An offset method that also moves the aim ray makes hand aim impossible.
-- -1 if the function is missing or returns nothing usable. Only far samples count (v0.5): for a hit within
-- 4 m the engine may move the start position (walls, the held tool), so its direction says nothing about our
-- look direction (the v0.4 headset log showed 37-51 degree "errors" while using tools up close); such a
-- sample returns -1 with the second result true. No hit at all (nothing within 50 m) is a far sample.
function measureAimError()
    if not GetPlayerAimInfo then return -1, false end
    local eye = playerEyePos()
    local ok, hit, _, endPos, dir, _, hitDist = pcall(GetPlayerAimInfo, eye, 50)
    if not ok or type(dir) ~= "table" or type(dir[3]) ~= "number" then return -1, false end
    local dist = 50
    if hit then
        if type(hitDist) == "number" then dist = hitDist
        elseif type(endPos) == "table" and type(endPos[3]) == "number" then dist = VecLength(VecSub(endPos, eye)) end
    end
    if dist <= 4 then return -1, true end
    local len = VecLength(dir)
    if len < 0.5 then return -1, false end
    local look = QuatRotateVec(yawPitchRot(GetPlayerYaw(), GetPlayerPitch()), Vec(0, 0, -1))
    return math.deg(math.acos(clamp(VecDot(VecScale(dir, 1 / len), look), -1, 1))), false
end

local function push(list, v, max)
    list[#list + 1] = v
    if #list > max then table.remove(list, 1) end
end

-- One frame of a candidate's measurement (state 1). Counted: settled, standing still, and (camera error)
-- informative frames. Pass = median camera error < 0.6 deg over >= 20 frames AND the aim check: with hand
-- aim, the median aim error of >= 10 informative samples (camera axis > 8 deg away from the look direction,
-- otherwise an aim ray moved by the offset is indistinguishable; near hits are no samples at all, see
-- measureAimError) < 3 deg. Without any informative aim sample for 5 s the candidate passes unverified
-- (recorded; the locked monitor keeps reporting the aim error). Decided only from the collected samples: a frame
-- without aim info (failed call, no direction) is no pass on its own (v0.5 review; the locked monitor demotes only
-- for > 10 deg, so a wrong pass here could stay for the level).
function measureCandidate(e, err, still, aimInfo, dt)
    if cal.used ~= cal.method or cal.usedWorld ~= cal.world then return end
    cal.frames = cal.frames + 1
    if cal.frames <= 5 or not still then return end            -- settle; walking frames are skipped
    cal.aimWait = cal.aimWait + dt
    if aimInfo then cal.aimErrs[#cal.aimErrs + 1] = cal.aimErr end
    if informativeFrame(e) then push(cal.errs, err, 40) end
    if #cal.errs < 20 then return end
    if median(cal.errs) >= 0.6 then nextCandidate() return end
    local aimOk = nil
    if nat.aimMode ~= 1 or not GetPlayerAimInfo then
        aimOk = true                                           -- head aim, or no aim function: counts as passed
    elseif #cal.aimErrs >= 10 then
        aimOk = median(cal.aimErrs) < 3
    elseif cal.aimWait >= 5 then
        if #cal.aimErrs >= 3 then aimOk = median(cal.aimErrs) < 3 else aimOk, cal.aimUnverified = true, true end
    end
    if aimOk == nil then return end                            -- keep measuring until the aim test can tell
    if aimOk then
        cal.state, cal.recent, cal.recentFar, cal.aimRecent, cal.lock = 2, {}, {}, {}, nil
    else
        nextCandidate()
    end
end

-- Locked offset method (state 2). The camera goes bad: far-probe (rotation) median > 2 deg for 3 s of
-- standing still -> the one re-calibration per level; frames in which the player camera moves > 2 deg on its own
-- (pcAn: shake near a tornado, an explosion) do not count towards it. A bad aim ray (informative median > 3 deg,
-- hand aim) is only reported (L_AIM_ERR, cal.aimBad = for how long): in the v0.4 headset test the aim "errors"
-- came from near hits while using tools, not from the method. A gross one (median of the far samples > 10 deg for
-- 5 s, a method that turns the aim ray) asks for a re-calibration (v0.5 review). v0.6 review F1: in the v0.5 headset
-- log that path ran while the user sprayed (aim error 59.8 deg), walked the wrong compositions while the player moved
-- and ended in the override (no tools for minutes). So: aim samples count only while no tool body exists and on clean
-- ticks (aimSampleClean); the re-calibration starts after 1 s of standing still, keeps the locked method (cal.lock)
-- and gives way to it again when the player moves (measureCamera) or when no other candidate passes (then the aim
-- error is a diagnostic only: cal.aimOnly, +4000 in L_CAM_METHOD); it never ends in the override.
function monitorLocked(far, still, aimInfo, dt, e)
    if still and (e.pcAn or -1) <= 2 then
        push(cal.recentFar, far, 30)
        if #cal.recentFar >= 10 and median(cal.recentFar) > 2 then cal.badTime = cal.badTime + dt else cal.badTime = 0 end
    end
    if aimInfo and aimSampleClean() and GetToolBody() == 0 then push(cal.aimRecent, cal.aimErr, 30) end
    local aimMed = (nat.aimMode == 1 and #cal.aimRecent >= 10) and median(cal.aimRecent) or 0
    if aimMed > 3 then cal.aimBad = cal.aimBad + dt else cal.aimBad = 0 end
    if aimMed > 10 and not cal.aimOnly then cal.aimFar = cal.aimFar + dt else cal.aimFar = 0 end
    if cal.aimFar >= 5 then cal.aimPend = true elseif #cal.aimRecent >= 10 and aimMed <= 10 then cal.aimPend = false end
    if cal.badTime >= 3 and cal.reruns < 1 then
        cal.reruns = cal.reruns + 1
        startCalibration()
    elseif cal.aimPend then
        if still then cal.aimStill = cal.aimStill + dt else cal.aimStill = 0 end
        if cal.aimStill >= 1 then
            cal.aimPend, cal.aimStill = false, 0
            cal.lock = { cal.method, cal.world, cal.cand, cal.aimUnverified }
            cal.state = 1
            nextCandidate()
        end
    end
end

-- v0.6 review F1: the engine's aim ray says something about the camera method only when nothing else moves it: not
-- while the tool is used (toolInUse; the v0.5 log: 59.8 deg while spraying) or something is picked, and not on a yaw
-- teleport tick (the look read back and the ray may then be a tick apart).
function aimSampleClean()
    return not aimState.teleTick and not aimState.toolUse and not GetBool("game.player.picking")
end

-- The tool is used now: usetool held, or the aiming hand's trigger at the press threshold (0.55, native input).
function toolInUse()
    if InputDown and InputDown("usetool") then return true end
    if not ctl then return false end
    return ((nat.leftHanded == 1) and ctl.ltrig or ctl.rtrig) >= 0.55
end

-- draw(), every frame while active on foot. `strict` is an older record the engine camera matched exactly
-- (one-frame camera delay): its error counts too, since calibration judges composition, not latency.
-- Returns this frame's probe error (-1: not measurable).
-- v0.22 (docs/V022_PLAN.md section 4.1): gate = attachGate's reason for this frame; a gated frame (a scope zoom, a frustum
-- or camera that is not ours) still returns its error (camdbg) but is no sample: nothing pushed into cal.recent, no
-- measureCandidate / monitorLocked.
function measureCamera(strict, gate)
    local e = hist[#hist]
    local err, far = probeError(e)
    if strict and strict ~= e then
        local e2, f2 = probeError(strict)
        if e2 >= 0 and e2 < err then err, far = e2, f2 end
    end
    local dt = perf.lastDt
    local still = playerStill(dt)
    cal.aimErr, cal.aimNear = measureAimError()
    local look = QuatRotateVec(yawPitchRot(GetPlayerYaw(), GetPlayerPitch()), Vec(0, 0, -1))
    local aimInfo = nat.aimMode == 1 and cal.aimErr >= 0
        and VecDot(QuatRotateVec(e.rot, Vec(0, 0, -1)), look) < math.cos(math.rad(8))
    if cal.state == 3 then
        -- fallback locked: one more calibration once the player has stood still for 10 s
        if still and not cal.retried3 then cal.stillTime = cal.stillTime + dt else cal.stillTime = 0 end
        if cal.stillTime >= 10 then
            cal.retried3, cal.stillTime = true, 0
            startCalibration()
        end
    end
    -- v0.6 review F1: an aim re-calibration shows its candidates only while the player stands still
    if cal.state == 1 and cal.lock and not still then restoreLock(false) end
    if err < 0 then return err end
    if gate and gate ~= 0 then return err end
    push(cal.recent, err, 30)
    if cal.state == 1 then
        measureCandidate(e, err, still, aimInfo, dt)
    elseif cal.state == 2 then
        monitorLocked(far, still, aimInfo, dt, e)
    end
    return err
end

-- Camera spike diagnostics (L_CAMDBG_*, slots 160-167, 193-195, L_CAM_PSRC 185, v0.6 L_CAM_PDEC 187): why does the image
-- jump while the player uses a tool? The window is the native [lua2] period, 5 s (v0.5 review: 100 frames covered
-- only 1-2 s of it at 45-90 fps): buckets of 0.5 s of os.clock() (without os.clock: of 30 frames), the current one
-- and the last 10 kept. Each holds the worst measured frame's record, the measured and bad (> 5 deg) frame counts and
-- the P-source counts (v0.6: and which P candidate render used, see renderCameraFrame); the window's worst record and
-- sums are published every frame. Context bits (L_CAMDBG_CTX): 0 picking,
-- 1 usetool down, 2 grabbing, 3 yaw teleport this tick, 4 pitch changed > 1 deg since the last frame, 5 right eye,
-- 6 held base, 7 walking (> 0.3 m/s), 8 render's offset rotation differs from the tick's by > 2 deg,
-- 9 GetPlayerCameraTransform differs > 2 deg from the analytic rotation in a way our offsets do not explain,
-- 10 eye source decontaminated, 11 the offset was built on the analytic P (not the player camera), 12 the player
-- camera contains our own offset (feedback), 13 analytic P while the player camera moves on its own (head bob or
-- shake reach the image), v0.22 14 the frame was gated (attachGate: zoom, frustum or a foreign camera).
local camdbg = { buckets = {}, cur = nil, pitch = nil, look = nil }

function camDbgContext(e, pitchStep)
    local b = 0
    if GetBool("game.player.picking") then b = b + 1 end
    if InputDown and InputDown("usetool") then b = b + 2 end
    if GetPlayerGrabBody() ~= 0 then b = b + 4 end
    if aimState.teleTick then b = b + 8 end
    if pitchStep > 1 then b = b + 16 end
    if e.eye == 1 then b = b + 32 end
    if e.held then b = b + 64 end
    if VecLength(GetPlayerVelocity()) > 0.3 then b = b + 128 end
    if (e.oDiff or 0) > 2 then b = b + 256 end
    if (e.pcAn or -1) > 2 then b = b + 512 end
    if eyeSrc.use == 1 then b = b + 1024 end
    if (att.gate or 0) ~= 0 then b = b + 16384 end   -- (v0.22 section 4.1: this frame was gated)
    return b + (e.pFlags or 0)
end

-- The current bucket of the camera spike window (a new one every 0.5 s, or every 30 frames without os.clock).
function camDbgBucket()
    local d = camdbg
    local now = (os and os.clock) and os.clock() or nil
    local c = d.cur
    if not c or (now and c.t and now - c.t >= 0.5) or ((not now or not c.t) and c.frames >= 30) then
        c = { t = now, frames = 0, worst = nil, n = 0, bad = 0, pc = 0, an = 0, pd = { 0, 0, 0 }, tn = 0, tb = 0 }
        d.cur = c
        d.buckets[#d.buckets + 1] = c
        if #d.buckets > 11 then table.remove(d.buckets, 1) end
    end
    c.frames = c.frames + 1
    return c
end

-- draw(), every frame: e = this frame's camera record and err its probe error (nil / < 0: not measured), c the
-- camera the engine reports. Record = { error, context, look change (deg), P-source angle, GetCameraTransform vs
-- C (deg), (cm), v0.6 review F2: rotation of the offset O sent (deg, -1 none) }. v0.6 review F2: the measured and bad
-- frames are also counted apart for ticks with a yaw teleport (tn / tb; L_CAMDBG_TELE, the rest L_CAMDBG_NOTELE): in
-- the v0.5 log the bad frames tracked the teleports, and a teleport tick's image may be off by |O| (L_CAMDBG_OMAG).
function camDbgFrame(e, err, c)
    local d = camdbg
    local cur = camDbgBucket()
    local pitch, look = nil, nil
    if e then
        pitch = GetPlayerPitch()
        look = QuatRotateVec(yawPitchRot(GetPlayerYaw(), pitch), Vec(0, 0, -1))
        if e.pSrc == 1 then cur.pc = cur.pc + 1 elseif e.pSrc == 2 then cur.an = cur.an + 1 end
        if e.pCand then cur.pd[e.pCand + 1] = cur.pd[e.pCand + 1] + 1 end
        if err and err >= 0 and c then
            local step = d.pitch and math.abs(pitch - d.pitch) or 0
            local turn = d.look and math.deg(math.acos(clamp(VecDot(look, d.look), -1, 1))) or 0
            local tele = aimState.teleTick
            cur.n = cur.n + 1
            if tele then cur.tn = cur.tn + 1 end
            if err > 5 then
                cur.bad = cur.bad + 1
                if tele then cur.tb = cur.tb + 1 end
            end
            if not cur.worst or err > cur.worst[1] then
                cur.worst = { err, camDbgContext(e, step), turn, e.pcAn or -1, quatAngle(c.rot, e.rot),
                              VecLength(VecSub(c.pos, e.pos)) * 100,
                              (e.O and not e.att) and quatAngle(e.O.rot, Quat()) or -1 }   -- (v0.9 review ATT-4)
            end
        end
    end
    d.pitch, d.look = pitch, look
    local worst, n, bad, npc, nan, pd, tn, tb = nil, 0, 0, 0, 0, { 0, 0, 0 }, 0, 0
    for i = 1, #d.buckets do
        local k = d.buckets[i]
        n, bad, npc, nan, tn, tb = n + k.n, bad + k.bad, npc + k.pc, nan + k.an, tn + k.tn, tb + k.tb
        for j = 1, 3 do pd[j] = pd[j] + k.pd[j] end
        if k.worst and (not worst or k.worst[1] > worst[1]) then worst = k.worst end
    end
    W(L2.CAM_PSRC, npc * 1000 + nan)
    W(L2.CAM_PDEC, math.min(pd[1], 999) * 1000000 + math.min(pd[2], 999) * 1000 + math.min(pd[3], 999))
    W(L2.CAMDBG_WORST, worst and worst[1] or -1)
    W(L2.CAMDBG_CTX, worst and worst[2] or 0)
    W(L2.CAMDBG_AIMDELTA, worst and worst[3] or -1)
    W(L2.CAMDBG_PC_AN, worst and worst[4] or -1)
    W(L2.CAMDBG_GCT_C, worst and worst[5] or -1)
    W(L2.CAMDBG_GCT_POS, worst and worst[6] or -1)
    W(L2.CAMDBG_BAD, bad)
    W(L2.CAMDBG_N, n)
    W(L2.CAMDBG_TELE, math.min(tb, 999) * 1000 + math.min(tn, 999))
    W(L2.CAMDBG_NOTELE, math.min(bad - tb, 999) * 1000 + math.min(n - tn, 999))
    W(L2.CAMDBG_OMAG, worst and worst[7] or -1)
end

-- ---------------------------------------------------------------------------------------------
-- aim
-- ---------------------------------------------------------------------------------------------
-- Rewriting the player's yaw is a teleport. v0.8 (docs/V08_PLAN.md section 2): only in "precise" moments (the 0.3
-- degree dead band of v0.3): main-hand trigger or grip pressed, the tool used, X (interact) held, something carried by
-- the engine grab, a physical hand grab being armed (phys arm), and 0.5 s after any of these; always with aim_update =
-- precise or the A/B-test bit ("forced", counted apart in L_TELE_REASON). Lazy aim (none of these) never turns the
-- player any more: the v0.7 headset log had ~3 yaw teleports per second from it (move_dir = head followed the head
-- with a 3 degree band), each one a camera spike that zeroes the velocity and likely the jump and crouch state; the
-- walk direction now comes from native (input.cpp rotates the left stick by the head). v0.6 review F4: pressed = the
-- native press threshold (0.55), not merely touched (0.15). Second result: a precise situation (not forced only).
-- v0.16 (docs/V016_PLAN.md section 1; the v0.15 log: the engine tool put at the hand by SetToolOffset keeps its
-- first-person orientation, which follows the player's aim - and that aim followed the hand only in precise moments, so
-- the tool in the hand pointed along the body): while the offset placement runs (probe.act.run) it is a precise moment
-- all the time, so the player's yaw / pitch - and with them the engine tool - follow the hand (setPlayerAim: the v0.9
-- attach band 0.5 deg / 0.06 s; teleportBlocked() unchanged).
-- v0.18 (docs/V018_PLAN.md section 1; the v0.17 log: rotctl kept, yet ~11 aim teleports per second the whole time a tool
-- was held - each a 1-3 deg step the engine may apply a frame earlier or later than predicted, the wobble, and fps 61-78
-- instead of ~110): the placement forces precise aim only while the tool can point nowhere but along the player's aim -
-- its rotation control rejected (4) or not available (none yet / no tool name / a kept v0.13..v0.16 path, rcFree18).
-- With the control kept (3) [or in its self-check (1 / 2) - no longer, see the review note below] R turns the tool to
-- the hand (RMAX 175 deg) and the aim follows the hand only in the classic precise situations above (+ 0.5 s, the v0.8
-- rule). (A forced stretch still sets the
-- timer like any precise moment: a tool's first ticks - state 0, its self-check not started - aim for 0.5 s more.)
-- v0.18 review LUA18-SELFCHECK-LAZY-AIM-FALSE-KEEP (deviation from V018 section 1, which names the self-check too): only
-- the KEPT control (3) frees the aim. During the self-check's windows (1 / 2) the aim is forced as in v0.17: with lazy
-- aim each window's rotErr also held how far the hand happened to point from the (static) player yaw, so an engine
-- ignoring R was kept when the hand drifted in the off window only (and a partly working control could be rejected),
-- and for the whole 10 s off window (R identity) the tool pointed along the player's old yaw.
function rcFree18()
    local a = probe.act
    if PRB.V013 or PRB.V014 or PRB.V015 or PRB.V016 or not SetToolTransform or a.key == "" then return false end
    local st = a.rc and a.rc.st or 0
    return st == 3
end

-- v0.18 review LUA18-STALE-AIM-BLOCKED-USE: with the control kept (rcFree18) the main trigger merely touched (>= TOUCH,
-- P18) is a precise situation too, so the player's yaw catches up with the hand before the 0.55 press fires along it.
-- v0.19 (docs/V019_PLAN.md section 1): the placement forces precise aim only while the engine tool is at the hand: a
-- tool in use (m19 2, from the 0.15 touch: its effects start along the player's aim) or a tool without a replica (m19
-- 0, the v0.18 rule - the self-check is out of the flow, so "not available": forced). Parked (m19 1, the replica seen)
-- nothing is forced: the classic precise situations only, no aim teleports while a tool is merely held.
local function preciseAim(dt)
    local lh = nat.leftHanded == 1
    local trig = lh and ctl.ltrig or ctl.rtrig
    local sq = lh and ctl.lsq or ctl.rsq
    local arming = (phys.l.arm or 0) > 0 or (phys.r.arm or 0) > 0
    local run = probe.act.run
    local free = run and rcFree18()
    local m = probe.act.m19
    local forced = run and ((m == 0 and not free) or m == 2)
    -- v0.19 review LUA19-PARK-TOOL-STALE-YAW: parked (m19 1: a PARK tool - sledge, plank - or a USE tool not yet at the
    -- hand) the main trigger touched (>= P19.USE) is a precise situation too - a pre-click catch-up, not idle forcing:
    -- idle aim forces nothing, so the player's yaw stays wherever the last precise moment left it, and the swing / plank
    -- / shot at 0.55 (or one while teleports are blocked) went along that stale yaw instead of where the laser and the
    -- replica point. Merely holding the tool still teleports nothing (V019 section 1).
    local touch = run and m == 1 and trig >= PRB.P19.USE
    if trig >= 0.55 or sq >= 0.55 or aimState.toolUse or hasBit(ctl.buttons, 4) or GetPlayerGrabBody() ~= 0
        or arming or forced or touch or (free and trig >= PRB.P18.TOUCH) then
        aimState.preciseTimer = 0.5
    else
        aimState.preciseTimer = math.max(0, aimState.preciseTimer - dt)
    end
    local situation = aimState.preciseTimer > 0
    return nat.aimUpdate == 0 or hasBit(nat.perf, PF.PRECISE) or situation, situation
end

-- v0.8 (docs/V08_PLAN.md section 2): no yaw teleport while A or B is held (N_BUTTONS bit0/1, whatever they are bound
-- to), within 0.7 s after an A press (jump.guard, A bound to jump), while airborne (IsPlayerGrounded false; in water
-- only when not treading water, playerInWater) or while the game's crouch input is down (L_GAME_INPUT bit6): a
-- teleport zeroes the velocity and most likely resets the jump and crouch state (v0.7 headset log: jump and crouch did
-- not work). v0.6 let a tool-use teleport through after 0.25 s of the guard and allowed teleports after 2 s in the
-- air; both are gone.
-- v0.16 review LUA16-TELEPORT-JUMP-INPUT: also while the game's own jump input is down (L_GAME_INPUT bit4, gi 16): jump
-- bound to another button (bind_x, a stick click) had no guard, and v0.16 teleports on almost every tick a tool is held
-- (preciseAim), the jump tick included (the v0.7 log's pattern: jumps that did not happen). updateJump arms the guard
-- on that input's press as well.
function teleportBlocked()
    local b = nat.valid and (nat.raw[N_BUTTONS] or 0) or 0
    if hasBit(b, 1) or hasBit(b, 2) or jump.guard > 0 or hasBit(jump.gi, 16) or hasBit(jump.gi, 64) then
        return true
    end
    return jump.air > 0 and not playerInWater()
end

-- v0.7 (docs/V07_PLAN.md section 2): the yaw teleport. The v0.6 headset log had a bad camera frame on practically every
-- yaw teleport tick and on the frame after it: the plan's hypothesis is that SetPlayerTransform(pos, yaw-only rotation)
-- makes the engine reset the pitch (the transform carries none) when it applies the teleport, whatever SetPlayerPitch
-- follows. So the teleport is one SetPlayerTransformWithPitch ("including pitch", script_defs.lua) with the look's own
-- rotation: QuatEuler(pitch, yaw, 0) = yaw about Y, then pitch about the local X (the game's camera convention, e.g.
-- data/script/creativemode.lua QuatEuler(cameraX, cameraY, 0); positive pitch looks up, as GetPlayerPitch and
-- yawPitchOf). The next tick checks that the engine kept both (aimCheck); after 5 failed checks in a row (a wrong
-- convention, or the pitch is ignored) the v0.6 trio is used (aimState.trio, +8000 in L_CAM_METHOD), for good without
-- SetPlayerTransformWithPitch, else (v0.7 review F2) for AIM_CHECK.RETRY seconds, then WithPitch is tried again with a
-- fresh run of checks. The caller restores the velocity either way (the teleport zeroes it).
local AIM_CHECK = { RETRY = 30, TOL = 2 }   -- (v0.8: TOL; one table, the main chunk is near the 200-local limit)
function aimTeleport(pos, yaw, pitch)
    if not SetPlayerTransformWithPitch then aimState.trio, aimState.trioLeft = true, nil end
    if aimState.trio then
        SetPlayerTransform(Transform(pos, QuatAxisAngle(Vec(0, 1, 0), yaw)))
        SetPlayerPitch(pitch)
        return
    end
    SetPlayerTransformWithPitch(Transform(pos, QuatEuler and QuatEuler(pitch, yaw, 0) or yawPitchRot(yaw, pitch)))
    aimState.check = { yaw, pitch, heartbeat, playerGrounded() ~= false }
end

-- tick(), before anything sets the aim: did the engine keep the yaw and pitch of the last tick's teleport (within
-- AIM_CHECK.TOL degrees, v0.8: 2, v0.7 had 1 and the v0.7 headset log fell back to the trio after 5 failed checks in a
-- row; a steeper pitch may end at the engine's own limit, at least 70 degrees on the same side)? The errors of the last
-- check and the counts are published (L_AIMCHK_*, see writeStatus). Only right after
-- that tick and in VR gameplay outside vehicles (pause, a vehicle or a missed tick can move the look on their own).
-- v0.7 review F2: only while the player was grounded at the teleport and is now (IsPlayerGrounded; a ladder, water or
-- a jump can turn the look on their own; unknown counts as grounded), and the trio after a fallback runs out after
-- AIM_CHECK.RETRY s (dt, every tick).
function aimCheck(live, dt)
    if aimState.trioLeft then
        aimState.trioLeft = aimState.trioLeft - (dt or 0)
        if aimState.trioLeft <= 0 then
            aimState.trio, aimState.trioLeft, aimState.fails, aimState.retries = false, nil, 0, aimState.retries + 1
        end
    end
    local c = aimState.check
    aimState.check = nil
    if not c or not live or c[3] ~= heartbeat - 1 or aimState.trio then return end
    if not c[4] or playerGrounded() == false then return end
    local p, want = GetPlayerPitch(), c[2]
    local tol = AIM_CHECK.TOL
    local pitchOk = math.abs(p - want) < tol or (p * want > 0 and math.abs(p) >= 70 and math.abs(p) < math.abs(want))
    aimState.checks = aimState.checks + 1
    aimState.yawErr, aimState.pitchErr = math.abs(angleDiff(GetPlayerYaw(), c[1])), math.abs(p - want)
    if pitchOk and aimState.yawErr < tol then
        aimState.fails, aimState.passed = 0, aimState.passed + 1
    else
        aimState.fails = aimState.fails + 1
        if aimState.fails >= 5 then aimState.trio, aimState.trioLeft = true, AIM_CHECK.RETRY end
    end
end

-- Pitch is always set (cheap, no teleport). The yaw teleport (aimTeleport) is followed by SetPlayerVelocity: the v0.3
-- trio's proven way to keep the player's momentum. v0.8: only with precise aim (preciseAim; never in lazy aim) and
-- never while teleportBlocked() (A or B held, the jump guard, airborne, crouching). v0.6 review F2/F4: in the v0.5 log
-- the camera errors tracked the yaw teleport ticks (the 0.3 deg band teleported on almost every tick of tool use).
-- While the tool is used the band is 1.5 deg and a teleport waits until 0.12 s after the last one (the v0.7 rate limit).
-- situation = precise because of a precise situation (L_TELE_REASON counts it as such, else as forced).
-- v0.9 (docs/V09_PLAN.md section 1.4): while the camera method attach is in use the view cannot move with the player's
-- aim, so aim changes are free: during tool use the band is 0.5 deg and the rate limit 0.06 s (outside tool use and
-- the teleportBlocked() rules unchanged).
-- v0.16 (docs/V016_PLAN.md section 1): the offset placement running counts as tool use here (the engine tool in the
-- hand turns only with the player's aim: the 0.5 deg band and the 0.06 s rate limit of v0.9 attach).
local function setPlayerAim(yaw, pitch, precise, situation)
    pitch = clamp(pitch, -89, 89)
    -- (v0.18, docs/V018_PLAN.md section 2: the pose before this tick's aim - prediction B of actPlace17)
    aimState.preYaw, aimState.prePitch, aimState.preAt = GetPlayerYaw(), GetPlayerPitch(), heartbeat
    if precise then aimState.preciseTick = heartbeat end   -- (v0.21 section 4.3: no body turn in this tick, bodyTurn)
    SetPlayerPitch(pitch)
    if precise and nat.yawControl == 1 and not hasBit(nat.perf, PF.NO_YAW) then
        -- (v0.19, docs/V019_PLAN.md section 1: the parked engine tool is no tool use - the replica does not turn with
        -- the player's aim)
        local use = aimState.toolUse or (probe.act.run and probe.act.m19 ~= 1)
        local attached = cal.method == 4
        local d = angleDiff(yaw, GetPlayerYaw())
        local big = math.abs(d) > (use and (attached and 0.5 or 1.5) or 0.3)
        if big and teleportBlocked() then
            jump.blocked = jump.blocked + 1
        elseif big and probe.step > 0 then
            -- (v0.12, docs/V012_PLAN.md section 2: no yaw teleport while the engine tool frame probe runs: it would move
            -- every reference frame between the probe's measurements; the pitch above is still set)
        elseif big and use and aimState.since < (attached and 0.06 or 0.12) then
            aimState.limited = aimState.limited + 1
        elseif big then
            local pt = GetPlayerTransform()
            local vel = GetPlayerVelocity()
            aimTeleport(pt.pos, yaw, pitch)
            SetPlayerVelocity(vel)
            aimState.teleports = aimState.teleports + 1
            aimState.since, aimState.teleAt = 0, heartbeat
            if situation then aimState.byPrecise = aimState.byPrecise + 1 else aimState.byForced = aimState.byForced + 1 end
        end
    elseif not precise and nat.yawControl == 1 and not hasBit(nat.perf, PF.NO_YAW) and probe.act.run and rcFree18()
        and probe.step == 0 and aimState.since > PRB.P18.DRIFT_T
        and math.abs(angleDiff(yaw, GetPlayerYaw())) > PRB.P18.DRIFT and not teleportBlocked() then
        -- v0.18 review LUA18-STALE-AIM-BLOCKED-USE (deviation from V018 section 1 / the v0.8 "lazy aim never turns the
        -- player"): with the control kept the player's yaw drifts from the hand as far as the hand turns outside the
        -- precise situations, and a use while teleports are blocked (the jump guard, airborne, crouch, A / B) fired
        -- along that stale yaw while R kept the visible tool on the hand. So in lazy aim, the control kept and not
        -- blocked: one yaw teleport once the drift exceeds P18.DRIFT deg and the last teleport is P18.DRIFT_T s old
        -- (counted with the forced ones in L_TELE_REASON - no precise situation - and apart in aimState.byDrift).
        local pt = GetPlayerTransform()
        local vel = GetPlayerVelocity()
        aimTeleport(pt.pos, yaw, pitch)
        SetPlayerVelocity(vel)
        aimState.teleports = aimState.teleports + 1
        aimState.since, aimState.teleAt = 0, heartbeat
        aimState.byForced, aimState.byDrift = aimState.byForced + 1, aimState.byDrift + 1
    end
end

local function pulse(hand, amp, dur)       -- hand 1 = left, 2 = right
    hapticSeq[hand] = hapticSeq[hand] + 1
    if hand == 1 then
        W(L_HAPTIC_AMP_L, amp); W(L_HAPTIC_DUR_L, dur); W(L_HAPTIC_SEQ_L, hapticSeq[1])
    else
        W(L_HAPTIC_AMP_R, amp); W(L_HAPTIC_DUR_R, dur); W(L_HAPTIC_SEQ_R, hapticSeq[2])
    end
end

-- Returns the heading change (degrees) requested with the right stick this tick.
-- Pushing right turns right, which is a negative yaw change (positive yaw = turning left).
local function turnDelta(dt)
    local rx = nat.rstickX or 0
    if nat.turnMode == 1 then
        if math.abs(rx) > 0.2 then
            local amt = (math.abs(rx) - 0.2) / 0.8
            if rx < 0 then amt = -amt end
            return -amt * nat.smoothSpeed * dt
        end
        return 0
    end
    -- One flick does one thing: snap turn and tool switching share the right stick's armed state,
    -- which re-arms only when the stick returns near the centre.
    if snapArmed and math.abs(rx) > 0.7 and math.abs(rx) > math.abs(nat.rstickY or 0) then
        snapArmed = false
        if rx > 0 then return -nat.snapAngle else return nat.snapAngle end
    end
    return 0
end

-- ---------------------------------------------------------------------------------------------
-- tool in the hand
-- ---------------------------------------------------------------------------------------------
-- Puts the visible tool body exactly in the controller hand. SetToolTransform is only an extra offset on
-- top of the game's own tool position, so the absolute SetToolTransformOverride is used. Its reference
-- frame is undocumented; candidates (L_TOOL_FRAME): 1 player (or animator) position + 1.7 m up with the
-- player's heading only (the frame the game's toolanimation.lua uses), 2 the eye frame (GetPlayerEyeTransform,
-- with pitch), 3 the player camera P (true eye + analytic yaw/pitch, the frame our camera offset is composed
-- with), 4 the final camera = our desired camera C of the frame (v0.5: in the v0.4 headset test the body was
-- 0.25-1.95 m off in frames 1-3). measureToolDist identifies the frame the engine uses (tool_frame = auto) or
-- tool_frame forces one (N_TOOL_FRAME). The engine applies the override after physics; on a held-base
-- (right-eye) frame the camera does not move with the player, so frames 1-3 are predicted forward by one frame
-- of player movement; frame 4 needs nothing (L = C^-1 * toolWorld does not depend on the base).
local function toolFrame()
    local pt = GetPlayerTransform()
    local pos = pt.pos
    local anim = GetPlayerAnimator()
    if anim ~= 0 then pos = GetAnimatorTransform(anim).pos end
    local up = GetPlayerUp()
    if VecLength(up) < 0.5 then up = Vec(0, 1, 0) end
    return Transform(VecAdd(pos, VecScale(up, 1.7)), pt.rot)
end

-- The four candidate frames now, indexed by frame number; cam = this frame's desired camera C.
function toolCandidates(cam)
    return { toolFrame(), GetPlayerEyeTransform(), playerCameraFrame(), Transform(VecCopy(cam.pos), cam.rot) }
end

-- Where the tool must be (world): tool -Z along the main hand's aim (the laser), its right-hand point at the
-- controller grip. In first person the tool reports no hand pose (no fp_ hand locations exist), but tool
-- prefabs carry the third-person "tp_action_rh" (v0.7: the TOOL_MODELS value for a built-in tool, see toolHandle).
-- Second result: the grip position (world).
-- v0.19 (docs/V019_PLAN.md section 2; the tool_views2 render: the sledge stands upright in tool space, 1.2 m along +Y,
-- tp_action_rh at the bottom of the handle - with its -Z along the aim ray it stood straight up out of the fist, the head
-- over a metre above it, "too high"): a HANDLE tool (handleTool19) is held like a real hammer - rotation = grip.rot *
-- Rx(-90): tool +Y along the grip's -Z (OpenXR: along the controller handle toward the thumb), +Z along the grip's +Y,
-- +X along +X (a proper rotation), the handle point at the grip as before. The replica and the engine target alike;
-- every other tool (a muzzle, the plank, a modded tool) as before.
-- v0.19 review LUA19-SLEDGE-HANDLE-AXIS / LUA19-SLEDGE-AXIS / V19-SLEDGE-GEOMETRY-WRONG-PREMISE (deviation from V019
-- sections 0 / 2, whose premise is wrong): the tool_views2 render ignored the vox scene graph's rotation (nTRN _r).
-- data/vox/tool/sledge.vox is a 3x7x24 model under _r=24, which the engine applies (rifle / shotgun: 22-23 voxels along
-- the model's X under _r=17, their prefab muzzles at z -1.125), so in tool space the sledge lies along Z: the handle
-- from about z +0.5 to -0.55, the head (7 voxels along Y) at z -0.55..-0.7, tp_action_rh (0, -0.025, -0.25) and
-- tp_action_lh (-0.05, -0.025, 0.3) both on the handle line. Rx(-90) turned that handle across the fist (head along
-- the grip's -Y, the tail 0.75 m along +Y). The sledge is held with rot = grip.rot: tool -Z (the head end) along the
-- grip's -Z (OpenXR: out of the thumb side of the fist), the handle through the fist, the striking faces (tool +-Y)
-- along the grip's +-Y; tp_action_rh at the grip as before.
function toolWorldOf(base)
    local lh = nat.leftHanded == 1
    local rot = localToWorld(base, lh and ctl.laim or ctl.raim, nat.worldScale).rot
    local grip = localToWorld(base, lh and ctl.lgrip or ctl.rgrip, nat.worldScale)
    if handleTool19(GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")) then
        rot = grip.rot
    end
    local toolPos = grip.pos
    local rh = toolHandle()
    if rh then toolPos = VecSub(grip.pos, QuatRotateVec(rot, rh)) end
    return Transform(toolPos, rot), grip.pos
end

-- Tick: the override L = X^-1 * toolWorld * K^-1 in the frame X in use, K = the mean body offset the identification
-- measured in that frame (toolKUpdate; none before it). The engine puts the body at X * L * K = toolWorld, and the
-- next K measurement (L^-1 * X^-1 * Bw) does not depend on L (v0.5 review: v0.5 left K in, so an identified K kept
-- the tool |K| away from the fist). With frame 4 the camera C is computed before (updateActive: computeCamera runs
-- first). L, the K taken out, the frame placed against (pk) and the candidate frames are kept for the next tick's
-- measurement; render() and draw() refresh the candidates, the grip and toolWorld (retoolInRender, toolRendered).
-- v0.6 review: the closed-loop correction (toolCorrUpdate, in frame k's axes) is added to L's position last.
-- v0.12 (docs/V012_PLAN.md section 2): while the engine tool frame probe runs this tick sends the probe's override
-- instead (probeStep; no placement: toolCal.sent stays nil, so neither the v0.5 frame measurement nor L_TOOL_ERR takes
-- the tick); once the probe has chosen a reference the override is the probe's (probePlace, sent.pr = the reference);
-- otherwise (not honored, inconsistent, no reference yet) the v0.11 placement below.
-- v0.13 (docs/V013_PLAN.md section 2): the probe's placement aims at the servo's target D' (servoTarget: the desired
-- transform with a lead and the integral correction) instead of the desired transform itself; sent.tw stays the
-- desired one (L_TOOL_ERR: where the replica is drawn).
-- v0.14 (docs/V014_PLAN.md section 1): with attach in use the servo's placement no longer waits for a probe reference
-- (probePlace: reference 1 with an identity L / Krot without one; sent.pr = the reference placed with, 0 only for the
-- v0.11 placement). Exactly one SetToolTransformOverride per tick: this is its only caller in a tick (probeStep's
-- override replaces the placement, the other two paths return after theirs; retoolInRender and the servo send none),
-- so the engine never smooths toward a second target the same tick.
-- v0.15 (docs/V015_PLAN.md sections 1-2): with attach in use NO SetToolTransformOverride any more (the v0.14 log: not
-- honored from our script; the engine keeps its tool at its own first-person pose, the "base"): the placement with the
-- actuator the test identified (actPlace: SetToolTransform or SetToolOffset; nothing while none is known). sent.L is
-- nil then (measureToolDist takes only L_TOOL_ERR from such a tick: no override to measure frames with), act = true.
-- PRB.V014 (or V013) restores the v0.14 path below for the tests of that kept code.
-- v0.16 (docs/V016_PLAN.md section 1): the actuator is fixed (SetToolOffset in the player-yaw frame, actUpdate), so
-- actPlace places from the first tick this is reached in attach - the conditions actCanRun mirrors.
function placeToolInHand(cam, base, held, dt)
    local X = toolCandidates(cam)
    local k = toolCal.frame
    local frame = X[k]
    if held and k ~= 4 then frame = Transform(VecAdd(frame.pos, VecScale(GetPlayerVelocity(), dt)), frame.rot) end
    local tw, grip = toolWorldOf(base)
    toolTarget = tw.pos
    if cal.method == 4 and not (PRB.V013 or PRB.V014) then
        actPlace(tw, dt, cam)
        toolCal.sent = { X = X, pk = frame, tick = heartbeat, grip = grip, rc = nil, camErr = -1, tw = tw, k = k,
                         kUsed = false, pr = 0, act = true }
        return
    end
    if probe.step > 0 then
        -- (attach may have ended in this very tick, updateCameraMode: no probe override without it)
        if cal.method == 4 then probeStep(cam) return end
        probeAbort()
    end
    local O = probePlace(cam, servoTarget(tw, dt), held, dt)
    if O then
        SetToolTransformOverride(O)
        toolCal.sent = { L = O, K = Transform(), X = X, pk = frame, tick = heartbeat, grip = grip, rc = nil,
                         camErr = -1, tw = tw, k = k, kUsed = false, pr = probe.ref ~= 0 and probe.ref or 1 }
        return
    end
    local K = (toolCal.kMean and toolCal.kFrame == k) and toolCal.kMean or nil
    local L = TransformToLocalTransform(frame, tw)
    if K then L = TransformToParentTransform(L, TransformToLocalTransform(K, Transform())) end
    if toolCal.corr and toolCal.corrFrame == k then L = Transform(VecAdd(L.pos, toolCal.corr), L.rot) end
    SetToolTransformOverride(L)
    toolCal.sent = { L = L, K = K or Transform(), X = X, pk = frame, tick = heartbeat, grip = grip, rc = nil,
                     camErr = -1, tw = tw, k = k, kUsed = K ~= nil, pr = 0 }
end

-- render(), after a tick that placed the tool: the candidate frames as the engine has them now (post-physics,
-- what the next tick's measurement compares with) and the grip where render puts the glove (the fist check).
-- With frame 2 in use its candidate stays the tick's eye frame it was placed with (v0.5 review: the eye read back
-- in render may already hold this frame's camera, so it would be identified with values it is not placed with).
-- No override is sent here (v0.5 review: L = C^-1 * toolWorld is base-independent, so render's equalled the tick's,
-- and the override belongs in tick: a render-time one could outlive a tick that sends none).
function retoolInRender(cam, base)
    local s = toolCal.sent
    if not s or s.tick ~= heartbeat or not ctl then return end
    s.X = toolCandidates(cam)
    if toolCal.frame == 2 then s.X[2] = s.pk end
    local tw, grip = toolWorldOf(base)
    s.grip, s.tw = grip, tw
end

-- draw(), on foot: c = the camera the engine rendered this frame, strict = the record it matched exactly (nil: none),
-- err = this frame's probe error (< 0: not measured). Candidate 4 becomes the rendered camera (v0.5 review: our
-- desired C put every camera error while using a tool into K_4), unless c matched an older record (one-frame lag:
-- c is not this frame's camera); it is also the camera of the "override ignored" check.
function toolRendered(c, strict, err)
    local s = toolCal.sent
    if not s or s.tick ~= heartbeat then return end
    s.camErr = err or -1
    if not strict or strict == hist[#hist] then
        s.X[4] = Transform(VecCopy(c.pos), c.rot)
        s.rc = s.X[4]
    end
end

-- tool_frame (N_TOOL_FRAME): 1..4 forces that frame (L_TOOL_FRAME2 +20, nothing is switched); 0 auto.
function updateToolFrameMode()
    local req = nat.valid and (nat.toolFrame or 0) or 0
    toolCal.forced = req >= 1 and req <= 4
    toolCal.frame = toolCal.forced and req or toolCal.auto
end

-- v0.4 distance rule, tool_frame = auto only. d[k] = distance (m) of the tool body from the override as frame k
-- places it (at[k]). Only ticks in which the frames put the override > 2 cm apart can tell them apart (e.g. at pitch
-- ~0 frames 1 and 2 coincide; v0.5: and the frame that explains the body must be > 2 cm from ours, since frame 4
-- is always a few cm off); the others are skipped. 30 such ticks in a row in which another frame has < 1 cm error
-- while ours has > 3 cm switch frames. It assumes a zero body offset K and is kept for that case (a static pose
-- gives the identification below nothing to compare); while an identification locks the frame (byK) it is off.
-- No bias is learned (every shipped character has a zero tool_offset; a learned bias could lock a wrong frame in).
-- Frame 2 is no candidate while the eye is not the raw one (eyeSrc.src ~= 0: it carries our camera offset).
function calibrateToolFrame(d, at)
    if toolCal.forced or toolCal.byK then return end
    local cur = toolCal.auto
    local best, spread = 0, 0
    for k = 1, 4 do
        if k ~= cur then spread = math.max(spread, VecLength(VecSub(at[k], at[cur]))) end
        if k ~= cur and d[k] >= 0 and d[k] < 0.01 and (best == 0 or d[k] < d[best])
            and (k ~= 2 or eyeSrc.src == 0) then best = k end
    end
    if spread <= 0.02 or (best ~= 0 and VecLength(VecSub(at[best], at[cur])) <= 0.02) then return end
    if best ~= 0 and d[cur] > 0.03 then
        if toolCal.runFrame == best then toolCal.run = toolCal.run + 1 else toolCal.runFrame, toolCal.run = best, 1 end
        if toolCal.run >= 30 then
            toolCal.auto, toolCal.autoBy, toolCal.run, toolCal.runFrame = best, "dist", 0, 0
            toolCal.frame = best
        end
        return
    end
    toolCal.run, toolCal.runFrame = 0, 0
end

-- Tool frame identification (v0.5). If the engine places the tool body at Bw = X * L * K in its frame X, with K a
-- constant body offset in tool space, then K_X = L^-1 * X^-1 * Bw is the same in every tick for the engine's
-- frame and wanders for the others (their relation to X changes as the player looks around). A tick is a sample
-- if some two candidates put the override > 4 cm apart (v0.5 review: v0.5 also dropped every tick with any pair
-- 1-4 cm apart, e.g. the eye frame vs P differing by our own half-IPD offset near the recenter point, so a still
-- player gave no samples at all; closer pairs only make a loser's spread smaller, which leaves the decision
-- undecided, never wrong). Spread of a candidate over the last 30 samples = the largest deviation of K from its
-- mean: position (cm) + rotation as the displacement it causes 30 cm out (0.52 cm per degree). PREF: of coinciding
-- candidates (one frame), the one kept (after the frame in use).
-- v0.6 review: CGAIN / CMAX / CSKIP = the closed-loop correction's gain, largest length (m) and the largest error (m)
-- that is still a sample (see toolCorrUpdate). v0.7: CORR = the closed-loop correction runs (off: it diverged in the
-- v0.6 headset log, docs/V07_PLAN.md section 0/3).
local TOOLF = { N = 30, SAME = 0.01, APART = 0.04, WIN = 1.5, LOSE = 4, PREF = { 4, 3, 2, 1 }, CGAIN = 0.3, CMAX = 1,
                CSKIP = 1.5, CORR = false }

function toolSampleCounts(at)
    for i = 1, 3 do
        for j = i + 1, 4 do
            if VecLength(VecSub(at[i], at[j])) > TOOLF.APART then return true end
        end
    end
    return false
end

-- Spread (cm, see above), mean position and mean rotation (normalised quaternion) of candidate k's K over the
-- samples.
function toolSpread(smp, k)
    local n = #smp
    local q0 = smp[1].k[k].rot
    local mp, mq = Vec(0, 0, 0), { 0, 0, 0, 0 }
    for i = 1, n do
        local K = smp[i].k[k]
        mp = VecAdd(mp, K.pos)
        local q = K.rot
        local sg = (q[1] * q0[1] + q[2] * q0[2] + q[3] * q0[3] + q[4] * q0[4] < 0) and -1 or 1
        for j = 1, 4 do mq[j] = mq[j] + q[j] * sg end
    end
    mp = VecScale(mp, 1 / n)
    local ql = math.sqrt(mq[1] * mq[1] + mq[2] * mq[2] + mq[3] * mq[3] + mq[4] * mq[4])
    if ql < 1e-9 then mq = q0 else mq = { mq[1] / ql, mq[2] / ql, mq[3] / ql, mq[4] / ql } end
    local worst = 0
    for i = 1, n do
        local K = smp[i].k[k]
        local dev = VecLength(VecSub(K.pos, mp)) * 100 + math.rad(quatAngle(K.rot, mq)) * 30
        if dev > worst then worst = dev end
    end
    return worst, mp, mq
end

-- Candidates a and b put the override at the same place (< 1 cm) in every sample: one frame, not competitors.
function toolSame(smp, a, b)
    for i = 1, #smp do
        if VecLength(VecSub(smp[i].at[a], smp[i].at[b])) >= TOOLF.SAME then return false end
    end
    return true
end

-- With 30 samples: the frame whose K is constant (spread < 1.5 cm) while every other candidate's spread is > 4 cm
-- is the engine's. Of candidates that coincide with it (one frame, all with spread < 1.5 cm) the frame in use is
-- kept, else the first of 4, 3, 2, 1 (v0.5 review: frame 4 is built from our own data alone, frame 2 from a value
-- read back in render that is placed with the tick's). Frame 2 never wins while the eye is not the raw one
-- (eyeSrc.src ~= 0: it carries our camera offset). tool_frame = auto switches to it and the identification locks
-- the distance rule out (byK); while tool_frame is forced it is only remembered (auto, idFrame) for when it is
-- back to auto, and nothing is locked.
function identifyToolFrame()
    local smp = toolCal.samples
    local n = #smp
    for k = 1, 4 do toolCal.spread[k] = (n >= 2) and toolSpread(smp, k) or -1 end
    if n < TOOLF.N then return end
    local first = 0
    for k = 1, 4 do
        if toolCal.spread[k] < TOOLF.WIN then
            if first == 0 then first = k elseif not toolSame(smp, first, k) then return end   -- two frames fit: undecided
        end
    end
    if first == 0 then return end
    for k = 1, 4 do
        if k ~= first and toolCal.spread[k] <= TOOLF.LOSE and not toolSame(smp, first, k) then return end
    end
    local win = 0
    for i = 0, 4 do
        local k = (i == 0) and toolCal.frame or TOOLF.PREF[i]
        if win == 0 and toolCal.spread[k] < TOOLF.WIN and (k ~= 2 or eyeSrc.src == 0) then win = k end
    end
    if win == 0 then return end
    if win ~= toolCal.idFrame then toolCal.loseRun = 0 end
    toolCal.auto, toolCal.autoBy, toolCal.idFrame, toolCal.run, toolCal.runFrame = win, "K", win, 0, 0
    if not toolCal.forced then toolCal.frame, toolCal.byK = win, true end
end

-- After an identification (idFrame): its mean body offset K over a full window in which K is constant (spread <
-- 1.5 cm) is what placeToolInHand takes out of the override (kMean; |K.pos| > 1 m is no body offset and is not
-- used). L_TOOLF_K = |K| (cm) of idFrame over >= 5 samples, -1 before any identification (v0.5 review: the frame
-- in use's "K" before it is no body offset and read like a large one). The identified frame's spread above 4 cm
-- for a full window of new samples releases the identification (v0.5 review: a wrong lock lasted the session):
-- K is dropped and the distance rule and the identification may choose again. pushed = a new sample this tick.
function toolKUpdate(pushed)
    local f, smp = toolCal.idFrame, toolCal.samples
    local n = #smp
    if f == 0 then toolCal.kLen = -1 return end
    if pushed then
        if n >= TOOLF.N and toolCal.spread[f] > TOOLF.LOSE then toolCal.loseRun = toolCal.loseRun + 1
        else toolCal.loseRun = 0 end
        if toolCal.loseRun >= TOOLF.N then
            toolCal.idFrame, toolCal.byK, toolCal.kMean, toolCal.loseRun, toolCal.kLen = 0, false, nil, 0, -1
            return
        end
    end
    toolCal.kLen = -1
    if n < 5 then return end
    local spread, mp, mq = toolSpread(smp, f)
    toolCal.kLen = VecLength(mp) * 100
    if n >= TOOLF.N and spread < TOOLF.WIN then
        if VecLength(mp) <= 1 then toolCal.kMean, toolCal.kFrame = Transform(mp, mq), f else toolCal.kMean = nil end
    end
end

-- "Override ignored" check (v0.5 review): M = rendered camera^-1 * tool body, over the last 30 ticks with a rendered
-- camera. If the engine drops our override for its own tool pose (toolanimation.lua calls SetToolTransform every
-- tick), the body keeps a fixed place in the view: M stays constant while our override L wanders, which the four
-- frame spreads cannot tell from "none of the four frames". Returns M's spread (cm) once L's spread is > 4 cm, else
-- -1 (a still override tells nothing).
function toolOverrideIgnored()
    local m = toolCal.mSamples
    if #m < TOOLF.N or toolSpread(m, 2) <= TOOLF.LOSE then return -1 end
    return (toolSpread(m, 1))
end

-- The direct "in the fist" check (v0.5 review): the tool's handle location tp_action_rh in the world (the engine
-- places it with the body) against the grip of the frame the override was sent for, cm; -1 n/a.
function toolFist(s)
    if not GetToolLocationWorldTransform or not s.grip then return -1 end
    local ok, t = pcall(GetToolLocationWorldTransform, "tp_action_rh")
    if not ok or type(t) ~= "table" or type(t.pos) ~= "table" then return -1 end
    return VecLength(VecSub(t.pos, s.grip)) * 100
end

-- Closed-loop tool correction (v0.6 review; v0.7: off unless TOOLF.CORR, since in the v0.6 headset log it sat at its
-- 1 m clamp, toolCorr=100cm, and never converged; off, corr stays nil and L_TOOL_CORR is -1). Whatever frame the
-- engine really places the tool body in, the body belongs at toolWorld (the hand, where render puts the replica and the gloves). At the start of each tick the
-- body's position error against the last override's target (s.tw, as render refreshed it) is turned into the axes of
-- the frame that override was sent in (s.X[s.k], as render / draw refreshed it) and integrated (gain CGAIN, length at
-- most CMAX m) into toolCal.corr, which placeToolInHand adds to the next override's position. This keeps the invisible
-- engine tool (where its flames, paint, shots and hits start) or the visible one (replica failed) at the fist even when
-- no frame identification succeeds (the v0.5 headset log: 38-82 cm). Dropped when the tool, its body, the frame in use
-- or whether an identified K is taken out changes (it absorbed that offset), and while the override is found ignored;
-- a camera spike frame (clean false) or an error over CSKIP (a teleport or respawn, the engine's own tool animation) is
-- no sample. Only the body origin is corrected (a rotation error still moves its other points). L_TOOL_CORR = |corr|
-- (cm).
function toolCorrUpdate(s, bw, clean)
    if not TOOLF.CORR then toolCal.corr = nil return end
    local kOn = s.kUsed == true
    if toolCal.corrFrame ~= s.k or toolCal.corrK ~= kOn then toolCal.corr, toolCal.corrFrame, toolCal.corrK = nil, s.k, kOn end
    -- (the "override ignored" check, toolOverrideIgnored: the body does not follow the override at all, so a correction
    -- could only wind up; dropped)
    if toolCal.spreadM >= 0 and toolCal.spreadM < TOOLF.WIN then toolCal.corr = nil return end
    local X = s.X[s.k]
    if not clean or not s.tw or not X then return end
    local e = VecSub(s.tw.pos, bw.pos)
    if VecLength(e) > TOOLF.CSKIP then return end
    local c = VecAdd(toolCal.corr or Vec(0, 0, 0), VecScale(QuatRotateVec(qconj(X.rot), e), TOOLF.CGAIN))
    local l = VecLength(c)
    if l > TOOLF.CMAX then c = VecScale(c, TOOLF.CMAX / l) end
    toolCal.corr = c
end

-- At the start of a tick (before anything moves the player): the tool body against last tick's override as each
-- candidate frame (kept from that frame's render and draw, see retoolInRender / toolRendered) places it, with the K
-- taken out put back (at = where the body belongs then). L_TOOL_DIST/2/3, L_TOOL_DIST4 = body error (m) in frames
-- 1/2/3/4, -1 = nothing to compare; L_TOOLF_SPREAD_* (cm, -1 below 2 samples); L_TOOLF_K see toolKUpdate;
-- L_TOOL_FRAME2 = frame in use (+10 chosen by the K identification, +20 forced, +30 by the v0.4 distance rule);
-- L_TOOLF_SPREAD_M see toolOverrideIgnored; L_TOOL_FIST_CM see toolFist. A frame whose camera probe error was
-- > 0.5 deg gives no sample and no distance-rule tick (v0.5 review: a camera spike put ~10 cm into K). A new tool
-- body or tool starts the samples over (last override was for the old one) and drops K (and the closed-loop
-- correction, see toolCorrUpdate: L_TOOL_CORR).
function measureToolDist()
    local body = GetToolBody()
    local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
    if body ~= toolCal.body or tool ~= toolCal.tool then
        toolCal.body, toolCal.tool, toolCal.run, toolCal.runFrame, toolCal.sent = body, tool, 0, 0, nil
        toolCal.samples, toolCal.spread, toolCal.kLen = {}, { -1, -1, -1, -1 }, -1
        toolCal.mSamples, toolCal.spreadM, toolCal.kMean, toolCal.loseRun = {}, -1, nil, 0
        toolCal.corr = nil                -- (v0.6 review: the correction belongs to the old tool)
        probe.errs = {}                   -- (v0.12 L_TOOL_ERR: the old tool's errors)
    end
    updateToolFrameMode()
    local d = { -1, -1, -1, -1 }
    local s = toolCal.sent
    -- (v0.13, docs/V013_PLAN.md section 1: while the visible-offset self-test runs or settles the offset may have moved
    -- the tool body 50 m down: no frame sample, correction or L_TOOL_ERR sample from those ticks)
    if probe.vofs.phase > 0 then s = nil end
    toolCal.fist = -1
    if s and body ~= 0 and not s.L then
        -- (v0.15, docs/V015_PLAN.md section 1: a tick placed without an override - only L_TOOL_ERR)
        if s.tw then
            push(probe.errs, VecLength(VecSub(GetBodyTransform(body).pos, s.tw.pos)) * 100, PRB.N)
            probe.idle = 0
        end
    elseif s and body ~= 0 then
        local bw = GetBodyTransform(body)
        local lk = TransformToParentTransform(s.L, s.K).pos
        local at, ks = {}, {}
        for k = 1, 4 do
            at[k] = TransformToParentPoint(s.X[k], lk)   -- where the body belongs as frame k places the override
            d[k] = VecLength(VecSub(bw.pos, at[k]))
            ks[k] = TransformToLocalTransform(s.L, TransformToLocalTransform(s.X[k], bw))
        end
        local clean = s.camErr <= 0.5
        toolCorrUpdate(s, bw, clean)
        local pushed = clean and toolSampleCounts(at)
        if clean then calibrateToolFrame(d, at) end
        if pushed then push(toolCal.samples, { k = ks, at = at }, TOOLF.N) end
        identifyToolFrame()
        toolKUpdate(pushed)
        if s.rc then push(toolCal.mSamples, { k = { TransformToLocalTransform(s.rc, bw), s.L } }, TOOLF.N) end
        toolCal.spreadM = toolOverrideIgnored()
        toolCal.fist = toolFist(s)
        -- (v0.12 L_TOOL_ERR, docs/V012_PLAN.md section 2: the engine tool body against where the last placement wanted
        -- it, s.tw as render refreshed it, i.e. where the replica was drawn)
        if s.tw then
            push(probe.errs, VecLength(VecSub(bw.pos, s.tw.pos)) * 100, PRB.N)
            probe.idle = 0
        end
    elseif body == 0 then
        toolCal.kLen = -1
    end
    if not (s and body ~= 0) then
        -- (v0.12: no placement for a whole window: the errors are no longer current, L_TOOL_ERR -1)
        probe.idle = probe.idle + 1
        if probe.idle >= PRB.N then probe.errs = {} end
    end
    W(L_TOOL_DIST, d[1])
    W(LX.TOOL_DIST2, d[2])
    W(LX.TOOL_DIST3, d[3])
    W(L2.TOOL_DIST4, d[4])
    W(L2.TOOLF_SPREAD_C, toolCal.spread[4])
    W(L2.TOOLF_SPREAD_P, toolCal.spread[3])
    W(L2.TOOLF_SPREAD_F1, toolCal.spread[1])
    W(L2.TOOLF_SPREAD_E, toolCal.spread[2])
    W(L2.TOOLF_SPREAD_M, toolCal.spreadM)
    W(L2.TOOLF_K, toolCal.kLen)
    W(L2.TOOL_FIST_CM, toolCal.fist)
    W(L2.TOOL_CORR, (body ~= 0 and TOOLF.CORR) and VecLength(toolCal.corr or Vec(0, 0, 0)) * 100 or -1)
    local how = toolCal.autoBy == "K" and 10 or (toolCal.autoBy == "dist" and 30 or 0)
    W(L2.TOOL_FRAME2, toolCal.frame + (toolCal.forced and 20 or how))
    toolCal.sent = nil
end

-- ---------------------------------------------------------------------------------------------
-- v0.12 engine tool frame probe (docs/V012_PLAN.md section 2)
-- ---------------------------------------------------------------------------------------------
-- The v0.11 headset log had the engine tool body (where the game starts its effects: muzzle flash, spray, flame) 20-140 cm
-- from the hand in a wildly varying place of the camera frame: SetToolTransformOverride is not applied in the frame
-- placeToolInHand assumes. Instead of guessing, the probe measures it: four known overrides, the body's response gives
-- the frame's axes and origin F in the world, and F is related to each candidate reference frame R (L_R = R^-1 * F). The
-- reference whose L_R stays the same over two runs (the player has moved and looked around in between) is the engine's;
-- the placement then puts the body exactly on the hand (probePlace). The probe is invisible (it only runs while the
-- replica is shown and the engine tool hidden) and only while the tool is surely not in use.

-- Reference frame r now (1 toolFrame(), 2 the player camera playerCameraFrame(), 3 the camera C, 4 GetPlayerTransform()).
function probeRef(r, cam)
    if r == 1 then return toolFrame() end
    if r == 2 then return playerCameraFrame() end
    if r == 3 then return Transform(VecCopy(cam.pos), cam.rot) end
    local pt = GetPlayerTransform()
    return Transform(VecCopy(pt.pos), pt.rot)
end

-- Forgets every run (a new tool: its body offset, and maybe its frame, are its own); key = the new one. A
-- run in progress counts as aborted (the next one RETRY s later); otherwise the wait since the last run is kept (runs
-- stay at least RETRY s apart also across a tool switch).
function probeReset(key)
    local p = probe
    if p.step > 0 then p.wait = PRB.RETRY end
    p.key, p.state, p.result, p.step, p.hold, p.runs, p.res = key, 0, 0, 0, 0, 0, {}
    p.ref, p.L, p.krot, p.axes, p.T, p.R, p.amb, p.def = 0, nil, nil, 0, {}, nil, 0, false
end

-- v0.12 review LUA-PRB-3: the selected tool changed (key = the tool name). The outgoing tool's runs, results and chosen
-- reference go to the cache; the incoming tool's come back from it (switching back places with its measured frame at
-- once, no new runs), otherwise it starts afresh (probeReset). (Per tool, not per engine frame: L_R holds the tool
-- body's own origin offset, see probePlace.)
function probeSwitch(key)
    local p = probe
    if p.key ~= "" then
        p.cache[p.key] = { ref = p.ref, L = p.L, krot = p.krot, runs = p.runs, amb = p.amb, res = p.res,
                           result = p.result, axes = p.axes, def = p.def }
    end
    probeReset(key)
    local c = p.cache[key]
    if c then
        p.ref, p.L, p.krot, p.runs, p.amb, p.res = c.ref, c.L, c.krot, c.runs, c.amb, c.res
        p.result, p.state, p.axes, p.def = c.result, c.result, c.axes, c.def
    end
end

-- A run ends without a result (a condition broke): the last result is shown again, the next run waits RETRY seconds.
function probeAbort()
    local p = probe
    p.step, p.hold, p.wait, p.state, p.T, p.R = 0, 0, PRB.RETRY, p.result, {}, nil
end

-- Every tick, before updateActive (after updateToolReplica: replica.shown is this tick's). Conditions (section 2): VR
-- active on foot, attach in use (cal.method 4 and the last camera attached), hand aim, a tool selected with a tool body,
-- the replica shown (the engine tool hidden: the probe is invisible), the main trigger and grip below 0.15 for 0.5 s,
-- usetool not down (L_GAME_INPUT bit5), not grabbing (the engine grab or a physical hand holding). A run starts when they
-- hold, no run waits (RETRY s after the last run or abort), no reference is chosen yet and fewer than RUNS runs were done
-- for this tool. A running run is aborted when a condition breaks, the tool body changes, the player moved more than
-- MOVE m since its start or the last tick sent no probe override (placeToolInHand did not run: aim or grip untracked).
-- v0.12 review LUA-PRB-2: the axes are world differences over 16 ticks (v0.13: 48), so any motion of the engine's frame
-- during a run is added to them (slow walking or smooth turning locked a reference 4 cm / 10 deg off, or used up the RUNS budget with
-- "inconsistent" runs). The player must also be still: player speed below VEL, the right stick x within STICK (no
-- smooth or snap turn) and the camera (draw's rc, compared with the previous probe tick's) turning slower than ROT deg/s;
-- this starts no run and aborts a running one (an aborted run is not counted). v0.12 review LUA-PRB-3: the key is the
-- tool name (the cache keeps every tool's results, probeSwitch); a tick with GetToolBody() == 0 keeps the key (it is
-- only not ok; a running run aborts on tb ~= p.body), so a short gap no longer forgets the chosen frame.
function probeUpdate(dt, flags)
    local p = probe
    local tb = GetToolBody()
    local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
    local named = tool ~= "" and tool ~= "none"
    local key = (tb ~= 0 and named) and tostring(tool) or p.key
    if key ~= p.key then probeSwitch(key) end
    p.wait = math.max(0, p.wait - dt)
    local lh = nat.leftHanded == 1
    local trig = ctl and (lh and ctl.ltrig or ctl.rtrig) or 1
    local sq = ctl and (lh and ctl.lsq or ctl.rsq) or 1
    if trig < PRB.TRIG and sq < PRB.TRIG then p.quiet = p.quiet + dt else p.quiet = 0 end
    p.turn = 0
    if p.rc and p.lastRc and dt > 0 then p.turn = quatAngle(p.lastRc.rot, p.rc.rot) / dt end
    p.lastRc = p.rc
    local still = VecLength(GetPlayerVelocity()) < PRB.VEL and math.abs(nat.rstickX or 0) <= PRB.STICK
        and p.turn < PRB.ROT
    local ok = active and not hasBit(flags, LF_VEHICLE) and cal.method == 4 and cal.used == 4 and nat.aimMode == 1
        and tb ~= 0 and named and replica.shown and p.quiet >= PRB.QUIET
        and not hasBit(jump.gi, 32) and GetPlayerGrabBody() == 0 and not phys.l.hold and not phys.r.hold and still
    if p.step > 0 then
        local moved = VecLength(VecSub(GetPlayerTransform().pos, p.p0)) > PRB.MOVE
        if not ok or tb ~= p.body or moved or p.at ~= heartbeat - 1 then probeAbort() end
    end
    -- (v0.13, docs/V013_PLAN.md section 1: the visible-offset self-test has the same start conditions and goes first; a
    -- probe run never starts while it runs or settles, and it never starts while a probe runs)
    -- (v0.14, docs/V014_PLAN.md section 1: neither starts any more - PRB.V013 is only set by the tests of this kept
    -- code; the key bookkeeping above still runs, the servo resets on it)
    if PRB.V013 then vofsUpdate(dt, ok, tb) end
    if PRB.V013 and p.step == 0 and ok and p.wait <= 0 and p.ref == 0 and p.runs - p.amb < PRB.RUNS
        and p.vofs.phase == 0 then
        p.step, p.hold, p.body, p.p0, p.T, p.R, p.state = 1, 0, tb, VecCopy(GetPlayerTransform().pos), {}, nil, 1
    end
end

-- placeToolInHand while a run is on: override O_(step) (identity rotation) held for HOLD ticks; on the last one the body
-- (GetBodyTransform(GetToolBody()) in tick: where the engine put it with this override at the end of the previous frame)
-- is measured, at O0 also the references. Reference 3 is the camera the engine rendered that frame (draw's, probe.rc):
-- with stereo pairs this tick's C belongs to the other eye (the spec's "render camera"; this tick's C only without a
-- draw-time camera). After O3 the run is evaluated.
-- v0.13 review LUA13-PRB-NOAGREE: O0 is held 2 x HOLD ticks. The jump to O0 starts wherever the v0.11 placement left
-- the body (0.3-1 m and more from O0, a different place in every run); after HOLD ticks of the engine's ~25 % per tick
-- 0.75^11 = 4 % of it was left in T0, which moved F and skewed every axis by a run-dependent amount (two runs with the
-- hand 0.3 m apart disagreed by more than AGREE_CM / AGREE_DEG, nothing was chosen). 0.75^23 = 0.13 % now; the later
-- steps start from O_(i-1), the same in every run, so their leftover does not break agreement.
function probeStep(cam)
    local p = probe
    p.at, p.hold = heartbeat, p.hold + 1
    local o = PRB.O[p.step]
    SetToolTransformOverride(Transform(Vec(o[1], o[2], o[3])))
    if p.hold < ((p.step == 1) and 2 * PRB.HOLD or PRB.HOLD) then return end
    local bt = engineCall(GetBodyTransform, p.body)
    if type(bt) ~= "table" or type(bt.pos) ~= "table" or type(bt.rot) ~= "table" then probeAbort() return end
    p.T[p.step] = bt
    if p.step == 1 then
        p.R = { probeRef(1, cam), probeRef(2, cam), p.rc or probeRef(3, cam), probeRef(4, cam) }
    end
    if p.step < #PRB.O then
        p.step, p.hold = p.step + 1, 0
        return
    end
    p.step, p.hold, p.wait = 0, 0, PRB.RETRY
    probeEvaluate()
end

-- The rotation whose columns are the orthonormalised axes a (a[i] = the body's response to O_i, / D; len = |a[i]|), nil
-- when they are inconsistent: a length outside SMIN..SMAX, two axes more than ORTHO degrees from perpendicular, or a
-- mirrored (left-handed) set, which no rotation describes. Gram-Schmidt from a1 (then a2); z = x cross y.
function probeAxesRot(a, len)
    for i = 1, 3 do
        if len[i] < PRB.SMIN or len[i] > PRB.SMAX then return nil end
        for j = i + 1, 3 do
            if math.abs(VecDot(a[i], a[j])) / (len[i] * len[j]) > math.sin(math.rad(PRB.ORTHO)) then return nil end
        end
    end
    if VecDot(VecCross(a[1], a[2]), a[3]) <= 0 then return nil end
    local x = VecScale(a[1], 1 / len[1])
    local y = VecNormalize(VecSub(a[2], VecScale(x, VecDot(a[2], x))))
    local z = VecCross(x, y)
    -- rotation matrix (columns x, y, z) -> quaternion
    local tr = x[1] + y[2] + z[3]
    local qx, qy, qz, qw
    if tr > 0 then
        local s = math.sqrt(tr + 1) * 2
        qw, qx, qy, qz = 0.25 * s, (y[3] - z[2]) / s, (z[1] - x[3]) / s, (x[2] - y[1]) / s
    elseif x[1] > y[2] and x[1] > z[3] then
        local s = math.sqrt(1 + x[1] - y[2] - z[3]) * 2
        qw, qx, qy, qz = (y[3] - z[2]) / s, 0.25 * s, (y[1] + x[2]) / s, (z[1] + x[3]) / s
    elseif y[2] > z[3] then
        local s = math.sqrt(1 + y[2] - x[1] - z[3]) * 2
        qw, qx, qy, qz = (z[1] - x[3]) / s, (y[1] + x[2]) / s, 0.25 * s, (z[2] + y[3]) / s
    else
        local s = math.sqrt(1 + z[3] - x[1] - y[2]) * 2
        qw, qx, qy, qz = (x[2] - y[1]) / s, (z[1] + x[3]) / s, (z[2] + y[3]) / s, 0.25 * s
    end
    return Quat(qx, qy, qz, qw)
end

-- A completed run: honored = the body moved > HONOR m for some O_i; axes a_i = (T_i - T0) / D (L_PROBE_AXES); F = (T0's
-- position, the axes' rotation), Krot = F.rot^-1 * T0.rot (the body's own rotation in the frame), L_R = R^-1 * F for
-- each reference at the O0 measurement. The result (3 not honored, 4 inconsistent, 5 honored) is kept; probeChoose may
-- make it 2.
function probeEvaluate()
    local p, T = probe, probe.T
    p.runs = p.runs + 1
    local a, len, honored = {}, {}, false
    for i = 1, 3 do
        local d = VecSub(T[i + 1].pos, T[1].pos)
        if VecLength(d) > PRB.HONOR then honored = true end
        a[i] = VecScale(d, 1 / PRB.D)
        len[i] = VecLength(a[i])
    end
    p.axes = 0
    for i = 1, 3 do p.axes = p.axes * 1000 + clamp(math.floor(len[i] * 100 + 0.5), 0, 999) end
    local res = { ok = false }
    local rot = honored and probeAxesRot(a, len) or nil
    if not honored then
        p.result = 3
    elseif not rot then
        p.result = 4
    else
        local F = Transform(VecCopy(T[1].pos), rot)
        res.ok, res.krot, res.L = true, QuatRotateQuat(qconj(rot), T[1].rot), {}
        for r = 1, 4 do res.L[r] = TransformToLocalTransform(p.R[r], F) end
        p.result = 5
    end
    p.res[#p.res + 1] = res
    probeChoose()
    p.state = p.result
end

-- Consistency over runs: when the two most recent runs both have a frame, the reference whose L_R differs least between
-- them (position < AGREE_CM cm and rotation < AGREE_DEG degrees; score cm + deg, an earlier reference wins ties within
-- TIE) is chosen with the latest run's L_R and Krot (state 2; no further runs for this tool). After one run, or when no
-- reference agrees, nothing is chosen (the placement stays v0.11's; state 5 while the latest run had a frame).
-- v0.12 review LUA-PRB-1 / L12-PROBE-NONDISCRIMINATING: agreement only counts when the two runs could tell the
-- references apart. For a reference r of another class than the winner (1 and 4 are one class: a constant apart),
-- L_r changes between the runs exactly as the relation R_best^-1 * R_r does (the rotation part by the same angle), so
-- every such r must disagree by at least SEP_CM cm or SEP_DEG deg (2 x the agreement: a clear margin over noise). A
-- still player (the same yaw, aim pitch and head in both runs; or the pitch clamped at -89 both times) made every
-- reference agree and the lowest index won for good. Such a pair chooses nothing and the older run is dropped; the run
-- is not counted toward RUNS (amb), so a later run after the player moved still decides (state stays 5).
-- v0.13 (docs/V013_PLAN.md section 2): such a pair no longer waits for a better one (the v0.12 log never got a choice,
-- and every probe run is a 0.8 s stretch in which the tool must not be used): reference 1, toolFrame() - the game's own
-- tool frame (toolanimation.lua) - is chosen with the latest run's L_1 and Krot, state 2, def (+100 in L_PROBE_REF);
-- the servo takes up what a wrong guess leaves.
-- v0.13 review LUA13-PRB-NOAGREE / SC-2: the same default once the RUNS budget is spent without a choice (no reference
-- agreed, or the two most recent runs were not both ok: ok / not honored / ok, ok / ok / inconsistent) and some run had
-- a frame: reference 1 with the newest ok run's L_1 and Krot (state 2, def). Without it the tool kept runs = RUNS and no
-- reference for the whole session: no servo, the engine tool never shown, effects not from the hand. (A pair that
-- disagrees before the budget is spent still gets its next run: it can pick the engine's reference itself.)
function probeChoose()
    local p = probe
    local n = #p.res
    if n >= 2 and p.res[n - 1].ok and p.res[n].ok then
        local a, b = p.res[n - 1].L, p.res[n].L
        local best, score, dp, dr = 0, 0, {}, {}
        for r = 1, 4 do
            dp[r], dr[r] = VecLength(VecSub(a[r].pos, b[r].pos)) * 100, quatAngle(a[r].rot, b[r].rot)
            if dp[r] < PRB.AGREE_CM and dr[r] < PRB.AGREE_DEG and (best == 0 or dp[r] + dr[r] < score - PRB.TIE) then
                best, score = r, dp[r] + dr[r]
            end
        end
        if best ~= 0 then
            for r = 1, 4 do
                if PRB.CLASS[r] ~= PRB.CLASS[best] and dp[r] < PRB.SEP_CM and dr[r] < PRB.SEP_DEG then
                    p.ref, p.L, p.krot, p.result, p.def = 1, b[1], p.res[n].krot, 2, true
                    return
                end
            end
            p.ref, p.L, p.krot, p.result, p.def = best, b[best], p.res[n].krot, 2, false
            return
        end
    end
    if p.runs - p.amb < PRB.RUNS then return end
    for i = n, 1, -1 do
        local last = p.res[i]
        if last.ok then
            p.ref, p.L, p.krot, p.result, p.def = 1, last.L[1], last.krot, 2, true
            return
        end
    end
end

-- tick (placeToolInHand), a reference chosen and attach in use (the probe measured the engine there): F_now = R_now *
-- L_R (R_now predicted by one frame of player movement on a held-base frame for the player-bound references, as the
-- v0.11 placement does for its frames 1-3), O.pos = F_now.rot^-1 * (desired.pos - F_now.pos), O.rot = F_now.rot^-1 *
-- desired.rot * Krot^-1 (the spec's F.rot is the frame's rotation now: it turns with its reference). The engine puts the
-- body at F_now * O * Krot = desired. (Exact for a body origin at the override point; a body offset with a position part
-- cannot be told from the frame's origin by translations alone.) nil: no placement by the probe.
-- v0.14 (docs/V014_PLAN.md section 1): without a probe result (the probe no longer runs) reference 1, toolFrame() - the
-- game's own tool override frame - with L = identity and Krot = identity (F = toolFrame() now); the servo's integrals
-- take up whatever that guess leaves (a frame offset, a body offset). nil only without attach (or, with PRB.V013, the
-- v0.13 wait for a reference).
function probePlace(cam, tw, held, dt)
    local p = probe
    if cal.method ~= 4 then return nil end
    local ref, L, krot = p.ref, p.L, p.krot
    if ref == 0 or not L then
        if PRB.V013 then return nil end
        ref, L, krot = 1, nil, nil
    end
    local R = probeRef(ref, cam)
    if held and ref ~= 3 then R = Transform(VecAdd(R.pos, VecScale(GetPlayerVelocity(), dt)), R.rot) end
    local F = L and TransformToParentTransform(R, L) or R
    local inv = qconj(F.rot)
    local rot = QuatRotateQuat(inv, tw.rot)
    if krot then rot = QuatRotateQuat(rot, qconj(krot)) end
    return Transform(QuatRotateVec(inv, VecSub(tw.pos, F.pos)), rot)
end

-- L6 probe / tool error slots (every tick, writeStatus). v0.13: +100 in L_PROBE_REF for a default choice (probeChoose),
-- then the L7 slots (writeServoStatus).
-- v0.21 (docs/V021_PLAN.md section 9): 237..239 are L_HCOL / L_HCOL_ERR / L_HCOL_EV now (writeDiag21); the probe's
-- L_PROBE_STATE / REF / AXES values are kept in diag.prb only.
function writeProbeStatus()
    local p = probe
    diag.prb.probeState = p.state
    diag.prb.probeRef = p.ref + 10 * p.runs + (p.def and 100 or 0)
    diag.prb.probeAxes = p.axes
    W(L6.TOOL_ERR, median(p.errs))
    -- (v0.22: 242 is L_PUNCH now, writeDiag22)
    -- (v0.15, docs/V015_PLAN.md section 3: the L7 servo slots report the v0.15 placement unless the kept v0.14 servo
    -- runs; the L8 slots always)
    if PRB.V013 or PRB.V014 then writeServoStatus() end
    actWrite(not (PRB.V013 or PRB.V014))
end

-- ---------------------------------------------------------------------------------------------
-- v0.13 visible-offset self-test (docs/V013_PLAN.md section 1)
-- ---------------------------------------------------------------------------------------------
-- The v0.12 headset log: GetToolBody()'s shapes were tagged invisible at every draw, yet a second tool was drawn 40-84 cm
-- right of the camera. script_defs.lua says SetToolOffset / SetToolTransform act on "the visible tool body": the game may
-- draw a separate visible copy of the tool that our tags never reach. The test sends SetToolOffset(0, -50, 0) for TICKS
-- ticks and watches the logical body (GetToolBody, where the effects start): if it went 50 m down with the offset, the
-- offset moves the tool itself and is never used again for this body (state 3: effects would start 50 m below);
-- otherwise only the visible copy moved (state 2), and from then on the offset keeps that copy 50 m below while the
-- replica is shown. Invisible like the probe: it runs only while the replica is shown.

-- SetToolOffset(OFS), guarded; the heartbeat is recorded so that render() sends it again in this frame (the game's own
-- playerbody.lua sets the offset every tick too; whichever script runs last would win, render() runs after all ticks).
-- false: SetToolOffset is missing or failed.
function vofsOffset()
    local v, o = probe.vofs, PRB.VOFS.OFS
    if not SetToolOffset then return false end
    if not pcall(SetToolOffset, Vec(o[1], o[2], o[3])) then return false end
    v.sentAt, v.calls = heartbeat, v.calls + 1
    return true
end

-- No usable answer for this tool body (SetToolOffset or the body's transform unavailable, or ABORTS aborted runs): state
-- 4, the test runs again AGAIN seconds later.
function vofsInconclusive()
    local v = probe.vofs
    if v.phase ~= 0 then vofsSettle() end
    v.phase, v.n, v.state, v.aborts, v.wait = 0, 0, 4, 0, PRB.VOFS.AGAIN
end

-- Deviation (the spec's 10-tick wait assumes an engine that follows at once): a test that sent the offset and did not end
-- in state 2 may have moved the logical body down; with the log's ~25 % per tick it is still metres below 10 ticks
-- later (50 m * 0.75^10 = 2.8 m), so the probe's next run waits RETRY s (a run measuring a returning body chose nothing
-- in two runs in the mock). State 2 needs no wait: the body never moved.
-- v0.13 review LUA13-SERVO-SETTLE: the servo waits as long (settle = RETRY s, counted down in vofsUpdate; servoTarget
-- neither integrates nor fills its window meanwhile): it resumed 10 ticks after the offset stopped, with the body
-- still metres below, wound c up to the 1 m clamp and held the tool up to 1 m off the hand.
function vofsSettle()
    probe.wait = math.max(probe.wait, PRB.RETRY)
    probe.vofs.settle = math.max(probe.vofs.settle, PRB.RETRY)
end

-- A condition broke during the offset ticks: the state from before the run is shown again (0 or 4), the next run RETRY s
-- later; the ABORTS-th abort in a row makes it inconclusive.
function vofsAbort()
    local v = probe.vofs
    vofsSettle()
    v.phase, v.n, v.aborts, v.wait, v.state = 0, 0, v.aborts + 1, PRB.VOFS.RETRY, v.last or 0
    if v.aborts >= PRB.VOFS.ABORTS then vofsInconclusive() end
end

-- The measured result r (2 / 3) becomes the state once the wait is over (or the body changed during it).
function vofsResult(r)
    local v = probe.vofs
    if r ~= 2 then vofsSettle() end
    v.phase, v.n, v.state, v.aborts = 0, 0, r, 0
end

-- The tool body changed (key = the new one; "once per tool body", spec section 1): a run in the offset ticks is aborted
-- for the old body, one already measured keeps its result; the old body's state / aborts / wait go to the cache and the
-- new body's come back from it (a body seen before is not tested again).
function vofsSwitch(key)
    local v = probe.vofs
    if v.phase == 1 then vofsAbort() elseif v.phase == 2 then vofsResult(v.result) end
    if v.key ~= 0 then v.cache[v.key] = { state = v.state, aborts = v.aborts, wait = v.wait } end
    local c = v.cache[key] or { state = 0, aborts = 0, wait = 0 }
    v.key, v.state, v.aborts, v.wait = key, c.state, c.aborts, c.wait
end

-- Every tick from probeUpdate (ok = the probe's start conditions this tick, tb = GetToolBody()). Starts when ok holds, no
-- probe run is in progress, no wait is pending and the body was not tested yet (state 0) or inconclusive (state 4, AGAIN
-- s later): P0 = the body's position, the offset sent this tick and the next TICKS - 1 (tick and render), P1 measured on
-- the TICKS-th. Aborted (vofsAbort) when ok breaks, the body changes or the player moves more than MOVE m. Then WAIT
-- ticks without the offset (the body settles back before a probe may measure it; state 1 still), then the result (not
-- 2: the probe waits RETRY s more, vofsSettle).
-- Decision: |P1 - P0 - OFS| < FOLLOW (the spec's rule) -> 3; deviation, for safety: also 3 when the body went more than
-- FOLLOW m in any direction without reaching it (an engine smoothing more slowly than the log's 25 % per tick, or one
-- applying the offset in a camera / tool frame, v0.13 review LUA13-VOFS-AXIS, would otherwise make a body that follows
-- the offset look like a separate copy, and state 2 would then start every effect 50 m away); else 2. In state 2 the offset is sent every tick (and in render) while the replica is shown.
function vofsUpdate(dt, ok, tb)
    local v, c = probe.vofs, PRB.VOFS
    if tb ~= 0 and tb ~= v.key then vofsSwitch(tb) end
    v.wait = math.max(0, v.wait - dt)
    v.settle = math.max(0, v.settle - dt)            -- (v0.13 review LUA13-SERVO-SETTLE, see vofsSettle)
    if v.phase == 1 then
        local moved = VecLength(VecSub(GetPlayerTransform().pos, v.pp)) > PRB.MOVE
        if not ok or tb ~= v.body or moved then vofsAbort() return end
        v.n = v.n + 1
        if not vofsOffset() then vofsInconclusive() return end
        if v.n < c.TICKS then return end
        local bt = engineCall(GetBodyTransform, v.body)
        if type(bt) ~= "table" or type(bt.pos) ~= "table" or type(bt.pos[3]) ~= "number" then vofsInconclusive() return end
        local o = Vec(c.OFS[1], c.OFS[2], c.OFS[3])
        local d = VecSub(bt.pos, v.p0)
        -- (v0.13 review LUA13-VOFS-AXIS: "followed" by the displacement in any direction, not only along world -Y:
        -- script_defs.lua calls SetToolOffset an offset on the visible tool body, set like SetToolTransform; applied
        -- in the camera or tool frame, a hand pointing down sent the body 50 m sideways, d . down < 5 and |d - o| ~ 70
        -- made it state 2 and every effect then started 50 m away. A still player's hand moves the body well under
        -- FOLLOW m in TICKS ticks; a separate copy leaves d ~ 0.)
        local follow = VecLength(d) > c.FOLLOW or VecLength(VecSub(d, o)) < c.FOLLOW
        v.result, v.phase, v.n = follow and 3 or 2, 2, 0
    elseif v.phase == 2 then
        v.n = v.n + 1
        if v.n >= c.WAIT then vofsResult(v.result) end
    elseif ok and probe.step == 0 and v.wait <= 0 and (v.state == 0 or v.state == 4) then
        local bt = engineCall(GetBodyTransform, tb)
        if not SetToolOffset or type(bt) ~= "table" or type(bt.pos) ~= "table" or type(bt.pos[3]) ~= "number" then
            vofsInconclusive()
            return
        end
        v.last = v.state
        v.phase, v.n, v.body, v.p0, v.pp, v.state = 1, 1, tb, VecCopy(bt.pos), VecCopy(GetPlayerTransform().pos), 1
        if not vofsOffset() then vofsInconclusive() end
    elseif v.state == 2 and replica.shown then
        vofsOffset()
    end
end

-- ---------------------------------------------------------------------------------------------
-- v0.13 engine tool servo (docs/V013_PLAN.md section 2)
-- ---------------------------------------------------------------------------------------------
-- The v0.12 log: the engine moves the tool toward the override by roughly 25 % per tick (an exponential approach), and a
-- probe-measured frame keeps a residual error (the run's own smoothing, a body offset with a position part). Closed loop
-- on the measured body instead: D = the desired transform (toolWorldOf) with a lead of LEAD s on the hand's velocity, M
-- = the engine tool body now (where the engine put it at the end of the previous frame), c += K * e (|c| <= CMAX), and
-- the probe's placement aims at D' = (D.pos + c, D.rot). Still hand, exponential engine: c settles at minus the
-- residual bias; a hand at constant speed: the body on the hand with c covering what the lead does not.
-- v0.13 review LUA13-SERVO-ONE-TICK / SC-1: e = the previous servo tick's desired position (no lead) - M, i.e. the body
-- against the hand pose it was placed (and rendered) for. v0.13 had e = D - M: this tick's target with the lead against
-- the previous frame's body, which drove the body v * (dt + LEAD) ahead of the hand (13 cm at 2 m/s) while L_SERVO_ERR
-- read ~0 and the servo reported locked; and with an engine smoothing in the player's frame the world-velocity lead
-- (walking, falling, turning) left the tool 15-20 cm off the hand, also "locked". The lead is now feed-forward only.

-- c and the window start over: a new tool body, reference or measured frame (servoTarget), or the servo off (body 0).
-- (v0.13 review: also the self-test hold and the engine-tool latch.)
-- (v0.14, docs/V014_PLAN.md section 1: also the tool switched - the replica is the tool seen until the new tool's servo
-- has caught up - and the rotation servo with it.)
function servoReset(tb)
    local sv, p = probe.servo, probe
    sv.c, sv.body, sv.ref, sv.L, sv.errs, sv.far, sv.prev, sv.recent = Vec(0, 0, 0), tb, p.ref, p.L, {}, 0, nil, 0
    sv.held, sv.engine, sv.high = false, false, 0
    sv.key, sv.cw, sv.prevRot, sv.rerrs = p.key, Vec(0, 0, 0), nil, {}
    sv.stall, sv.freeze = 0, 0                     -- (v0.14 review LUA14-SERVO-WINDUP / LUA14-SERVO-JUMP-INTEGRAL)
end

-- v0.14 (docs/V014_PLAN.md section 1): the rotation error q_e = a * conj(b) (world) as w = axis * angle (radians, the
-- shorter way: q and -q are the same rotation) and its angle in degrees.
function servoRotErr(a, b)
    local q = QuatRotateQuat(a, qconj(b))
    local x, y, z, w = q[1], q[2], q[3], q[4]
    if w < 0 then x, y, z, w = -x, -y, -z, -w end
    local s = math.sqrt(x * x + y * y + z * z)
    if s < 1e-9 then return Vec(0, 0, 0), 0 end
    local ang = 2 * math.atan2(s, w)
    return Vec(x * ang / s, y * ang / s, z * ang / s), math.deg(ang)
end

-- placeToolInHand, every tick that places (tw = the desired transform, dt = this tick's): the target the probe's
-- placement puts the body at, D' (above); tw itself while no reference is chosen, attach is not in use or there is no
-- tool body (then the probe does not place anyway; v0.13 review LUA13-SERVO-STALE-LOCK: a live servo is dropped right
-- there, so writeServoStatus reports it off in this tick: it stayed "locked" from its old window for IDLE ticks and
-- kept the engine tool shown at the v0.11 placement). The velocity is the desired position's change since the previous
-- tick's servo tick; above VMAX m/s it is a pose jump (a teleport, a tracking glitch), no lead then. The integral and the
-- window (errs: |e| in cm, L_SERVO_ERR / the locked test) need the previous tick's desired position (the first servo
-- tick has none) and skip the ticks of the visible-offset self-test and its settle wait (the offset may have moved the
-- body 50 m down; v0.13 review LUA13-SERVO-SETTLE: the settle wait too, and the window is emptied meanwhile, so the
-- engine tool is not shown on an old lock; deviation from the review's "servoReset after it": c is kept, it was frozen
-- (never wound up) during the wait and is still this body's correction, a reset would re-learn its bias with a
-- transient). Errors above DIV m for DIV_T s: c reset, "diverged recently" for RECENT s (counted in diverged).
-- v0.14 (docs/V014_PLAN.md section 1): no longer gated on a probe reference (the probe never runs): the servo runs
-- whenever attach is in use on foot with VR active, a tool body and the hand tracked (placeToolInHand's own conditions),
-- placing against reference 1 with identity L / Krot unless a probe result exists (probePlace); PRB.V013 restores the
-- v0.13 wait for the kept probe's tests. A tool switch (the probe's key, the tool name) resets it like a new body. NEW
-- rotation servo, the position servo's twin: q_e = Dprev.rot * conj(M.rot) (world; the previous servo tick's desired
-- rotation against the body placed for it), w = axis * angle (the shorter way), cw += KROT * w (|cw| <= CWMAX deg), the
-- target rotation QuatAxisAngle(cw) * D.rot; its angle goes into rerrs (L_SERVO_ROTERR, the shown latch). No lead on the
-- rotation (the spec's lead is a position feed-forward; with the engine's smoothing cw settles at what the lag needs).
-- cw is reset with c (servoReset: new body, tool, reference, divergence, servo off).
-- v0.14 review SPECX-1: the lead is LEAD_TICKS * dt s (dt capped at LEAD_DT; the lag of a per-tick smoothing at this
-- tick rate, see PRB), and the rotation gets it too: the desired rotation's per-tick world turn (prevRot -> tw.rot, below
-- 90 deg) scaled to the lead, applied before cw (the deviation from "no lead on the rotation" above). v0.14 review
-- LUA14-SERVO-JUMP-INTEGRAL: a pose jump (the test that drops the lead) freezes c / cw and the windows for FREEZE ticks
-- (the engine's catch-up on the following ticks is no bias; the integral took it as one and overshot ~50 cm), empties the
-- windows (the old lock must not latch the engine tool again) and drops the engine latch at once (the far-off engine
-- tool is not the only tool seen). v0.14 review LUA14-SERVO-WINDUP: c or cw at its clamp with the error above UNLOCK cm
-- for DIV_T s is a stall (the engine does not follow; the DIV test cannot see a body within ~1.5 m) and resets like a
-- divergence (state 3, counted in diverged).
function servoTarget(tw, dt)
    local p, sv, c = probe, probe.servo, PRB.SERVO
    local tb = GetToolBody()
    if cal.method ~= 4 or tb == 0 or (PRB.V013 and (p.ref == 0 or not p.L)) then
        if sv.body ~= 0 then servoReset(0) end
        sv.at = -1
        return tw
    end
    if tb ~= sv.body or p.ref ~= sv.ref or p.L ~= sv.L or p.key ~= sv.key then servoReset(tb) end
    local hold = p.vofs.phase > 0 or p.vofs.settle > 0
    if hold then
        sv.held, sv.errs, sv.rerrs, sv.far, sv.engine, sv.high = true, {}, {}, 0, false, 0
    else
        sv.held = false
    end
    local v, last = nil, (sv.prev and sv.at == heartbeat - 1) and sv.prev or nil
    local lastRot = last and sv.prevRot or nil
    if last and dt > 0 then
        v = VecScale(VecSub(tw.pos, last), 1 / dt)
        if VecLength(v) > c.VMAX then
            -- (v0.14 review LUA14-SERVO-JUMP-INTEGRAL: a pose jump - freeze, empty windows, the latch off at once)
            v = nil
            sv.freeze, sv.errs, sv.rerrs, sv.engine, sv.high, sv.stall = c.FREEZE, {}, {}, false, 0, 0
        end
    end
    sv.prev, sv.prevRot, sv.at = VecCopy(tw.pos), Quat(tw.rot[1], tw.rot[2], tw.rot[3], tw.rot[4]), heartbeat
    sv.recent = math.max(0, sv.recent - dt)
    local lead = c.LEAD_TICKS * math.min(math.max(dt, 0), c.LEAD_DT)   -- (v0.14 review SPECX-1: per tick, not 0.05 s)
    local D = v and VecAdd(tw.pos, VecScale(v, lead)) or VecCopy(tw.pos)
    local frozen = (sv.freeze or 0) > 0
    if frozen then sv.freeze = sv.freeze - 1 end
    local bt = (last and not hold) and engineCall(GetBodyTransform, tb) or nil
    if type(bt) == "table" and type(bt.pos) == "table" and type(bt.pos[3]) == "number" then
        local e = VecSub(last, bt.pos)
        local el = VecLength(e)
        if not frozen then
            push(sv.errs, el * 100, PRB.N)
            sv.c = VecAdd(sv.c, VecScale(e, c.K))
            local cl = VecLength(sv.c)
            if cl > c.CMAX then sv.c = VecScale(sv.c, c.CMAX / cl) end
        end
        if not frozen and lastRot and type(bt.rot) == "table" and type(bt.rot[4]) == "number" then
            local w, deg = servoRotErr(lastRot, bt.rot)
            push(sv.rerrs, deg, PRB.N)
            sv.cw = VecAdd(sv.cw, VecScale(w, c.KROT))
            local wl, wmax = VecLength(sv.cw), math.rad(c.CWMAX)
            if wl > wmax then sv.cw = VecScale(sv.cw, wmax / wl) end
        end
        -- (v0.14 review LUA14-SERVO-WINDUP: an integral at its clamp with the error still above UNLOCK cm is a stall)
        if not frozen and (VecLength(sv.c) >= c.CMAX * 0.99 or VecLength(sv.cw) >= math.rad(c.CWMAX) * 0.99)
            and el > c.UNLOCK / 100 then
            sv.stall = (sv.stall or 0) + dt
        else
            sv.stall = 0
        end
        if el > c.DIV then sv.far = sv.far + dt else sv.far = 0 end
        if sv.far >= c.DIV_T or sv.stall >= c.DIV_T then
            servoReset(tb)
            sv.prev, sv.recent, sv.diverged = VecCopy(tw.pos), c.RECENT, sv.diverged + 1
            sv.prevRot = Quat(tw.rot[1], tw.rot[2], tw.rot[3], tw.rot[4])
        end
    end
    local rot, wl = tw.rot, VecLength(sv.cw)
    if v and lastRot and dt > 0 then
        -- (v0.14 review SPECX-1: the rotation's lead, the per-tick world turn scaled to the lead)
        local wv = servoRotErr(tw.rot, lastRot)
        local wvl = VecLength(wv)
        if wvl > 1e-9 and wvl < math.rad(90) then
            rot = QuatRotateQuat(QuatAxisAngle(VecScale(wv, 1 / wvl), math.deg(wvl * lead / dt)), rot)
        end
    end
    if wl > 1e-9 then rot = QuatRotateQuat(QuatAxisAngle(VecScale(sv.cw, 1 / wl), math.deg(wl)), rot) end
    return Transform(VecAdd(D, sv.c), rot)
end

-- L7 slots (every tick, writeProbeStatus). The servo is off (0; c and the window dropped) once IDLE ticks passed without
-- a servo tick; else 2 locked (a full window of N ticks with a median below LOCK cm), 3 a divergence within RECENT s, 1
-- converging. v0.13 review SC-3 / LUA13-SHOWN-HYST: L_SERVO_STATE keeps the spec's meaning; the engine-tool decision
-- (sv.engine, what updateToolReplica's rule reads next tick) is latched: on when locked, off when the servo is off or
-- diverged, or after UNLOCK_N ticks in a row with the median above UNLOCK cm (a median wandering around LOCK no longer
-- swaps the replica and the engine tool every few ticks).
-- v0.14 (docs/V014_PLAN.md section 1, the shown rule; the engine tool body IS the visible tool and cannot be hidden):
-- the latch goes on when a full window's medians are below SHOW_CM cm AND SHOW_DEG deg (L_SERVO_STATE's 4 cm lock is
-- not needed: 6 cm on the hand is the engine tool in the hand), off when the position median is above UNLOCK cm for
-- UNLOCK_N ticks in a row, the servo is off or diverged (state 3). L_VOFS_STATE is the fixed 3 (the self-test no longer
-- runs; the kept test's own state only with PRB.V013), L_SERVO_ROTERR the rotation median (-1 none).
function writeServoStatus()
    local sv, v, c = probe.servo, probe.vofs, PRB.SERVO
    local live = sv.at >= 0 and heartbeat - sv.at < c.IDLE
    if not live and sv.body ~= 0 then servoReset(0) end
    local med = live and median(sv.errs) or -1
    local rmed = live and median(sv.rerrs) or -1
    local full = live and #sv.errs >= PRB.N
    local locked = full and med < c.LOCK
    sv.state = (not live) and 0 or (locked and 2 or (sv.recent > 0 and 3 or 1))
    sv.high = (live and med > c.UNLOCK) and sv.high + 1 or 0
    if sv.state == 0 or sv.state == 3 or sv.high >= c.UNLOCK_N then
        sv.engine = false
    elseif full and med < c.SHOW_CM and #sv.rerrs >= PRB.N and rmed < c.SHOW_DEG then
        sv.engine = true
    end
    diag.prb.vofsState = PRB.V013 and v.state or 3   -- (v0.21: 243 is L_BODY_VIS, the old value kept in diag.prb)
    W(L7.SERVO_STATE, sv.state)
    W(L7.SERVO_ERR, med)
    W(L7.TOOL_SHOWN, sv.shown and 1 or 0)
    W(L7.SERVO_ROTERR, rmed)
end

-- ---------------------------------------------------------------------------------------------
-- v0.15 actuator test and placement (docs/V015_PLAN.md sections 1-3)
-- ---------------------------------------------------------------------------------------------
-- The v0.14 headset log: the servo never converged (40-70 cm, 15-67 deg, "diverged" most of the time); with the v0.12
-- probe and v0.3-v0.11 that makes SetToolTransformOverride from our legacy global script NOT reliably honored for the
-- built-in tools. The visible second tool (the engine tool body, GetToolBody) sits at the engine's own first-person pose
-- relative to the player (the "base"; it followed the player's yaw when our aim teleports turned the player).
-- script_defs.lua documents two more calls on the visible tool body: SetToolTransform(transform, sway) ("additional
-- transform", toolanimation.lua's tool animations) and SetToolOffset ("additional offset"; the v0.13 self-test saw it move
-- the body > 5 m). Which one works from our script is measured per tool (actUpdate / actTrial: a 0.4 m pulse along X
-- and the body's response) and then used to put the body on the hand (actPlace / actSend). The game's playerbody.lua
-- calls SetToolOffset every tick and the last call of a frame may win, so every call is made in tick AND again in
-- render() (which runs after every script's tick, actRender).

-- q as a unit quaternion (identity for a degenerate one). The base estimate feeds back (base = M * T_prev^-1, T = base^-1
-- * D, M = base * T next frame): the conjugate is the inverse only of a unit quaternion, so rounding grew without it
-- (NaN after ~90 ticks in the mock, like stripOffset's P2).
function quatUnit(q)
    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if not (l > 1e-9) then return Quat() end
    return Quat(q[1] / l, q[2] / l, q[3] / l, q[4] / l)
end

-- The placement starts over (c, windows, latch, what was sent): a new tool or tool body, a new actuator, or idle.
-- (sentAt is kept: the next sample still knows whether its frame had a call of ours.)
function actPlaceReset()
    local a = probe.act
    a.c, a.errs, a.rerrs, a.engine, a.high = Vec(0, 0, 0), {}, {}, false, 0
    a.sentT, a.sentW, a.dPrev, a.prevTw, a.prevAt, a.lead, a.base, a.at = nil, nil, nil, nil, -1, nil, nil, -1
    a.baseL, a.sentP, a.good, a.clampN = nil, nil, false, 0
    -- (v0.17, docs/V017_PLAN.md section 1: "a tool switch / respawn resets" the base EMA; R starts again from identity
    -- (the self-check's state, rc, belongs to the tool and stays); the jitter window starts over)
    a.bL, a.rejT, a.bN, a.R, a.sentO, a.sentR, a.prevE, a.eAt, a.jit = nil, 0, 0, nil, nil, nil, nil, -1, {}
    -- (v0.17 review LUA17-RESIDUAL-WALK-BIAS / V17-RESIDUAL-TICK-VS-POSTPHYSICS and V17-JITTER-NOT-BODY-MINUS-HAND: the
    -- target and the hand of the last call in the player-camera frame, hPrev the hand as dPrev's partner)
    a.dL, a.hL, a.hPrev = nil, nil, nil
    -- (v0.17 review LUA17-PIVOT-LAG-UNTESTED: the pivot estimate belongs to the tool body, pivotLearn17)
    a.pv, a.pvS, a.pvN, a.pvV = nil, nil, nil, nil
    -- (v0.18, docs/V018_PLAN.md section 2: a pending score belongs to the last call; the EMAs and the choice describe
    -- the engine's timing, not the tool, and stay)
    a.tp, a.tpRB = nil, nil
    -- (v0.18 review LUA18-PRESS-ROT-LURCH: R's base rotation goes with R; LUA18-2B-RESIDUAL-NOT-HANDLE /
    -- V18-SPEC-2B-RESIDUAL-NOT-HANDLE: the grip and handle of the last call, the body-origin window)
    a.Rq, a.gL, a.gPrev, a.rhS, a.berrs = nil, nil, nil, nil, {}
    a.sentW2, a.sentW4 = nil, nil                   -- (v0.19 review V19-PARK-FRAME4-BOOKKEEPING: the park's two frames)
end

-- v0.15 review LUA15-ACT-FRAME-AMBIGUOUS / V15-FRAME-AMBIG: the safety net (actWrite) - a decided actuator 2 that does not
-- converge (a wrong frame cached: the loop's error map is -(R - I), divergent above 60 deg between the true and the
-- chosen frame) is dropped from the cache and its offset pulse tested again (deviation: pulse 2 only, as V15-FRAME-
-- AMBIG; the transform pulse's failed trials are kept); NETS such retests without the engine tool shown -> actuator 0
-- (retried after RETRY s, as a failed pulse).
function actRetest()
    local a, c = probe.act, PRB.ACT
    a.cache[a.key] = nil
    a.nets = a.nets + 1
    if a.nets >= c.NETS then
        a.a, a.f, a.st, a.retry, a.nets = 0, 0, 2, c.RETRY, 0
    else
        a.a, a.f, a.st, a.pulse, a.votes, a.angs, a.inconc = 0, 0, 0, 2, { {}, {} }, { {}, {} }, 0
        a.tr[2] = 0
    end
    actPlaceReset()
end

-- v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: the guard without pulses (actWrite, without PRB.V015) - the placement did not
-- converge (the position median above UNLOCK cm for RETEST placing ticks in a row, or |o| at TMAX for CLAMP_N). The
-- section 0 evidence (X pulses) fits the yaw frame and the player's yaw+pitch frame alike (pitch turns about X); with
-- the wrong one the loop's error map is -(R - I), R the pitch, divergent above ~50-60 deg. So: in the yaw frame at
-- |pitch| >= PITCH deg (below it both frames nearly coincide and the other one cannot help) the yaw+pitch frame (4) is
-- tried; otherwise, or when that did not converge either, back to the yaw frame and no SetToolOffset for RETRY s (st 3:
-- actCanRun false - the replica shown, precise aim no longer forced; L_ACT 322). A tool switch ends the hold (actSwitch).
function actHold()
    local a, c = probe.act, PRB.ACT
    if (a.vf or 2) == 2 and not a.tried4 and math.abs(GetPlayerPitch()) >= c.PITCH then
        a.vf, a.tried4 = 4, true
    else
        a.vf, a.tried4, a.hold = 2, false, c.RETRY
    end
    a.f, a.st = a.vf, (a.hold > 0) and 3 or 2
    actPlaceReset()
end

-- The selected tool (name) changed (key = the new one; section 1: "cached per tool name"): a decided result goes to the
-- cache, the incoming tool's comes back from it (placed at once, no new test; an actuator 0 keeps its retry time) or the
-- tool starts idle. A trial in its pulse ticks is dropped (not counted), its quiet ticks still run (the body may be
-- displaced).
function actSwitch(key)
    local a = probe.act
    if a.key ~= "" and a.st == 2 then
        a.cache[a.key] = { a = a.a, f = a.f, retry = a.retry, tr = { a.tr[1], a.tr[2] }, code = { a.code[1], a.code[2] } }
    end
    local c = a.cache[key]
    a.key, a.pulse, a.votes, a.angs = key, 1, { {}, {} }, { {}, {} }
    a.inconc, a.wait, a.nets = 0, 0, 0                      -- (v0.15 review: per tool)
    a.hold = 0                                              -- (v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: per tool)
    if a.phase == 1 then a.phase, a.n = 2, 0 end
    if c then
        a.a, a.f, a.st, a.retry, a.tr, a.code = c.a, c.f, 2, c.retry, { c.tr[1], c.tr[2] }, { c.code[1], c.code[2] }
    else
        a.a, a.f, a.st, a.retry, a.tr, a.code = 0, 0, 0, 0, { 0, 0 }, { -1, -1 }
    end
    rcSwitch17(key)
    actPlaceReset()
end

-- v0.17 (docs/V017_PLAN.md section 3): the rotation control's self-check is per tool name. A decided tool (3 kept / 4
-- rejected) is in rcCache since its decision and comes back from it; any other starts at 0 (none yet: its off window
-- starts with its first placing tick). A test whose windows were still running is dropped - not counted, run again
-- from its off window when that tool is selected next ("while a window runs nothing else changes": a window holds one
-- tool only).
function rcSwitch17(key)
    local a = probe.act
    local d = a.rcCache[key]
    a.rc = { st = d and d.st or 0, t = 0, offP = {}, offR = {}, onP = {}, onR = {}, ab = d and d.ab or -1 }
end

-- v0.17 (docs/V017_PLAN.md section 3): "re-test a kept tool after a respawn / quickload only" - a quickload re-runs this
-- file (nothing cached survives); a respawn (a tick with the player dead, LF_DEAD) drops every KEPT tool from the cache
-- (a rejected one stays rejected), and the current tool, if kept, starts its test again. The base EMA is reset too.
function rcRespawn17()
    local a = probe.act
    for k, d in pairs(a.rcCache) do
        if d.st == 3 then
            a.rcCache[k] = nil
            a.rcN = math.max(a.rcN - 1, 0)
        end
    end
    if a.rc.st == 3 then rcSwitch17(a.key) end
    actPlaceReset()
end

-- This tick's sample of the tool body tb (where the engine put it at the end of the last frame) into hist, the last 5 of
-- consecutive ticks (a gap or another body starts it over). clean = that frame had no call of ours on the body (no pulse,
-- no placement). nil: no transform.
function actSample(tb)
    local a = probe.act
    local bt = engineCall(GetBodyTransform, tb)
    if type(bt) ~= "table" or type(bt.pos) ~= "table" or type(bt.pos[3]) ~= "number" or type(bt.rot) ~= "table"
        or type(bt.rot[4]) ~= "number" then
        a.hist = {}
        return nil
    end
    local h = a.hist
    local last = h[#h]
    if last and (last.hb ~= heartbeat - 1 or last.body ~= tb) then
        h = {}
        a.hist = h
    end
    local s = { hb = heartbeat, t = a.clock, pos = VecCopy(bt.pos), rot = quatUnit(bt.rot),
                body = tb, clean = a.pulsedAt ~= heartbeat - 1 and a.sentAt ~= heartbeat - 1 }
    h[#h + 1] = s
    if #h > 5 then table.remove(h, 1) end
    return s
end

-- Pulse p, guarded: 1 SetToolTransform(Transform(Vec(PULSE, 0, 0)), 0) (sway 0: "set to zero to disable"), 2
-- SetToolOffset(Vec(PULSE, 0, 0)). false when the function is missing or fails; else the heartbeat and the pulse are
-- recorded (render() sends it again in this frame).
function actPulse(p)
    local d = PRB.ACT.PULSE
    local ok
    if p == 1 then ok = SetToolTransform ~= nil and pcall(SetToolTransform, Transform(Vec(d, 0, 0)), 0)
    else ok = SetToolOffset ~= nil and pcall(SetToolOffset, Vec(d, 0, 0)) end
    if ok then probe.act.pulsedAt, probe.act.pulsedP = heartbeat, p end
    return ok
end

-- Pulse p failed (TRIALS trials without WIN matching, or its function is missing): pulse 1 -> pulse 2 is tested next;
-- pulse 2 -> actuator 0 (the replica only, as v0.13), tested again RETRY s later.
function actFail(p)
    local a = probe.act
    if p == 1 then a.pulse = 2 else a.a, a.f, a.st, a.retry = 0, 0, 2, PRB.ACT.RETRY end
end

-- Actuator 2's frame f as a rotation: 1 world (identity), 2 the player's yaw (GetPlayerTransform().rot), 3 the camera
-- (cam: the camera this call's frame is rendered with; draw's probe.rc or GetCameraTransform() without one), 4 (v0.16
-- review LUA16-FRAME-PITCH-NO-FALLBACK, without PRB.V015 only) the player's yaw and pitch (actHold tries it).
function actFrameRot(f, cam)
    if f == 2 then return GetPlayerTransform().rot end
    if f == 4 then return yawPitchRot(GetPlayerYaw(), GetPlayerPitch()) end
    if f == 3 then
        local c = cam or probe.rc or GetCameraTransform()
        return c.rot
    end
    return Quat()
end

-- v0.15 review LUA15-ACT-FRAME-AMBIGUOUS: the X axes of the three offset frames now lie pairwise SEP deg or more apart
-- (an offset trial starts only then: an X pulse cannot tell coinciding frames apart - world and yaw at yaw ~0, yaw and
-- camera when the head looks along the aim, whatever its pitch, a rotation about X).
function actFramesApart()
    local x = {}
    for f = 1, 3 do x[f] = QuatRotateVec(actFrameRot(f), Vec(1, 0, 0)) end
    for i = 1, 2 do
        for j = i + 1, 3 do
            if math.deg(math.acos(clamp(VecDot(x[i], x[j]), -1, 1))) < PRB.ACT.SEP then return false end
        end
    end
    return true
end

-- A trial's end (s1 = B1, the sample of the tick after the pulse's TICKS-th: TICKS pulsed frames, v0.15 review
-- LUA15-ACT-B1-OFFBYONE): the response r = B1 - B0 minus the base motion over
-- those ticks (the velocity of the clean samples before the pulse, actUpdate, times the time between B0 and B1). The
-- expected axes: pulse 1 the body's local X, pulse 2 world X, the player-yaw X and the render camera's X (frames 1..3).
-- Deviation: the axes are taken at B1 (the frame the response was made in; draw's camera of that frame, probe.rc, the
-- player yaw of the last pulse tick, yawAt - v0.15 review LUA15-ACT-B1-OFFBYONE moved B1 one tick later), not
-- at B0 - the same for a still player, closer while turning. A frame matches with an angle below ANG and a length LMIN..
-- LMAX; the trial votes for the best frame only, when it is separated (v0.15 review, see SEP). A frame with WIN votes
-- works (several: the smallest summed angle) ->
-- actuator p (2: in that frame), decided; TRIALS trials without one -> the pulse fails (actFail). L_ACT_T1 / T2 = round(
-- |r| cm) * 1000 + the best angle (capped 999).
function actTrial(s1)
    local a, c = probe.act, PRB.ACT
    local p = a.pulse
    local r = VecSub(VecSub(s1.pos, a.b0.pos), VecScale(a.v, s1.t - a.b0.t))
    local len = VecLength(r)
    local axes = { QuatRotateVec(s1.rot, Vec(1, 0, 0)) }
    if p == 2 then
        axes = { Vec(1, 0, 0), QuatRotateVec(a.yawAt or actFrameRot(2), Vec(1, 0, 0)),
                 QuatRotateVec(actFrameRot(3), Vec(1, 0, 0)) }
    end
    local best, fb, ang = 180, 1, {}
    for f = 1, #axes do
        ang[f] = 180
        if len > 1e-6 then ang[f] = math.deg(math.acos(clamp(VecDot(r, axes[f]) / len, -1, 1))) end
        if ang[f] < best then best, fb = ang[f], f end
    end
    a.code[p] = math.floor(len * 100 + 0.5) * 1000 + math.min(math.floor(best + 0.5), 999)
    local match = best < c.ANG and len >= c.LMIN and len <= c.LMAX
    -- v0.15 review LUA15-ACT-FRAME-AMBIGUOUS / V15-FRAME-AMBIG: only the best frame fb votes, and only when every other
    -- frame lies SEP deg further off; a matching response with another frame within SEP of the best is inconclusive (not
    -- counted, no vote: wait for a pose where the axes separate; INCONC in a row -> PAUSE s without trials). (Before:
    -- every frame within ANG voted, a tie went to noise and the wrong frame was cached for good.) A response matching
    -- nothing still counts as a failed trial.
    if match then
        for f = 1, #axes do
            if f ~= fb and ang[f] - best < c.SEP then
                a.inconc = a.inconc + 1
                if a.inconc >= c.INCONC then a.inconc, a.wait = 0, c.PAUSE end
                return
            end
        end
        a.votes[p][fb] = (a.votes[p][fb] or 0) + 1
        a.angs[p][fb] = (a.angs[p][fb] or 0) + best
    end
    a.inconc = 0
    a.tr[p] = a.tr[p] + 1
    local win = nil
    for f = 1, #axes do
        if (a.votes[p][f] or 0) >= c.WIN and (not win or a.angs[p][f] < a.angs[p][win]) then win = f end
    end
    if win then
        a.a, a.f, a.st = p, (p == 2) and win or 0, 2
    elseif a.tr[p] >= c.TRIALS then
        actFail(p)
    end
end

-- v0.16 (docs/V016_PLAN.md section 1): whether the offset placement can run this tick - the conditions under which
-- placeToolInHand reaches actPlace: VR active on foot, attach in use (cal.method 4), hand aim, the main hand's grip and
-- aim tracked, not the A/B-test NO_TOOL bit, and a tool body (tb). Read at the start of the tick (updateToolReplica
-- hides the replica at once, before the first placing call: the engine tool is the one in the hand; preciseAim makes
-- the aim follow the hand), so a change within the tick (attach failing in updateCameraMode) shows from the next tick.
function actCanRun(flags, tb)
    -- (v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: not while held off after a placement that did not converge, actHold)
    if not active or tb == 0 or hasBit(flags, LF_VEHICLE) or cal.method ~= 4 or nat.aimMode ~= 1 or not ctl
        or hasBit(nat.perf, PF.NO_TOOL) or (probe.act.hold or 0) > 0 then
        return false
    end
    local lh = nat.leftHanded == 1
    return hasBit(ctl.hv, lh and 1 or 4) and hasBit(ctl.hv, lh and 2 or 8)
end

-- v0.19 (docs/V019_PLAN.md section 1): every tick, before updateToolReplica decides who is seen - the "in use" timer:
-- the main trigger at P19.USE (0.15, touched: before the 0.55 click, so the engine tool is at the hand when the shot
-- fires) or usetool down sets it to P19.TAIL, else it counts down (in use while > 0: until 0.3 s after both end). Only
-- while VR is active. m19 starts each tick at 0 (the v0.18 flow); updateToolReplica sets it for a tool with a replica
-- (mode19).
function use19(dt)
    local a, p = probe.act, PRB.P19
    a.m19 = 0
    local lh = nat.leftHanded == 1
    local trig = ctl and (lh and ctl.ltrig or ctl.rtrig) or 0
    local down = active and (trig >= p.USE or (InputDown ~= nil and InputDown("usetool") == true))
    if down then a.u19 = p.TAIL else a.u19 = math.max((a.u19 or 0) - math.max(dt or 0, 0), 0) end
end

-- Every tick (after probeUpdate, before updateActive). Keeps the tool key (actSwitch) and this tick's body sample. The
-- test (section 1) runs while no actuator is decided (or RETRY s after actuator 0) when: VR active on foot, attach in use
-- (cal.method and the last camera 4), a tool selected with a tool body, the main trigger AND grip released (below TRIG)
-- for REL s, not grabbing (the engine grab or a physical hand holding) - no stillness needed (and not while the A/B test
-- skips the tool work, PF.NO_TOOL: the pulses move the visible tool). A trial starts once the last 4 samples (3 tick
-- intervals) are clean: B0 = this tick's sample, the base velocity v = their displacement over their time (linear
-- extrapolation of the base motion); the pulse is sent this tick and the next TICKS - 1 (tick and render), B1 is the
-- sample of the tick after the TICKS-th (actTrial; v0.15 review LUA15-ACT-B1-OFFBYONE), then QUIET ticks without a
-- pulse; the next trial no sooner than SETTLE ticks after the last pulse. Only in hand-aim mode (v0.15 review
-- V15-AIMMODE-GATE: in head aim nothing places the engine tool, the pulses would only make the seen tool jump). A
-- condition breaking during the pulse ticks drops the trial (not counted; its quiet ticks still run). Pulse 1 is tested
-- until decided, then pulse 2.
-- Nothing runs with PRB.V014 / V013 (the kept v0.14 servo places instead).
-- v0.16 (docs/V016_PLAN.md section 1; the v0.15 log: SetToolOffset answered in the player-yaw frame for every tool,
-- SetToolTransform inconsistently, and the pulses were seen): the test runs only with PRB.V015 (its tests). Otherwise the
-- actuator is fixed - 2 in the yaw frame, decided (L_ACT 222) for every tool, no pulse ever - and run = actCanRun.
function actUpdate(dt, flags)
    local a, c = probe.act, PRB.ACT
    a.clock = a.clock + math.max(dt or 0, 0)
    local tb = GetToolBody()
    local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
    local named = tool ~= "" and tool ~= "none"
    local key = (tb ~= 0 and named) and tostring(tool) or a.key
    if key ~= a.key then actSwitch(key) end
    if tb ~= a.body then
        a.body = tb
        if a.phase == 1 then a.phase, a.n = 2, 0 end
        actPlaceReset()
    end
    local s = nil
    if tb ~= 0 then s = actSample(tb) else a.hist = {} end
    local lh = nat.leftHanded == 1
    local trig = ctl and (lh and ctl.ltrig or ctl.rtrig) or 1
    local sq = ctl and (lh and ctl.lsq or ctl.rsq) or 1
    if trig < PRB.TRIG and sq < PRB.TRIG then a.rel = a.rel + dt else a.rel = 0 end
    a.run = false
    -- (v0.16: the kept v0.13 / v0.14 paths place without an actuator - none, idle, as they had in v0.15)
    if PRB.V013 or PRB.V014 then
        if not PRB.V015 then a.a, a.f, a.st = 0, 0, 0 end
        return
    end
    if not PRB.V015 then
        -- (v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: the frame in use, vf - 2, or 4 after the yaw frame diverged at a
        -- steep pitch; st 3 while held off, actHold - nothing placed, the replica shown, L_ACT 322)
        a.hold = math.max((a.hold or 0) - math.max(dt or 0, 0), 0)
        a.a, a.f, a.st, a.phase, a.n = 2, a.vf or 2, (a.hold > 0) and 3 or 2, 0, 0
        a.run = actCanRun(flags, tb)
        -- (v0.17, docs/V017_PLAN.md sections 1 / 3: a respawn resets the base EMA and re-tests the kept tools)
        if not PRB.V016 and hasBit(flags, LF_DEAD) then rcRespawn17() end
        return
    end
    a.wait = math.max(a.wait - math.max(dt or 0, 0), 0)
    if a.st == 2 and a.a == 0 then
        a.retry = a.retry - dt
        if a.retry <= 0 then
            a.st, a.pulse, a.tr, a.votes, a.angs = 1, 1, { 0, 0 }, { {}, {} }, { {}, {} }
        end
    end
    local ok = active and not hasBit(flags, LF_VEHICLE) and cal.method == 4 and cal.used == 4 and tb ~= 0 and named
        and s ~= nil and a.rel >= c.REL and GetPlayerGrabBody() == 0 and not phys.l.hold and not phys.r.hold
        and not hasBit(nat.perf, PF.NO_TOOL) and nat.aimMode == 1   -- (v0.15 review V15-AIMMODE-GATE)
    if a.phase == 1 then
        if not ok then
            a.phase, a.n = 2, 0
            return
        end
        a.n = a.n + 1
        -- v0.15 review LUA15-ACT-B1-OFFBYONE / V15-TRIAL-FRAMES: pulsed in n = 1..TICKS; B1 is the next tick's sample
        -- (a sample shows the frame before it: TICKS pulsed frames; before, B1 was taken in the TICKS-th pulse tick,
        -- 3 pulsed frames, and the 4th pulse went unmeasured into the quiet ticks)
        if a.n > c.TICKS then
            actTrial(s)
            a.phase, a.n = 2, 0
        elseif not actPulse(a.pulse) then
            actFail(a.pulse)
            a.phase, a.n = 2, 0
            return
        elseif a.n == c.TICKS then
            -- (the player yaw of the last pulsed frame, the one B1 shows - B1's tick has the next one already; the
            -- camera, probe.rc, is that frame's draw camera then)
            a.yawAt = GetPlayerTransform().rot
        end
    elseif a.phase == 2 then
        a.n = a.n + 1
        if a.n >= c.QUIET then a.phase, a.n = 0, 0 end
    -- (v0.15 review LUA15-ACT-B1-OFFBYONE / V15-TRIAL-FRAMES: SETTLE ticks after the last pulse - the 4 velocity samples
    -- not from a body still easing back; V15-FRAME-AMBIG: not while paused after INCONC inconclusive trials)
    elseif ok and a.st ~= 2 and #a.hist >= 4 and (heartbeat - a.pulsedAt > c.SETTLE or heartbeat < a.pulsedAt)
        and a.wait <= 0 then
        local h = a.hist
        for i = #h - 3, #h do
            if not h[i].clean then return end
        end
        if a.pulse == 2 and not actFramesApart() then return end
        local o = h[#h - 3]
        a.st, a.b0, a.v, a.yawAt = 1, s, Vec(0, 0, 0), nil
        if s.t > o.t then a.v = VecScale(VecSub(s.pos, o.pos), 1 / (s.t - o.t)) end
        a.phase, a.n = 1, 1
        if not actPulse(a.pulse) then
            actFail(a.pulse)
            a.phase, a.n = 2, 0
        end
    end
end

-- The player-camera frame the engine's first-person tool pose follows (section 0: it followed the player's yaw): the
-- model eye (attachEye; the engine eye without attach) with the player's yaw and pitch. L_BASE_P's frame.
function actPlayerFrame()
    return Transform(attachEye() or GetPlayerEyeTransform().pos, yawPitchRot(GetPlayerYaw(), GetPlayerPitch()))
end

-- tick, from placeToolInHand (attach in use, the hand tracked; tw = the desired transform, cam = this tick's camera).
-- Only with a decided actuator 1 or 2, no trial phase running and this tick's sample M of the same body (section 2:
-- "while no actuator is known yet: replica shown, nothing sent"). Base estimate: our call of the last frame taken out
-- of M - actuator 1 base = M * T_prev^-1, actuator 2 base.pos = M.pos - F * o_prev (sentW); a frame without a call of
-- ours: base = M. Deviation: that base is where the engine put it for the LAST frame's player pose, so it is carried
-- along with the player-camera frame (actPlayerFrame) from the pose at that frame's call (sentP) to the pose now: baseL
-- = sentP^-1 * base, base = P_now * baseL (render() again with its own pose; the spec's base for a still player). The
-- mock without it: 3-4 cm while walking 1.5-3 m/s or turning 90-180 deg/s until c caught up, and one frame 7-23 cm off
-- on a 20 deg yaw teleport (our aim teleports turn the player while the tool is used); with it 0. The residual e = the
-- desired transform that call was made for (dPrev: no lead, no c) - M goes into the windows (|e| cm; the angle, deg)
-- and the small integral c += K * e (|c| <= CMAX; for the engine's smoothing; not above ILIM m, see PRB; deviation: only
-- when that call's base was a real estimate, good: our own call taken out, or a clean M - not the first call after a
-- tool switch back, whose body still sat where the tool was last used, the mock: c wound up to 10 cm). The v0.14
-- tick-scaled lead (servoTarget, v0.14 review SPECX-1) on the position and the rotation, with ACT.LEAD_TICKS (see PRB:
-- 0; the velocity capped at VMAX); a pose jump (a step above JUMP m in one tick, v0.15 review LUA15-PLACE-VMAX-WORLD)
-- has none and empties the windows (the latch off at once). Then the call (actSend).
-- v0.17 (docs/V017_PLAN.md sections 1-3): without PRB.V015 / V016 the placement is actPlace17's; the code below is the
-- kept v0.15 / v0.16 placement (their tests).
function actPlace(tw, dt, cam)
    if not (PRB.V015 or PRB.V016) then return actPlace17(tw, dt, cam) end
    local a, c, sc = probe.act, PRB.ACT, PRB.SERVO
    local tb = GetToolBody()
    local s = a.hist[#a.hist]
    if a.st ~= 2 or a.a == 0 or a.phase ~= 0 or tb == 0 or tb ~= a.body or not s or s.hb ~= heartbeat then return end
    local M = Transform(VecCopy(s.pos), s.rot)
    local mine = a.sentAt == heartbeat - 1
    local base, good = M, not mine and s.clean
    if mine and a.a == 1 and a.sentT then
        base, good = TransformToParentTransform(M, TransformToLocalTransform(a.sentT, Transform())), true
        base.rot = quatUnit(base.rot)
    elseif mine and a.a == 2 and a.sentW then
        base, good = Transform(VecSub(M.pos, a.sentW), M.rot), true
    end
    local P = actPlayerFrame()
    a.baseL = TransformToLocalTransform((mine and a.sentP) or P, base)
    a.base = TransformToParentTransform(P, a.baseL)
    a.base.rot = quatUnit(a.base.rot)
    if mine and a.dPrev then
        local e = VecSub(a.dPrev.pos, M.pos)
        local el = VecLength(e)
        push(a.errs, el * 100, PRB.N)
        push(a.rerrs, quatAngle(a.dPrev.rot, M.rot), PRB.N)
        if el < c.ILIM and a.good then
            a.c = VecAdd(a.c, VecScale(e, c.K))
            local cl = VecLength(a.c)
            if cl > c.CMAX then a.c = VecScale(a.c, c.CMAX / cl) end
        end
    end
    local dp, dq = Vec(0, 0, 0), Quat()
    if a.prevTw and a.prevAt == heartbeat - 1 and dt > 0 then
        -- v0.15 review LUA15-PLACE-VMAX-WORLD / V15-VMAX-WALK: a pose jump is a step of more than JUMP m in one tick (a
        -- teleport, a quickload), not a world speed above VMAX - walking (7 m/s by default) or a swing emptied the
        -- windows every tick, so the engine tool was never shown (two tools). Not relative to the player frame: an aim
        -- yaw teleport turns that frame 20+ deg in one tick. VMAX now only caps the lead's velocity.
        local step = VecSub(tw.pos, a.prevTw.pos)
        if VecLength(step) > c.JUMP then
            a.errs, a.rerrs, a.engine, a.high = {}, {}, false, 0
        else
            local v = VecScale(step, 1 / dt)
            local vl = VecLength(v)
            if vl > sc.VMAX then v = VecScale(v, sc.VMAX / vl) end
            local lead = c.LEAD_TICKS * math.min(dt, sc.LEAD_DT)
            dp = VecScale(v, lead)
            local wv = servoRotErr(tw.rot, a.prevTw.rot)
            local wvl = VecLength(wv)
            if wvl > 1e-9 and wvl < math.rad(90) then
                dq = QuatAxisAngle(VecScale(wv, 1 / wvl), math.deg(wvl * lead / dt))
            end
        end
    end
    a.prevTw, a.prevAt, a.lead, a.at, a.good = tw, heartbeat, { dp = dp, dq = dq }, heartbeat, good
    actSend(tw, cam)
    a.clampN = (a.clampAt == heartbeat) and a.clampN + 1 or 0      -- (v0.15 review: the safety net, actWrite)
end

-- The call (tick and render; tw = the desired transform as the caller has it): D = (tw.pos + the lead + c, the lead turn
-- * tw.rot). Actuator 1: T = base^-1 * D (|T.pos| <= TMAX), SetToolTransform(T, 0). Actuator 2: o = F^-1 * (D.pos -
-- base.pos) (|o| <= TMAX), SetToolOffset(o); the rotation stays the engine's (the player's aim). What was sent is kept
-- for the next tick's base estimate (render's call is the frame's last one and wins).
-- v0.16 review V16-HANDLE-ROT (without PRB.V015, actuator 2): the offset cannot turn the tool, so its handle sits at
-- the body + R_eng * rh, R_eng = the engine tool's own rotation (base.rot: the player's aim and the first-person tilt,
-- no wrist roll), not the hand's tw.rot - the body origin aimed at tw.pos (= grip - tw.rot * rh) put the handle up to
-- |(R_eng - R_hand) * rh| off the fist (the booster, 0.29 m off the Z axis, 15 cm at a 30 deg wrist roll). The target
-- is grip - base.rot * rh instead; dPrev holds it (the residual, L_PLACE_ERR and the integral against it; its rotation
-- stays tw.rot for the rotErr diagnostic).
function actSend(tw, cam)
    local a, c = probe.act, PRB.ACT
    local base, l = a.base, a.lead
    local dpos = tw.pos
    if not PRB.V015 and a.a == 2 then
        local rh = toolHandle()
        if rh then dpos = VecSub(VecAdd(tw.pos, QuatRotateVec(tw.rot, rh)), QuatRotateVec(base.rot, rh)) end
    end
    local D = Transform(VecAdd(VecAdd(dpos, l.dp), a.c), quatUnit(QuatRotateQuat(l.dq, tw.rot)))
    if a.a == 1 then
        local T = TransformToLocalTransform(base, D)
        local tl = VecLength(T.pos)
        T = Transform((tl > c.TMAX) and VecScale(T.pos, c.TMAX / tl) or T.pos, quatUnit(T.rot))
        if not SetToolTransform or not pcall(SetToolTransform, T, 0) then return end
        a.sentT, a.sentP = T, actPlayerFrame()
    else
        local F = actFrameRot(a.f, cam)
        local o = QuatRotateVec(qconj(F), VecSub(D.pos, base.pos))
        local ol = VecLength(o)
        if ol > c.TMAX then o, a.clampAt = VecScale(o, c.TMAX / ol), heartbeat end
        if not SetToolOffset or not pcall(SetToolOffset, o) then return end
        a.sentW, a.sentP = QuatRotateVec(F, o), actPlayerFrame()
    end
    a.sentAt, a.dPrev = heartbeat, (dpos == tw.pos) and tw or Transform(dpos, tw.rot)
end

-- ---------------------------------------------------------------------------------------------
-- v0.17 placement (docs/V017_PLAN.md sections 1-3). The v0.16 headset log (section 0): every tool wobbled 5-7 cm. The
-- v0.16 offset came from the base of the PREVIOUS frame's measured body (base = M - F * o_prev) plus an integral, in the
-- player-yaw frame our aim teleports turn ~15 times a second, and tick and render each sent their own value - so every
-- teleport and every frame of the engine's own tool sway / bob left a one-frame error. v0.17: the base is learnt as a
-- slow EMA in the player-camera frame P (it follows the player's aim exactly, the sway averages out) and PREDICTED for
-- this frame from P after this tick's aim teleport; no integral; one value per frame (render re-sends it); the sway
-- switched off (SetToolTransform(..., 0)); and the rotation the offset cannot give is tried with SetToolTransform's
-- rotation, kept only where a self-check shows it working.
-- ---------------------------------------------------------------------------------------------

-- a -> b by t along the shorter way (b's sign flipped into a's hemisphere), unit; nlerp below 0.1 deg apart.
function quatSlerp17(a, b, t)
    local d = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    local s = 1
    if d < 0 then d, s = -d, -1 end
    local wa, wb = 1 - t, t * s
    if d < 0.9999996 then
        local th = math.acos(clamp(d, -1, 1))
        local sn = math.sin(th)
        wa, wb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn * s
    end
    return quatUnit(Quat(a[1] * wa + b[1] * wb, a[2] * wa + b[2] * wb, a[3] * wa + b[3] * wb, a[4] * wa + b[4] * wb))
end

-- Section 1, the base learning (every placing tick with this tick's sample M of the tool body; P = the player-camera
-- frame now). The sample with what we applied to its frame taken out: position M.pos - F * o (sentW, the world offset
-- of the last frame's call), rotation M.rot * R^-1 (sentR: the engine composes our rotation in the tool's local frame,
-- section 3) - only when that frame had our call (mine); in the player-camera frame the engine placed it with (sentP:
-- render's, the frame's post-physics pose; P when the frame had no call of ours), b = P_frame^-1 * that. Deviation
-- (spec: "P read back after this tick's aim"): this tick's P is the pose AFTER this tick's teleport, but the body was
-- placed in the last frame with that frame's pose - taken back with this tick's P every teleport would put its whole
-- turn (1-3 deg, 1-4 cm at the tool) into the sample; the prediction (actPlace17) does use this tick's P. bL = the EMA
-- (weight EMA per sample, the rotation by a slerp the shorter way); a sample more than REJ m from it is rejected (an
-- animation swing, a glitch); the first sample starts it, and so does a sample after REJ_T s of rejected ones in a row
-- (deviation: a base that really moved - an engine pose we do not model - would otherwise never be learnt; a tool
-- switch and a respawn reset it anyway, actPlaceReset). Deviation, the warm-up (bN = samples in the EMA): the first
-- WARM samples weigh 1 / bN at least (a plain mean, so a fresh EMA is not 0.2-slow), and a far one among them starts
-- the EMA again instead of being rejected - the first sample after a tool switch or a new tool body shows where the
-- body sat before the engine placed it (the mock: ~50 cm off), and rejecting the real base after it held the tool
-- that far off the hand for REJ_T s.
-- v0.17 review V17-RESET-FIRST-SAMPLE-CONTAMINATED: a sample whose applied offset is unknown (our call in its frame, but
-- sentW dropped by actPlaceReset - a tool switch, a new body, a respawn) or the first sample of a body (hist restarts on
-- a new body or a gap, actSample: the engine may not have placed it yet) is not learnt at all - each one seeded the EMA
-- 4-14 cm off when the engine base lay within REJ of the placed tool (below REJ the warm-up does not drop it), a visible
-- jump of the new tool settling over ~12 frames. The next tick (nothing sent without an EMA) gives a clean sample.
-- (sentW is not kept across the reset: if the engine does not carry the old offset to the new body, taking it out
-- would add the error the other way.)
-- v0.17 review LUA17-PIVOT-LAG-UNTESTED (deviation, section 3 assumes M.rot = base.rot * R about the body origin and lets
-- the base EMA absorb anything else): an engine turning the tool about a point pv of the tool frame moves the body by
-- base.rot * (I - R) * pv; the EMA learnt that only with its ~5-sample lag, so every wrist turn left cm-scale wobble
-- (0.3 m: 2 cm at 90 deg/s, 4 cm at 180) the window medians did not see. pv is estimated by least squares from
-- consecutive samples of ours whose R changed: their positions s (P frame, our offset taken out, no pivot correction)
-- differ by q * (R_prev - R) * pv (q = the base rotation in P), so y = q^-1 * (s - s_prev) = A * pv, A = R_prev - R;
-- normal equations N = sum A^T A, V = sum A^T y (kept for the tool body: actPlaceReset), pv = (N + PV_L I)^-1 V
-- (Tikhonov: a direction no turn excited stays 0), |pv| <= PV_MAX m; a step |y| > PV_Y m (a glitch, a moved base) is
-- not used. Engine composing about the origin: y = 0, pv = 0 - nothing changes. actLearn17 takes q * (I - R) * pv out of
-- each sample and actPlace17 adds base.rot * (I - R) * pv to the prediction (R identity: no term at all).
function pivotLearn17(s, q, R)
    local a, p = probe.act, PRB.P17
    local prev = a.pvS
    a.pvS = R and { s = s, R = R, hb = heartbeat } or nil
    if not (p.PIV and prev and R and prev.hb == heartbeat - 1) then return end
    local y = QuatRotateVec(qconj(q), VecSub(s, prev.s))
    if VecLength(y) > p.PV_Y then return end
    if not a.pvN then a.pvN, a.pvV = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }, { 0, 0, 0 } end
    local col, N, V = {}, a.pvN, a.pvV
    for i = 1, 3 do
        local ei = Vec(i == 1 and 1 or 0, i == 2 and 1 or 0, i == 3 and 1 or 0)
        col[i] = VecSub(QuatRotateVec(prev.R, ei), QuatRotateVec(R, ei))
    end
    for i = 1, 3 do
        for j = 1, 3 do N[i][j] = N[i][j] + VecDot(col[i], col[j]) end
        V[i] = V[i] + VecDot(col[i], y)
    end
    local m = {}
    for i = 1, 3 do m[i] = { N[i][1], N[i][2], N[i][3] }; m[i][i] = m[i][i] + p.PV_L end
    local function det(c1, c2, c3)       -- the determinant of the matrix with columns c1, c2, c3
        return c1[1] * (c2[2] * c3[3] - c2[3] * c3[2]) - c2[1] * (c1[2] * c3[3] - c1[3] * c3[2])
            + c3[1] * (c1[2] * c2[3] - c1[3] * c2[2])
    end
    local c1 = { m[1][1], m[2][1], m[3][1] }
    local c2 = { m[1][2], m[2][2], m[3][2] }
    local c3 = { m[1][3], m[2][3], m[3][3] }
    local d = det(c1, c2, c3)
    if not (math.abs(d) > 1e-18) then return end
    local pv = Vec(det(V, c2, c3) / d, det(c1, V, c3) / d, det(c1, c2, V) / d)
    local l = VecLength(pv)
    if not (l == l) then return end
    if l > p.PV_MAX then pv = VecScale(pv, p.PV_MAX / l) end
    a.pv = pv
end

-- (the pivot's shift of the body for rotation R and base rotation q: q * (pv - R * pv); zero without a pivot estimate)
function pivotShift17(q, R)
    local pv = probe.act.pv
    if not pv or not R or not PRB.P17.PIV then return Vec(0, 0, 0) end
    return QuatRotateVec(q, VecSub(pv, QuatRotateVec(R, pv)))
end

-- v0.19 review V19-PARK-FRAME4-BOOKKEEPING: the base (world position) of a parked sample (mpos, SP = the call's
-- player-camera frame). actPark19 booked the park in both offset frames (sentW2 the player's yaw, sentW4 yaw + pitch):
-- actHold may have left vf at 4 (one non-converging use at a steep pitch, kept across tools), and with the 10 m lever a
-- wrong frame puts the sample 10 m * 2 sin(pitch / 2) off (3.5 m at 20 deg: rejected, then re-seeded after REJ_T - the
-- next use clamped at TMAX, held off). Where the two bookings lie 2 * BMAX apart or more (|pitch| >~ 17 deg) at most
-- one base is within BMAX m of the eye (an engine tool's first-person pose is): that one is used and is a vote for its
-- frame - VOTES in a row set vf (the at-hand placement's frame too; tried4: the other frame is not tried by actHold).
-- Closer bookings (both plausible, or neither): the voted frame once decided, else the one nearer the learnt base,
-- else (none yet) the yaw frame SetToolOffset is proven in.
function parkBase19(mpos, SP)
    local a, p = probe.act, PRB.P19
    local b2, b4 = VecSub(mpos, a.sentW2), VecSub(mpos, a.sentW4)
    local l2, l4 = TransformToLocalPoint(SP, b2), TransformToLocalPoint(SP, b4)
    if VecLength(VecSub(a.sentW2, a.sentW4)) >= 2 * p.BMAX then
        local ok2, ok4 = VecLength(l2) <= p.BMAX, VecLength(l4) <= p.BMAX
        if ok2 ~= ok4 then
            local f = ok2 and 2 or 4
            if a.fv19 == f then a.fvN19 = a.fvN19 + 1 else a.fv19, a.fvN19 = f, 1 end
            if a.fvN19 >= p.VOTES and (a.vf or 2) ~= f then a.vf, a.f, a.tried4 = f, f, true end
            return ok2 and b2 or b4
        end
    end
    local f = (a.fvN19 >= p.VOTES) and a.fv19 or nil
    if not f and a.bL then
        f = (VecLength(VecSub(l2, a.bL.pos)) <= VecLength(VecSub(l4, a.bL.pos))) and 2 or 4
    end
    return (f == 4) and b4 or b2
end

function actLearn17(M, mine, P, dt)
    local a, p = probe.act, PRB.P17
    if (mine and not a.sentW) or #a.hist < 2 then return end
    local bw, br = M.pos, M.rot
    if mine and a.sentW then bw = VecSub(M.pos, a.sentW) end
    -- (v0.19 review V19-PARK-FRAME4-BOOKKEEPING: a parked sample taken back in the frame that fits, parkBase19)
    if mine and a.sentW2 and a.sentW4 then bw = parkBase19(M.pos, a.sentP or P) end
    if mine and a.sentR then br = QuatRotateQuat(M.rot, qconj(a.sentR)) end
    local b = TransformToLocalTransform((mine and a.sentP) or P, Transform(bw, quatUnit(br)))
    b.rot = quatUnit(b.rot)
    -- (v0.17 review LUA17-PIVOT-LAG-UNTESTED: the pivot learnt from the raw sample, then its shift taken out)
    local R = mine and a.sentR or nil
    -- (v0.18 review LUA18-PRESS-ROT-LURCH: a sample of an aim-teleport frame is not used for the pivot - it is taken back
    -- with the frame the predictor chose, which the engine may not have used (before the late engine's B is chosen: off
    -- by |base| * angle); R now jumps against the base on such frames (carried, rotCtl17), so that error was fitted as
    -- a pivot of several cm - the late engine's jitter 0.4 -> 2.7 mm. The pair after it starts afresh too.)
    pivotLearn17(b.pos, b.rot, (aimState.teleAt ~= heartbeat - 1) and R or nil)
    b.pos = VecSub(b.pos, pivotShift17(b.rot, R))
    local e = a.bL
    local far = e and VecLength(VecSub(b.pos, e.pos)) > p.REJ
    if not e or (far and a.bN < p.WARM) then
        a.bL, a.rejT, a.bN = b, 0, 1
        return
    end
    if far then
        a.rejT = a.rejT + math.max(dt or 0, 0)
        if a.rejT >= p.REJ_T then a.bL, a.rejT, a.bN = b, 0, 1 end
        return
    end
    a.rejT, a.bN = 0, a.bN + 1
    local k = math.max(p.EMA, 1 / a.bN)
    a.bL = Transform(VecAdd(e.pos, VecScale(VecSub(b.pos, e.pos), k)), quatSlerp17(e.rot, b.rot, k))
end

-- Section 3, the rotation control (base = this frame's predicted base, tw = the hand's desired transform): R = the
-- SetToolTransform rotation, assumed composed in the tool's local frame (M.rot = base.rot * R). Off (self-check state
-- 0 / 1 / 4): identity. On (2 / 3): R_target = base.rot^-1 * D.rot, R = slerp(R_prev, R_target, GAIN) the shorter way,
-- |angle(R)| <= RMAX deg. Deviation (spec: base.rot_est = M.rot * R_prev^-1): the predicted base's rotation - the same
-- estimate (the EMA learns M.rot * R_prev^-1, actLearn17), carried to this frame's aim instead of the last frame's (an
-- aim teleport would otherwise turn the target by the whole teleport for a frame).
-- v0.18 (docs/V018_PLAN.md section 1): RMAX 175 deg (was 90) - with the control kept the player's aim no longer follows
-- the hand outside the precise situations (preciseAim), so R must cover the whole wrist turn; base = the frame the
-- teleport-timing predictor chose (actPlace17).
-- v0.18 review LUA18-PRESS-ROT-LURCH: the previous R is first carried into this frame's base (Rp = base.rot^-1 *
-- Rq * R_prev, Rq = the base rotation R_prev was computed with), so the slerp smooths the tool's WORLD rotation (base.rot
-- * R): a big aim teleport (the press after the hand drifted from the player's yaw with the control kept: up to 175 deg)
-- turned the base at once while R slerped from its old value - the tool off the hand by half the step on the press
-- frame, halving every frame after.
function rotCtl17(base, tw)
    local a, p = probe.act, PRB.P17
    if a.rc.st ~= 2 and a.rc.st ~= 3 then
        a.R, a.Rq = Quat(), nil
        return a.R
    end
    local Rp = a.R or Quat()
    if a.Rq then Rp = quatUnit(QuatRotateQuat(QuatRotateQuat(qconj(base.rot), a.Rq), Rp)) end
    local R = quatSlerp17(Rp, quatUnit(QuatRotateQuat(qconj(base.rot), tw.rot)), p.GAIN)
    if R[4] < 0 then R = Quat(-R[1], -R[2], -R[3], -R[4]) end
    local ang = math.deg(2 * math.acos(clamp(R[4], -1, 1)))
    if ang > p.RMAX then R = quatSlerp17(Quat(), R, p.RMAX / ang) end
    a.R, a.Rq = R, base.rot
    return R
end

-- Section 3, the self-check (each placing tick with a residual: el = position error (m), deg = rotation error, dt).
-- State rc.st: 0 none yet -> 1 the off window (R = identity) from the first placing tick -> after WIN s of placing
-- ticks 2 the on window (the control on) -> after WIN s more: kept (3) if rotErr_on <= KEEP_ROT * rotErr_off and
-- posErr_on <= posErr_off + KEEP_CM cm (the windows' medians), else rejected (4, R identity from now on); cached per
-- tool name (rcCache, rcN tools decided; rcSwitch17), L_ROTCTL_AB = the rotErr medians. Only a tool with a name (key).
-- Only the windows' end changes anything (a window empty of samples - nothing placed with a residual - runs again).
-- v0.17 review LUA17-PIVOT-LAG-UNTESTED (deviation from section 3, which compares medians only): also the windows' P90
-- (PCT) of the position error, onP90 <= offP90 + KEEP_CM. An engine turning the tool about a point off its origin moves
-- the body by (R_prev - R) * pivot every frame R changes; the base EMA learns that only with its ~5-frame lag, so every
-- wrist turn brings back cm-scale wobble (0.3 m pivot: max 2 cm at 90 deg/s, 4 cm at 180) while the still frames keep
-- the median low - such a control is rejected now (R identity: no pivot shift at all) instead of kept with lag.
function pct17(list, q)                      -- the q-quantile of a list (sorted copy), -1 for an empty one
    local n = #list
    if n == 0 then return -1 end
    local s = {}
    for i = 1, n do s[i] = list[i] end
    table.sort(s)
    return s[math.min(n, math.floor(n * q) + 1)]
end

function rcStep17(el, deg, dt)
    local a, p = probe.act, PRB.P17
    local rc = a.rc
    if a.key == "" or rc.st == 3 or rc.st == 4 then return end
    if rc.st == 0 then rc.st, rc.t = 1, 0 end
    if rc.st == 1 then
        push(rc.offP, el * 100, 100000)
        push(rc.offR, deg, 100000)
    else
        push(rc.onP, el * 100, 100000)
        push(rc.onR, deg, 100000)
    end
    rc.t = rc.t + math.max(dt or 0, 0)
    if rc.t < p.WIN then return end
    rc.t = 0
    if rc.st == 1 then
        rc.offPm, rc.offRm, rc.offP90 = median(rc.offP), median(rc.offR), pct17(rc.offP, p.PCT)
        rc.offP, rc.offR = {}, {}
        if rc.offPm >= 0 then rc.st = 2 end
        return
    end
    local onPm, onRm, onP90 = median(rc.onP), median(rc.onR), pct17(rc.onP, p.PCT)
    rc.onP, rc.onR = {}, {}
    if onPm < 0 then return end
    rc.onP90 = onP90
    local keep = onRm <= p.KEEP_ROT * rc.offRm and onPm <= rc.offPm + p.KEEP_CM and onP90 <= rc.offP90 + p.KEEP_CM
    rc.st = keep and 3 or 4
    rc.ab = math.min(math.floor(rc.offRm + 0.5), 999) * 1000 + math.min(math.floor(onRm + 0.5), 999)
    a.rcCache[a.key] = { st = rc.st, ab = rc.ab }
    a.rcN = a.rcN + 1
    if not keep then a.R, a.Rq = Quat(), nil end   -- (Rq: v0.18 review LUA18-PRESS-ROT-LURCH)
end

-- v0.18 (docs/V018_PLAN.md section 2; the v0.17 log: jitter 7-22 mm with ~11 aim teleports per second - a 1-3 deg
-- teleport the engine applies to its tool a frame later or earlier than predicted moves the predicted base by |base| *
-- angle, ~0.5 m * 1-3 deg = 1-3 cm, for one frame): two predictions of a teleport frame's base, A = the player-camera
-- frame after this tick's teleport (v0.17), B = before it (the pose setPlayerAim found: the previous tick's yaw /
-- pitch); a frame without a teleport has one (A = B). The tick after a teleport frame scores both against the body
-- measured: the distance between M and the body each predicts - its base (frame * bL) + the pivot's shift for the R
-- sent + the offset applied (sentW), i.e. the measured base (M minus what we applied) against the predicted base - and
-- keeps an EMA (P18.EMA) of each over teleport ticks only. B is used once P18.N ticks are scored and EMA_B < HYS *
-- EMA_A, A again when EMA_A < HYS * EMA_B (hysteresis). Run before actLearn17: bL, sentR and the pivot are still the
-- ones that frame was predicted with. L_TP_PRED (actWrite) publishes the choice.
-- v0.18 review LUA18-PRED-B-OFFSET-FRAME / V18-SPEC-TPPRED-OFFSET-FRAME (deviation: three hypotheses, not two): the
-- offset is applied in a player frame too (f 2 the yaw, 4 yaw + pitch), so an engine placing its tool with the frame
-- before the teleport most likely turns the offset with it - B (base before, offset after) is then wrong by |o| * angle
-- (|o| ~1 m: the v0.17 wobble again, B never chosen). Each prediction now adds the applied local offset sentO in its own
-- frame: A = base(rA) + FA * sentO, B = base(rB) + FA * sentO, W = base(rB) + FB * sentO (whole frame late). The better
-- of B / W is compared with A by the same N / HYS rule (W kept apart in tpW; between B and W the same hysteresis);
-- L_TP_PRED reports either before-variant as 1 (the interface is fixed).
function tpScore18(M)
    local a, p = probe.act, PRB.P18
    local t = a.tp
    a.tp = nil
    if not t or t.hb ~= heartbeat - 1 or not a.bL or not a.sentO then return end
    local function body(r, F)
        local b = TransformToParentTransform(Transform(t.pos, r), a.bL)
        return VecAdd(VecAdd(b.pos, pivotShift17(quatUnit(b.rot), a.sentR)), QuatRotateVec(F, a.sentO))
    end
    local eA = VecLength(VecSub(M.pos, body(t.rA, t.FA)))
    local eB = VecLength(VecSub(M.pos, body(t.rB, t.FA)))
    local eW = VecLength(VecSub(M.pos, body(t.rB, t.FB)))
    if not (eA == eA and eB == eB and eW == eW) then return end
    if a.tpN == 0 then
        a.tpEA, a.tpEB, a.tpEW = eA, eB, eW
    else
        a.tpEA, a.tpEB = a.tpEA + p.EMA * (eA - a.tpEA), a.tpEB + p.EMA * (eB - a.tpEB)
        a.tpEW = a.tpEW + p.EMA * (eW - a.tpEW)
    end
    a.tpN = a.tpN + 1
    local w = a.tpEW < a.tpEB
    local best = w and a.tpEW or a.tpEB
    if not a.tpB then
        if a.tpN >= p.N and best < p.HYS * a.tpEA then a.tpB, a.tpW = true, w end
    else
        local cur = a.tpW and a.tpEW or a.tpEB
        if a.tpEA < p.HYS * cur then
            a.tpB, a.tpW = false, false
        elseif w ~= a.tpW and best < p.HYS * cur then
            a.tpW = w
        end
    end
end

-- tick, from actPlace without PRB.V015 / V016 (attach in use, the hand tracked; tw = the desired transform, cam = this
-- tick's camera). With this tick's sample M of the same body: the base learnt (actLearn17); when the last frame had our
-- call, its residual (the target that call aimed at, dPrev, against M: L_PLACE_ERR / ROTERR, the jitter, the self-check)
-- and the integral (section 1: gain P17.K = 0, the code kept). A pose jump (a step above JUMP m in one tick) empties
-- the windows as before. Then, from the EMA (none yet: nothing sent): this frame's base = P_now * bL (P_now = the
-- player-camera frame after this tick's aim teleport); the rotation R (rotCtl17); the target: the handle on the fist
-- (v0.16 review V16-HANDLE-ROT) with the tool's rotation as the engine will have it, base.rot * R; o = F^-1 * (D.pos -
-- base.pos), F = the offset frame now (the player's yaw read back after the teleport; frame 4 after actHold), |o| <=
-- TMAX; SetToolTransform(Transform(0, R), 0) (section 2: sway 0, every placing tick) and SetToolOffset(o). render()
-- re-sends both unchanged (actRender).
-- v0.18 (docs/V018_PLAN.md section 2): a teleport frame's two predictions are scored first (tpScore18); on a teleport
-- tick the base is predicted with the frame the predictor chose (B: this tick's eye with the yaw / pitch before the
-- teleport) and that frame is the one the next sample is taken back with (sentP); the target and the hand stay in P
-- (where the hand is does not depend on when the engine turns its tool).
-- v0.18 (docs/V018_PLAN.md section 2b, "hold the handle, not the body origin"; the user: "every tool sits strangely in
-- my hand, the sledgehammer is too high"): the body origin's target is grip - Q * rh, Q = the engine tool's rotation
-- predicted for this frame: base.rot * the R SENT this frame (the composition rotCtl17 assumes, M.rot = base.rot * R;
-- base = the frame the predictor chose), base.rot alone when no R went out (the control off: identity; SetToolTransform
-- missing or failed) - not grip - D.rot * rh (tw.pos, toolWorldOf): the engine's rotation is not the hand's (the v0.17
-- log: 39 deg median), and an origin on tw.pos leaves the handle |rh| * 2 sin(err / 2) off the fist (the sledge, |rh|
-- 0.25 m, at 40 deg: 17 cm). R keeps aiming at D.rot (rotCtl17(base, tw)). v0.17's target was base.rot * R already
-- (v0.16 review V16-HANDLE-ROT), but with R also when SetToolTransform was missing or failed (the engine turned nothing:
-- the target then converged on the D.rot one) - R is sent first now, and render re-sends the R sent (actRender). The
-- residual measures the handle point (LUA18-2B-RESIDUAL-NOT-HANDLE below); the base is learnt from the measured body
-- with what was applied (sentW / sentR) taken out, never from the target (actLearn17).
function actPlace17(tw, dt, cam)
    local a, c, p = probe.act, PRB.ACT, PRB.P17
    -- (v0.19 review V19-HOLD-STOPS-PARKING: held off (st 3, actHold) with the replica seen (m19 1, see mode19) the engine
    -- tool is still parked - and the base still learnt - below; only the at-hand placement waits for the hold's end)
    if a.a ~= 2 or (a.st ~= 2 and not (a.st == 3 and a.m19 == 1)) then return end
    local tb = GetToolBody()
    local s = a.hist[#a.hist]
    local P = actPlayerFrame()
    if tb ~= 0 and tb == a.body and s and s.hb == heartbeat then
        local M = Transform(VecCopy(s.pos), s.rot)
        local mine = a.sentAt == heartbeat - 1
        if mine then tpScore18(M) end
        actLearn17(M, mine, P, dt)
        if mine and a.dPrev then
            local e = VecSub(a.dPrev.pos, M.pos)
            -- v0.18 review LUA18-2B-RESIDUAL-NOT-HANDLE / V18-SPEC-2B-RESIDUAL-NOT-HANDLE (V018 section 2b): the residual
            -- is the measured handle point M.pos + M.rot * rh against the call's grip (gPrev, render's pose) - L_PLACE_ERR,
            -- the integral and the self-check's posErr. dPrev.pos = grip - base.rot * R * rh is a predicted target: body
            -- vs it read ~0 while an engine honouring R only partly left the handle |rh| * 2 sin(err / 2) off the fist
            -- (the sledge at 39 deg: 17 cm, "too high"). Without a handle point the body origin as before. The body-
            -- origin error stays in berrs for actWrite's UNLOCK / actHold guard (a frame that does not converge): a
            -- handle off by the engine's rotation is no wrong frame.
            local eh = e
            if a.rhS and a.gPrev then eh = VecSub(a.gPrev, VecAdd(M.pos, QuatRotateVec(M.rot, a.rhS))) end
            local el, deg = VecLength(eh), quatAngle(a.dPrev.rot, M.rot)
            push(a.errs, el * 100, PRB.N)
            push(a.berrs, VecLength(e) * 100, PRB.N)
            push(a.rerrs, deg, PRB.N)
            if el < c.ILIM then
                a.c = VecAdd(a.c, VecScale(eh, p.K))
                local cl = VecLength(a.c)
                if cl > c.CMAX then a.c = VecScale(a.c, c.CMAX / cl) end
            end
            -- (section 4, L_JITTER: the frame-to-frame change of body - hand, consecutive frames only)
            -- v0.17 review V17-JITTER-NOT-BODY-MINUS-HAND: body - hand (the hand target tw.pos of the call, hPrev), not
            -- body - dPrev - dPrev = grip - base.rot * R * rh moves with the engine tool's rotation, so the swing of a
            -- long-handled tool about the fist at every aim teleport (rotation control off: |rh| * 1-3 deg, 0.5-1.5 cm)
            -- read ~0 there; e (body - target) stays the measure of L_PLACE_ERR, the integral and the self-check
            -- (v0.18 review LUA18-2B-RESIDUAL-NOT-HANDLE: those three now take the handle's error eh; the jitter as it was)
            local ev = a.hPrev and VecSub(M.pos, a.hPrev) or VecScale(e, -1)
            if a.prevE and a.eAt == heartbeat - 1 then push(a.jit, VecLength(VecSub(ev, a.prevE)) * 1000, p.JN) end
            a.prevE, a.eAt = ev, heartbeat
            -- (v0.19, docs/V019_PLAN.md section 1: the rotation control's self-check is out of the flow - R stays
            -- identity, L_ROTCTL 0; only the kept v0.18 flow runs it, PRB.V018)
            if PRB.V018 then rcStep17(el, deg, dt) end
        end
    end
    if a.prevTw and a.prevAt == heartbeat - 1 and VecLength(VecSub(tw.pos, a.prevTw.pos)) > c.JUMP then
        a.errs, a.rerrs, a.engine, a.high, a.prevE, a.berrs = {}, {}, false, 0, nil, {}
    end
    a.prevTw, a.prevAt = tw, heartbeat
    -- (v0.19, docs/V019_PLAN.md section 1: idle with a replica - the engine tool parked; the sample above still taught the
    -- base, so a use places it at the hand from its first tick)
    if a.m19 == 1 then return actPark19(cam) end
    -- (v0.19 review V19-USE-WITHOUT-BASE: mode19 keeps a tool without a base parked; should one reach here in use
    -- anyway, park it rather than send nothing - the unplaced engine tool at its own pose)
    if a.m19 == 2 and not a.bL then return actPark19(cam) end
    if not a.bL then return end
    -- (v0.18, docs/V018_PLAN.md section 2: B differs from A only on a tick of ours with a yaw teleport)
    -- (v0.18 review LUA18-PRED-B-OFFSET-FRAME / V18-SPEC-TPPRED-OFFSET-FRAME: also the offset frame before the
    -- teleport, FB - f 4: rB; f 2: the frame read back turned back by the teleport's yaw step; f 3 / 1: unchanged - and
    -- on a W tick (tpW) the offset is built in it)
    local PB = P
    local F = actFrameRot(a.f, cam)
    local Fo = F
    a.tp, a.tpRB = nil, nil
    if aimState.teleAt == heartbeat and aimState.preAt == heartbeat then
        local rB = yawPitchRot(aimState.preYaw, aimState.prePitch)
        local FB = F
        if a.f == 4 then
            FB = rB
        elseif a.f == 2 then
            FB = quatUnit(QuatRotateQuat(QuatAxisAngle(Vec(0, 1, 0), angleDiff(aimState.preYaw, GetPlayerYaw())), F))
        end
        a.tp = { hb = heartbeat, pos = VecCopy(P.pos), rA = P.rot, rB = rB, FA = F, FB = FB }
        if a.tpB then PB, a.tpRB = Transform(VecCopy(P.pos), rB), rB end
        if a.tpB and a.tpW then Fo = FB end
    end
    local base = TransformToParentTransform(PB, a.bL)
    base.rot = quatUnit(base.rot)
    a.base, a.baseL = base, a.bL
    local R = rotCtl17(base, tw)
    a.sentR = nil
    if SetToolTransform and pcall(SetToolTransform, Transform(Vec(0, 0, 0), R), 0) then a.sentR = R end
    -- (v0.18, docs/V018_PLAN.md section 2b: the handle on the fist with the rotation the engine tool will have, Q)
    local dpos, grip = tw.pos, nil
    local rh = toolHandle()
    if rh then
        grip = VecAdd(tw.pos, QuatRotateVec(tw.rot, rh))
        dpos = VecSub(grip, QuatRotateVec(QuatRotateQuat(base.rot, a.sentR or Quat()), rh))
    end
    -- (v0.17 review LUA17-PIVOT-LAG-UNTESTED: the body origin as R turns it about the learnt pivot, pivotLearn17; v0.18
    -- section 2b: the R sent - none, no shift)
    local o = QuatRotateVec(qconj(Fo), VecSub(VecAdd(dpos, a.c), VecAdd(base.pos, pivotShift17(base.rot, a.sentR))))
    local ol = VecLength(o)
    if ol > c.TMAX then o, a.clampAt = VecScale(o, c.TMAX / ol), heartbeat end
    if not SetToolOffset or not pcall(SetToolOffset, o) then return end
    a.sentO, a.sentW, a.sentP = o, QuatRotateVec(Fo, o), PB
    a.sentW2, a.sentW4 = nil, nil                   -- (v0.19 review V19-PARK-FRAME4-BOOKKEEPING: a placing call, not a park)
    a.sentAt, a.dPrev, a.at, a.good = heartbeat, Transform(dpos, tw.rot), heartbeat, true
    -- v0.17 review LUA17-RESIDUAL-WALK-BIAS / V17-RESIDUAL-TICK-VS-POSTPHYSICS: the target (and the hand, hPrev, V17-
    -- JITTER-NOT-BODY-MINUS-HAND) also in this tick's player-camera frame; render carries both to its post-physics pose
    -- (actRender), the one the body is placed and its sample taken back with (actLearn17) - the tick's world target
    -- against that body put the player's whole move between tick and render (v * dt: 11.7 cm at 7 m/s, 60 fps) into
    -- L_PLACE_ERR, the jitter and the self-check's posErr (actHold after 1 s of walking below ~58 fps; a working
    -- rotation control rejected when the on window had more walking). Without a render the tick's values stand.
    a.hPrev = VecCopy(tw.pos)
    a.dL, a.hL = TransformToLocalTransform(P, a.dPrev), TransformToLocalPoint(P, tw.pos)
    -- (v0.18 review LUA18-2B-RESIDUAL-NOT-HANDLE: the call's grip and handle point for the next residual; render carries
    -- the grip to its pose like dL / hL)
    a.rhS, a.gL, a.gPrev = rh, nil, grip
    if grip then a.gL = TransformToLocalPoint(P, grip) end
    a.clampN = (a.clampAt == heartbeat) and a.clampN + 1 or 0      -- (the v0.16 review guard, actWrite / actHold)
end

-- v0.19 (docs/V019_PLAN.md section 1), tick, from actPlace17 while a tool with a replica is idle (m19 1): the engine tool
-- parked out of sight - SetToolOffset(P19.PARK) (the player-yaw frame the v0.15 log proved: 10 m down, moved 1:1) and
-- SetToolTransform(Transform(), 0) (sway 0, no rotation), render re-sends both (actRender). It is a call of ours like a
-- placement (sentAt / sentO / sentW / sentP), so the next tick's sample takes the known offset out and the base EMA
-- keeps learning (actLearn17): a use places the engine tool at the hand from its first tick. Nothing aims (no target,
-- no residual, no teleport-timing score: dPrev / tp nil) and the at-the-hand windows (L_PLACE_ERR / ROTERR / JITTER,
-- the body-origin guard) start empty at each parking stretch - they describe the engine tool at the hand only.
function actPark19(cam)
    local a, p = probe.act, PRB.P19
    if a.parkAt ~= heartbeat - 1 then a.errs, a.rerrs, a.berrs, a.jit, a.high = {}, {}, {}, {}, 0 end
    a.tp, a.tpRB, a.R, a.Rq, a.sentR, a.clampN = nil, nil, Quat(), nil, nil, 0
    a.dPrev, a.dL, a.hL, a.gL, a.gPrev, a.rhS, a.hPrev, a.prevE = nil, nil, nil, nil, nil, nil, nil, nil
    if SetToolTransform and pcall(SetToolTransform, Transform(), 0) then a.sentR = Quat() end
    local o = Vec(p.PARK[1], p.PARK[2], p.PARK[3])
    if not SetToolOffset or not pcall(SetToolOffset, o) then return end
    a.sentO, a.sentW, a.sentP = o, QuatRotateVec(actFrameRot(a.f, cam), o), actPlayerFrame()
    -- (v0.19 review V19-PARK-FRAME4-BOOKKEEPING: the park in both offset frames - the 10 m lever makes a wrong frame
    -- cost 10 m * 2 sin(pitch / 2), metres; actLearn17 takes the sample back with the one that fits, parkBase19)
    a.sentW2, a.sentW4 = QuatRotateVec(actFrameRot(2, cam), o), QuatRotateVec(actFrameRot(4, cam), o)
    a.sentAt, a.at, a.parkAt, a.good, a.base, a.baseL = heartbeat, heartbeat, heartbeat, true, nil, a.bL
end

-- render(), on foot (cam / base = render's camera and VR base): a pulse tick's pulse again, or this tick's placement
-- again with render's desired transform (the hand as this frame shows it, where the replica is drawn; the tick's base
-- estimate and lead) - after every script's tick, so ours is the frame's last call.
-- v0.17 (docs/V017_PLAN.md section 1: "compute once per frame in tick; render() re-sends exactly the same o"; section 2:
-- the sway-0 SetToolTransform in render too): without PRB.V015 / V016 the tick's offset and rotation again, nothing
-- recomputed - the engine sees one value per frame whichever call it takes. Only the player-camera frame of the call is
-- refreshed (sentP: the frame's post-physics pose, the one the engine places the body with; the next tick's sample is
-- taken back into the base frame with it).
function actRender(cam, base)
    local a = probe.act
    if a.pulsedAt == heartbeat then
        actPulse(a.pulsedP)
        return
    end
    if not (PRB.V015 or PRB.V016) then
        if a.at ~= heartbeat or not a.sentO then return end
        -- (v0.18, docs/V018_PLAN.md section 2b: the R tick SENT - the one its target was computed with; identity when
        -- tick's call failed)
        if SetToolTransform then pcall(SetToolTransform, Transform(Vec(0, 0, 0), a.sentR or Quat()), 0) end
        if SetToolOffset and pcall(SetToolOffset, a.sentO) then
            local Pr = actPlayerFrame()
            a.sentP = Pr
            -- (v0.18, docs/V018_PLAN.md section 2: a teleport frame predicted with B keeps B's rotation at render's eye;
            -- both predictions are scored at render's eye, the pose the body is placed with)
            if a.tpRB then a.sentP = Transform(VecCopy(Pr.pos), a.tpRB) end
            if a.tp and a.tp.hb == heartbeat then a.tp.pos, a.tp.rA = VecCopy(Pr.pos), Pr.rot end
            -- (v0.17 review LUA17-RESIDUAL-WALK-BIAS / V17-RESIDUAL-TICK-VS-POSTPHYSICS: the residual's target and the
            -- jitter's hand in the pose the body is placed with, see actPlace17)
            if a.dL then
                a.dPrev = TransformToParentTransform(Pr, a.dL)
                a.dPrev.rot = quatUnit(a.dPrev.rot)
            end
            if a.hL then a.hPrev = TransformToParentPoint(Pr, a.hL) end
            if a.gL then a.gPrev = TransformToParentPoint(Pr, a.gL) end   -- (v0.18 review LUA18-2B-RESIDUAL-NOT-HANDLE)
        end
        return
    end
    if a.at ~= heartbeat or not a.baseL or not ctl then return end
    a.base = TransformToParentTransform(actPlayerFrame(), a.baseL)
    a.base.rot = quatUnit(a.base.rot)
    actSend((toolWorldOf(base)), cam)
end

-- Every tick (writeProbeStatus). The shown latch (section 2): live = a placing tick within IDLE ticks with a decided
-- actuator 1 / 2 (else the placement is off: c, the windows and the latch dropped); on when a full window's position
-- median is below SHOW_CM cm (actuator 1: and the rotation median below SHOW_DEG deg), off when the median is above
-- UNLOCK cm for UNLOCK_N ticks in a row, the placement is off, this tick placed nothing (unlike the override, each call
-- acts on its own frame only) or the actuator is 0 (updateToolReplica reads it next
-- tick: on = the replica hidden, the engine tool in the hand). L8 slots (section 3); l7 = also the L7 servo slots,
-- which report this placement (SERVO_STATE 0 not placing this tick, 1 placing with the replica shown, 2 the engine tool
-- shown; the medians while live; VOFS the v0.14 fixed 3). L_BASE_P: this tick's base estimate (baseL), or the body
-- itself when its frame had nothing of ours, in the player-camera frame (actPlayerFrame), -1 none.
-- v0.16 (docs/V016_PLAN.md section 1): without PRB.V015 the latch is "placed this tick" (no 6 cm window, no safety
-- net); L_ACT is the fixed 222, T1 / T2 -1 and TRIALS 0 (no pulse); the medians as before (rotErr: how well the
-- engine tool's orientation - the player's aim - follows the hand).
function actWrite(l7)
    local a, c = probe.act, PRB.ACT
    -- (v0.19 review V19-HOLD-STOPS-PARKING: a parking call during a hold (st 3) is live too - else the reset below
    -- dropped what was sent (render re-sends nothing) and the base every tick)
    local live = a.at >= 0 and heartbeat - a.at < c.IDLE and a.a ~= 0 and (a.st == 2 or a.parkAt == heartbeat)
    if not live and (a.at >= 0 or a.engine) then actPlaceReset() end
    -- (v0.19, docs/V019_PLAN.md section 3: parked this tick - L_ACT state 4, the at-the-hand diagnostics -1)
    local parked = live and a.parkAt == heartbeat
    local med = (live and not parked) and median(a.errs) or -1
    local rmed = (live and not parked) and median(a.rerrs) or -1
    -- (v0.18 review LUA18-2B-RESIDUAL-NOT-HANDLE: the v0.17 placement's errs measure the handle now; the guard against a
    -- frame that does not converge keeps reading the body origin, berrs - a long handle off by the engine's rotation
    -- (the sledge, 30+ deg: > 12 cm) is no wrong frame and must not drop the placement)
    local v17 = not (PRB.V013 or PRB.V014 or PRB.V015 or PRB.V016)
    local gmed = (live and v17) and median(a.berrs) or med
    a.high = (live and gmed > c.UNLOCK) and a.high + 1 or 0
    -- v0.15 review LUA15-ACT-FRAME-AMBIGUOUS / V15-FRAME-AMBIG: the safety net - actuator 2 above UNLOCK cm for RETEST
    -- placing ticks in a row or |o| clamped for CLAMP_N: a wrong frame (diverging), tested again (actRetest)
    -- (v0.16, docs/V016_PLAN.md section 1: only with the kept v0.15 test, PRB.V015 - the yaw frame is fixed, there is
    -- nothing to retest)
    if PRB.V015 and live and a.a == 2 and (a.high >= c.RETEST or a.clampN >= c.CLAMP_N) then
        actRetest()
        live, med, rmed = false, -1, -1
    end
    -- v0.16 review LUA16-FRAME-PITCH-NO-FALLBACK: the same condition without PRB.V015 - no pulse, the other frame or the
    -- replica (actHold)
    if not PRB.V015 and live and a.a == 2 and (a.high >= c.RETEST or a.clampN >= c.CLAMP_N) then
        actHold()
        live, med, rmed = false, -1, -1
    end
    -- (a tick without a placing call: our calls act on one frame only, the engine tool is back at its base in this one)
    -- v0.16 (docs/V016_PLAN.md section 1): no latch - the engine tool is the one shown whenever this tick placed it (the
    -- v0.15 6 cm rule kept the replica in view next to it: "still a second tool"); updateToolReplica hides the replica by
    -- actCanRun itself. The medians stay diagnostics (L_PLACE_ERR / ROTERR).
    if not PRB.V015 then
        a.engine = live and a.at == heartbeat and not parked   -- (v0.19: parked = the replica is the tool seen)
    elseif not live or a.at ~= heartbeat or a.high >= c.UNLOCK_N then
        a.engine = false
    elseif #a.errs >= PRB.N and med < c.SHOW_CM and (a.a ~= 1 or (#a.rerrs >= PRB.N and rmed < c.SHOW_DEG)) then
        a.engine, a.nets = true, 0
    end
    if l7 then
        diag.prb.vofsState = 3                         -- (v0.21: 243 is L_BODY_VIS, the old value kept in diag.prb)
        W(L7.SERVO_STATE, (not live or a.at ~= heartbeat) and 0 or (a.engine and 2 or 1))
        W(L7.SERVO_ERR, med)
        W(L7.TOOL_SHOWN, probe.servo.shown and 1 or 0)
        W(L7.SERVO_ROTERR, rmed)
    end
    local s = a.hist[#a.hist]
    local l = (a.at == heartbeat and a.baseL) and a.baseL.pos or nil
    if not l and s and s.hb == heartbeat and s.clean then l = TransformToLocalPoint(actPlayerFrame(), s.pos) end
    local bp = -1
    if l then
        local function part(m) return clamp(math.floor(m * 100 + 0.5) + 500, 0, 999) end
        bp = part(l[1]) * 1000000 + part(l[2]) * 1000 + part(-l[3])
    end
    -- (v0.19, docs/V019_PLAN.md section 3: state 4 = the engine tool parked this tick; 2 = at the hand as before)
    W(L8.ACT, a.a + 10 * ((a.a == 2) and a.f or 0) + 100 * (parked and 4 or a.st))
    -- v0.17 (docs/V017_PLAN.md section 4): 249..251 reused - the self-check of the current tool + 10 * tools decided,
    -- the rotErr medians of its windows, the jitter median (-1 while not placing: actPlaceReset empties it).
    -- v0.17 review N17-2: the kept paths (PRB.V013..V016) no longer write their v0.15 / v0.16 pulse values (a.code,
    -- a.tr) there - with L_LUA_VERSION 17 native decodes 249..251 as L_ROTCTL / AB / JITTER, so V016's -1 / -1 / 0 read
    -- as "jitter=0.0" (a believable perfect result) and V015's pulse codes as rotErr off/on. They report "none" (-1)
    -- for the self-check, and the jitter median as it is (only the v0.17 placement fills a.jit: -1 on these paths).
    -- v0.21 (docs/V021_PLAN.md section 9): 249 / 250 are L_BODY_COL / L_PHYS_PROBE now (writeDiag21); the L_ROTCTL /
    -- L_ROTCTL_AB values below are kept in diag.prb only (rotctl / rotctlAb)
    local prb = diag.prb
    if PRB.V013 or PRB.V014 or PRB.V015 or PRB.V016 then
        prb.rotctl, prb.rotctlAb = -1, -1
        W(L8.JITTER, median(a.jit))
    elseif PRB.V018 then
        prb.rotctl, prb.rotctlAb = a.rc.st + 10 * math.min(a.rcN, 99), a.rc.ab
        W(L8.JITTER, median(a.jit))
    else
        -- v0.19 (docs/V019_PLAN.md sections 1 / 3): the self-check is out of the flow - L_ROTCTL 0, its medians none
        -- (-1); the jitter only while the engine tool is at the hand (-1 parked: actPark19 also empties the window)
        prb.rotctl, prb.rotctlAb = 0, -1
        W(L8.JITTER, parked and -1 or median(a.jit))
    end
    W(L8.PLACE_ERR, med)
    W(L8.PLACE_ROTERR, rmed)
    W(L8.BASE_P, bp)
    -- v0.18 (docs/V018_PLAN.md section 2): 255 (was LUA8_RES, always 0) = the teleport-timing predictor's choice, 0 A /
    -- 1 B, + 10 * teleport ticks scored (capped 99); 0 on the kept paths (they never score)
    W(L8.TP_PRED, (a.tpB and 1 or 0) + 10 * math.min(a.tpN, 99))
end

-- ---------------------------------------------------------------------------------------------
-- hands: voxel gloves (tools/gen_hands.py), line hands as the fallback
-- ---------------------------------------------------------------------------------------------
local HAND_VOXEL = 0.05   -- generated by tools/gen_hands.py: vox scale attribute (5 mm voxels)
local HAND_PARTS = {   -- generated by tools/gen_hands.py: size in voxels (x, y, z), offset (m) from the
                       -- shape's voxel (0,0,0) corner to the grip origin (model frame)
    open_r = { 9, 27, 46, -0.010, 0.055, 0.105 },
    point_r = { 19, 21, 44, 0.040, 0.045, 0.095 },
    fist_r = { 19, 21, 33, 0.040, 0.045, 0.040 },
    open_l = { 9, 27, 46, 0.055, 0.055, 0.105 },
    point_l = { 19, 21, 44, 0.055, 0.045, 0.095 },
    fist_l = { 19, 21, 33, 0.055, 0.045, 0.040 },
}

-- BLK_BEGIN: generated by tools/gen_hands.py --blocky (do not edit by hand)
BLK = {   -- blocky hands (hands_blocky.vox): VOXEL = vox scale attribute (25 mm voxels); PARTS = size in
          -- voxels (x, y, z), offset (m) from the shape's voxel (0,0,0) corner to the grip origin (model frame)
    VOXEL = 0.25,
    PARTS = {
        blk_open_r = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_point_r = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_fist_r = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_finger_r = { 1, 1, 2, 0.050, -0.025, 0.100 },
        blk_arm_r = { 4, 4, 8, 0.050, 0.050, -0.050 },
        blk_open_l = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_point_l = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_fist_l = { 4, 4, 4, 0.050, 0.050, 0.050 },
        blk_finger_l = { 1, 1, 2, -0.025, -0.025, 0.100 },
        blk_arm_l = { 4, 4, 8, 0.050, 0.050, -0.050 },
    },
}
-- BLK_END

-- BODY_BEGIN: generated by tools/gen_bodymodels.py (do not edit by hand)
BODY_MODELS = {   -- player characters (data/prefab/player/player_<id>.xml): tex = the character's texture,
                  -- bones = the vox elements of each SHOW bone body { object, pos (m), rot (deg) [, own
                  -- texture] }, att = the vox elements tagged attachment under a SHOW bone { object [, own
                  -- texture] }; file player/player_<id>.vox, scale 0.5 (docs/V022_PLAN.md section 1.2)
    billy_bones_jones = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.079951, 0.025239, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.499376, -0.02497, -0.025, -87.137535, 90, 0 } },
            leg_upper_r = { { "leg_band_r", 0.275906, 0.011236, 0, -87.13752, 90, 0 }, { "leg_upper_r", 0.499376, -0.024969, 0.025, -87.13752, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.374, 0.027, 0, -94.085907, 90.000008, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.374, 0.027, 0, -94.085258, 90.000008, 0 } },
            foot_l = { { "foot_l", 0.125, 0.025001, 0, -90.000015, 89.999992, 0.000009 } },
            foot_r = { { "foot_r", 0.125, 0.024997, 0, -90.000031, 90.000008, 0.000003 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000007, 89.999969, -0.000017 } },
            toes_r = { { "toes_r", 0.049997, 0, 0, -0.000005, 89.999992, 0.000005 } },
        },
        att = { { "brick", "12 0.75" } } },
    bjorn = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, 0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.025, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.025, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.025001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.024996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = { { "hood" }, { "radio" } } },
    carlos_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.125, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, -0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, -0.024999, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.025, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.025, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.075001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.074996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = { { "hood" } } },
    chris_seabranch = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.05, 0.05, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.05, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.000219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.398822, -0.03068, 0, -85.601112, 90, 0.000003 } },
            leg_upper_r = { { "leg_upper_r", 0.398822, -0.030677, 0, -85.60154, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.324, 0.027, 0.025, -94.763985, 90, 0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.324, 0.027, 0.025, -94.763542, 90, 0 } },
            foot_l = { { "sock_l", 0.025, 0.000001, 0, -90.000031, 90, 0.000014 }, { "foot_l", 0.125, 0.025001, 0.025, -90.000031, 90, 0.000014 } },
            foot_r = { { "sock_r", 0.025, 0.000001, 0, -90.000015, 90, 0.000002 }, { "foot_r", 0.125, 0.025001, 0.025, -90.000015, 90, 0.000002 } },
            toes_l = { { "toes_l", 0.050001, 0, 0.025, -0.000014, 89.999992, -0.000019 } },
            toes_r = { { "toes_r", 0.050001, 0, 0.025, -0.000005, 89.999969, 0.000005 } },
        },
        att = { { "prop_towel" }, { "prop_cleaver", "12 0.75" } } },
    freya = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "buckle_back", 0.1, -0.0625, -0.025, -90.000023, -90.000008, 0.00001 }, { "stomach", -0.025, 0, 0, -90.000023, -90.000008, 0.00001 }, { "buckle", 0.1, 0.1125, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.050239, 0, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.450691, -0.001468, 0.025, -86.633591, 90.000008, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.450692, -0.001465, 0.025, -86.633873, 90, -0.000002 } },
            leg_lower_l = { { "leg_lower_l", 0.325943, -0.003325, 0, -93.814255, 90, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.325943, -0.003325, 0, -93.813866, 90, -0.000003 } },
            foot_l = { { "foot_l", 0.1, 0.05, 0, -90, 89.999992, 0.00001 } },
            foot_r = { { "foot_r", 0.1, 0.05, 0, -90.000008, 90, -0.000002 } },
            toes_l = { { "toes_l", 0.05, 0, 0, 0.000002, 89.999969, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.000005, 89.999985, 0.000005 } },
        },
        att = { { "stereo" } } },
    fumiaki_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.125, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, 0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.025, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.025, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.075001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.074996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = { { "hood" }, { "wrench", "12 0.75" } } },
    gina_campbell = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "belt_buckle", 0, 0.15, 0, -90.000023, -90.000008, 0.00001 }, { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "badge", 0.15, 0.13772, 0.05, -90.000023, -90.000008, 0.00001 }, { "chest", -0.025, 0.02522, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024999, 0.025, -89.999916, 90, -0.000003 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000145, 90, 0 } },
            leg_lower_l = { { "boot_cuff_l", 0.172949, 0.036586, 0.025, -93.814507, 90, 0.000002 }, { "leg_lower_l", 0.424058, 0.028273, 0, -93.814507, 90, 0.000002 } },
            leg_lower_r = { { "boot_cuff_r", 0.17295, 0.036585, 0.025, -93.813507, 90, 0 }, { "leg_lower_r", 0.424059, 0.028267, 0, -93.813507, 90, 0 } },
            foot_l = { { "foot_l", 0.1, 0.075, 0, -90.000031, 90, 0.00001 } },
            foot_r = { { "foot_r", 0.1, 0.075, 0, -90.000038, 90, 0.000003 } },
            toes_l = { { "toes_l", 0.050005, 0, 0, -0.000017, 89.999992, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, -0.00001, 89.999992, 0 } },
        },
        att = { { "purse_l" } } },
    ingrid_funke = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.05, 0.025, -0.025, -90.000023, -90.000008, 0.00001 }, { "buckle", 0, 0.1, 0, -90.000023, -90.000008, 0.00001 } },
            chest = { { "bow-tie", 0.25, 0.125219, 0, -90.000023, -90.000008, 0.00001 }, { "chest", 0, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.400777, -0.001665, 0.025, -86.185715, 90, 0 }, { "knee_pad_l", 0.427385, 0.021617, -0.005, -86.185715, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.400777, -0.001661, 0.025, -86.186241, 90, 0 }, { "knee_pad_r", 0.427385, 0.021621, 0.005, -86.186241, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.376, 0.002, 0, -94.085777, 90.000008, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.376, 0.002, 0, -94.085381, 90, 0 } },
            foot_l = { { "foot_l", 0.125, 0.049999, 0, -90.000031, 90, 0.000012 } },
            foot_r = { { "foot_r", 0.125, 0.050001, 0, -90.000015, 90, 0 } },
            toes_l = { { "toes_l", 0.049999, 0, 0, -0.000014, 89.999992, -0.000019 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.000002, 89.999985, 0.000007 } },
        },
        att = {} },
    james_thorvaldsson = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, 0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.025, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.025, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.025001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.024996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = { { "hood" }, { "radio" } } },
    keiko_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis_flat", -0.05, 0.099998, -0.025, -89.999863, -90, 0.000007 }, { "pelvis", -0.1, -0.025002, -0.025, -89.999863, -90, 0.000007 } },
            stomach = { { "stomach", -0.075, -0.000001, 0, -89.999863, -90, 0.000007 } },
            chest = { { "chest", -0.025, 0.050179, -0.025, -89.999863, -90, 0.000007 } },
            leg_upper_l = { { "knee_l", 0.477116, 0.022018, -0.005, -86.633377, 90, 0 }, { "leg_upper_l", 0.450691, -0.001471, 0.025, -86.633377, 90, 0 } },
            leg_upper_r = { { "knee_r", 0.477116, 0.02202, 0.005, -86.633606, 90.000008, -0.000003 }, { "leg_upper_r", 0.447755, -0.051383, 0.025, -86.633606, 90.000008, -0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.375829, -0.001561, 0, -93.576523, 90, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.375829, -0.001562, 0, -93.576065, 90, -0.000003 } },
            foot_l = { { "foot_l", 0.125, 0.05, 0, -89.999855, 89.999992, 0.00001 } },
            foot_r = { { "foot_r", 0.125, 0.05, 0, -89.999863, 90.000008, 0 } },
            toes_l = { { "toes_l", 0.050002, 0, 0, 0.000152, 89.999985, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.00015, 90.000023, 0.000014 } },
        },
        att = { { "backpack" }, { "tape" } } },
    lisa_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1, -0.025002, -0.025, -89.999863, -90, 0.000007 }, { "pelvis_flat", -0.05, 0.099998, -0.025, -89.999863, -90, 0.000007 } },
            stomach = { { "stomach", -0.075, -0.000001, 0, -89.999863, -90, 0.000007 } },
            chest = { { "chest", -0.025, 0.050179, -0.025, -89.999863, -90, 0.000007 } },
            leg_upper_l = { { "leg_upper_l", 0.450691, -0.001471, 0.025, -86.633377, 90, 0 }, { "knee_l", 0.477116, 0.022018, -0.005, -86.633377, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.450692, -0.001469, 0.025, -86.633606, 90.000008, -0.000003 }, { "knee_r", 0.477116, 0.02202, 0.005, -86.633606, 90.000008, -0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.375829, -0.001561, 0, -93.576523, 90, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.375829, -0.001562, 0, -93.576065, 90, -0.000003 } },
            foot_l = { { "foot_l", 0.125, 0.05, 0, -89.999855, 89.999992, 0.00001 } },
            foot_r = { { "foot_r", 0.125, 0.05, 0, -89.999863, 90.000008, 0 } },
            toes_l = { { "toes_l", 0.050002, 0, 0, 0.000152, 89.999985, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.00015, 90.000023, 0.000014 } },
        },
        att = { { "backpack" }, { "spanner", "12 0.75" } } },
    magnus = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1, 0, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.00018, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.349731, -0.028511, 0.025, -81.253769, 90, -0.000002 } },
            leg_upper_r = { { "leg_upper_r", 0.349732, -0.028511, 0.025, -81.253784, 90, 0 } },
            leg_lower_l = { { "leg_knee_l", 0.114905, 0.079549, 0.02, -98.130219, 90, 0 }, { "leg_lower_l", 0.375, 0.028, 0.02, -98.130219, 90, 0 } },
            leg_lower_r = { { "leg_knee_r", 0.114905, 0.07955, 0.03, -98.130074, 90.000008, 0 }, { "leg_lower_r", 0.375, 0.028, 0.03, -98.130074, 90.000008, 0 } },
            foot_l = { { "foot_l", 0.125, 0.025001, 0.02, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.125, 0.025, 0.03, -90.000031, 90.000008, 0 } },
            toes_l = { { "toes_l", 0.05, 0, 0.02, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.05, 0, 0.03, -0.000007, 89.999992, 0.000007 } },
        },
        att = { { "prop_hook" }, { "prop_fish" }, { "backpack" } } },
    maria_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis_flat", -0.05, 0.099998, -0.025, -89.999863, -90, 0.000007 }, { "pelvis", -0.1, -0.025002, -0.025, -89.999863, -90, 0.000007 } },
            stomach = { { "stomach", -0.075, -0.000001, 0, -89.999863, -90, 0.000007 } },
            chest = { { "chest", -0.025, 0.050179, -0.025, -89.999863, -90, 0.000007 } },
            leg_upper_l = { { "knee_l", 0.477116, 0.022018, -0.005, -86.633377, 90, 0 }, { "leg_upper_l", 0.450691, -0.001471, 0.025, -86.633377, 90, 0 } },
            leg_upper_r = { { "knee_r", 0.477116, 0.02202, 0.005, -86.633606, 90.000008, -0.000003 }, { "leg_upper_r", 0.450692, -0.001469, 0.025, -86.633606, 90.000008, -0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.375829, -0.001561, 0, -93.576523, 90, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.375829, -0.001562, 0, -93.576065, 90, -0.000003 } },
            foot_l = { { "foot_l", 0.125, 0.05, 0, -89.999855, 89.999992, 0.00001 } },
            foot_r = { { "foot_r", 0.125, 0.05, 0, -89.999863, 90.000008, 0 } },
            toes_l = { { "toes_l", 0.050002, 0, 0, 0.000152, 89.999985, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.00015, 90.000023, 0.000014 } },
        },
        att = { { "backpack" }, { "pincers", "12 0.75" } } },
    monty_quilez = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1, 0, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.175, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "quilez_tail", 0.1, -0.087278, -0.1, -90.000023, -90.000008, 0.00001 }, { "quilez", 0.125, -0.087278, -0.025, -90.000023, -90.000008, 0.00001 }, { "chest", -0.025, 0.025222, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.398983, -0.0285, -0.025, -85.914215, 90, -0.000002 } },
            leg_upper_r = { { "leg_upper_r", 0.398984, -0.028497, 0.025, -85.914665, 90, 0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.027, 0.025, -93.814278, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.027, 0.025, -93.813805, 90, 0.000003 } },
            foot_l = { { "sock_l", 0.025, 0, 0, -90.000023, 89.999992, 0.000007 }, { "foot_l", 0.125, 0.025, 0.025, -90.000023, 89.999992, 0.000007 } },
            foot_r = { { "sock_r", 0.025, 0, 0, -90.000015, 90, 0.000003 }, { "foot_r", 0.125, 0.025, 0.025, -90.000015, 90, 0.000003 } },
            toes_l = { { "toes_l", 0.05, 0, 0.025, -0.000012, 89.999992, -0.000022 } },
            toes_r = { { "toes_r", 0.05, 0, 0.025, -0.000002, 89.999969, 0.000002 } },
        },
        att = {} },
    nils_andree = { tex = "12 0.65",
        bones = {
            pelvis = { { "pelvis", -0.1, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "collar", 0.25, 0.02522, -0.025, -90.000023, -90.000008, 0.00001 }, { "chest", -0.025, 0.00022, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.450691, -0.001469, 0, -86.633453, 90, -0.000005 } },
            leg_upper_r = { { "leg_upper_r", 0.450692, -0.001467, 0, -86.633621, 90, 0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.375, 0.028, -0.012, -98.130203, 90, -0.000005 } },
            leg_lower_r = { { "leg_lower_r", 0.375, 0.028, 0.013, -98.129951, 90, 0.000005 } },
            foot_l = { { "sock_l", 0.075, 0.025, 0.0125, -90.000023, 89.999992, 0.000007 }, { "foot_l", 0.125, 0.05, 0, -90.000023, 89.999992, 0.000007 } },
            foot_r = { { "sock_r", 0.075, 0.025, 0.0375, -90.000015, 90, 0.000005 }, { "foot_r", 0.125, 0.05, 0, -90.000015, 90, 0.000005 } },
            toes_l = { { "toes_l", 0.05, 0, 0, -0.000012, 89.999992, -0.000022 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.000002, 89.999969, 0.000002 } },
        },
        att = { { "hood" } } },
    parisa = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.075, 0.075, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.02524, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "knee_l", 0.45, -0.000003, 0, -89.999672, 90, 0 }, { "leg_upper_l", 0.425, 0.024997, 0.025, -89.999672, 90, 0 } },
            leg_upper_r = { { "knee_r", 0.45, 0.000002, 0, -90.000282, 90, -0.000003 }, { "leg_upper_r", 0.425, 0.025002, 0.025, -90.000282, 90, -0.000003 } },
            leg_lower_l = { { "leg_lower_l", 0.372, 0.052, 0.023, -94.086258, 90, 0 } },
            leg_lower_r = { { "leg_lower_r", 0.372, 0.052, 0.028, -94.085182, 90, 0.000002 } },
            foot_l = { { "sock_l", 0.025, 0.025001, 0, -90.000015, 89.999992, 0.00001 }, { "foot_l", 0.125, 0.050002, 0, -90.000015, 89.999992, 0.00001 } },
            foot_r = { { "sock_r", 0.025, 0.024999, 0, -90.000015, 90, 0 }, { "foot_r", 0.125, 0.049999, 0, -90.000015, 90, 0 } },
            toes_l = { { "toes_l", 0.050002, 0, 0, -0.000007, 89.999969, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.000002, 89.999985, 0.000007 } },
        },
        att = {} },
    sam_sandstream = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.1125, 0, -0.025, -90.000023, -90.000008, 0.00001 }, { "pocket_r", 0.0125, 0.025, -0.2, -90.000023, -90.000008, 0.00001 }, { "pocket_l", 0.0125, 0.025, 0.15, -90.000023, -90.000008, 0.00001 }, { "leg_sockets", -0.0625, 0.025, -0.025, -90.000023, -90.000008, 0.00001 }, { "belt_buckle", 0.0625, 0.125, 0, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.05, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", 0, 0.025259, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.3625, -0.000003, 0, -89.999626, 90, -0.000003 } },
            leg_upper_r = { { "leg_upper_r", 0.3625, 0.000002, 0, -90.000313, 90, 0 } },
            leg_lower_l = { { "knee_l", 0.048226, 0.028268, 0.025, -93.814484, 90, 0 }, { "leg_lower_l", 0.449003, 0.029934, 0, -93.814484, 90, 0 }, { "boot_cuff_l", 0.397, 0.052, 0.025, -93.814484, 90, 0 } },
            leg_lower_r = { { "knee_r", 0.048226, 0.028272, 0.025, -93.813782, 90, -0.000002 }, { "leg_lower_r", 0.449003, 0.029933, 0, -93.813782, 90, -0.000002 }, { "boot_cuff_r", 0.397, 0.052, 0.025, -93.813782, 90, -0.000002 } },
            foot_l = { { "foot_l", 0.125, 0.05, 0.025, -90.000031, 90, 0.000009 } },
            foot_r = { { "foot_r", 0.125, 0.05, 0.025, -90.000008, 90, -0.000002 } },
            toes_l = { { "toes_l", 0.05, 0, 0, -0.000017, 89.999992, -0.000017 } },
            toes_r = { { "toes_r", 0.05, 0, 0, 0.000005, 89.999985, 0.000005 } },
        },
        att = {} },
    spacesuit = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, 0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399221, 0.024953, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399221, 0.024948, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.025001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.024996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = {} },
    sven_lagom = { tex = "12 0.5",
        bones = {
            pelvis = { { "pelvis", -0.075, -0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            stomach = { { "stomach", -0.025, 0.025, -0.025, -90.000023, -90.000008, 0.00001 } },
            chest = { { "chest", -0.025, 0.025219, -0.025, -90.000023, -90.000008, 0.00001 } },
            leg_upper_l = { { "leg_upper_l", 0.425, 0.024998, 0.025, -89.999786, 90, 0 } },
            leg_upper_r = { { "leg_upper_r", 0.425, 0.025001, 0.025, -90.000107, 90, 0 } },
            leg_lower_l = { { "leg_lower_l", 0.399, 0.025, 0, -93.576767, 90, -0.000003 } },
            leg_lower_r = { { "leg_lower_r", 0.399, 0.025, 0, -93.575706, 90, 0.000002 } },
            foot_l = { { "foot_l", 0.1, 0.025001, 0, -90.000008, 89.999985, 0.000005 } },
            foot_r = { { "foot_r", 0.1, 0.024996, 0, -90.000015, 89.999992, 0 } },
            toes_l = { { "toes_l", 0.050001, 0, 0, -0.000005, 89.999969, -0.000019 } },
            toes_r = { { "toes_r", 0.049996, 0, 0, 0, 89.999992, -0.000005 } },
        },
        att = { { "hood" }, { "radio" } } },
}
-- BODY_END

local LINE_HAND = {   -- generated by tools/gen_hands.py: polylines x,y,z (cm, right hand, model frame)
    open = { { 3.3, -4.5, -1.7, 3.3, 4.5, -1.7, 3.3, 3.5, 7.4, 3.3, -3.5, 7.4, 3.3, -4.5, -1.7 }, { 3, 3.5, -1.4, 3, 3.9, -5, 2.8, 4.2, -7.3, 2.7, 4.4, -8.3 }, { 3, 1, -1.7, 3, 1.1, -5.7, 2.8, 1.1, -8.3, 2.7, 1.1, -9.5 }, { 3, -1.5, -1.5, 3, -1.8, -5.3, 2.8, -2, -7.7, 2.7, -2.1, -8.8 }, { 3.2, -3.8, -0.9, 3.2, -4.4, -3.8, 3.1, -4.7, -5.6, 3, -4.9, -6.5 }, { 2.9, 2.6, 5, 2.5, 5.2, 2.2, 2.2, 6.5, -0.6, 2, 7, -2.6 } },
    point = { { 3.3, -4.5, -1.7, 3.3, 4.5, -1.7, 3.3, 3.5, 7.4, 3.3, -3.5, 7.4, 3.3, -4.5, -1.7 }, { 3, 3.5, -1.4, 2.8, 3.6, -5, 2.5, 3.7, -7.3, 2.4, 3.7, -8.4 }, { 3, 1, -1.7, -0.7, 1, -3.2, -2.8, 1, -1.7, -3.2, 1, -0.5 }, { 3, -1.5, -1.5, -0.4, -1.5, -3.3, -2.5, -1.5, -2.1, -3, -1.5, -1.2 }, { 3.2, -3.8, -0.9, 1.2, -3.8, -3.1, -0.6, -3.8, -3.2, -1.4, -3.8, -2.9 }, { 2.9, 2.6, 5, 1.8, 4.6, 3.5, -1.3, 5, 3.1, -3.1, 4.8, 1 } },
    fist = { { 3.3, -4.5, -1.7, 3.3, 4.5, -1.7, 3.3, 3.5, 7.4, 3.3, -3.5, 7.4, 3.3, -4.5, -1.7 }, { 3, 3.5, -1.4, -0.1, 3.5, -3.3, -2.2, 3.5, -2.4, -2.8, 3.5, -1.5 }, { 3, 1, -1.7, -0.7, 1, -3.2, -2.8, 1, -1.7, -3.2, 1, -0.5 }, { 3, -1.5, -1.5, -0.4, -1.5, -3.3, -2.5, -1.5, -2.1, -3, -1.5, -1.2 }, { 3.2, -3.8, -0.9, 1.2, -3.8, -3.1, -0.6, -3.8, -3.2, -1.4, -3.8, -2.9 }, { 2.9, 2.6, 5, 1.8, 4.6, 3.5, -1.3, 5, 3.1, -3.1, 4.8, 1 } },
}

local HAND_POSES = { "open", "point", "fist" }
-- One static, non-colliding body per hand ("tdvr_hand=r" / "=l") with the three pose shapes; the shown
-- pose is the one without the "invisible" tag.
local hands = {
    spawned = false, failed = false, skin = -1,
    body = {},                                  -- side ("r"/"l") -> body handle
    shapes = { r = {}, l = {} },                -- side -> pose -> shape handle
    shown = { r = false, l = false },           -- visible glove pose per side (false = hidden)
    want = { r = "open", l = "open" },          -- pose selected this tick (also used by the line hands)
    squeeze = { r = false, l = false }, trigger = { r = false, l = false },   -- hysteresis states
    static = false, allShapes = false, sizeOk = false, lines = false,
    pickHits = 0, pickRun = 0, safety = false, safetyHide = false, noPickTime = 0,
    countTimer = 1000, count = 0, renderPlaced = false,
    cleaned = false,                            -- unwanted glove bodies deleted (see updateHands)
    clock = 0, spawnT = -1000, badSpawns = 0, judge = false,   -- re-spawn rate limit (see respawnHands)
    -- v0.5: vox scale attribute (HAND_VOXEL from the generated block; 0.1 = 1 cm voxels until it exists), the bounds
    -- check (see verifyHands: samples left, last error code (margin mm * 1000 + centre error mm, handBoundsCheck), result
    -- L_HAND_MAPPING with -2 = not run yet), fist_r's
    -- GetShapeSize encoded x*10000 + y*100 + z. v0.5 review: sizeKnown = GetShapeSize gave a size; voxelMm = its 4th
    -- return (mm*10, -1 n/a); bUpd/bLast = update() count and result at the last bounds sample. (v0.6: no axis mapping
    -- any more, the grid order is the model's, see applyHandLayout)
    voxel = HAND_VOXEL or 0.1, bstep = 0, bErr = -1, mapping = -2, sizeR = 0,
    sizeKnown = false, voxelMm = -1, bUpd = 0, bLast = nil,
    -- v0.8: bodyStatic = the gloves were spawned as static bodies (handBodyStatic at the spawn), park = side -> where a
    -- glove body was last put (spawn point, the hand, or away by the pick safety; parkOwnBody holds a hidden one there)
    bodyStatic = false, park = {},
    -- v0.21 (docs/V021_PLAN.md section 3.2, blocky hands = hands.skin 2): extra = side -> { arm = shape, finger = shape }
    -- (the blocky forearm and pointing finger, on the glove body; empty for glove / skin), extraOk = all 4 extras found
    -- with their voxel size within 10 %, blkFail = the blocky spawn failed in this Lua state (no shapes or a voxel size
    -- the engine did not honour: the glove texture instead, L_HCOL fail 7), varC = the blocky pose shapes are spawned
    -- without collide="false" (the variant-C respawn of the solid hands, spawnHands{ varC = true })
    extra = { r = {}, l = {} }, extraOk = false, blkFail = false, varC = false,
}

-- v0.21 (docs/V021_PLAN.md section 3.2): the generated entry { x, y, z voxels, corner -> grip offset } of a pose shape
-- ("open" / "point" / "fist") or, blocky only, an extra ("arm" / "finger") of one side ("r" / "l"): BLK.PARTS while the
-- spawned texture is blocky (hands.skin 2), else HAND_PARTS (glove / skin; no extras: nil).
function handPart(pose, side)
    if hands.skin == 2 then return BLK and BLK.PARTS["blk_" .. pose .. "_" .. side] end
    return HAND_PARTS[pose .. "_" .. side]
end

-- v0.21 (section 3.2, was HP.PALM): the palm centre in the hand model frame (right hand; x mirrored for the left):
-- blocky inside the cube on the palm side, glove / skin HP.PALM.
function handPalm()
    if hands.skin == 2 then return { -0.03, 0, 0 } end
    return HP.PALM
end

-- Model frame -> grip frame (HAND_XFORM): base mapping QuatAxisAngle(Vec(1,0,0), -90) (model -Z, the fingers,
-- -> grip -Y; model +Y, the thumb, -> grip -Z), then the ini extra rotation about grip X, then Y, then Z
-- (degrees) and the ini extra position (grip frame, metres). The ini values are for the right hand; the left
-- hand gets their mirror in X (M*xf*M, M = diag(-1,1,1)): position (-x, y, z), angles (rx, -ry, -rz).
function handXform(mirror)
    local r, p = nat.handOfsR or { 0, 0, 0 }, nat.handOfsP or { 0, 0, 0 }
    local m = mirror and -1 or 1
    local rx, ry, rz = r[1] or 0, (r[2] or 0) * m, (r[3] or 0) * m
    local rot = QuatAxisAngle(Vec(1, 0, 0), -90)
    if rx ~= 0 then rot = QuatRotateQuat(QuatAxisAngle(Vec(1, 0, 0), rx), rot) end
    if ry ~= 0 then rot = QuatRotateQuat(QuatAxisAngle(Vec(0, 1, 0), ry), rot) end
    if rz ~= 0 then rot = QuatRotateQuat(QuatAxisAngle(Vec(0, 0, 1), rz), rot) end
    return Transform(Vec((p[1] or 0) * m, p[2] or 0, p[3] or 0), rot)
end

function validBody(h)
    return h ~= nil and (not IsHandleValid or IsHandleValid(h))
end

function isGloveBody(b)
    return b ~= nil and b ~= 0 and (b == hands.body.r or b == hands.body.l)
end

-- v0.8 (docs/V08_PLAN.md section 3): the gloves and the tool replica are DYNAMIC bodies by default. History of the
-- headset logs: no glove bodies (v0.5) 120-160 fps, two static glove bodies moved every frame (v0.6) ~60 fps, plus a
-- static replica (v0.7) ~20 fps with the GPU idle; the hypothesis is that moving a STATIC body makes the engine rebuild
-- its static-world data every time. Static bodies (the v0.7 way) with hand_body = static (N_HAND_BODY 1) or the A/B-test
-- bit (N_PERF_FLAGS bit6, PF.STATIC_HANDS). Both kinds keep collide='false', the 0/0 collision filter and the tags
-- unbreakable nocull noquery nonav; a change respawns the gloves and rebuilds the replica.
function handBodyStatic()
    return nat.valid and ((nat.handBody or 0) == 1 or hasBit(nat.perf, PF.STATIC_HANDS)) or false
end

-- v0.8: puts one of our own bodies (a glove or the tool replica) at t. A dynamic one (not reported static by
-- IsBodyDynamic) also gets its linear and angular velocity zeroed, every time: it is simulated between two placements
-- (gravity, an explosion's impulse) and must neither drift nor carry speed into the next frame. A body that is not shown
-- is held at its last place the same way every tick (parkOwnBody), so it cannot fall away.
function placeOwnBody(b, t)
    if not validBody(b) then return end
    SetBodyTransform(b, t)
    if engineCall(IsBodyDynamic, b) ~= false then
        engineCall(SetBodyVelocity, b, Vec(0, 0, 0))
        engineCall(SetBodyAngularVelocity, b, Vec(0, 0, 0))
    end
end

-- v0.8: a hidden dynamic body (glove pose not shown, replica not shown) is put back at park (its last place) each tick;
-- a static one is left alone (nothing moves it, and moving a static body is what costs).
-- v0.21 (docs/V021_PLAN.md section 6.2): a glove that is a variant-C collider in FREE / BLOCKED (HC.owns) is not moved.
-- That side becomes a GHOST in hcolTick (HC.rules is told the glove is not shown, hands.shown), which runs after
-- updateHands in the same tick: a state set here would be undone there.
function parkOwnBody(b, park)
    if HC.var == 3 and isGloveBody(b) then
        local side = (b == hands.body.r) and "r" or "l"
        if HC.owns(side) then return end
    end
    if park and validBody(b) and engineCall(IsBodyDynamic, b) == true then placeOwnBody(b, park) end
end

-- Query filters apply to the next query only: called right before the laser raycast and the hands' reach queries.
-- Our own bodies (gloves, v0.6 tool replica) and, with `held`, the bodies the physical hands hold (the laser passes
-- through them like through the engine's carried object; a reach query must still find the other hand's body).
-- v0.22 (review LUA22-3): the held bodies first (should the engine cap the reject list, they matter most), then ours; the
-- body copies (v0.22 section 1.9) unless noCopies - the hands' queries (hcolQueryFilter) never see them anyway (collide
-- false, filter 0/0, QueryCollisionMask / "physical") - in one QueryRejectBodies call where the API has it.
function rejectOwnBodies(held, noCopies)
    if held then
        if phys.l.hold then QueryRejectBody(phys.l.hold.body) end
        if phys.r.hold then QueryRejectBody(phys.r.hold.body) end
    end
    if hands.body.r then QueryRejectBody(hands.body.r) end
    if hands.body.l then QueryRejectBody(hands.body.l) end
    if replica.body ~= 0 then QueryRejectBody(replica.body) end
    -- (v0.21 section 6.7: the solid hands' and shins' colliders)
    if HC.r.body then QueryRejectBody(HC.r.body) end
    if HC.l.body then QueryRejectBody(HC.l.body) end
    if BC.r.body then QueryRejectBody(BC.r.body) end
    if BC.l.body then QueryRejectBody(BC.l.body) end
    if not noCopies and #BCOPY.list > 0 then
        if QueryRejectBodies then
            engineCall(QueryRejectBodies, BCOPY.bodyArray())
        else
            for i = 1, #BCOPY.list do QueryRejectBody(BCOPY.list[i].body) end
        end
    end
end

-- Deletes every glove body in the scene (also stale copies: a quickload keeps spawned bodies, but our handles
-- are gone) and forgets our handles.
function deleteGloves()
    if FindBodies and Delete then
        local old = FindBodies("tdvr_hand", true) or {}
        for i = 1, #old do Delete(old[i]) end
    end
    hands.body, hands.shapes, hands.shown = {}, { r = {}, l = {} }, { r = false, l = false }
    hands.extra, hands.extraOk = { r = {}, l = {} }, false
    deleteColliders()                     -- (v0.21 section 6.7: the solid hands' / shins' / self-test bodies with them)
end

-- GetShapeSize of every glove shape: { part, x, y, z } per shape (v0.5 review H1/H2). Also fist_r's size code, whether
-- any size came back, and the voxel size check: GetShapeSize's 4th return (metres) must be within 10% of
-- HAND_VOXEL * 0.1 for every shape, else the engine did not honour the vox scale (giant gloves). Returns the sizes
-- and true if a voxel size is wrong.
function handShapeSizes()
    local out, want, bad = {}, hands.voxel * 0.1, false
    hands.sizeKnown, hands.voxelMm, hands.sizeR = false, -1, 0
    for s = 1, 2 do
        local side = (s == 1) and "r" or "l"
        for p = 1, 3 do
            local sh = hands.shapes[side][HAND_POSES[p]]
            if sh then
                local x, y, z, v = 0, 0, 0, nil
                if GetShapeSize then
                    local ok, a, b, c, d = pcall(GetShapeSize, sh)
                    if ok then x, y, z, v = a or 0, b or 0, c or 0, d end
                end
                out[#out + 1] = { handPart(HAND_POSES[p], side), x, y, z }   -- (v0.21: blocky BLK.PARTS)
                if x > 0 and y > 0 and z > 0 then
                    hands.sizeKnown = true
                    if type(v) == "number" then
                        if side == "r" and p == 3 then hands.voxelMm = v * 10000 end
                        if math.abs(v - want) > want * 0.1 then bad = true end
                    end
                end
                if side == "r" and p == 3 then hands.sizeR = x * 10000 + y * 100 + z end
            end
        end
    end
    return out, bad
end

-- Every measured size equals its HAND_PARTS size (v0.6: the grid order is the model's, no axis mapping).
function handSizesFit(sizes)
    for i = 1, #sizes do
        local e = sizes[i]
        if e[2] ~= e[1][1] or e[3] ~= e[1][2] or e[4] ~= e[1][3] then return false end
    end
    return #sizes > 0
end

-- Every glove shape's local transform (v0.6, docs/V06_PLAN.md section 6): Transform(-c), c = the HAND_PARTS corner
-- offset, with the IDENTITY rotation. The v0.5 headset log showed GetShapeSize(fist_r) in the file's MagicaVoxel order
-- (19x33x21 for a 19x21x33 model): a shape's voxel grid is indexed in MV order and SetShapeLocalTransform maps grid
-- coordinates directly (any axis rotation of the loader is gone once we set the local transform). tools/gen_hands.py
-- now writes MV (x, y, z) = model (x, y, z), so the grid's (0,0,0) corner at -c puts the model origin (the grip) at the
-- body origin, and every GetShapeSize equals its HAND_PARTS size. The size check (L_HANDS_STATE bit3, L_HAND_MAPPING 99)
-- is reported only: no rotation search any more, nothing is given up for it. Returns true if a voxel size is wrong
-- (see handShapeSizes): only that, or a failed Spawn, falls back to the line hands.
-- v0.21 (docs/V021_PLAN.md section 3.2): the blocky extras (forearm, finger) get the same corner layout from BLK.PARTS;
-- hands.extraOk = all 4 found and their voxel size (GetShapeSize's 4th return) within 10 % of hands.voxel * 0.1. A
-- wrong extra voxel size is a wrong blocky voxel size (returned as voxelBad, like a pose shape's).
function applyHandLayout()
    local sizes, voxelBad = handShapeSizes()
    hands.sizeOk = #sizes == 6 and handSizesFit(sizes)
    local extras, want = 0, hands.voxel * 0.1
    for s = 1, 2 do
        local side = (s == 1) and "r" or "l"
        for p = 1, 3 do
            local sh = hands.shapes[side][HAND_POSES[p]]
            local part = handPart(HAND_POSES[p], side)
            if sh then SetShapeLocalTransform(sh, Transform(Vec(-part[4], -part[5], -part[6]))) end
        end
        for kind, sh in pairs(hands.extra[side] or {}) do
            local part = handPart(kind, side)
            if part then
                SetShapeLocalTransform(sh, Transform(Vec(-part[4], -part[5], -part[6])))
                local _, _, _, v = engineCall(GetShapeSize, sh)
                if type(v) == "number" and math.abs(v - want) > want * 0.1 then voxelBad = true
                else extras = extras + 1 end
            end
        end
    end
    hands.extraOk = extras == 4
    return voxelBad
end

-- Bounds sample (L_HAND_BOUNDS_ERR, v0.6: diagnostics only). The right glove body sits at its spawn point with identity
-- rotation (it is not placed while the check runs), so GetShapeBounds(fist_r) (world AABB) must be the model box [-c,
-- -c + size * voxel] that applyHandLayout puts the grid in. v0.6 review GLV-1: the engine's AABB carries a margin (the
-- v0.5 headset log: boundsErr 20.0 mm and "big" on a placement that was right), so the judgement is margin-invariant:
-- per axis the margin m_i = (extent_i - size_i * voxel) / 2 and the centre error |box centre_i - model box centre_i|
-- (a uniform margin cancels in the centre; a wrong corner offset or rotation moves it). Returns the code for
-- L_HAND_BOUNDS_ERR: the smallest margin (mm, rounded, 0..999) * 1000 + the largest centre error (mm, at most 999)
-- (-1 n/a), and "ok" (the centre within max(0.6 voxel, 5 mm) and equal margins: none below -tol, all within tol of each
-- other: the engine put the grid where we did), "big" (unequal margins and the box's largest extent over 20 % above the
-- model's: the voxel size was not honoured), "off" (anything else), -1 (cannot be judged now: body rotated, bounds empty
-- or failing) or -2 (cannot be judged at all: a function is missing).
function handBoundsCheck()
    local sh, body = hands.shapes.r.fist, hands.body.r
    if not (sh and body and GetShapeBounds and GetBodyTransform) then return -1, -2 end
    local ok, mn, mx = pcall(GetShapeBounds, sh)
    if not ok or type(mn) ~= "table" or type(mx) ~= "table" or type(mn[3]) ~= "number" or type(mx[3]) ~= "number" then
        return -1, -1
    end
    local bt = GetBodyTransform(body)
    if quatAngle(bt.rot, Quat()) > 0.5 then return -1, -1 end
    local vs = hands.voxel * 0.1
    local lo, hi = VecSub(mn, bt.pos), VecSub(mx, bt.pos)
    local A = VecSub(hi, lo)
    if A[1] < vs * 0.5 or A[2] < vs * 0.5 or A[3] < vs * 0.5 then return -1, -1 end
    local part = handPart("fist", "r")               -- (v0.21: the blocky cube with hand_texture = blocky)
    local tol = math.max(vs * 0.6, 0.005)
    local cErr, mLo, mHi = 0, math.huge, -math.huge
    for i = 1, 3 do
        local size = part[i] * vs
        local m = (A[i] - size) * 0.5
        mLo, mHi = math.min(mLo, m), math.max(mHi, m)
        cErr = math.max(cErr, math.abs((lo[i] + hi[i]) * 0.5 - (size * 0.5 - part[i + 3])))
    end
    local code = clamp(math.floor(mLo * 1000 + 0.5), 0, 999) * 1000 + math.min(cErr * 1000, 999)
    local equal = mLo >= -tol and mHi - mLo <= tol
    if not equal and math.max(A[1], A[2], A[3]) > 1.2 * math.max(part[1], part[2], part[3]) * vs then return code, "big" end
    if equal and cErr <= tol then return code, "ok" end
    return code, "off"
end

-- L_HAND_MAPPING once the bounds check has ended (the v0.5 encoding, with the mapping index always 0 = identity since
-- v0.6): 100 * k, k = 0 the bounds agree, 1 they disagree, 2 they could not be judged; 99 GetShapeSize differs from the
-- HAND_PARTS sizes; -1 GetShapeSize gave no size; -2 not run yet / no gloves.
function handMappingCode(k)
    if not hands.sizeKnown then return -1 end
    if not hands.sizeOk then return 99 end
    return 100 * k
end

-- Bounds check (hands.bstep = samples left, 0 = not running), v0.6: diagnostics only, it can never disable the gloves
-- (the v0.5 headset test lost them to it: hands=0xCE). It decides only on two equal samples in a row (v0.5 review H1:
-- the engine may refresh a shape's AABB only in its physics step). A sample is taken only after an update() call since
-- the spawn or the last sample, or after 5 ticks without any. No two equal judged samples among 8, or no GetShapeBounds
-- at all: unverifiable. The right glove stays hidden and unplaced meanwhile.
function verifyHands()
    if hands.bstep == 0 then return end
    if perf.updTotal == hands.bUpd and heartbeat - (hands.bTick or 0) < 5 then return end
    hands.bTick, hands.bUpd = heartbeat, perf.updTotal
    local err, res = handBoundsCheck()
    if err >= 0 then hands.bErr = err end
    hands.bstep = hands.bstep - 1
    local same = type(res) == "string" and res == hands.bLast
    hands.bLast = res
    if not same and hands.bstep > 0 and res ~= -2 then return end
    hands.bstep = 0
    hands.mapping = handMappingCode(same and (res == "ok" and 0 or 1) or 2)
end

-- Deletes stale copies and spawns both gloves. No shape at all, or a voxel size the engine did not honour (v0.5
-- review H2), fails for good (line fallback); a missing body on either side is judged a failed spawn on the next
-- tick (see respawnHands). The vox scale attribute is HAND_VOXEL; the shape local transforms are set in this tick
-- (applyHandLayout, identity rotation), and the bounds diagnostics start on a later tick (verifyHands). v0.8: dynamic
-- bodies (dynamic="true", made dynamic with SetBodyDynamic if the engine spawned them static) unless handBodyStatic()
-- (dynamic="false", made static: the v0.7 gloves); hands.static (L_HANDS_STATE bit1) = both bodies are static.
-- v0.21 (docs/V021_PLAN.md section 3.2): hand_texture = blocky (N_HAND_SKIN 2): MOD/hands_blocky.vox at BLK.VOXEL, the
-- pose shapes blk_<pose>_<side> plus the extras blk_arm_<side> / blk_finger_<side> (tags tdvr_extra=arm|finger, in
-- hands.extra). Every shape keeps collide="false" and the 0/0 filter, except the blocky POSE shapes of a variant-C
-- respawn (opts.varC, kept in hands.varC for later respawns; the solid hands' self-test chose the visible glove as the
-- collider, section 6.2): spawned without collide="false" (the filter 0/0 is still set at once, in this call). A blocky
-- spawn without shapes or with a voxel size the engine did not honour sets hands.blkFail (for this Lua state) and spawns
-- the glove texture at once; a failed glove / skin spawn falls back to the line hands as before. Any other skin value
-- than 1 / 2 is the glove (as v0.20, which loads the glove for 2).
function spawnHands(opts)
    deleteGloves()
    local skin = nat.handSkin or 0
    if skin == 2 and hands.blkFail then skin = 0 end
    if opts ~= nil then hands.varC = opts.varC == true end
    local blk = skin == 2
    local varC = blk and hands.varC
    hands.spawned, hands.skin, hands.cleaned = true, skin, false
    hands.voxel = blk and BLK.VOXEL or (HAND_VOXEL or 0.1)
    hands.spawnT, hands.judge = hands.clock, true
    local wantStatic = handBodyStatic()
    hands.bodyStatic = wantStatic
    local file = blk and "MOD/hands_blocky.vox" or ((skin == 1) and "MOD/hands_skin.vox" or "MOD/hands_glove.vox")
    local at = Transform(GetPlayerEyeTransform().pos)
    hands.park = { r = at, l = at }
    local found, static = 0, true
    for s = 1, 2 do
        local side = (s == 1) and "r" or "l"
        local xml = '<body tags="tdvr_hand=' .. side .. ' nomerge" dynamic="' .. (wantStatic and "false" or "true") .. '">'
        for p = 1, 3 do
            xml = xml .. '<vox tags="tdvr_pose=' .. HAND_POSES[p] .. ' unbreakable nocull noquery nonav" file="' .. file
                .. '" object="' .. (blk and "blk_" or "") .. HAND_POSES[p] .. "_" .. side .. '" scale="'
                .. tostring(hands.voxel) .. '"' .. (varC and "" or ' collide="false"') .. '/>'
        end
        if blk then
            for _, kind in ipairs({ "arm", "finger" }) do
                xml = xml .. '<vox tags="tdvr_extra=' .. kind .. ' unbreakable nocull noquery nonav" file="' .. file
                    .. '" object="blk_' .. kind .. "_" .. side .. '" scale="' .. tostring(hands.voxel)
                    .. '" collide="false"/>'
            end
        end
        local ents = (Spawn and Spawn(xml .. "</body>", at, true)) or {}
        if type(ents) ~= "table" then ents = {} end
        for i = 1, #ents do
            local h = ents[i]
            local kind = GetEntityType and GetEntityType(h) or ""
            if kind == "body" then
                hands.body[side] = h
            elseif kind == "shape" then
                if SetShapeCollisionFilter then SetShapeCollisionFilter(h, 0, 0) end
                local pose = GetTagValue and GetTagValue(h, "tdvr_pose")
                if type(pose) == "string" and pose ~= "" and handPart(pose, side)
                    and not hands.shapes[side][pose] then
                    hands.shapes[side][pose] = h
                    found = found + 1
                elseif blk then
                    local ex = GetTagValue and GetTagValue(h, "tdvr_extra")
                    if (ex == "arm" or ex == "finger") and not hands.extra[side][ex] then hands.extra[side][ex] = h end
                end
            end
        end
        local body = hands.body[side]
        if body and IsBodyDynamic and IsBodyDynamic(body) == wantStatic then
            if SetBodyDynamic then SetBodyDynamic(body, not wantStatic) end
        end
        if not body or (IsBodyDynamic and IsBodyDynamic(body)) or (not IsBodyDynamic and not wantStatic) then
            static = false
        end
        for p = 1, 3 do
            local sh = hands.shapes[side][HAND_POSES[p]]
            if sh then SetTag(sh, "invisible") end
        end
        for _, sh in pairs(hands.extra[side]) do SetTag(sh, "invisible") end
    end
    local voxelBad = applyHandLayout()
    if blk and (found == 0 or voxelBad) then
        hands.blkFail = true                   -- (section 3.2: the glove texture instead, for this Lua state)
        return spawnHands()
    end
    hands.failed = found == 0 or voxelBad
    hands.allShapes = found == 6
    hands.static = static
    hands.bstep, hands.bErr, hands.mapping, hands.bLast = 0, -1, -2, nil
    if hands.failed then                       -- leave nothing behind; the line hands take over
        for s = 1, 2 do
            local b = hands.body[(s == 1) and "r" or "l"]
            if b and Delete then Delete(b) end
        end
        hands.body = {}
        if voxelBad then hands.mapping = handMappingCode(2) end   -- (the bounds are not looked at)
    else
        hands.bstep, hands.bTick, hands.bUpd = 8, heartbeat, perf.updTotal   -- first sample after a physics step
    end
end

-- Pose per hand with hysteresis (on 0.55 / off 0.45): fist when squeezing or holding a body (v0.6 physical hands), or
-- for the main hand while a tool body exists or something is carried; point while the trigger is pulled; open otherwise.
function selectPose(side)
    local isLeft = side == "l"
    local sq = isLeft and ctl.lsq or ctl.rsq
    local tr = isLeft and ctl.ltrig or ctl.rtrig
    hands.squeeze[side] = sq > 0.55 or (hands.squeeze[side] and sq > 0.45)
    hands.trigger[side] = tr > 0.55 or (hands.trigger[side] and tr > 0.45)
    local main = isLeft == (nat.leftHanded == 1)
    if hands.squeeze[side] or phys[side].hold or (main and (GetToolBody() ~= 0 or GetPlayerGrabBody() ~= 0)) then
        return "fist"
    end
    if hands.trigger[side] then return "point" end
    return "open"
end

-- v0.21 (docs/V021_PLAN.md section 3.2): the blocky forearm is shown whenever a pose is, the pointing finger only with
-- the pose "point".
function showGlove(side, pose)
    local prev = hands.shown[side]
    if prev == pose then return end
    local shapes = hands.shapes[side]
    if prev and shapes[prev] then SetTag(shapes[prev], "invisible") end
    if pose and shapes[pose] then RemoveTag(shapes[pose], "invisible") end
    hands.shown[side] = pose
    local ex = hands.extra[side] or {}
    if ex.arm and (not prev) ~= (not pose) then
        if pose then RemoveTag(ex.arm, "invisible") else SetTag(ex.arm, "invisible") end
    end
    if ex.finger and (prev == "point") ~= (pose == "point") then
        if pose == "point" then RemoveTag(ex.finger, "invisible") else SetTag(ex.finger, "invisible") end
    end
end

-- Spawn / re-spawn while gloves are wanted. A re-spawn for a lost body waits >= 2 s after the last spawn; a
-- spawn whose bodies are not both valid on the next tick (a side missing, or deleted again at once) is a failed
-- one, and 3 failed spawns in a row give up (hands.failed: line fallback, bit 7). A texture change re-spawns
-- at once, and so does (v0.8) a change of the body kind (handBodyStatic: hand_body, the A/B test's bit6).
function respawnHands()
    if hands.judge and hands.spawned and not hands.failed then
        hands.judge = false
        if validBody(hands.body.r) and validBody(hands.body.l) then
            hands.badSpawns = 0
        else
            hands.badSpawns = hands.badSpawns + 1
            if hands.badSpawns >= 3 then hands.failed = true return end
        end
    end
    -- (v0.21: blocky wanted after a failed blocky spawn is the glove texture, hands.blkFail)
    local skin = nat.handSkin or 0
    if skin == 2 and hands.blkFail then skin = 0 end
    if not hands.spawned or (not hands.failed and (hands.skin ~= skin
        or hands.bodyStatic ~= handBodyStatic())) then
        spawnHands()
        return
    end
    if hands.failed or (validBody(hands.body.r) and validBody(hands.body.l)) then return end
    if hands.clock - hands.spawnT >= 2 then spawnHands() end
end

-- Once per tick: spawn/re-spawn, pose choice, visibility, the pick safety and the diagnostics.
-- Gloves only ever exist while VR is active (nothing happens to the game without the native part).
function updateHands(dt)
    local style = nat.handStyle or 0
    local noHands = hasBit(nat.perf, PF.NO_HANDS)
    local gloves = active and ctl ~= nil and style == 2 and not noHands
    hands.clock = hands.clock + dt
    if gloves then respawnHands() end
    if hands.bstep > 0 and hands.bTick ~= heartbeat then verifyHands() end   -- bounds confirmation, one sample per tick
    -- Gloves not wanted (another hand_style, or given up): once per Lua state and after every spawn, delete
    -- every glove body, also the ones a quickload restored from the save (this state has no handle to them).
    if (style ~= 2 or hands.failed) and not hands.cleaned then
        deleteGloves()
        hands.cleaned = true
        if style ~= 2 then
            hands.spawned, hands.failed, hands.badSpawns, hands.judge = false, false, 0, false
            hands.bstep, hands.mapping = 0, -2                -- no gloves: L_HAND_MAPPING "not run"
        end
    end
    hands.lines = active and ctl ~= nil and not noHands and (style == 1 or (style == 2 and hands.failed))
    -- Safety: if the engine's look ray keeps stopping on a glove (30 ticks in a row), hide the gloves
    -- whenever the main hand is about to use, grab or interact, and move them far below the player (a hidden
    -- shape may still take part in queries). The latch clears after 5 s without a pick hit.
    local lh = nat.leftHanded == 1
    if hands.spawned and not hands.failed then
        local pick = GetPlayerPickBody and GetPlayerPickBody() or 0
        if isGloveBody(pick) or isGloveBody(GetPlayerInteractBody()) or isGloveBody(GetPlayerGrabBody()) then
            hands.pickHits = hands.pickHits + 1
            hands.pickRun = hands.pickRun + 1
            hands.noPickTime = 0
            if hands.pickRun >= 30 then hands.safety = true end
        else
            hands.pickRun = 0
            hands.noPickTime = hands.noPickTime + dt
            if hands.noPickTime >= 5 then hands.safety = false end
        end
    end
    hands.safetyHide = hands.safety and ctl ~= nil
        and ((lh and ctl.ltrig or ctl.rtrig) > 0.15 or (lh and ctl.lsq or ctl.rsq) > 0.15 or hasBit(ctl.buttons, 4))
    if hands.safetyHide then
        local away = Transform(VecAdd(GetPlayerTransform().pos, Vec(0, -500, 0)))
        for s = 1, 2 do
            local side = (s == 1) and "r" or "l"
            -- (v0.21 section 6.2: a live variant-C collider glove is not moved 500 m down; hcolTick makes it a GHOST)
            if validBody(hands.body[side]) and not HC.liveC(side) then
                placeOwnBody(hands.body[side], away)
                hands.park[side] = away
            end
        end
    end
    for s = 1, 2 do
        local side = (s == 1) and "r" or "l"
        local pose = false
        if ctl then
            hands.want[side] = selectPose(side)
            if gloves and not hands.failed and not hands.safetyHide and hasBit(ctl.hv, side == "l" and 1 or 4)
                and not (side == "r" and hands.bstep > 0) then   -- (the right glove stays put during the bounds check)
                pose = hands.want[side]
            end
        end
        if hands.spawned and not hands.failed then
            showGlove(side, pose)
            if not pose then parkOwnBody(hands.body[side], hands.park[side]) end   -- (v0.8: a hidden dynamic glove)
        end
    end
    hands.countTimer = hands.countTimer + dt
    if hands.countTimer >= 1 and FindBodies then
        hands.countTimer = 0
        hands.count = #(FindBodies("tdvr_hand", true) or {})
    end
    local st = 0
    if hands.spawned and not hands.failed then st = st + 1 end
    if hands.static then st = st + 2 end
    if hands.allShapes then st = st + 4 end
    if hands.sizeOk then st = st + 8 end
    if hands.shown.r or hands.shown.l then st = st + 16 end
    if hands.renderPlaced then st = st + 32 end
    if hands.lines then st = st + 64 end
    if hands.failed then st = st + 128 end
    if hands.safetyHide then st = st + 256 end   -- (extra bit 8: gloves hidden by the pick safety)
    W(LX.HANDS_STATE, st)
    W(LX.HANDS_PICKHITS, hands.pickHits)
    W(LX.HANDS_COUNT, hands.count)
    -- expected GetShapeSize(fist_r): v0.6 the HAND_PARTS size itself (identity grid order; equal to L_HAND_SIZE_R)
    local g = handPart("fist", "r") or HAND_PARTS.fist_r   -- (v0.21: the blocky cube with hand_texture = blocky)
    W(L2.HAND_SIZE_R, hands.sizeR)
    W(L2.HAND_SIZE_EXP, g[1] * 10000 + g[2] * 100 + g[3])
    W(L2.HAND_BOUNDS_ERR, hands.bErr)
    W(L2.HAND_MAPPING, hands.mapping)
    W(L2.HAND_VOXEL_MM, hands.voxelMm)
    hands.renderPlaced = false
end

function drawLineHand(t, pose, mirror)
    local polys = LINE_HAND[pose] or LINE_HAND.open
    local sx = mirror and -0.01 or 0.01
    for i = 1, #polys do
        local pl = polys[i]
        local prev = nil
        for j = 1, #pl - 2, 3 do
            local p = TransformToParentPoint(t, Vec(pl[j] * sx, pl[j + 1] * 0.01, pl[j + 2] * 0.01))
            if prev then DrawLine(prev, p, 0.95, 0.72, 0.45, 0.9) end
            prev = p
        end
    end
end

-- v0.21 (docs/V021_PLAN.md sections 3.3 / 6.6): the controller hand's world transform from the world base: grip *
-- handXform (the hand model frame: grip at the origin, fingers -Z; the ini hand offsets apply). What the gloves, the
-- line hands and the physical hands (handWorld) use; the solid hand's collider target is this * HC.LOCAL.
function ctrlHandT(side, base)
    local grip = (side == "l") and ctl.lgrip or ctl.rgrip
    return TransformToParentTransform(localToWorld(base, grip, nat.worldScale), handXform(side == "l"))
end

-- v0.21 (sections 3.3 / 6.6): where the visible hand of `side` is this frame: HC[side].vis, the blend onto its collider
-- that hcolVisual keeps while the collider is held back (nil: none), else the controller hand ctrlHandT. The tool
-- replica is moved by D = visualHandT * ctrlHandT^-1 with it (placeToolReplica): the identity in free air.
function visualHandT(side, base)
    local h = HC[side]
    if h and h.vis then return h.vis end
    return ctrlHandT(side, base)
end

-- Gloves, line hands and the laser, from the given world base. Done in render() (same base the camera was
-- just set from, after physics) so they stay on the controllers in both eyes while walking; in tick only if
-- render() is not being called.
-- v0.22 (docs/V022_PLAN.md section 3.2): handLive = the live base for the solid hands (NHP_STEADY: render's base of
-- now on a held right-eye frame; nil = base, the v0.21 way).
function placeHandsAndLaser(base, inRender, handLive)
    if not ctl then return end
    HC.r.vis, HC.l.vis = nil, nil         -- (v0.21: set again by hcolVisual for a shown hand)
    HC.visBase, HC.visLive = base, handLive or base
    for s = 1, 2 do
        local side = (s == 1) and "r" or "l"
        local pose = hands.shown[side]
        local lines = hands.lines and hasBit(ctl.hv, side == "l" and 1 or 4)
        if pose or lines then
            local t = ctrlHandT(side, base)
            if pose and hands.body[side] then
                -- (v0.21 section 6.6: hcolVisual gives the visible hand's transform while its collider is blocked,
                -- nil = the controller hand t, the v0.20 placement)
                local tl = (handLive and handLive ~= base) and ctrlHandT(side, handLive) or t
                local vt = hcolVisual(side, t, tl) or t
                if not HC.owns(side) then             -- (v0.21 variant C in FREE / BLOCKED: physics places it)
                    placeOwnBody(hands.body[side], vt)     -- (v0.8: velocities zeroed for a dynamic glove)
                    hands.park[side] = vt
                end
                if inRender then hands.renderPlaced = true end
            end
            if lines then drawLineHand(t, hands.want[side], side == "l") end
        end
    end
    -- (v0.6: no laser while the main hand holds a body)
    if laserTarget and not phys[(nat.leftHanded == 1) and "l" or "r"].hold then
        local hand = localToWorld(base, (nat.leftHanded == 1) and ctl.laim or ctl.raim, nat.worldScale)
        DrawLine(hand.pos, laserTarget, 1, 0.25, 0.2, 0.85)
    end
end

-- ---------------------------------------------------------------------------------------------
-- tool replica (v0.6, docs/V06_PLAN.md section 5; v0.7 replica v2, docs/V07_PLAN.md section 3)
-- ---------------------------------------------------------------------------------------------
-- The v0.5 headset log showed that the engine's first-person tool placement follows SetToolTransformOverride in no
-- frame we can model (fist distance 38-82 cm), so with tool_display = replica the engine tool body is hidden and a
-- static copy of it (v0.8: a dynamic one by default, see placeOwnBody) is drawn exactly at the hand instead. The
-- override logic keeps running: it still puts the (invisible) engine tool as near the hand as it can, for the tool's
-- effects and raycasts. v0.7: the v0.6 copy
-- (CreateShape + CopyShapeContent) failed for every tool in the v0.6 headset log (CreateShape makes 0.1 m voxels, the
-- tools use vox scale 0.25-0.5), so the copy is now spawned from the tool's own prefab body (TOOL_MODELS), and the
-- closed-loop correction that diverged there is off (TOOLF.CORR, see toolCorrUpdate).

-- The built-in tool ids (data/prefab/tool; L_TOOL_CODE). None of their scripts set "invisible" tags on the tool (v0.6
-- review R5: only these get a stale tag cleared after a quickload).
local TOOL_CODES = { sledge = 1, spraycan = 2, extinguisher = 3, blowtorch = 4, shotgun = 5, plank = 6, pipebomb = 7,
    gun = 8, bomb = 9, wire = 10, rocket = 11, booster = 12, leafblower = 13, turbo = 14, explosive = 15, rifle = 16,
    steroid = 17, cutter = 18, camera = 19 }

-- v0.7 (docs/V07_PLAN.md section 3): the replica is spawned from the tool's own prefab body (see buildToolReplica).
local TOOL_MODELS = {   -- generated by tools/gen_toolmodels.py from data/prefab/tool/*.xml: the tool body's
                        -- vox elements as Spawn XML (files tool/<name>.vox: the game's own data/vox/tool, v0.20;
                        -- buildToolReplica falls back to MOD/tool_<name>.vox once), rh = tp_action_rh
                        -- (m, tool space), lh = tp_action_lh (m, tool space) where the prefab has one, scale = first
                        -- vox scale, n = vox count, muzzle (m, tool space)
    blowtorch = { xml = "<vox texture='12 0.75' file='tool/blowtorch.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, 0, -0.05 }, lh = { -0.325, 0.075, -0.375 }, scale = 0.5, n = 1, muzzle = { -0.025, 0.125, -0.85 } },
    bomb = { xml = "<vox texture='12 0.65' file='tool/bomb.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, 0, -0.025 }, scale = 0.5, n = 1 },
    booster = { xml = "<vox texture='12 0.65' file='tool/booster.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.15, 0.25, -0.05 }, lh = { -0.15, 0.25, -0.05 }, scale = 0.5, n = 1 },
    explosive = { xml = "<vox texture='12 0.65' file='tool/explosive.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.275, -0.125, -0.025 }, lh = { -0.275, -0.125, -0.025 }, scale = 0.5, n = 1 },
    extinguisher = { xml = "<vox texture='12 0.75' file='tool/extinguisher.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, 0.025, -0.05 }, lh = { -0.125, -0.075, -0.175 }, scale = 0.5, n = 1, muzzle = { -0.025, -0.025, -0.525 } },
    gun = { xml = "<vox texture='12 0.65' blendtexture='3 0.05' file='tool/gun.vox' scale='0.45' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { -0.015, 0.045, -0.067 }, scale = 0.45, n = 1, muzzle = { -0.025, 0.15, -0.475 } },
    leafblower = { xml = "<vox pos='-0.1 -0.15 0.0' texture='12 0.5' blendtexture='3 0.05' file='tool/leafblower.vox' object='leaf_blower' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/><vox pos='-0.025 0.025 0.0' rot='0.0 0.0 0.0' texture='12 0.5' blendtexture='3 0.05' file='tool/leafblower.vox' object='handle' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/><group name='rotation_point' pos='0.0 -0.02 -0.515' rot='-15.0 0.0 0.0'><vox pos='-0.025 0.0 0.0' rot='0.0 0.0 0.0' texture='12 0.75' blendtexture='3 0.1' file='tool/leafblower.vox' object='end' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/></group>",
        rh = { 0.025, 0.075, 0.2 }, lh = { -0.225, 0.075, -0.05 }, scale = 0.5, n = 3, muzzle = { 0, 0.05, -0.6 } },
    pipebomb = { xml = "<vox texture='12 0.75' file='tool/pipebomb.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.025, 0, -0.025 }, scale = 0.5, n = 1, muzzle = { 0, 0, 0 } },
    plank = { xml = "<vox pos='0.0 0.0 -0.25' texture='12 0.75' blendtexture='3 0.1' file='tool/plank.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.1, 0.025, 0.15 }, lh = { 0.1, 0.025, -0.6 }, scale = 0.5, n = 1 },
    rifle = { xml = "<vox texture='12 0.75' blendtexture='3 0.25' file='tool/rifle.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, 0.05, -0.1 }, lh = { -0.05, 0.075, -0.35 }, scale = 0.5, n = 1, muzzle = { -0.025, 0.175, -1.125 } },
    rocket = { xml = "<vox pos='-0.02 -0.14 -0.08' texture='12 0.65' blendtexture='3 0.15' file='tool/rocket.vox' object='rocket_launcher' scale='0.4' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, -0.06, -0.18 }, lh = { 0, -0.04, -0.38 }, scale = 0.4, n = 1, muzzle = { -0.02, 0.14, -0.64 } },
    shotgun = { xml = "<vox texture='12 0.5' blendtexture='3 0.1' file='tool/shotgun.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, 0, -0.15 }, lh = { -0.025, 0.025, -0.55 }, scale = 0.5, n = 1, muzzle = { -0.025, 0.125, -1.125 } },
    sledge = { xml = "<vox texture='12 0.65' file='tool/sledge.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0, -0.025, -0.25 }, lh = { -0.05, -0.025, 0.3 }, scale = 0.5, n = 1 },
    spraycan = { xml = "<vox pos='0.0 -0.15 -0.0' rot='0.0 0.0 0.0' texture='12 0.5' file='tool/spraycan.vox' object='spraycan' scale='0.25' tags='unbreakable nocull noquery nonav' collide='false'><vox pos='-0.0125 0.2375 -0.0125' rot='0.0 0.0 0.0' texture='12 0.5' file='tool/spraycan.vox' object='spraycan_nozzle' scale='0.25' tags='unbreakable nocull noquery nonav' collide='false'/></vox>",
        rh = { 0.025, 0, 0 }, scale = 0.25, n = 2, muzzle = { 0, 0.125, -0.075 } },
    steroid = { xml = "<vox texture='12 0.5' file='tool/steroid.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.025, -0.05, -0.075 }, scale = 0.5, n = 1 },
    turbo = { xml = "<vox texture='12 0.65' file='tool/turbo.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.15, 0.25, -0.05 }, lh = { -0.15, 0.25, -0.05 }, scale = 0.5, n = 1 },
    wire = { xml = "<vox texture='12 0.5' file='tool/wire.vox' scale='0.5' tags='unbreakable nocull noquery nonav' collide='false'/>",
        rh = { 0.025, 0.025, -0.075 }, scale = 0.5, n = 1 },
}

-- Guarded engine call: its results, or nil if the function is missing or fails.
function engineCall(f, ...)
    if not f then return nil end
    local ok, a, b, c, d = pcall(f, ...)
    if not ok then return nil end
    return a, b, c, d
end

-- Deletes every tool replica in the scene (also the stale copies a quickload restores without our handles) and forgets
-- ours.
function deleteToolReplicas()
    if FindBodies and Delete then
        local old = FindBodies("tdvr_tool", true) or {}
        for i = 1, #old do Delete(old[i]) end
    end
    if replica.body ~= 0 and Delete and validBody(replica.body) then Delete(replica.body) end
    replica.body, replica.n, replica.shapes, replica.visible = 0, 0, {}, false
    replica.src, replica.shapeVis, replica.placed, replica.srcLt, replica.ownLt, replica.animated = {}, {}, false, {}, {}, {}
end

-- v0.7: the tool's handle point tp_action_rh (tool space, Vec) for toolWorldOf: the TOOL_MODELS value for a built-in
-- tool (the replica is that prefab's body), else the engine's tool location (a modded tool), nil none. v0.7 review F6:
-- left-handed (N_LEFT_HANDED) the tool's tp_action_lh (TOOL_MODELS lh, or the engine's location for a modded tool),
-- else tp_action_rh mirrored in X.
function toolHandle()
    local lh = nat.leftHanded == 1
    local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
    local m = TOOL_MODELS[tool]
    if m then
        -- v0.19 (the user: "the sledgehammer is too high"): a handle tool held one-handed by the END of its handle - the
        -- two-handed pose's tp_action_lh (sledge: z +0.3 of a handle running -0.525..+0.475, the head at -0.63), not
        -- tp_action_rh (z -0.25, up near the head: 0.7 m of handle stuck out below the fist); mirrored in X left-handed
        if handleTool19(tool) and m.lh then return Vec(lh and -m.lh[1] or m.lh[1], m.lh[2], m.lh[3]) end
        if lh and m.lh then return Vec(m.lh[1], m.lh[2], m.lh[3]) end
        return Vec(lh and -m.rh[1] or m.rh[1], m.rh[2], m.rh[3])
    end
    if not GetToolLocationLocalTransform then return nil end
    if lh then
        local l = GetToolLocationLocalTransform("tp_action_lh")
        if l and l.pos and VecLength(l.pos) < 1.0 then return l.pos end
    end
    local rh = GetToolLocationLocalTransform("tp_action_rh")
    if rh and rh.pos and VecLength(rh.pos) < 1.0 then return lh and Vec(-rh.pos[1], rh.pos[2], rh.pos[3]) or rh.pos end
    return nil
end

-- v0.19 (docs/V019_PLAN.md section 2): a HANDLE tool - a built-in tool without a muzzle (not the plank, held like a
-- board) whose model is longest along tool +Y: the sledge (hard-coded, the tool_views2 render), any other such tool by
-- the extents its replica measured at the build (replicaLongY19; unknown before the first build). toolWorldOf holds it by
-- the handle. Never on the kept paths (PRB.V013..V016, V018: their tools aim along the controller ray).
-- v0.19 review LUA19-SLEDGE-HANDLE-AXIS / V19-SLEDGE-GEOMETRY-WRONG-PREMISE / LUA19-HANDLE-SWAP-FLIP /
-- V19-USE-HANDLE-TOOL-FLIP (deviation from V019 section 2): the sledge only. The "longest along +Y" rule rested on the
-- unrotated vox render; in the game (GetShapeLocalTransform carries the vox rotation) it selected only wire and steroid
-- (no _r, 0.20 / 0.35 m along Y) - USE tools, whose engine tool (turned with the player's aim, R identity) then jumped
-- by tens of degrees against the handle-held replica on every press and back after the tail. replicaLongY19 and the
-- replica's measurement are gone; the sledge (a PARK tool: never swapped) is held along tool Z (toolWorldOf).
function handleTool19(tool)
    if PRB.V013 or PRB.V014 or PRB.V015 or PRB.V016 or PRB.V018 then return false end
    return tool == "sledge" and TOOL_MODELS[tool] ~= nil
end

-- v0.19 (docs/V019_PLAN.md section 1): this tick's flow for the current tool (updateToolReplica, which hides the replica
-- by it): 0 the v0.18 one (the engine tool at the hand whenever the placement runs, forced aim) - a tool without a
-- replica model or whose replica is not built (rep false: a modded tool, a failed build, tool_display = engine) and the
-- kept paths; 1 the replica seen, the engine tool parked (idle, or a PARK tool: the sledge / plank act along the
-- player's aim, not from the tool body, so they never need it); 2 a USE tool in use (use19): the engine tool at the hand.
-- v0.19 review V19-HOLD-STOPS-PARKING: also 1 while the at-hand placement is held off (actHold, hold > 0: actCanRun false,
-- the replica shown) - the engine tool is parked through the hold (actPlace17), not left at its own first-person pose.
-- v0.19 review LUA19-USE-WITHOUT-BASE / V19-USE-WITHOUT-BASE: also 1 while no base is learnt for this tool and body (bL
-- nil, or a switch actUpdate has not taken yet this tick: key / body differ - actSwitch / actPlaceReset will clear bL):
-- in use without a base actPlace17 cannot place, so the replica hidden showed the unplaced engine tool for 1-2 ticks.
-- Parked, the next sample learns the base and the following tick brings the engine tool to the hand.
function mode19(tool, rep)
    if PRB.V013 or PRB.V014 or PRB.V015 or PRB.V016 or PRB.V018 or not rep or not TOOL_MODELS[tool] then return 0 end
    local a = probe.act
    if PRB.P19.PARKT[tool] or (a.u19 or 0) <= 1e-6 then return 1 end
    if (a.hold or 0) > 0 then return 1 end
    if not a.bL or a.key ~= tool or a.body ~= GetToolBody() then return 1 end
    return 2
end

-- Shows the engine tool shapes we hid again (the ones still there). v0.6 review R4: only the ones that were visible
-- before we hid them (a shape the tool script keeps hidden stays hidden).
function unhideEngineTool()
    for sh, ours in pairs(replica.hidden) do
        if ours and validBody(sh) then RemoveTag(sh, "invisible") end
    end
    replica.hidden, replica.toolHid = {}, {}
end

-- Hides every shape of the engine tool body tb (again each time: a tool script may clear the tag every frame, as
-- snowball.lua does after a throw; a shape the tool adds later is hidden too). Returns true if any shape was hidden.
-- v0.6 review R4: the first sighting records the tool's own state (replica.hidden[s] = it was visible, so we hid it;
-- toolHid[s] = the tool keeps it hidden); a shape found untagged later was shown by the tool script since (it wants it
-- visible again). setReplicaVisible mirrors toolHid onto the copies. (A tool script that hides a shape again after that
-- cannot be told from our own tag: its copy stays shown.)
function hideEngineTool(tb)
    local shapes = (tb ~= 0) and engineCall(GetBodyShapes, tb)
    if type(shapes) ~= "table" then return false end
    local r = replica
    for i = 1, #shapes do
        local s = shapes[i]
        local tagged = HasTag ~= nil and HasTag(s, "invisible") == true
        if r.hidden[s] == nil then
            r.toolHid[s], r.hidden[s] = tagged, not tagged
        elseif not tagged then
            r.toolHid[s], r.hidden[s] = false, true
        end
        if not tagged then SetTag(s, "invisible") end
    end
    return #shapes > 0
end

-- Tags the replica's shapes invisible (v false) or untags them (v true), only on a change. v0.6 review R4: a copy whose
-- source shape the tool script keeps hidden (toolHid) stays hidden.
function setReplicaVisible(v)
    local r = replica
    for i = 1, #r.shapes do
        local sh = r.shapes[i]
        local want = v and not r.toolHid[r.src[i] or 0]
        if r.shapeVis[i] ~= want and validBody(sh) then
            if want then RemoveTag(sh, "invisible") else SetTag(sh, "invisible") end
            r.shapeVis[i] = want
        end
    end
    r.visible = v
end

-- v0.7: the voxel size check of a spawned copy n (docs/V07_PLAN.md section 3): GetShapeSize's 4th return must be the
-- model's vox scale * 0.1 m within 5 % (a voxel size the engine does not give is not checked). nil when it fits, else
-- the L_TOOL_REPLICA_N code -(model voxel * 10000 + measured voxel), both in 0.1 mm (the v0.6 missed-1 format; the
-- v0.6 headset log had -(500 * 10000 + 1000) for every tool: CreateShape's 0.1 m voxels).
function replicaScaleCode(n, scale)
    local _, _, _, v = engineCall(GetShapeSize, n)
    local want = scale * 0.1
    if type(v) ~= "number" or math.abs(v - want) <= want * 0.05 then return nil end
    return -(clamp(math.floor(want * 10000 + 0.5), 0, 9999) * 10000 + clamp(math.floor(v * 10000 + 0.5), 0, 9999))
end

-- The engine tool shapes that pair with the copies (index i <-> copy i; R4/R7): the engine body's shapes when it has
-- exactly as many, each with the same voxel counts (built from the same prefab, in the same order), else none (then the
-- copies neither mirror the tool's own hidden shapes nor follow its animated ones).
function pairToolShapes(tb, shapes)
    local src = engineCall(GetBodyShapes, tb)
    if type(src) ~= "table" or #src ~= #shapes then return {} end
    for i = 1, #src do
        local x1, y1, z1 = engineCall(GetShapeSize, src[i])
        local x2, y2, z2 = engineCall(GetShapeSize, shapes[i])
        if type(x1) ~= "number" or x1 ~= x2 or y1 ~= y2 or z1 ~= z2 then return {} end
    end
    return src
end

-- Builds the replica of the held tool (v0.7 replica v2, docs/V07_PLAN.md section 3): Spawn of a body ("tdvr_tool"; v0.8:
-- dynamic, or static with handBodyStatic(), see placeOwnBody) holding the tool's own prefab body content (TOOL_MODELS[tool].xml: the same vox elements, nesting,
-- positions, rotations, scales and textures; the body origin is the prefab's tool_space origin, as for the engine's
-- tool body; v0.7 review F5: every vox element also carries collide='false' and the gloves' tags 'unbreakable nocull
-- noquery nonav', see tools/gen_toolmodels.py), every returned shape without collisions (filter 0, 0, kept as well),
-- unbreakable, nocull, and each one's voxel size
-- checked against the model (replicaScaleCode). Failures leave nothing behind and set replica.failN (the native log
-- formats every value below -2 as "voxel mismatch src= copy=", so only that format is used): no model (a modded tool;
-- L_TOOL_CODE tells) or Spawn without a body -1, no shapes (e.g. the vox file missing) -(model
-- voxel * 10000 + 0) ("copy=0.0mm"), a voxel size mismatch (replicaScaleCode). Returns true when built. v0.6 review R1: built 500 m below the player with every copy
-- tagged invisible; shown only once placeToolReplica has put it at the hand (never at the eye, or left in the world,
-- while the hand is not tracked). R4/R7: replica.src[i] = the paired engine shape of copy i (pairToolShapes).
-- v0.20 (no redistributed game assets): TOOL_MODELS spawns the game's own tool/<name>.vox (data/vox/tool; a Spawn path
-- without MOD/ or LEVEL/ resolves to data/vox, as data/script/snowball.lua's "snowball.vox"). When that spawn gives no
-- body or no shapes, the v0.7-v0.19 copy MOD/tool_<name>.vox (an older install's mod folder) is tried once; a failure
-- then reports that second spawn, as v0.19 did. replica.voxSrc = "game" / "mod" (the path that built it), nil none
-- (Lua-side only: no new slot; the test reads it).
function spawnReplicaXml(xml, away, static)
    local ents = engineCall(Spawn, '<body tags="tdvr_tool nomerge" dynamic="' .. (static and "false" or "true") .. '">'
        .. xml .. "</body>", away, true)
    local body, shapes = 0, {}
    if type(ents) == "table" then
        for i = 1, #ents do
            local kind = GetEntityType(ents[i])
            if kind == "body" and body == 0 then body = ents[i]
            elseif kind == "shape" then shapes[#shapes + 1] = ents[i] end
        end
    end
    return body, shapes
end

function buildToolReplica(tb, tool)
    deleteToolReplicas()
    local r = replica
    r.failN = -1
    r.voxSrc = nil
    local m = TOOL_MODELS[tool]
    if not m then return false end
    if not (Spawn and GetEntityType) then return false end
    local away = Transform(VecAdd(GetPlayerTransform().pos, Vec(0, -500, 0)))
    local static = handBodyStatic()          -- (v0.8: dynamic unless hand_body = static or the A/B-test bit6)
    r.park = away
    local body, shapes = spawnReplicaXml(m.xml, away, static)
    r.voxSrc = "game"
    if body == 0 or #shapes == 0 then
        -- (v0.20: the game path gave nothing usable - delete what it left, try the older install's copies once)
        local legacy = string.gsub(m.xml, "file='tool/", "file='MOD/tool_")
        if legacy ~= m.xml then
            r.body = body
            deleteToolReplicas()
            body, shapes = spawnReplicaXml(legacy, away, static)
            r.voxSrc = "mod"
        end
    end
    r.body = body
    if r.body == 0 then r.voxSrc = nil; return false end
    -- v0.7 review F4: the copies in GetBodyShapes order, the API (and order) pairToolShapes reads the engine tool with;
    -- Spawn's own list only when that gives none
    local listed = engineCall(GetBodyShapes, r.body)
    if type(listed) == "table" and #listed > 0 then shapes = listed end
    if IsBodyDynamic and SetBodyDynamic and IsBodyDynamic(r.body) == static then SetBodyDynamic(r.body, not static) end
    if not static then placeOwnBody(r.body, away) end   -- (v0.8: a dynamic copy starts at rest)
    local code = (#shapes == 0) and -(clamp(math.floor(m.scale * 1000 + 0.5), 0, 9999) * 10000) or nil
    for i = 1, #shapes do
        local n = shapes[i]
        SetTag(n, "invisible")
        engineCall(SetShapeCollisionFilter, n, 0, 0)
        SetTag(n, "unbreakable")
        SetTag(n, "nocull")
        code = code or replicaScaleCode(n, m.scale)
    end
    if code then
        deleteToolReplicas()
        r.failN, r.voxSrc = code, nil
        return false
    end
    r.shapes, r.src = shapes, pairToolShapes(tb, shapes)
    for i = 1, #shapes do
        r.shapeVis[i], r.ownLt[i] = false, engineCall(GetShapeLocalTransform, shapes[i])
        local s = r.src[i]
        if s then
            r.srcLt[i] = engineCall(GetShapeLocalTransform, s)
            if r.hidden[s] == nil then r.toolHid[s] = HasTag ~= nil and HasTag(s, "invisible") == true end
        end
    end
    r.n, r.visible, r.placed = #shapes, false, false
    return true
end

-- v0.6 review R2 (measure first): the replica is a static body with a 0/0 collision filter; whether the engine's own
-- pick / interact rays or other scripts' default-layer queries can still hit it is unknown. Each tick: the game's pick,
-- interact and grab bodies against it (L_REPLICA_PICK counts such ticks), and, until one hits, one default-layer ray from
-- the eye to its centre with only the gloves rejected (a hit sets +100 in L_TOOL_REPLICA for this Lua state). Returns
-- true if the game picked it while the main trigger or grip is pressed or X is held (the tool, grab or interact would act
-- on our copy): updateToolReplica then drops the replica for this tool (state 2, L_TOOL_REPLICA_N -2).
function replicaPickCheck()
    local r = replica
    local b = r.body
    if b == 0 or not validBody(b) then return false end
    local pick = GetPlayerPickBody and GetPlayerPickBody() or 0
    local picked = pick == b or GetPlayerInteractBody() == b or GetPlayerGrabBody() == b
    if picked then r.picks = r.picks + 1 end
    if not r.rayHit and r.placed and QueryRaycast and GetShapeBody then
        local c = GetBodyTransform(b).pos
        local mn, mx = engineCall(GetBodyBounds, b)
        if type(mn) == "table" and type(mx) == "table" and type(mn[3]) == "number" and type(mx[3]) == "number" then
            c = VecScale(VecAdd(mn, mx), 0.5)
        end
        local eye = GetPlayerEyeTransform().pos
        local d = VecSub(c, eye)
        local l = VecLength(d)
        if l > 0.01 and l < 5 then
            if hands.body.r then QueryRejectBody(hands.body.r) end
            if hands.body.l then QueryRejectBody(hands.body.l) end
            engineCall(QueryRejectPlayer)   -- (v0.10 section 2: the player's own animated body is never the answer)
            local hit, _, _, shape = engineCall(QueryRaycast, eye, VecScale(d, 1 / l), l + 0.05)
            if hit and type(shape) == "number" and shape ~= 0 and engineCall(GetShapeBody, shape) == b then r.rayHit = true end
        end
    end
    if not picked or not ctl then return false end
    local lh = nat.leftHanded == 1
    return (lh and ctl.ltrig or ctl.rtrig) > 0.15 or (lh and ctl.lsq or ctl.rsq) > 0.15 or hasBit(ctl.buttons, 4)
end

-- Every tick (docs/V06_PLAN.md section 5). tool_display = replica (N_TOOL_DISPLAY 1) and a tool body: the replica is
-- built once per tool id and tool body handle, when VR controls the view on foot with hand aim; a failed one
-- (L_TOOL_REPLICA 2; v0.7 also a tool without a TOOL_MODELS entry, a modded tool) is not retried until either changes,
-- and the engine tool stays visible. Shown (VR active on foot,
-- hand aim, the main grip and aim poses tracked, no A/B-test NO_TOOL bit): the engine tool's shapes are tagged invisible
-- every tick (render places the replica and tags them again, see placeToolReplica). Not shown (VR inactive, a vehicle,
-- v0.6 review R6: aim_mode = head, where the engine tool acts along the head, not along the copy's controller; R1: the
-- main hand not tracked): the replica's shapes are hidden and the engine tool's tags removed. tool_display = engine or
-- no tool body: the replica is deleted. A replica deleted under us (a level script) counts as failed, as does one the
-- game picked while the trigger, grip or X was pressed (R2, see replicaPickCheck). Once per Lua state every stale
-- replica is deleted (quickload, like the gloves), and (R5) the engine tool's "invisible" tags are cleared for a built-in
-- tool (a quickload may restore our tags with the body; the next tick hides it again if the replica is shown).
-- L_TOOL_REPLICA = state (+10 engine tool hidden this tick, +100 a default-layer ray hit the replica), L_TOOL_REPLICA_N =
-- its shapes (a failed build: replica.failN, see buildToolReplica; -2 dropped after a pick), L_REPLICA_PICK.
-- v0.13 (docs/V013_PLAN.md section 2, which tool is shown): when the visible-offset self-test found that the engine tool
-- body IS the visible one (vofs state 3: it cannot be hidden by the offset) and the servo is locked (last tick's
-- L_SERVO_STATE 2: the engine tool sits on the hand; v0.13 review SC-3 / LUA13-SHOWN-HYST: latched,
-- probe.servo.engine, see writeServoStatus), the replica is hidden and the engine tool shown (its shapes are no longer
-- tagged): exactly one tool is seen and it is the one the effects come from. Otherwise the replica as before.
-- v0.14 (docs/V014_PLAN.md section 1): the engine tool cannot be hidden, so the servo's engine latch alone decides
-- (writeServoStatus: 6 cm + 8 deg on, 12 cm for 10 ticks off): engine on -> our replica hidden, only the engine tool in
-- the hand is seen (effects start there); off -> the replica as now (two tools only while the servo has not caught up).
-- probe.servo.shown = the engine tool is the one seen (a tool body and no replica shown: L_TOOL_SHOWN 1).
-- v0.16 (docs/V016_PLAN.md section 1): the replica is hidden whenever the offset placement can run (actCanRun), not
-- after a 30-tick error window; PRB.V015 restores the v0.15 latch.
-- v0.19 (docs/V019_PLAN.md section 1): only while the engine tool is brought to the hand (mode19 2 a USE tool in use, 0
-- a tool without a replica); with its replica built and idle (mode19 1) the replica is shown and the engine tool parked.
function updateToolReplica(flags)
    local r = replica
    if not r.cleaned then
        deleteToolReplicas()
        local tb0 = GetToolBody()
        local tool0 = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
        local shapes = (tb0 ~= 0 and TOOL_CODES[tool0]) and engineCall(GetBodyShapes, tb0)
        if type(shapes) == "table" then
            for i = 1, #shapes do RemoveTag(shapes[i], "invisible") end
        end
        clearForeignTags()                   -- (v0.10 review LTH-3 / SPEC-4: foreign shapes we hid before a quickload)
        r.cleaned = true
    end
    local tb = GetToolBody()
    adoptForeignToolShapes(tb)               -- (v0.10 review LTH-2 / SPEC-2: before hideEngineTool / buildToolReplica)
    local hidden = false
    if not (nat.valid and nat.toolDisplay == 1) or tb == 0 then
        if r.body ~= 0 then deleteToolReplicas() end
        unhideEngineTool()
        r.key, r.state, r.shown = "", 0, false
    else
        local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
        -- (v0.8: the body kind is part of the key, a hand_body / A/B-test change rebuilds the replica)
        local key = tostring(tool) .. "#" .. tostring(tb) .. (handBodyStatic() and "#s" or "#d")
        local lh = nat.leftHanded == 1
        local want = active and nat.aimMode == 1 and not hasBit(flags, LF_VEHICLE) and not hasBit(nat.perf, PF.NO_TOOL)
        local show = want and ctl ~= nil and hasBit(ctl.hv, lh and 1 or 4) and hasBit(ctl.hv, lh and 2 or 8)
        if key ~= r.key then
            unhideEngineTool()
            if want then
                r.key = key
                r.state = buildToolReplica(tb, tool) and 1 or 2
            else
                if r.body ~= 0 then deleteToolReplicas() end
                r.key, r.state = "", 0
            end
        elseif r.state == 1 and not validBody(r.body) then
            deleteToolReplicas()
            r.state, r.failN = 2, -1
        end
        if r.state == 1 and replicaPickCheck() then
            deleteToolReplicas()
            r.state, r.failN = 2, -2
        end
        -- (v0.13 review SC-3: the latched lock; v0.14 section 1: the latch alone - vofs 3 is known, the test no longer
        -- runs - and only for the body and tool the servo runs for: a tool switch shows the new tool's replica at once,
        -- servoTarget resets the latch only later in this tick)
        local sv = probe.servo
        local engine = (not PRB.V013 or probe.vofs.state == 3) and sv.engine and sv.body == tb
            and sv.key == tostring(tool)
        -- (v0.15, docs/V015_PLAN.md section 2: the v0.15 placement's latch, for the tool and body it placed; the v0.14
        -- servo's only with PRB.V014 / V013)
        if PRB.V015 and not (PRB.V013 or PRB.V014) then
            local a = probe.act
            engine = a.engine and a.body == tb and a.key == tostring(tool)
        elseif not (PRB.V013 or PRB.V014) then
            -- (v0.16, docs/V016_PLAN.md section 1: never our replica while the offset placement runs - hidden at once,
            -- before its first call, also right after a tool switch; shown only where it cannot run, as v0.15)
            engine = actCanRun(flags, tb)
            -- (v0.19, docs/V019_PLAN.md section 1: a tool with its replica built is seen as the replica unless it is in
            -- use (mode19 2); idle - and always for a PARK tool - the replica, the engine tool parked by actPark19)
            probe.act.m19 = mode19(tostring(tool), r.state == 1)
            if probe.act.m19 == 1 then engine = false end
        end
        r.shown = show and r.state == 1 and not engine
        if r.shown then hidden = hideEngineTool(tb) else unhideEngineTool() end
        setReplicaVisible(r.shown and r.placed)
        if not r.shown and r.body ~= 0 then parkOwnBody(r.body, r.park) end   -- (v0.8: a hidden dynamic copy)
    end
    probe.servo.shown = tb ~= 0 and not r.shown
    W(L2.TOOL_REPLICA, r.state + (hidden and 10 or 0) + (r.rayHit and 100 or 0))
    W(L2.TOOL_REPLICA_N, (r.state == 2) and r.failN or r.n)
    W(L2.REPLICA_PICK, r.picks)
end

-- render() (tick when render() is not called): the replica at the hand like the gloves, with the camera's base:
-- toolWorld = (grip - rot * tp_action_rh, rot = the aim rotation) (toolWorldOf), and the engine tool hidden again (a
-- tool script may have cleared the tag since the tick). Not moved while the main grip or aim is not tracked (then not
-- shown either, see updateToolReplica). v0.6 review R7: a tool that animates its shapes (e.g. a spinning barrel) moves
-- the copies along; v0.7: copy i (paired with engine shape i, see pairToolShapes) gets its own build-time local
-- transform changed by what moved the engine shape since the build (D = now * build^-1, copy = D * own; nothing is set
-- while the engine shape is where it was at the build, so a different engine body origin cannot move the copy).
-- R1: the copies are shown once placed. v0.7 review F1: only for a tool with more than one shape (a single shape can only
-- move as a whole, which is the engine's own tool placement, not a part animation), and a change of an engine shape by
-- more than REPLICA_ANIM.POS m or REPLICA_ANIM.DEG degrees is ignored (replica.wild counts such frames).
local REPLICA_ANIM = { POS = 0.05, DEG = 45 }
function placeToolReplica(base)
    local r = replica
    if not r.shown or not ctl or not validBody(r.body) then return end
    local lh = nat.leftHanded == 1
    if not hasBit(ctl.hv, lh and 1 or 4) or not hasBit(ctl.hv, lh and 2 or 8) then return end
    r.park = (toolWorldOf(base))
    -- v0.21 (docs/V021_PLAN.md section 3.3): D * toolWorldOf(base), D = visualHandT * ctrlHandT^-1 - only while the
    -- visible hand is not the controller hand (its solid collider held back, HC[side].vis): the replica stays in the
    -- visible fist; in free air no D at all, the v0.20 placement exactly
    local hs = HC[lh and "l" or "r"]
    if hs and hs.vis then
        local inv = TransformToLocalTransform(ctrlHandT(lh and "l" or "r", base), Transform())
        r.park = TransformToParentTransform(TransformToParentTransform(hs.vis, inv), r.park)
    end
    placeOwnBody(r.body, r.park)              -- (v0.8: velocities zeroed for a dynamic copy)
    local animN = (#r.shapes > 1) and #r.shapes or 0   -- (v0.7 review F1: a one-shape tool has no parts to animate)
    for i = 1, animN do
        local s, n, lt0, own = r.src[i], r.shapes[i], r.srcLt[i], r.ownLt[i]
        if s and lt0 and own and validBody(s) and validBody(n) then
            local lt = engineCall(GetShapeLocalTransform, s)
            if type(lt) == "table" and type(lt.pos) == "table" and type(lt.rot) == "table" then
                local dp, da = VecLength(VecSub(lt.pos, lt0.pos)), quatAngle(lt.rot, lt0.rot)
                local moved = dp > 1e-4 or da > 0.05
                if dp > REPLICA_ANIM.POS or da > REPLICA_ANIM.DEG then
                    -- not a part animation (v0.7 review F1): the copy stays at (or goes back to) its build-time place
                    if r.animated[i] then SetShapeLocalTransform(n, own) end
                    r.animated[i] = false
                    r.wild = r.wild + 1
                elseif moved or r.animated[i] then
                    SetShapeLocalTransform(n, TransformToParentTransform(TransformToParentTransform(lt,
                        TransformToLocalTransform(lt0, Transform())), own))
                    r.animated[i] = moved
                end
            end
        end
    end
    hideEngineTool(GetToolBody())
    r.placed = true
    setReplicaVisible(true)
end

-- ---------------------------------------------------------------------------------------------
-- physical hands (v0.6, docs/V06_PLAN.md section 7)
-- ---------------------------------------------------------------------------------------------
-- Each hand can pick up a light dynamic body with its grip (held in update() by ConstrainPosition and
-- ConstrainOrientation, so it collides and has weight), throw it on release and push bodies it moves into.
-- L_HANDS_NEAR tells the native input which grip presses belong to the hands: those are not sent to the game (the
-- engine grab must not act on the same press); N_GRIP_LATCH tells us which presses native actually kept (v0.6 review).

-- The heaviest body a hand may pick up (N_GRAB_MAX_MASS, kg; 120 without a value).
function handMaxMass()
    local m = nat.grabMaxMass or 0
    if m <= 0 then m = 120 end
    return m
end

-- v0.6 review H1: the body the player stands on (GetPlayerGroundContact's shape -> GetShapeBody), 0 none or unknown.
function playerGroundBody()
    if not (GetPlayerGroundContact and GetShapeBody) then return 0 end
    local c, gs = engineCall(GetPlayerGroundContact)
    if c ~= true or type(gs) ~= "number" or gs == 0 then return 0 end
    local b = engineCall(GetShapeBody, gs)
    if type(b) ~= "number" or isColliderBody(b) or isGloveBody(b) or (b ~= 0 and b == replica.body) then return 0 end
    if b ~= 0 and engineCall(HasTag, b, "tdvr_body") == true then return 0 end   -- (v0.22: a body copy)
    return b                              -- (v0.21 section 6.7: never one of our own bodies)
end

-- Can a hand pick up body b? Dynamic, with a mass in (0, grab_max_mass] (static bodies report 0: a building, the
-- terrain), not part of any vehicle (also the player's own), not carried by the engine grab, not the body the player
-- stands on (v0.6 review H1: holding it would lift the player with it, without limit). Returns its mass, or nil and
-- (v0.10, docs/V010_PLAN.md section 2) why: 1 not dynamic / no mass, 2 over grab_max_mass, 3 anything else (L_HANDREJ_*).
function handGrabMass(b)
    if type(b) ~= "number" or b == 0 or not validBody(b) then return nil, 3 end
    -- v0.11 review LUA-V011-HANDREJ-GROUND / LUA-HANDREJ-5: the dynamic / mass test runs before the ground test, so a
    -- static ground body (usually the world body, which also holds the walls) counts in L_HANDREJ_STATIC, not _OTHER.
    -- A dynamic body the player stands on is still why 3 (H1: never grabbed).
    if engineCall(IsBodyDynamic, b) ~= true then return nil, 1 end
    local m = engineCall(GetBodyMass, b)
    if type(m) ~= "number" or m <= 0 then return nil, 1 end
    if b == phys.ground then return nil, 3 end
    if m > handMaxMass() then return nil, 2 end
    local v = engineCall(GetBodyVehicle, b)
    if type(v) == "number" and v ~= 0 then return nil, 3 end
    if b == GetPlayerGrabBody() then return nil, 3 end
    return m
end

-- v0.10 (section 2) acceptance of a hand query hit (see handQuery): true, or false and why (1 / 2 / 3 as handGrabMass).
-- Grab: handGrabMass and a clear line from the palm p (handLineClear; blocked = 3); hit.mass is set. Push: a dynamic body
-- with a mass (pushHand checks the rest: contact distance, approach speed, held / ground bodies).
function handAcceptGrab(hit, p)
    local m, why = handGrabMass(hit.body)
    if not m then return false, why end
    if not handLineClear(p, hit) then return false, 3 end
    hit.mass = m
    return true
end

function handAcceptPush(hit)
    if engineCall(IsBodyDynamic, hit.body) ~= true then return false, 1 end
    local m = engineCall(GetBodyMass, hit.body)
    if type(m) ~= "number" or m <= 0 then return false, 1 end
    return true
end

-- The hand's world transform (the glove model frame: grip * handXform, so the ini hand offsets apply) and its palm
-- centre (handPalm, v0.21; was HP.PALM; the right palm faces model -X, the left one +X).
-- v0.21 (docs/V021_PLAN.md section 6.5): forQuery and the hand solid (FREE / BLOCKED): the PHYSICAL hand (its collider,
-- physHandT) - the grab query starts where the solid hand is, never through a wall; the hold target stays the controller.
function handWorld(side, base, forQuery)
    local t = ctrlHandT(side, base)
    if forQuery and HC.solid(side) then t = physHandT(side) or t end
    local pc = handPalm()                 -- (v0.21: was HP.PALM; the blocky palm sits deeper, section 3.2)
    return t, TransformToParentPoint(t, Vec((side == "l") and -pc[1] or pc[1], pc[2], pc[3]))
end

-- Closest dynamic physical body within r of point p (QueryClosestPoint): { body, point, normal, dist } or nil. Rejected:
-- our own bodies (gloves, tool replica), the engine's carried body and tool body, the player's vehicle. normal = the
-- surface's outward normal at point (v0.6 review L1): from the point to p while p is outside (> 2 mm; independent of the
-- engine's sign convention), else the query's normal (nil if it is no usable vector).
-- v0.10 (docs/V010_PLAN.md section 2): the v0.9 headset session never found a body (handsNear 0, no grab arm): the
-- query returns only the ONE closest shape, and in Teardown 2.0 the player's own animated body is most likely closest to
-- the palm every time, masking every real object behind it. So every query (filters apply to one query only) also
-- rejects the player (QueryRejectPlayer) and its animator (QueryRejectAnimator(GetPlayerAnimator()), 0 skipped; both
-- guarded), and the hit must pass accept(hit, p) (handAcceptGrab / handAcceptPush): a body that does not is rejected as
-- well (QueryRejectBody) and the query repeated, at most HP.QTRY times. Returns the first accepted hit (nil none) and
-- every hit the queries returned, closest first (the push shares a grab query's hits, see updatePhysHand), and whether
-- the loop stopped at the limit. Counts L_HANDQ / L_HANDHIT / L_HANDREJ_*.
-- v0.11 (docs/V011_PLAN.md section 3): the v0.10 headset log still had L_HANDHIT 0 in 10160 queries with
-- QueryRequire("physical dynamic"), so the query requires "physical" only; dynamic-ness is left to accept (handGrabMass /
-- handAcceptPush: IsBodyDynamic and a mass), so a static hit (a wall or floor closer than the crate) is rejected
-- (QueryRejectBody), counted in L_HANDREJ_STATIC, and the query repeated like any other unusable body.
function handQuery(p, r, accept)
    local seen = {}
    if not (QueryClosestPoint and GetShapeBody) then return nil, seen, false end
    local ph = phys
    local veh = GetPlayerVehicle()
    local extra = { GetPlayerGrabBody(), GetToolBody(), veh ~= 0 and engineCall(GetVehicleBody, veh) or 0,
                    engineCall(GetPlayerAnimator) }
    for _ = 1, HP.QTRY do
        engineCall(QueryRequire, "physical")
        rejectOwnBodies(false)
        for i = 1, 3 do
            if type(extra[i]) == "number" and extra[i] ~= 0 then QueryRejectBody(extra[i]) end
        end
        engineCall(QueryRejectPlayer)
        if type(extra[4]) == "number" and extra[4] ~= 0 then engineCall(QueryRejectAnimator, extra[4]) end
        for i = 1, #seen do QueryRejectBody(seen[i].body) end
        local hit, point, n, shape = engineCall(QueryClosestPoint, p, r)
        ph.q = ph.q + 1
        if not hit or type(point) ~= "table" or type(point[3]) ~= "number" or type(shape) ~= "number" or shape == 0 then
            return nil, seen, false
        end
        ph.qHit = ph.qHit + 1
        local body = engineCall(GetShapeBody, shape)
        if type(body) ~= "number" or body == 0 then return nil, seen, false end
        local d = VecLength(VecSub(point, p))
        if d > 0.002 then
            n = VecScale(VecSub(p, point), 1 / d)
        elseif type(n) ~= "table" or type(n[3]) ~= "number" or VecLength(n) < 0.5 then
            n = nil
        else
            n = VecNormalize(n)
        end
        local res = { body = body, point = point, normal = n, dist = d }
        seen[#seen + 1] = res
        local ok, why = accept(res, p)
        if ok then return res, seen, false end
        ph.rej[why or 3] = ph.rej[why or 3] + 1
    end
    return nil, seen, true
end

-- v0.6 review missed-2: nothing static between point p (the palm) and the reach hit's closest point (a grab through a
-- thin wall, floor or fence would press the body into it for as long as it is held): a ray from p toward the point, 1 cm
-- short of it, against static geometry only (our own static bodies rejected). true = clear (also within 1 cm, or
-- without QueryRaycast).
function handLineClear(p, hit)
    local l = hit.dist - 0.01
    if l <= 0 or not QueryRaycast then return true end
    engineCall(QueryRequire, "physical static")
    rejectOwnBodies(false)
    return engineCall(QueryRaycast, p, VecScale(VecSub(hit.point, p), 1 / hit.dist), l) ~= true
end

-- v0.11 (docs/V011_PLAN.md section 3) probe diagnostics, every 0.5 s of phys.clock while the hand physics run (from
-- updateHandPhysics, before the hands' own queries): does a closest-point query near the right palm find ANYTHING? One
-- query, QueryRequire("physical") with our own bodies and the player (guarded) rejected, QueryClosestPoint(right palm,
-- 1.0 m); not counted in L_HANDQ. The nearest hit per whole second of phys.clock is kept in phys.anyB (its kind: 1
-- static, 2 dynamic by IsBodyDynamic); phys.palmEye = right palm -> model eye (attachEye, else the eye the VR base uses)
-- every call, a sanity check of the palm position itself. Without a tracked right grip nothing is probed.
function handProbe()
    local p = phys
    p.palmEye = -1
    if not (ctl and hasBit(ctl.hv, 4) and p.base) then return end
    local _, palm = handWorld("r", p.base)
    p.palmEye = VecLength(VecSub(palm, attachEye() or playerEyePos()))
    -- (0.499: phys.clock is a float sum of the frame times, 0.5 s of them may add up a hair short of 0.5)
    if p.probeAt ~= nil and p.clock - p.probeAt < 0.499 and p.clock >= p.probeAt then return end
    p.probeAt = p.clock
    if not (QueryClosestPoint and GetShapeBody) then return end
    engineCall(QueryRequire, "physical")
    rejectOwnBodies(false)
    engineCall(QueryRejectPlayer)
    local hit, point, _, shape = engineCall(QueryClosestPoint, palm, 1.0)
    if not hit or type(point) ~= "table" or type(point[3]) ~= "number" or type(shape) ~= "number" or shape == 0 then
        return
    end
    local body = engineCall(GetShapeBody, shape)
    local kind = (type(body) == "number" and body ~= 0 and engineCall(IsBodyDynamic, body) == true) and 2 or 1
    local d, k = VecLength(VecSub(point, palm)), math.floor(p.clock)
    local o = p.anyB[k]
    if not o or d < o.dist then p.anyB[k] = { dist = d, kind = kind } end
end

-- World velocity of a hand over the last HP.VEL_WIN seconds of its samples (play-space grip positions, so a snap turn
-- or the base moving adds no jump; turned by the heading now, plus the player's velocity). nil: fewer than 2 samples, no
-- time between them, or a step inside the window larger than the hold target cap (a tracking glitch). Second result:
-- the same without the player's velocity (the hand's own motion; v0.6 review H1: the hold speed limit uses only that).
function handVelocity(hist, base)
    local n = #hist
    if n < 2 then return nil end
    local last, k = hist[n], n - 1
    while k > 1 and last.t - hist[k - 1].t <= HP.VEL_WIN do k = k - 1 end
    local span = last.t - hist[k].t
    if span <= 1e-4 then return nil end
    for i = k + 1, n do
        local st = hist[i].t - hist[i - 1].t
        if VecLength(VecSub(hist[i].p, hist[i - 1].p)) > HP.JUMP + HP.JUMP_V * st then return nil end
    end
    local v = QuatRotateVec(base.rot, VecScale(VecSub(last.p, hist[k].p), 1 / span))
    return VecAdd(v, GetPlayerVelocity()), v
end

-- Normalised lerp from rotation a towards b (the shorter way) by fraction f.
function quatToward(a, b, f)
    local s = (a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4] < 0) and -1 or 1
    local q = {}
    for i = 1, 4 do q[i] = a[i] + (b[i] * s - a[i]) * f end
    local l = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3] + q[4] * q[4])
    if l < 1e-9 then return b end
    return Quat(q[1] / l, q[2] / l, q[3] / l, q[4] / l)
end

-- The hold target follows the hand t, at most HP.JUMP + HP.JUMP_V * dt metres (0.27 m at 60 fps, faster than any
-- swing) and HP.TURN degrees per tick from the previous target: a tracking glitch (a controller pose jumping for a few
-- frames) can only drag a held body, never fling it.
function capHandStep(prev, t, dt)
    if not prev then return t end
    local d = VecSub(t.pos, prev.pos)
    local l = VecLength(d)
    local maxL = HP.JUMP + HP.JUMP_V * dt
    local pos, rot = t.pos, t.rot
    if l > maxL then pos = VecAdd(prev.pos, VecScale(d, maxL / l)) end
    local a = quatAngle(prev.rot, t.rot)
    if a > HP.TURN then rot = quatToward(prev.rot, t.rot, HP.TURN / a) end
    return Transform(pos, rot)
end

-- The hand's pose this tick: world transform and palm (phys.base), a velocity sample, the hold target and (v0.6 review
-- L2) its position relative to the player's (update() rebuilds the target from the player's position at its step, so a
-- held body does not trail the glove by a physics step of walking).
function trackHand(side, dt)
    local h, base = phys[side], phys.base
    h.world, h.palm = handWorld(side, base)
    if HC.solid(side) then h.palm = select(2, handWorld(side, base, true)) end   -- (v0.21: the physical palm)
    local g, ws = (side == "l") and ctl.lgrip or ctl.rgrip, nat.worldScale
    push(h.hist, { t = phys.clock, p = Vec(g[1] * ws, g[2] * ws, g[3] * ws) }, HP.HIST)
    h.vel, h.rvel = handVelocity(h.hist, base)
    if h.hold then h.target = capHandStep(h.target, h.world, dt) else h.target = h.world end
    h.tgtRel = VecSub(h.target.pos, GetPlayerTransform().pos)
end

-- Takes hand `side`'s candidate: the grab point (where the query touched it) in body space and the body relative to
-- the hand. A body the other hand already holds gets no second orientation constraint (two hands would fight; their
-- two grab points already turn it). A resting body is woken up (SetBodyActive; holdHands does it every step too).
function grabHand(side)
    local h = phys[side]
    local c = h.cand
    local b = c.body
    local bt = GetBodyTransform(b)
    local other = phys[(side == "l") and "r" or "l"].hold
    h.hold = { body = b, lp = TransformToLocalPoint(bt, c.point), rel = TransformToLocalTransform(h.world, bt),
               mass = c.mass, far = 0, stuck = 0, orient = not (other and other.body == b) }
    h.target, h.arm, h.cand = h.world, 0, nil   -- (a holding hand publishes "holding", not "near")
    engineCall(SetBodyActive, b, true)
    phys.grabs = phys.grabs + 1
    pulse((side == "l") and 1 or 2, 0.3, 0.03)
end

-- Lets go of hand `side`'s body. If the other hand still holds it, that hand takes over the orientation (from where
-- the body is now). Else with `throw` (the grip opened, hand_physics bit2) the body gets the hand's velocity (nil after
-- a tracking glitch: no throw) capped at HP.THROW_MAX, in full up to HP.THROW_FULL of grab_max_mass and scaled down
-- by mass above it (a heavy body keeps more of its own velocity); a throw (> HP.THROW_MIN) is counted.
function releaseHand(side, throw)
    local h = phys[side]
    local o = h.hold
    if not o then return end
    h.hold = nil
    local oh = phys[(side == "l") and "r" or "l"]
    if oh.hold and oh.hold.body == o.body then
        if not oh.hold.orient and validBody(o.body) and oh.target then
            oh.hold.orient, oh.hold.rel = true, TransformToLocalTransform(oh.target, GetBodyTransform(o.body))
        end
        return
    end
    if not throw or not h.vel or not validBody(o.body) then return end
    local v = h.vel
    local sp = VecLength(v)
    if sp < HP.THROW_MIN then return end
    if sp > HP.THROW_MAX then v = VecScale(v, HP.THROW_MAX / sp) end
    local bv = engineCall(GetBodyVelocity, o.body)
    if type(bv) ~= "table" or type(bv[3]) ~= "number" then bv = Vec(0, 0, 0) end
    local k = clamp(handMaxMass() * HP.THROW_FULL / o.mass, 0, 1)
    engineCall(SetBodyVelocity, o.body, VecAdd(bv, VecScale(VecSub(v, bv), k)))
    phys.throws = phys.throws + 1
end

-- Release rules of a held body: the grip opened (< 0.45: a throw if enabled); without a throw: the body gone (invalid
-- handle), static now, it lost over 30 % of its mass (a piece broke off and the grab point may be on the other one),
-- taken by the engine grab, the player stands on it (v0.6 review H1: stepped onto it), or its grab point more than
-- HP.FAR from the hand's for HP.FAR_T (the player teleported) or more than HP.STUCK for HP.STUCK_T (v0.6 review
-- missed-2: held against something static). v0.6 review missed-1: a chipped voxel (IsBodyBroken) no longer drops it, so
-- a held body can be used to smash things.
function checkHold(side, dt, bits)
    local h = phys[side]
    local o = h.hold
    local b = o.body
    if not h.on then releaseHand(side, hasBit(bits, 4)) return end
    local ok = validBody(b) and b ~= phys.ground and engineCall(IsBodyDynamic, b) == true and b ~= GetPlayerGrabBody()
    local m = ok and engineCall(GetBodyMass, b)
    if ok and type(m) == "number" and m < o.mass * 0.7 then ok = false end
    if ok then
        local tgt = TransformToParentTransform(h.target, o.rel)
        local d = VecLength(VecSub(TransformToParentPoint(GetBodyTransform(b), o.lp), TransformToParentPoint(tgt, o.lp)))
        if d > HP.FAR then o.far = o.far + dt else o.far = 0 end
        if d > HP.STUCK then o.stuck = o.stuck + dt else o.stuck = 0 end
        if o.far >= HP.FAR_T or o.stuck >= HP.STUCK_T then ok = false end
    end
    if not ok then releaseHand(side, false) end
end

-- Push (hand_physics bit1): a hand that holds nothing, touching a dynamic body (within HP.PUSH_D of it) and moving into
-- its surface faster than HP.PUSH_V (relative to the body: a body carried along is not pushed again) gives it an impulse
-- at the contact point along the inward surface normal of min(mass, 30) * that approach speed * 0.3, at most once per
-- HP.PUSH_GAP per body (v0.6 review L1: a hand moving away or sliding along no longer pulls or drags it; without a
-- usable normal the hand's own motion is the direction). Bodies a hand holds and (missed-3) the body the player stands
-- on are not pushed.
function pushHand(side)
    local p, h = phys, phys[side]
    local hit = h.hit
    if not hit or hit.dist > HP.PUSH_D or not h.vel then return end
    local b = hit.body
    if b == p.ground or (p.l.hold and p.l.hold.body == b) or (p.r.hold and p.r.hold.body == b) then return end
    if p.clock - (p.pushT[b] or -1000) < HP.PUSH_GAP or engineCall(IsBodyDynamic, b) ~= true then return end
    local m = engineCall(GetBodyMass, b)
    if type(m) ~= "number" or m <= 0 then return end
    local bv = engineCall(GetBodyVelocityAtPos, b, hit.point) or engineCall(GetBodyVelocity, b)
    if type(bv) ~= "table" or type(bv[3]) ~= "number" then bv = Vec(0, 0, 0) end
    local rv = VecSub(h.vel, bv)
    local n, vn = hit.normal, 0
    if n then
        vn = -VecDot(rv, n)
    else
        vn = VecLength(rv)
        if vn > 1e-6 then n = VecScale(rv, -1 / vn) end
    end
    if not n or vn <= HP.PUSH_V then return end
    -- (v0.21 section 6.5: a solid hand pushes by its collider; the impulse is skipped, counted)
    if HC.solid(side) then HC.pushSkips = HC.pushSkips + 1 return end
    if vn > HP.THROW_MAX then vn = HP.THROW_MAX end
    engineCall(ApplyBodyImpulse, b, hit.point, VecScale(n, -vn * math.min(m, HP.PUSH_MASS) * HP.PUSH_K))
    p.pushT[b], p.pushes = p.clock, p.pushes + 1
end

-- One hand, every tick while the hand physics run (bits = N_HAND_PHYSICS). The grip uses the gloves' hysteresis (on
-- 0.55 / off 0.45). v0.6 review M2/N2: native alone decides who owns a grip press (it latches it at its press edge from
-- the L_HANDS_NEAR it read) and echoes that in N_GRIP_LATCH: a press is this hand's (it may grab a candidate for HP.ARM
-- seconds; L_GRIP_ARM counts them) if the latch bit shows up at the press or within HP.LATCH_WAIT ticks after it (native
-- may publish it a frame late, or see the press a frame before our pair snapshot does); otherwise it belongs to the
-- engine grab for its whole length (no hand grab: both would act on one press, and native did send it to the game).
-- The reach has hysteresis (near from HP.REACH, still near up to HP.REACH + HP.REACH_OUT), so the published near bit
-- does not flicker at the edge; a candidate needs a clear line from the palm (handLineClear, review missed-2).
-- A hand whose grip is not tracked drops what it holds (no throw) and forgets its samples.
function updatePhysHand(side, dt, bits)
    local p, h = phys, phys[side]
    if not hasBit(ctl.hv, (side == "l") and 1 or 4) then
        releaseHand(side, false)
        h.hist, h.target, h.vel, h.rvel, h.hit, h.cand, h.on, h.arm, h.wait = {}, nil, nil, nil, nil, nil, false, 0, 0
        return
    end
    trackHand(side, dt)
    local sq = (side == "l") and ctl.lsq or ctl.rsq
    local was = h.on
    h.on = sq > 0.55 or (was and sq > 0.45)
    if h.on and not was then
        h.arm, h.wait = -1, HP.LATCH_WAIT + 1
    elseif not h.on then
        h.arm, h.wait = 0, 0
    end
    if h.wait > 0 then
        if hasBit(nat.gripLatch, (side == "l") and 1 or 2) then
            h.arm, h.wait, p.arms = HP.ARM, 0, p.arms + 1
        else
            h.wait = h.wait - 1
        end
    end
    if h.hold then checkHold(side, dt, bits) end
    local wasNear = h.cand ~= nil
    h.hit, h.cand = nil, nil
    local grabOn, pushOn = hasBit(bits, 1), hasBit(bits, 2)
    if not h.hold and (grabOn or pushOn) then
        -- (v0.10 section 2: the reach query rejects what it cannot grab and asks again, see handQuery; the push takes the
        -- closest pushable body among that query's hits (the reach covers PUSH_R) and only queries itself when the grab
        -- is off or the grab query stopped at its limit without one)
        local full, seen = false, {}
        if grabOn then
            h.cand, seen, full = handQuery(h.palm, HP.REACH + (wasNear and HP.REACH_OUT or 0), handAcceptGrab)
            if h.cand then
                local k = math.floor(p.clock)
                p.nearB[k] = math.min(p.nearB[k] or h.cand.dist, h.cand.dist)
            end
        end
        if pushOn then
            for i = 1, #seen do
                if handAcceptPush(seen[i]) then h.hit = seen[i] break end
            end
            if not h.hit and (not grabOn or full) then h.hit = handQuery(h.palm, HP.PUSH_R, handAcceptPush) end
        end
    end
    if h.on and h.arm > 0 and h.cand and not h.hold then grabHand(side) end
    if h.arm > 0 then
        h.arm = h.arm - dt
        if h.arm <= 0 then h.arm = -1 end
    end
    if hasBit(bits, 2) and not h.hold then pushHand(side) end
end

-- Lets go of everything (no throw) and forgets the hands' state.
function resetPhysHands()
    for s = 1, 2 do
        local side = (s == 1) and "l" or "r"
        releaseHand(side, false)
        local h = phys[side]
        h.hist, h.target, h.vel, h.rvel, h.hit, h.cand, h.on, h.arm, h.wait = {}, nil, nil, nil, nil, nil, false, 0, 0
    end
end

-- Every tick, after updateActive (docs/V06_PLAN.md section 7). The hands work while VR controls the view on foot with
-- hand_physics bit0 (grab) or bit1 (push); otherwise (VR inactive: paused, a menu, a cutscene; a vehicle; switched off)
-- everything is let go at once without a throw. grab switched off while holding: let go. L_HANDS_NEAR (every tick,
-- 0 when off): bit0/1 the left/right hand has a grabbable body in reach, bit2/3 it holds one. L_HANDGRAB = grabs*1000 +
-- throws; v0.6 review: L_HOLD_SLEEP (holdHands), L_GRIP_ARM (updatePhysHand), phys.ground = the body the player stands on.
function updateHandPhysics(dt, flags)
    local p = phys
    p.clock = p.clock + (dt or 0)
    local bits = nat.valid and (nat.handPhysics or 0) or 0
    local run = active and ctl ~= nil and p.baseTick == heartbeat and p.base ~= nil and not hasBit(flags, LF_VEHICLE)
        and (hasBit(bits, 1) or hasBit(bits, 2))
    p.ground = run and playerGroundBody() or 0
    if not run then
        resetPhysHands()
        p.palmEye = -1
    else
        handProbe()                       -- (v0.11 section 3: before the hands' queries, the diagnostics only)
        if not hasBit(bits, 1) then
            releaseHand("l", false)
            releaseHand("r", false)
        end
        updatePhysHand("l", dt, bits)
        updatePhysHand("r", dt, bits)
    end
    for b, t in pairs(p.pushT) do
        if p.clock - t > 1 then p.pushT[b] = nil end
    end
    local near = 0
    if p.l.cand then near = near + 1 end
    if p.r.cand then near = near + 2 end
    if p.l.hold then near = near + 4 end
    if p.r.hold then near = near + 8 end
    p.near = near
    W(LX.HANDS_NEAR, near)
    W(L2.HANDGRAB, p.grabs * 1000 + math.min(p.throws, 999))
    W(L2.HOLD_SLEEP, p.sleep)
    W(L2.GRIP_ARM, p.arms)
    -- v0.10 L4 hand diagnostics (docs/V010_PLAN.md section 2): cumulative counters; the nearest acceptable grab candidate
    -- over the last 5 s of phys.clock (whole-second buckets: the 5 s are 4 to 5 s long)
    local nearest, k0 = -1, math.floor(p.clock) - 4
    for k, d in pairs(p.nearB) do
        if k < k0 then p.nearB[k] = nil elseif nearest < 0 or d < nearest then nearest = d end
    end
    W(L4.HANDQ, math.min(p.q, 99999))
    W(L4.HANDHIT, p.qHit)
    W(L4.HANDREJ_STATIC, p.rej[1])
    W(L4.HANDREJ_MASS, p.rej[2])
    W(L4.HANDREJ_OTHER, p.rej[3])
    W(L4.HAND_NEAREST, nearest >= 0 and nearest * 100 or -1)
    -- v0.11 L5 probe diagnostics (docs/V011_PLAN.md section 3): the nearest probe hit over the last 5 s (the same
    -- whole-second buckets) and its kind; the palm -> model eye distance now
    local any = nil
    for k, o in pairs(p.anyB) do
        if k < k0 then p.anyB[k] = nil elseif not any or o.dist < any.dist then any = o end
    end
    W(L5.HAND_ANYDIST, any and any.dist * 100 or -1)
    W(L5.HAND_ANYKIND, any and any.kind or 0)
    W(L5.HAND_PALM_EYE, p.palmEye >= 0 and p.palmEye * 100 or -1)
end

-- v0.6 review H1: the held body's world box (GetBodyBounds) overlaps the player, a vertical cylinder of radius HP.BODY_R
-- around the player position pp from the feet to 0.1 m above the eye. false when the bounds are unknown.
function holdTouchesPlayer(b, pp)
    local mn, mx = engineCall(GetBodyBounds, b)
    if type(mn) ~= "table" or type(mx) ~= "table" or type(mn[3]) ~= "number" or type(mx[3]) ~= "number" then return false end
    if mx[2] < pp[2] or mn[2] > GetPlayerEyeTransform().pos[2] + 0.1 then return false end
    local dx = math.max(mn[1] - pp[1], 0, pp[1] - mx[1])
    local dz = math.max(mn[3] - pp[3], 0, pp[3] - mx[3])
    return dx * dx + dz * dz < HP.BODY_R * HP.BODY_R
end

-- update() (the physics step, 60 Hz): each held body is pulled at its grab point to the hold target (the hand pose of
-- the last tick, capped, see capHandStep; v0.6 review L2: at the player's position now) by ConstrainPosition and turned
-- by ConstrainOrientation (not for a second hand on the same body), with impulses limited per step: force min(mass * 40,
-- HP.FMAX) N per hand (v0.6 review L3: no longer scaled by grab_max_mass, so heavier allowed bodies are dragged, not
-- swung), and at most HP.CARRY times its weight while its box overlaps the player (H1: carried, never shoved into or
-- lifting the player); torque = that force at 15 cm, at most 12 rad/s. The speed limit is the braking speed sqrt(2 * a *
-- distance) (a = the force / mass) plus the hand's own speed (H1: without the player's velocity, which made it a
-- feedback loop), between 0.5 and 8 m/s: a force-limited pull that wants to close the gap in one step would overshoot
-- the hand and swing around it (heavy bodies most). v0.6 review M1: every held body is woken (SetBodyActive) at every
-- step (a still body could fall asleep in mid-air); L_HOLD_SLEEP counts the steps that found it asleep.
function holdHands(dt)
    if type(dt) ~= "number" or dt <= 0 then return end
    local pp = nil
    for s = 1, 2 do
        local h = phys[(s == 1) and "l" or "r"]
        local o = h.hold
        if o and h.target and validBody(o.body) then
            if engineCall(IsBodyActive, o.body) == false then phys.sleep = phys.sleep + 1 end
            engineCall(SetBodyActive, o.body, true)
            pp = pp or GetPlayerTransform().pos
            local tt = h.target
            if h.tgtRel then tt = Transform(VecAdd(pp, h.tgtRel), tt.rot) end
            local bt = GetBodyTransform(o.body)
            local tgt = TransformToParentTransform(tt, o.rel)
            local f = math.min(o.mass * HP.ACC, HP.FMAX)
            if holdTouchesPlayer(o.body, pp) then f = math.min(f, o.mass * 9.81 * HP.CARRY) end
            local imp = f * dt
            local pa, pb = TransformToParentPoint(bt, o.lp), TransformToParentPoint(tgt, o.lp)
            local vmax = math.sqrt(2 * f / o.mass * VecLength(VecSub(pb, pa))) + (h.rvel and VecLength(h.rvel) or 0)
            engineCall(ConstrainPosition, o.body, 0, pa, pb, clamp(vmax, HP.VEL_MIN, HP.VEL), imp)
            if o.orient then engineCall(ConstrainOrientation, o.body, 0, bt.rot, tgt.rot, HP.ANGVEL, imp * HP.LEVER) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- v0.21 solid hands and shins (docs/V021_PLAN.md sections 5-8)
-- ---------------------------------------------------------------------------------------------
-- All v0.21 state lives in the global tables BLK, HC, BC, BV, PM (the main chunk is at 194 of Lua 5.1's 200 locals);
-- every new engine call goes through engineCall (a missing API is a no-op). Single-player only: BV.mp (bodyMode) keeps
-- every part here off. Small helpers are fields of these tables (HC.*, BC.*, PM.*), so the global functions are exactly
-- the plan's (section 10). Nothing here calls the engine while every v0.21 option is off and nothing of ours exists
-- (HC.idle): the v0.20 behaviour, call for call.
-- One invisible DYNAMIC collider body per hand (variant A: a voxbox, B: a visible 80 % pose copy, C: the blocky glove's
-- own pose shape; the self-test colSelfTest picks the first that collides) is driven in update() toward the controller
-- hand by ConstrainPosition / ConstrainOrientation against the static world (bodyB 0, driveColliders); the visible glove
-- keeps the v0.20 render placement in free air and blends onto the collider when it is held back (hcolVisual). Two
-- invisible shin boxes follow the character's lower legs (shinTick). Our layers 64 / 128 are cleared from the player's
-- CollisionMask and from the mask of every player-animator shape while any collider is on (pmApply, pmAnimFilters).
-- HC = the hand colliders, section 6.1 (kg, N, N*m, m/s, rad/s, s, m); LOCAL = the collider's pose in the hand model frame
-- (variant A: blocky the cube centre = the grip, glove / skin the palm; right hand, x mirrored for the left; B / C: the
-- grip). Run state: fail = the permanent L_HCOL fail code of this Lua state (0 none; 2 mask, 3 animator filter, 4 self-
-- test, 5 pick fights, 6 player shove, 7 spawn, 10 hand ground fights), why = the fail digit written (with the passing
-- codes 1 option off, 7 blocky voxel, 8 no gloves, 9 multiplayer), sel / imp / var = the self-test, impulse unit and
-- variant codes (section 9), impScale = the measured maxImpulse unit (kHold / 1.05), mass / massScale = the self-test
-- collider's calibrated mass and m / MASS when it could not be calibrated (ST4; diagnostic only: each live collider
-- calibrates itself and driveColliders scales its F by its own ms), clock = s of tick dt, updAt = clock of
-- the last update(), gapEdge = this tick saw the first update() gap > GAP, incl = inconclusive self-test runs, ST = the
-- running self-test (nil none), vPrev = the player's speed last tick (shove detector), pushSkips = pushHand calls skipped
-- for a solid hand, delTick = the heartbeat deleteColliders last searched the scene; tele / ppPrev = the player was
-- teleported this tick (moved more than JUMP beyond its velocity * the physics time, R-10) / the player's position
-- last tick (hcolTick; the 6.5 JUMP rule judges the targets relative to the player, plus this, so walking or falling is
-- never a jump); ppDrv =
-- the player's position driveColliders read in the last update() (the held-back error, plan 16.1 R-8); the error
-- samples (FREE / BLOCKED ticks, L_HCOL_ERR) are a ring buffer of plain numbers: errT / errMm / errBl = clock, error mm,
-- blocked (ERR_CAP entries, errHead = the oldest, errN = how many), errW / errAt = the L_HCOL_ERR value computed at clock
-- errAt (recomputed every ERR_EVERY s, written every tick); logs (entries { clock, value }): snapLog, ghostLog,
-- clampLog (L_HCOL_EV), pickLog, shoveLog, fightLog (hand ground fights).
-- Per side HC.r / HC.l: st = the L_HCOL state digit (0 OFF, 1 FREE, 2 BLOCKED, 3 HELD, 4 GHOST, 5 PARKED, 6 SELFTEST),
-- body / shape / shapes (B: pose -> shape) = the collider, fl = shape -> the filter (and B visibility) set last, cal = its
-- density calibration { shapes, d, tries, n, target, m, done }, ms = its mass / MASS when not calibrated, tgtRel / tgtRot
-- = the target relative to the player's position / its rotation (tick, refreshed in render; update() rebuilds the world
-- target from the player's position then), prevRel / prevTgt = last tick's, prevLoc = last tick's target in the play
-- space (the base's part of a JUMP, R-7), drvRel = the tgtRel update() drove toward until this tick (R-8), rvel = the
-- target's own velocity, park = where it is parked, snapT / stuckT = s beyond SNAP / STUCK, ghostUntil = clock until
-- which it stays a ghost (grace, pick, ground fight), wasHeld, pickRun = ticks it was the game's pick / interact / grab
-- body, hapticAt, vis = the visible hand's transform hcolVisual chose this frame (nil: the controller hand; visualHandT,
-- placeToolReplica).
HC = { LAYER = 64, MASS = 1.0, F = 300, F_WEAK = 150, F_STRONG = 600, T = 15, VMAX = 8, VCAP = 30, VMIN = 0.5, W = 20,
       LEAD = 1 / 60, LEAD_MAX = 0.05, E0 = 0.03, E1 = 0.06, GHOST_LINE = 0.06, CLAMP_STEP = 0.06, RAY_R = 0.04,
       RAY_GAP = 0.02, SNAP_NOW = 1.5, SNAP = 0.6, SNAP_T = 0.3, JUMP = 0.25, STUCK = 0.4, STUCK_T = 3, CLEAR_R = 0.07,
       GRACE = 0.35, GAP = 0.5, PICK_OFF = 2, PICK_MAX = 3, HAPTIC = 0.3, HAPTIC_GAP = 0.15, GROUND_WEAK = 0.02,
       GROUND_NOVEL = 0.05, QMASK = 63,
       LOCAL = { blocky = { 0, 0, 0 }, glove = { -0.02, 0, -0.03 } },
       ERR_CAP = 2048, ERR_EVERY = 0.25,
       r = { st = 0 }, l = { st = 0 }, fail = 0, why = 0, sel = 0, imp = 0, var = 0, impScale = 1, mass = 0,
       massScale = 1, clock = 0, updAt = 0, gapEdge = false, gapPrev = false, incl = 0, ST = nil, vPrev = nil,
       pushSkips = 0, delTick = -1, tele = false, ppPrev = nil,
       errT = {}, errMm = {}, errBl = {}, errHead = 1, errN = 0, errAt = nil, errW = -1,
       snapLog = {}, ghostLog = {}, clampLog = {}, pickLog = {}, shoveLog = {}, fightLog = {},
       -- v0.22 (docs/V022_PLAN.md sections 2-3, all under NHP_STEADY / NHP_PUNCH): CLAMP_MIN = the smallest step swept,
       -- SW_BACK / SW_HALF / SW_R / SW_GAP = the sweep's start behind each point, the box half size, the ray radius and
       -- the gap kept to the wall (m), F_REST (N) / T_BLOCK = the drive while pressed against a wall, W_RATE (/s) = the
       -- visual blend's ramp, OMEGA (rad/s) = the dynamic-contact visual filter, YAW_EPOCH (deg) / JUMP_BIG (m) = the snap
       -- rules (3.5). State: baseEpoch = base jumps counted (snap turn, recenter, method / eye source / attach change,
       -- teleport), ek = the values compared last tick, steps = update() steps since the last tick, uclock = s of update()
       -- steps (the punch's clock), vdt = the visual's frame dt, visBase / visLive = the base the hands are drawn with and
       -- the live one (held frames), st3bN = the ST3b impulse factor (0 none), snapK = per snap kind (1 event, 2
       -- geometric, 3 SNAP_NOW, 4 SNAP_T, 5 teleport) the logs of L_HSNAP, order = update-order ratios (L_HSNAP)
       CLAMP_MIN = 0.005, SW_BACK = 0.03, SW_HALF = 0.05, SW_R = 0.045, SW_GAP = 0.005, F_REST = 40, T_BLOCK = 5,
       W_RATE = 12, OMEGA = 30, YAW_EPOCH = 20, JUMP_BIG = 0.6,
       baseEpoch = 0, ek = nil, steps = 1, uclock = 0, vdt = 0, visBase = nil, visLive = nil, st3bN = 0,
       snapK = { {}, {}, {}, {}, {} }, order = {} }
-- v0.22 (docs/V022_PLAN.md section 2.2): the punch - E restitution, V / VOWN (m/s) the approach speed and the hand's own
-- approach that trigger it, VCAP (m/s), DVMAX (m/s) the most a punch adds to a body's speed, LIFT the upward share, AIM
-- the share of the hand's direction, D (m) the contact distance beyond the collider, GAP (s) between punches of one
-- body, SEP (s) without contact before an onset, NEAR (m) / NEAR_K a body this near the player gets J * NEAR_K, M (kg) /
-- JMAX (N*s) per hand_strength (normal, weak, strong). State: T = body -> uclock of its last punch, log / onsetLog /
-- skipLog = { HC.clock, value } (L_PUNCH), gains = the measured gains (median), pend = per hand (r / l) the punch whose
-- gain the next step measures.
PUNCH = { E = 0.4, V = 1.5, VOWN = 1.0, VCAP = 10, DVMAX = 12, LIFT = 0.25, AIM = 0.5, D = 0.03, GAP = 0.25, SEP = 0.12,
          NEAR = 0.35, NEAR_K = 0.3, M = { 12, 6, 25 }, JMAX = { 90, 45, 180 },
          T = {}, log = {}, onsetLog = {}, skipLog = {}, gains = {}, pend = nil }
-- BC = the shin colliders, section 7; per side BC.r / BC.l (fields as HC's). off = the permanent shin reason of this Lua
-- state (2 mask, 3 animator filter, 4 self-test / variant not A / query-visible, 7 ground fights), reason = the L_BODY_COL
-- reason written (with 1 option off, 5 bones, 6 situation, 8 multiplayer), src = ticks the shin rotation came from the
-- leg_lower BODY / from QuatAlignXZ (cumulative), srcAt = the clock each source was used last (the L_BODY_COL shin
-- rotation digit: the last 5 s), sole = the measured box bottom above the player's feet (cm, 99 unknown), fightLog /
-- fightN = ground fights (10 s window / cumulative), fightUntil = clock until which both shins are ghosts after one,
-- bonesAnim / bonesOk = the animator whose bones were checked (leg_lower_* and foot_*), snapLog / ghostLog = the shins'
-- snaps and ghost entries (STUCK, L_BODY_COL; risk 12b).
BC = { LAYER = 128, MASS = 1.5, F = 250, T = 10, VMAX = 10, VCAP = 30, W = 20, AT = 0.55, FIGHT_V = 0.5, FIGHT_D = 0.05,
       FIGHT_OFF = 1, FIGHT_N = 3, FIGHT_WIN = 10, STUCK = 0.15, STUCK_T = 0.5, AXIS_TOL = 15,
       r = { st = 0 }, l = { st = 0 }, off = 0, reason = 0, src = { 0, 0 }, srcAt = { -1e9, -1e9 }, sole = 99,
       fightLog = {}, fightN = 0, fightUntil = -1, bonesAnim = -1, bonesOk = false, snapLog = {}, ghostLog = {} }
-- PM = the player's CollisionMask and the animator filters, section 5: MASK = our colliders' mask (255 - 64 - 128), KEY =
-- the registry backup of the bits we cleared, started = this Lua state's first tick ran (its scene cleanup, tick).
-- applied = the mask is ours now: cleared = the bits we took out, set = the value we set, chkAt = clock of the last
-- re-read, extLog = changes by someone else; m0 = the mask before we changed it (the first tick's, then pmApply's; -1
-- unknown), cur = the mask read last (-1 unknown). filt = shape -> { layer, mask originally, layer, mask set } while the
-- animator filters are ours (nil: not), anim / n = the animator and its shape count they were set for, guard = the
-- leg_lower_r and chest shapes the fast reset guard reads in update(), resetLog = resets seen, bits = the L_PHYS_PROBE
-- probe bits, deadWait = ticks left before the filters are read again after a death / respawn / a new character, bodiesN /
-- kidsN = the shapes of GetPlayerBodies() (the cross-check) / of GetEntityChildren(animator) at the last pmAnimFilters
-- (-1 not measured; both logged, L_PHYS_PROBE), chkFiltAt = clock of the last per-second filter check.
PM = { MASK = 63, KEY = "savegame.mod.tdvr.cmask", started = false, applied = false, cleared = 0, set = nil, chkAt = 0,
       extLog = {}, m0 = -1, cur = -1, filt = nil, anim = 0, n = 0, guard = {}, resetLog = {}, bits = 0, deadWait = 0,
       bodiesN = -1, kidsN = -1, chkFiltAt = 0 }

-- (helpers) a timestamped event; the events of the last `win` seconds (older than 60 s are dropped)
function HC.logAdd(list, v)
    list[#list + 1] = { HC.clock, v }
end
function HC.logCount(list, win)
    while #list > 0 and list[1][1] < HC.clock - 60 do table.remove(list, 1) end
    local n = 0
    for i = 1, #list do
        if list[i][1] > HC.clock - win then n = n + 1 end
    end
    return n
end
-- one L_HCOL_ERR sample (a FREE / BLOCKED tick): the error in mm and whether it was BLOCKED, into the ring buffer (plain
-- numbers, no table per sample; a full buffer drops its oldest)
function HC.errAdd(mm, blocked)
    local cap = HC.ERR_CAP
    if HC.errN >= cap then
        HC.errHead, HC.errN = HC.errHead % cap + 1, HC.errN - 1
    end
    local i = (HC.errHead + HC.errN - 1) % cap + 1
    HC.errT[i], HC.errMm[i], HC.errBl[i] = HC.clock, mm, blocked and 1 or 0
    HC.errN = HC.errN + 1
end
-- the samples older than 5 s leave the ring buffer (from its oldest end)
function HC.errTrim()
    local cap = HC.ERR_CAP
    while HC.errN > 0 and HC.errT[HC.errHead] <= HC.clock - 5 do
        HC.errHead, HC.errN = HC.errHead % cap + 1, HC.errN - 1
    end
    if HC.errN == 0 then HC.errHead = 1 end
end
function PM.bit(b)
    if not hasBit(PM.bits, b) then PM.bits = PM.bits + b end
end
-- mask m without the bits 64 / 128 (Lua 5.1 has no bit operators)
function PM.strip(m)
    return m - (hasBit(m, 64) and 64 or 0) - (hasBit(m, 128) and 128 or 0)
end
-- the permanent fail of hands and shins together (mask, animator filter, self-test)
function HC.offAll(code)
    if HC.fail == 0 then HC.fail = code end
    if BC.off == 0 then BC.off = code end
end
-- nothing of ours exists: no collider, no self-test, the mask and the filters untouched
function HC.idle()
    return not (HC.r.body or HC.l.body or BC.r.body or BC.l.body or HC.ST or PM.applied or PM.filt)
end
-- v0.22 (docs/V022_PLAN.md section 3.5): the base events since last tick - |bodyYaw change| > YAW_EPOCH, a re-centre,
-- the camera method / eye source / attach state changed, a player teleport (HC.tele) - each moves HC.baseEpoch on (a
-- snap turn is counted in updateActive); HC.target treats a changed epoch as a jump (with NHP_STEADY only). The eye
-- source counts only while it feeds the base (review F5: in attach, method 4, the base is attachEye() - a crouch that
-- flips eyeSrc.use moves nothing): -1 there.
function HC.epochCheck()
    local k = HC.ek
    local eu = attachEye() and -1 or eyeSrc.use
    if k and (math.abs(angleDiff(bodyYaw, k.yaw)) > HC.YAW_EPOCH or k.rc ~= nat.recenter or k.m ~= cal.method
        or k.eu ~= eu or k.as ~= att.state) then
        HC.baseEpoch = HC.baseEpoch + 1
    end
    if HC.tele == true then HC.baseEpoch = HC.baseEpoch + 1 end
    HC.ek = { yaw = bodyYaw, rc = nat.recenter, m = cal.method, eu = eu, as = att.state }
end
-- side in FREE / BLOCKED (solid: pushHand skipped, the grab query from the physical palm)
function HC.solid(side)
    local h = HC[side]
    return h ~= nil and (h.st == 1 or h.st == 2) and h.body ~= nil
end
-- variant C (the glove is the collider): the glove body is placed by physics, not by render / the pick safety
function HC.owns(side)
    return HC.var == 3 and HC.solid(side)
end
-- variant C collider alive (any driven state): the pick safety never moves that glove 500 m down
function HC.liveC(side)
    local h = HC[side]
    return HC.var == 3 and h.body ~= nil and h.st >= 1 and h.st <= 4
end
-- the collider's pose in the hand model frame (section 6.2): variant A blocky (0, 0, 0), glove / skin the palm (x
-- mirrored for the left hand); B and C: the grip (their body origin is the hand's)
function HC.loc(side)
    if HC.var ~= 1 then return Vec(0, 0, 0) end
    local p = (hands.skin == 2) and HC.LOCAL.blocky or HC.LOCAL.glove
    return Vec((side == "l") and -p[1] or p[1], p[2], p[3])
end
-- the points "clear" is judged at (collider-local): the blocky 1 x 1 x 3 box also at +0.10 / +0.20 m along +Z, a shin
-- at both ends; plus the points half way between (blocky z 0.05 / 0.15, shin +-0.075), so a stair nose or an edge
-- touching a long face between two of them is not "clear" (each point covers CLEAR_R 0.07 m around it)
function HC.pts(t, side)
    if t == BC then
        return { { 0, 0, 0 }, { 0.15, 0, 0 }, { -0.15, 0, 0 }, { 0.075, 0, 0 }, { -0.075, 0, 0 } }
    end
    if HC.var == 1 and hands.skin == 2 then
        return { { 0, 0, 0 }, { 0, 0, 0.1 }, { 0, 0, 0.2 }, { 0, 0, 0.05 }, { 0, 0, 0.15 } }
    end
    return { { 0, 0, 0 } }
end
-- the lowest world y of the box [lo, hi] (body-local corners) of a body at transform t: from the geometry we know, not
-- from GetShapeBounds (the engine's AABB carries a margin, see handBoundsCheck); also right for a tilted box
function HC.lowest(t, lo, hi)
    local y = math.huge
    for c = 0, 7 do
        local p = TransformToParentPoint(t, Vec((c % 2 == 1) and hi[1] or lo[1], (math.floor(c / 2) % 2 == 1) and hi[2]
            or lo[2], (math.floor(c / 4) == 1) and hi[3] or lo[3]))
        if p[2] < y then y = p[2] end
    end
    return y
end
-- the hands' file and object prefix (as spawnHands)
function HC.file()
    if hands.skin == 2 then return "MOD/hands_blocky.vox", "blk_" end
    return (hands.skin == 1) and "MOD/hands_skin.vox" or "MOD/hands_glove.vox", ""
end
-- Spawn(xml, at, true): the body and its shapes (0, {} on failure)
function HC.spawn(xml, at)
    local ents = engineCall(Spawn, xml, at, true)
    local body, shapes = 0, {}
    if type(ents) == "table" then
        for i = 1, #ents do
            local kind = engineCall(GetEntityType, ents[i])
            if kind == "body" and body == 0 then body = ents[i]
            elseif kind == "shape" then shapes[#shapes + 1] = ents[i] end
        end
    end
    return body, shapes
end
-- a shape's collision filter, set only when it changes (fl = the cache of collider h)
function HC.setF(h, s, l, m)
    h.fl = h.fl or {}
    local k = l * 1000 + m
    if h.fl[s] ~= k then
        engineCall(SetShapeCollisionFilter, s, l, m)
        h.fl[s] = k
    end
end
-- the collider shape of `side` that collides now: A the voxbox, B the one copy of the shown pose (respawned by hcolTick
-- when the shown pose changes), C the glove's shown pose
function HC.shape(side)
    local h = HC[side]
    if HC.var == 1 or HC.var == 2 then return h.shape end
    local pose = hands.shown[side] or "fist"
    return hands.shapes[side] and hands.shapes[side][pose]
end
-- collider filters (section 5 table): live -> (our layer, PM.MASK) on the colliding shape, every other shape 0/0 (B has
-- one visible shape, never tagged invisible: the very tag variant B exists to avoid, section 6.2)
function HC.applyF(t, side, live)
    local h = t[side]
    if t == BC then
        if h.shape then HC.setF(h, h.shape, live and BC.LAYER or 0, live and PM.MASK or 0) end
        return
    end
    local act = HC.shape(side)
    local list = ((HC.var == 1 or HC.var == 2) and { h.shape }) or (HC.var == 3 and hands.shapes[side]) or {}
    for _, s in pairs(list) do
        local on = live and s == act
        HC.setF(h, s, on and HC.LAYER or 0, on and PM.MASK or 0)
    end
end
-- one step of a density calibration (ST4 and every collider): after the body's first physics step m = GetBodyMass; not
-- within 10 % of the target -> density * target / m (mass ASSUMED linear in density), up to 3 tries; rec.m = the mass
function HC.calib(b, rec)
    if rec.done then return end
    rec.n = rec.n + 1
    if rec.n < 2 then return end               -- (update() runs before the physics step: wait for one)
    local m = engineCall(GetBodyMass, b)
    if type(m) ~= "number" or m <= 0 then
        rec.tries = rec.tries + 1
        if rec.tries > 3 then rec.done, rec.m = true, 0 end
        return
    end
    rec.m = m
    if math.abs(m - rec.target) <= rec.target * 0.1 or rec.tries >= 3 then rec.done = true return end
    rec.d = rec.d * rec.target / m
    for i = 1, #rec.shapes do engineCall(SetShapeDensity, rec.shapes[i], rec.d) end
    rec.tries = rec.tries + 1
end
-- the collider's force (hand_strength: 0 normal, 1 weak, 2 strong)
function HC.force(t)
    if t == BC then return BC.F end
    local k = nat.handStrength or 0
    if k == 1 then return HC.F_WEAK elseif k == 2 then return HC.F_STRONG end
    return HC.F
end
-- "clear" (section 6.5): no physical shape (our own bodies, the player and its character excluded, hcolQueryFilter)
-- within CLEAR_R of the points pts of transform t
function HC.clear(t, pts)
    for i = 1, #pts do
        local p = TransformToParentPoint(t, Vec(pts[i][1], pts[i][2], pts[i][3]))
        hcolQueryFilter()
        engineCall(QueryRequire, "physical")
        if engineCall(QueryClosestPoint, p, HC.CLEAR_R) == true then return false end
    end
    return true
end
-- the snap's eye -> target ray is clear (a snap never goes through a thin wall)
function HC.rayClear(to)
    local eye = attachEye() or GetPlayerEyeTransform().pos
    local d = VecSub(to, eye)
    local l = VecLength(d)
    if l < 1e-3 then return true end
    hcolQueryFilter()
    engineCall(QueryRequire, "physical")
    return engineCall(QueryRaycast, eye, VecScale(d, 1 / l), l, 0) ~= true
end
-- enter GHOST (counted: the hands' in L_HCOL_EV, the shins' in L_BODY_COL)
function HC.ghostIn(t, h)
    if h.st ~= 4 then HC.logAdd((t == BC) and BC.ghostLog or HC.ghostLog) end
    h.st = 4
end
-- snap: filter 0/0, at the target, the player's velocity, GHOST (count: an event of section 6.5, not a re-activation;
-- the hands' in L_HCOL_EV, the shins' in L_BODY_COL - a re-activation from PARKED / OFF is no ghost entry either, so
-- the ghost counts show real STUCK / grace / pick ghosts, review R21-GHOST-COUNT-NOISE)
function HC.snap(t, side, tgt, count)
    local h = t[side]
    HC.applyF(t, side, false)
    engineCall(SetBodyTransform, h.body, tgt)
    engineCall(SetBodyVelocity, h.body, GetPlayerVelocity())
    engineCall(SetBodyAngularVelocity, h.body, Vec(0, 0, 0))
    h.snapT, h.stuckT = 0, 0
    h.snapAt = HC.clock                   -- (v0.22: no punch from a side that snapped this tick)
    if count then
        HC.logAdd((t == BC) and BC.snapLog or HC.snapLog)
        HC.ghostIn(t, h)
    else
        h.st = 4
    end
end
-- PARKED (section 6.5): filter 0/0, held at its park point (C: the glove is the updateHands / render path's). Variant B's
-- core is a VISIBLE pose copy: deleted instead (respawned at the target when the side is back; review
-- R21-VARB-PARKED-VISIBLE, plan 16.1 R-9), so no frozen block hand stays where the hand last was.
function HC.park(t, side)
    local h = t[side]
    h.vis = nil
    if t == HC and HC.var == 2 and h.body then
        local gu = h.ghostUntil
        HC.drop(HC, side)
        HC[side].st, HC[side].ghostUntil = 5, gu
        return
    end
    if not h.body then h.st = 5 return end      -- (none in the world - e.g. deleted with the gloves -: parked as well)
    if validBody(h.body) then
        HC.applyF(t, side, false)
        if not (t == HC and HC.var == 3) then
            h.park = h.park or GetBodyTransform(h.body)
            parkOwnBody(h.body, h.park)
        end
    end
    h.st, h.wasHeld, h.prevTgt, h.prevRel, h.prevLoc, h.drvRel = 5, false, nil, nil, nil, nil
end
-- OFF: 0/0 and deleted (C: the glove stays, only its filters 0/0)
function HC.drop(t, side)
    local h = t[side]
    if h.body then
        if validBody(h.body) then
            HC.applyF(t, side, false)
            if not (t == HC and HC.var == 3) then engineCall(Delete, h.body) end
        end
    end
    t[side] = { st = 0 }
end
-- the hand collider's target from the world base: ctrlHandT * LOCAL plus the lead rvel * LEAD (at most LEAD_MAX);
-- returns it and whether it jumped: the BASE (the play space) moved it more than JUMP relative to the player since last
-- tick (a snap turn, a re-centre), or the player itself teleported (HC.tele: respawn, vehicle exit) - never by walking or
-- falling (world positions would be), nor by the hand's own motion in the play space (a punch at 30 fps covers more than
-- JUMP in one tick; review R21-PUNCH-JUMP, plan 16.1 R-7): the base's part is the move of last tick's play-space point
-- (prevLoc) from last tick's place relative to the player (prevRel - the hand's own move taken out). drvRel = the target
-- update() drove toward until now (tgtRel before this tick's; HC.rules judges FREE / BLOCKED against it, R-8).
-- v0.22 (docs/V022_PLAN.md section 3.5, NHP_STEADY): base = the LIVE base (phys.liveBase, 3.2); jumped = a teleport, a
-- base event since last tick (h.epoch ~= HC.baseEpoch: a snap turn, a re-centre, a camera method / eye source / attach
-- change) or a base-part move beyond JUMP_BIG + the player's speed * the physics steps / 60 - never the held right-eye
-- base or a raw-eye wobble (the v0.21 log's 40-150 snaps per 5 s while walking). h.jumpWhy = 1 event, 2 geometric, 5
-- teleport (L_HSNAP); h.rvelPrev = last tick's rvel (the punch's approach speed).
function HC.target(side, base, dt)
    local h = HC[side]
    local t = TransformToParentTransform(ctrlHandT(side, base), Transform(HC.loc(side)))
    local pp = GetPlayerTransform().pos
    local rel = VecSub(t.pos, pp)
    local loc = TransformToLocalPoint(base, t.pos)
    local jumped = HC.tele == true
    local steady = nat.handSteady == true
    h.jumpWhy = jumped and 5 or nil
    if steady and not jumped and h.epoch ~= nil and h.epoch ~= HC.baseEpoch then jumped, h.jumpWhy = true, 1 end
    if h.prevRel ~= nil and h.prevLoc ~= nil and not jumped then
        local own = VecSub(t.pos, TransformToParentPoint(base, h.prevLoc))
        local geo = VecLength(VecSub(VecSub(rel, h.prevRel), own))
        if steady then
            jumped = geo > HC.JUMP_BIG + VecLength(GetPlayerVelocity()) * (HC.steps or 1) / 60
        else
            jumped = geo > HC.JUMP
        end
        if jumped then h.jumpWhy = 2 end
    end
    h.epoch = HC.baseEpoch
    h.rvelPrev = h.rvel
    if h.prevRel and dt and dt > 0 and not jumped then h.rvel = VecScale(VecSub(rel, h.prevRel), 1 / dt) else h.rvel = nil end
    h.drvRel = h.tgtRel
    h.prevRel, h.prevTgt, h.prevLoc = rel, t.pos, loc
    local tgt = t
    if h.rvel then
        local lead = VecScale(h.rvel, HC.LEAD)
        local l = VecLength(lead)
        if l > HC.LEAD_MAX then lead = VecScale(lead, HC.LEAD_MAX / l) end
        tgt = Transform(VecAdd(t.pos, lead), t.rot)
    end
    h.lead = VecSub(tgt.pos, t.pos)
    h.tgtRel, h.tgtRot = VecSub(tgt.pos, pp), tgt.rot
    return tgt, jumped
end
-- the 6.5 rules of one collider (hands and shins): back from PARKED / OFF at the target as a ghost; snaps; stuck; HELD;
-- GHOST (ghost = a reason to stay one this tick) until clear; FREE / BLOCKED by the held-back error (R-8). Returns that
-- error (m).
function HC.rules(t, side, tgt, jumped, now, dt, ghost, held)
    local h = t[side]
    local isB = t == BC
    local pts = HC.pts(t, side)
    local snapped = false
    if h.st == 0 or h.st == 5 or h.st == 6 then HC.snap(t, side, tgt, false) snapped = true end
    local c = GetBodyTransform(h.body)
    local e = VecLength(VecSub(c.pos, tgt.pos))
    -- (a player teleport or an update gap snaps at once; a base jump (snap turn) or SNAP_NOW only through a clear eye ->
    -- target ray: a snap never goes through a thin wall, plan 14 / 16.1 R-7 - else the drive and the SNAP / STUCK rules)
    if HC.tele == true or HC.gapEdge or ((e > HC.SNAP_NOW or jumped) and HC.rayClear(tgt.pos)) then
        HC.snap(t, side, tgt, true)
        -- (v0.22 L_HSNAP: the snap's kind - 5 teleport, 1 event (a base event or an update gap), 2 geometric, 3 SNAP_NOW)
        if not isB then
            HC.logAdd(HC.snapK[(HC.tele == true and 5) or (HC.gapEdge and 1) or (jumped and (h.jumpWhy or 1)) or 3])
        end
        c, e, snapped = tgt, 0, true
    elseif e > HC.SNAP then
        h.snapT = (h.snapT or 0) + dt
        if h.snapT >= HC.SNAP_T and HC.rayClear(tgt.pos) then
            HC.snap(t, side, tgt, true)
            if not isB then HC.logAdd(HC.snapK[4]) end
            c, e, snapped = tgt, 0, true
        end
    else
        h.snapT = 0
    end
    -- (review R21-BLOCKED-FREE-AIR, plan 16.1 R-8: held back = the error against the target the physics last drove
    -- toward - the player's position update() last read plus the tgtRel it used -, not against this tick's target, which
    -- is one frame of the hand's own motion further: a free swing at 30 fps is not BLOCKED. The snaps above keep e.)
    local eh = e
    if not snapped and h.drvRel and HC.ppDrv then eh = VecLength(VecSub(c.pos, VecAdd(HC.ppDrv, h.drvRel))) end
    local sl, sT = isB and BC.STUCK or HC.STUCK, isB and BC.STUCK_T or HC.STUCK_T
    if (h.st == 1 or h.st == 2) and eh > sl then
        h.stuckT = (h.stuckT or 0) + dt
        if h.stuckT >= sT and (isB or not HC.clear(tgt, pts)) then
            h.stuckT = 0
            HC.ghostIn(t, h)              -- (a ghost leaves only where it is clear: it goes through to the hand)
        end
    else
        h.stuckT = 0
    end
    local st
    if held then
        st, h.wasHeld = 3, true
    else
        if h.wasHeld then h.wasHeld, h.ghostUntil = false, math.max(h.ghostUntil or -1, now + HC.GRACE) end
        if ghost or now < (h.ghostUntil or -1) then st = 4
        -- (a ghost (filter 0/0) leaves only once it has caught up with its target - within E1 for a hand, within its
        -- STUCK distance for a shin, whose target moves fast with the stride - and is clear there; else a collider just
        -- ghosted by STUCK would be BLOCKED again at once wherever a sparse "clear" sample missed the edge holding it)
        elseif (h.st == 4 or h.st == 3) and (eh > (isB and BC.STUCK or HC.E1) or not HC.clear(c, pts)) then st = 4
        else st = (eh > HC.E1) and 2 or 1 end
    end
    if st == 4 then HC.ghostIn(t, h) end
    if st == 2 and h.st ~= 2 and not isB and now - (h.hapticAt or -1000) >= HC.HAPTIC_GAP then
        pulse((side == "l") and 1 or 2, HC.HAPTIC, 0.03)
        h.hapticAt = now
    end
    h.st = st
    HC.applyF(t, side, st == 1 or st == 2)
    return eh
end
-- mask + animator filters on (the way IN, section 5): true when both are ours and read back as set this tick
function HC.pmOn(anim)
    if not pmApply() then HC.offAll(2) return false end
    if PM.applied and HC.clock - PM.chkAt >= 1 then        -- (re-read once per second: changed by someone else?)
        PM.chkAt = HC.clock
        local cur = engineCall(GetPlayerParam, "CollisionMask")
        if type(cur) == "number" and cur ~= PM.set then
            HC.logAdd(PM.extLog)
            if HC.logCount(PM.extLog, 60) >= 3 then HC.offAll(2) return false end
            local cl = (hasBit(cur, 64) and 64 or 0) + (hasBit(cur, 128) and 128 or 0)
            if cl > 0 then
                if hasBit(cl, 64) and not hasBit(PM.cleared, 64) then PM.cleared = PM.cleared + 64 end
                if hasBit(cl, 128) and not hasBit(PM.cleared, 128) then PM.cleared = PM.cleared + 128 end
                engineCall(SetPlayerParam, "CollisionMask", cur - cl)
                engineCall(SetInt, PM.KEY, PM.cleared)
            end
            PM.set = cur - cl
        end
    end
    if PM.deadWait > 0 then return false end
    if PM.filt then
        -- a new character (respawn, character change): its filters are read again after 30 ticks
        local kids = (anim ~= 0) and engineCall(GetEntityChildren, anim, "", true, "shape") or {}
        if anim ~= PM.anim or type(kids) ~= "table" or #kids ~= PM.n then
            pmAnimFilters(false)
            PM.deadWait = 30
            return false
        end
        if HC.clock - PM.chkFiltAt >= 1 then
            PM.chkFiltAt = HC.clock
            if not PM.recheck() then return false end
        end
        return true
    end
    local ok = pmAnimFilters(true)
    if ok == false then HC.offAll(3) return false end
    if ok == nil then return PM.recheck() end            -- (a readback not as set: a reset, re-applied)
    PM.chkFiltAt = HC.clock
    return true
end
-- every animator filter as we set it? A reset is re-applied at once and counted (bit 16); 3 resets in 60 s -> collisions
-- off (reason 3). true = all as set now.
function PM.recheck()
    if not PM.filt then return false end
    local bad = false
    for s, f in pairs(PM.filt) do
        if validBody(s) then
            local l, m = engineCall(GetShapeCollisionFilter, s)
            if l ~= f[3] or m ~= f[4] then
                bad = true
                engineCall(SetShapeCollisionFilter, s, f[3], f[4])
            end
        end
    end
    if not bad then return true end
    PM.bit(16)
    HC.logAdd(PM.resetLog)
    if HC.logCount(PM.resetLog, 60) >= 3 then HC.offAll(3) return false end
    for s, f in pairs(PM.filt) do
        if validBody(s) then
            local l, m = engineCall(GetShapeCollisionFilter, s)
            if l ~= f[3] or m ~= f[4] then return false end
        end
    end
    return true
end
-- the fast reset guard (update(), before driving): leg_lower_r's and chest's filter as we set them? A difference -> every
-- collider a ghost for this step, the filters re-applied at once (a reset). true = a reset seen.
function PM.fast()
    if not PM.filt then return false end
    for i = 1, #PM.guard do
        local s = PM.guard[i]
        local f = PM.filt[s]
        if f and validBody(s) then
            local l, m = engineCall(GetShapeCollisionFilter, s)
            if l ~= f[3] or m ~= f[4] then
                PM.recheck()
                return true
            end
        end
    end
    return false
end

-- Section 5: the player's CollisionMask without our bits 64 / 128 (m0 must be a number 0..255; the value read back must
-- be the one set, else fail 2 and restored). Backup of the cleared bits in PM.KEY (a precaution: "persistent" is not
-- "survives a quickload"). true = applied (also when it already had neither bit: nothing to set).
function pmApply()
    if PM.applied then return true end
    local m0 = engineCall(GetPlayerParam, "CollisionMask")
    if type(m0) ~= "number" or m0 < 0 or m0 > 255 or m0 ~= math.floor(m0) then return false end
    PM.m0 = m0
    local want = PM.strip(m0)
    local cl = m0 - want
    if cl > 0 then engineCall(SetPlayerParam, "CollisionMask", want) end
    PM.applied, PM.cleared, PM.set, PM.chkAt = true, cl, want, HC.clock
    if engineCall(GetPlayerParam, "CollisionMask") ~= want then
        pmRestore("readback")
        return false
    end
    if cl > 0 then engineCall(SetInt, PM.KEY, cl) end
    PM.cur = want
    return true
end

-- Section 5: gives the player's CollisionMask back the bits we cleared (OR, so another mod's own cleared bits stay
-- cleared) and clears PM.KEY. why "start" (once per Lua state, its first tick, before any spawn): the bits a crashed or
-- quickloaded state left in PM.KEY; without the key nothing is touched. Otherwise only while the mask is ours (PM.applied).
function pmRestore(why)
    local cur = engineCall(GetPlayerParam, "CollisionMask")
    if type(cur) == "number" then PM.cur = cur end
    if why == "start" and PM.m0 < 0 and type(cur) == "number" then PM.m0 = cur end
    local bits, key = 0, false
    if why == "start" then
        key = engineCall(HasKey, PM.KEY) == true
        if key then bits = engineCall(GetInt, PM.KEY) or 0 end
    elseif PM.applied then
        bits, key = PM.cleared, PM.cleared > 0
    else
        return
    end
    PM.applied, PM.cleared, PM.set = false, 0, nil
    if type(cur) == "number" and cur >= 0 and cur <= 255 and type(bits) == "number" then
        local m = cur
        if hasBit(bits, 64) and not hasBit(m, 64) then m = m + 64 end
        if hasBit(bits, 128) and not hasBit(m, 128) then m = m + 128 end
        if m ~= cur then
            engineCall(SetPlayerParam, "CollisionMask", m)
            PM.cur = m
        end
    end
    if key then engineCall(ClearKey, PM.KEY) end
end

-- Section 5: the player-animator shapes (GetEntityChildren(GetPlayerAnimator(), "", true, "shape"); GetPlayerBodies() only
-- a cross-check, PM.bodiesN) keep their layer and get their mask without 64 / 128; only a shape whose body is not 0, not
-- the world body and whose GetBodyAnimator is the player's (proxy shapes included: they may be the ones that collide).
-- More than 64 shapes, or no GetShapeCollisionFilter: nothing touched, false (reason 3). Probe bits 4 (an original was
-- (1, 255)) and 8 (every readback as set). Returns true, or nil when a readback differs (the caller counts a reset).
-- on false: the saved originals written back exactly (only shapes still valid) and forgotten.
function pmAnimFilters(on)
    if not on then
        if PM.filt then
            for s, f in pairs(PM.filt) do
                if validBody(s) then engineCall(SetShapeCollisionFilter, s, f[1], f[2]) end
            end
        end
        PM.filt, PM.guard = nil, {}
        return true
    end
    if PM.filt then return true end
    if type(GetShapeCollisionFilter) ~= "function" then return false end
    local anim = engineCall(GetPlayerAnimator)
    if type(anim) ~= "number" then anim = 0 end
    local list = (anim ~= 0) and engineCall(GetEntityChildren, anim, "", true, "shape") or {}
    if type(list) ~= "table" then list = {} end
    local wb = engineCall(GetWorldBody)
    local pb, nb = engineCall(GetPlayerBodies), 0
    if type(pb) == "table" then
        for i = 1, #pb do
            local sh = (pb[i] ~= wb) and engineCall(GetBodyShapes, pb[i]) or nil
            if type(sh) == "table" then nb = nb + #sh end
        end
    end
    PM.bodiesN, PM.kidsN = nb, #list                 -- (both logged, L_PHYS_PROBE; also when the list is too long)
    if #list > 64 then return false end
    PM.filt, PM.guard, PM.anim, PM.n = {}, {}, anim, #list
    local all = true
    for i = 1, #list do
        local s = list[i]
        local b = engineCall(GetShapeBody, s)
        if type(b) == "number" and b ~= 0 and b ~= wb and engineCall(GetBodyAnimator, b) == anim then
            local l, m = engineCall(GetShapeCollisionFilter, s)
            if type(l) == "number" and type(m) == "number" then
                if l == 1 and m == 255 then PM.bit(4) end
                local nm = PM.strip(m)
                engineCall(SetShapeCollisionFilter, s, l, nm)
                local rl, rm = engineCall(GetShapeCollisionFilter, s)
                if rl ~= l or rm ~= nm then all = false end
                PM.filt[s] = { l, m, l, nm }
            end
        end
    end
    for _, bone in ipairs({ "leg_lower_r", "chest" }) do
        local b = (anim ~= 0) and engineCall(GetBoneBody, anim, bone) or 0
        local sh = (type(b) == "number" and b ~= 0) and engineCall(GetBodyShapes, b) or nil
        if type(sh) == "table" and sh[1] and PM.filt[sh[1]] then PM.guard[#PM.guard + 1] = sh[1] end
    end
    if all then PM.bit(8) return true end
    return nil
end

-- Section 6.4: the filters of every new query of this spec: our own bodies (gloves, replica, held bodies, every collider,
-- rejectOwnBodies), the player and its character, and the collision mask HC.QMASK (as player_locomotion.lua does), so
-- our own legs and torso are never an obstacle. Only the self-test's ST5 / ST6 query without it, on purpose.
function hcolQueryFilter()
    rejectOwnBodies(true, true)
    engineCall(QueryRejectPlayer)
    local a = engineCall(GetPlayerAnimator)
    if type(a) == "number" and a ~= 0 then engineCall(QueryRejectAnimator, a) end
    engineCall(QueryCollisionMask, HC.QMASK)
end

-- Section 6.7: one of the colliders (hands, shins; variant C: the glove) or a self-test body.
function isColliderBody(b)
    if type(b) ~= "number" or b == 0 then return false end
    if b == HC.r.body or b == HC.l.body or b == BC.r.body or b == BC.l.body then return true end
    return HC.ST ~= nil and HC.ST.live[b] == true
end

-- Section 6.7: deletes every collider / shin / self-test body in the scene (FindBodies tdvr_hcol / tdvr_bcol / tdvr_probe,
-- and the body of any shape tagged tdvr_probe - never the world body) and forgets ours; a running self-test is then
-- inconclusive. With deleteGloves and once per Lua state on its first tick (tick), never in init(). A second call in the
-- same tick with nothing of ours spawned since (the first tick's cleanup, then the gloves' own) searches nothing.
function deleteColliders()
    if HC.delTick == heartbeat and HC.idle() then return end
    HC.delTick = heartbeat
    for _, tag in ipairs({ "tdvr_hcol", "tdvr_bcol", "tdvr_probe" }) do
        local list = engineCall(FindBodies, tag, true)
        if type(list) == "table" then
            for i = 1, #list do engineCall(Delete, list[i]) end
        end
    end
    local shapes = engineCall(FindShapes, "tdvr_probe", true)
    if type(shapes) == "table" and #shapes > 0 then
        local wb = engineCall(GetWorldBody)
        for i = 1, #shapes do
            local b = engineCall(GetShapeBody, shapes[i])
            if type(b) == "number" and b ~= 0 and b ~= wb then engineCall(Delete, b) end
        end
    end
    for _, t in ipairs({ HC, BC }) do
        for _, side in ipairs({ "r", "l" }) do
            local st = t[side].st
            t[side] = { st = (st == 6) and 6 or 0 }
        end
    end
    if HC.ST then HC.ST.aborted = true end
end

-- Section 6.2: the solid hand collider of `side` at transform at: variant A an invisible voxbox (1 x 1 x 3 blocky = hand
-- + forearm, 1 x 1 x 1 glove / skin) centred on the body origin, B ONE visible copy of the shown pose (h.pose; hands.shown,
-- else the fist) at 0.8 x the hands' scale re-centred on the grip - no "invisible" anywhere, the very tag B avoids; a
-- pose change respawns it (hcolTick) -, C the glove itself (hands.body). Filter 0/0, gravity 0, density 1 then
-- calibrated to HC.MASS (HC.calib in update()); a GHOST until clear. false = the spawn failed (fail 7).
function hcolSpawn(side, at)
    local h = HC[side]
    if HC.var == 3 then
        local gb = hands.body[side]
        if not validBody(gb) then return false end
        HC[side] = { st = 5, body = gb, fl = {} }
        engineCall(SetBodyGravityScale, gb, 0)
        local m = engineCall(GetBodyMass, gb)
        HC[side].ms = (type(m) == "number" and m > 0) and m / HC.MASS or 1
        HC.applyF(HC, side, false)
        return true
    end
    local xml
    local pose = hands.shown[side] or "fist"
    if HC.var == 1 then
        xml = '<body tags="tdvr_hcol=' .. side .. ' nomerge" dynamic="true"><voxbox size="1 1 '
            .. ((hands.skin == 2) and "3" or "1") .. '" density="1" tags="tdvr_hcolshape unbreakable nocull nonav '
            .. 'invisible noquery"/></body>'
    else
        local file, pre = HC.file()
        xml = '<body tags="tdvr_hcol=' .. side .. ' nomerge" dynamic="true"><vox tags="tdvr_hcolshape tdvr_pose=' .. pose
            .. ' unbreakable nocull nonav noquery" file="' .. file .. '" object="' .. pre .. pose .. "_" .. side
            .. '" scale="' .. tostring(0.8 * hands.voxel) .. '"/></body>'
    end
    local b, shapes = HC.spawn(xml, at)
    if b == 0 or #shapes == 0 then
        if b ~= 0 then engineCall(Delete, b) end
        return false
    end
    h = { st = 5, body = b, fl = {}, shapes = {}, park = at }
    HC[side] = h
    for i = 1, #shapes do
        local s = shapes[i]
        if HC.var == 1 then
            h.shape = s
            engineCall(SetShapeLocalTransform, s, Transform(Vec(-0.05, -0.05, -0.05)))
        else
            local part = handPart(pose, side)
            if part and not h.shape then
                h.shape, h.pose, h.shapes[pose] = s, pose, s
                engineCall(SetShapeLocalTransform, s, Transform(Vec(-0.8 * part[4], -0.8 * part[5], -0.8 * part[6])))
            end
        end
        engineCall(SetShapeDensity, s, 1)
    end
    if HC.var == 2 and not h.shape then
        engineCall(Delete, b)
        HC[side] = { st = 0 }
        return false
    end
    engineCall(SetBodyGravityScale, b, 0)
    h.cal = { shapes = shapes, d = 1, tries = 0, n = 0, target = HC.MASS }
    HC.applyF(HC, side, false)
    return true
end

-- Section 7: the shin collider of `side` (variant A only): an invisible 3 x 1 x 1 voxbox (0.30 x 0.10 x 0.10 m, long along
-- local +X) centred on the body origin; filter 0/0, gravity 0, density 1 then calibrated to BC.MASS. false = failed.
function shinSpawn(side, at)
    local b, shapes = HC.spawn('<body tags="tdvr_bcol=' .. side .. ' nomerge" dynamic="true"><voxbox size="3 1 1" '
        .. 'density="1" tags="tdvr_bcolshape unbreakable nocull nonav invisible noquery"/></body>', at)
    if b == 0 or #shapes == 0 then
        if b ~= 0 then engineCall(Delete, b) end
        return false
    end
    local h = { st = 5, body = b, shape = shapes[1], fl = {}, park = at }
    BC[side] = h
    engineCall(SetShapeLocalTransform, h.shape, Transform(Vec(-0.15, -0.05, -0.05)))
    engineCall(SetShapeDensity, h.shape, 1)
    engineCall(SetBodyGravityScale, b, 0)
    h.cal = { shapes = { h.shape }, d = 1, tries = 0, n = 0, target = BC.MASS }
    HC.applyF(BC, side, false)
    return true
end

-- Section 7: the shin target of `side`: centre = ankle + AT * (knee - ankle) (GetBoneWorldTransform of leg_lower / foot),
-- rotation = the leg_lower BODY's when its +X is within AXIS_TOL of the knee -> ankle line, else QuatAlignXZ(that line,
-- the player forward made orthogonal to it, its sign on the side of the body's own +Z) (BC.src counts which). nil when
-- the bones cannot be read.
function BC.target(anim, side)
    local kt = engineCall(GetBoneWorldTransform, anim, "leg_lower_" .. side)
    local at = engineCall(GetBoneWorldTransform, anim, "foot_" .. side)
    local lb = engineCall(GetBoneBody, anim, "leg_lower_" .. side)
    if type(kt) ~= "table" or type(at) ~= "table" or type(kt.pos) ~= "table" or type(at.pos) ~= "table"
        or type(lb) ~= "number" or lb == 0 then
        return nil
    end
    local d = VecSub(at.pos, kt.pos)
    if VecLength(d) < 0.05 then return nil end
    local x = VecNormalize(d)
    local centre = VecAdd(at.pos, VecScale(VecSub(kt.pos, at.pos), BC.AT))
    local rot = GetBodyTransform(lb).rot
    local bx = QuatRotateVec(rot, Vec(1, 0, 0))
    if math.deg(math.acos(clamp(VecDot(bx, x), -1, 1))) > BC.AXIS_TOL then
        local f = QuatRotateVec(GetPlayerTransform().rot, Vec(0, 0, -1))
        local z = VecSub(f, VecScale(x, VecDot(f, x)))
        if VecLength(z) < 1e-3 then z = VecSub(Vec(0, 1, 0), VecScale(x, x[2])) end
        -- (the box is symmetric: z on the side of the body's own +Z, so a source switch never turns it half round)
        if VecDot(z, QuatRotateVec(rot, Vec(0, 0, 1))) < 0 then z = VecScale(z, -1) end
        local q = engineCall(QuatAlignXZ, x, VecNormalize(z))
        if type(q) ~= "table" or type(q[4]) ~= "number" then return nil end
        rot = q
        BC.src[2], BC.srcAt[2] = BC.src[2] + 1, HC.clock
    else
        BC.src[1], BC.srcAt[1] = BC.src[1] + 1, HC.clock
    end
    return Transform(centre, rot)
end

-- Section 7, every tick from hcolTick: the shins (on = wanted and allowed: self-test variant A, not query-visible; sit =
-- the situation allows them: on foot, active, no rig / water / fly mode, the bones there, the mask and filters ours):
-- spawned when missing, the target relative to the player, the 6.5 rules with BC.STUCK / STUCK_T; otherwise PARKED / OFF.
-- BC.sole = the lower box's bottom above the player's feet (cm, 99 unknown).
function shinTick(dt, now, on, sit, ghost, anim)
    local sole = 99
    for i = 1, 2 do
        local side = (i == 1) and "r" or "l"
        local h = BC[side]
        if HC.ST then
            h.st = nat.bodyCollide and 6 or 0
        elseif not on then
            -- (deleted, as an off should be; the state digit is OFF only when the option is off, PARKED for every other
            -- cause - multiplayer, a self-test / mask / filter fail, ground fights -, section 7)
            HC.drop(BC, side)
            if nat.valid and nat.bodyCollide == true then BC[side].st = 5 end
        elseif not sit then
            HC.park(BC, side)
        else
            local tgt = BC.target(anim, side)
            if not tgt then
                HC.park(BC, side)
            else
                if not validBody(h.body) then
                    if not shinSpawn(side, tgt) then
                        if BC.off == 0 then BC.off = 4 end
                        HC.drop(BC, side)
                        return
                    end
                    h = BC[side]
                end
                local pp = GetPlayerTransform().pos
                local rel = VecSub(tgt.pos, pp)
                -- (the JUMP rule relative to the player, as the hands' (HC.target), plus the player's own teleport;
                -- a swinging shin moves fast even relative to the player, so it gets BC.VMAX * dt on top)
                local jumped = h.prevRel ~= nil and (VecLength(VecSub(rel, h.prevRel)) > HC.JUMP + BC.VMAX * dt
                    or HC.tele == true)
                if h.prevRel and dt > 0 and not jumped then h.rvel = VecScale(VecSub(rel, h.prevRel), 1 / dt)
                else h.rvel = nil end
                h.drvRel = h.tgtRel             -- (the target update() drove toward: the held-back error, R-8)
                h.prevRel, h.prevTgt, h.tgtRel, h.tgtRot = rel, tgt.pos, rel, tgt.rot
                HC.rules(BC, side, tgt, jumped, now, dt, ghost or now < BC.fightUntil, false)
                -- (the box's lowest corner from its known geometry, not the engine AABB, which carries a margin)
                if validBody(h.body) then
                    local low = HC.lowest(GetBodyTransform(h.body), Vec(-0.15, -0.05, -0.05), Vec(0.15, 0.05, 0.05))
                    sole = math.min(sole, clamp(math.floor((low - pp[2]) * 100 + 0.5), 0, 98))
                end
            end
        end
    end
    BC.sole = sole
end

-- Sections 6.4-6.5 and 7, every tick right before updateHandPhysics: the self-test (start, its tick-side steps, an
-- interruption = inconclusive), the mask and the animator filters (the way IN before any collider gets 64 / 128; the
-- way OUT after every collider is 0/0), each hand collider's target (relative to the player, from phys.base) and state,
-- the safety rules (pick fights, player shove, ground fights, the tool hand on trigger when query-visible) and the shins.
-- Nothing at all while nothing is wanted and nothing of ours exists (HC.idle): the v0.20 path.
function hcolTick(dt, flags)
    dt = dt or 0
    local now = HC.clock + dt
    HC.clock = now
    local wantH = nat.valid and nat.handCollide == true
    local wantB = nat.valid and nat.bodyCollide == true
    -- (section 8, "every off restores v0.20": the variant-C gloves - pose shapes spawned without collide="false" - are
    -- respawned as v0.20 gloves once hand collision is off for good: a permanent fail, multiplayer, the option off. The
    -- temporary PARKED causes - vehicle, death, inactive, a glove not dynamic - keep them.)
    if hands.varC and hands.spawned and not hands.failed
        and (HC.fail ~= 0 or BV.mp == true or not wantH or HC.var ~= 3) then
        HC.drop(HC, "r")
        HC.drop(HC, "l")
        spawnHands({ varC = false })
    end
    if not (wantH or wantB) and HC.idle() then
        HC.r.st, HC.l.st, BC.r.st, BC.l.st = 0, 0, 0, 0
        HC.ppPrev, HC.tele = nil, false
        return
    end
    local gapNow = now - HC.updAt > HC.GAP
    HC.gapEdge, HC.gapPrev = gapNow and not HC.gapPrev, gapNow
    -- (section 6.5 JUMP: the player itself teleported - respawn, vehicle exit, a quickload - when it moved more than JUMP
    -- beyond what its velocity explains; walking 7 m/s at 30 fps or a fall is not a jump. The gap edge snaps anyway. The
    -- time the player moved is the PHYSICS time since last tick - the update() steps, 1/60 s each -, not the tick dt:
    -- below 30 fps the engine runs at most 2 steps per frame, slower than real time (review R21-TELE-LOWFPS, R-10);
    -- no step since last tick: no test)
    local pp0 = GetPlayerTransform().pos
    local steps = perf.updates
    HC.steps = steps
    HC.tele = HC.ppPrev ~= nil and steps > 0 and not HC.gapEdge
        and VecLength(VecSub(VecSub(pp0, HC.ppPrev), VecScale(GetPlayerVelocity(), steps / 60))) > HC.JUMP
    -- (kept over a frame without a step: a move in it counts at the next tick that has one)
    if steps > 0 or HC.ppPrev == nil then HC.ppPrev = pp0 end
    HC.epochCheck()                       -- (v0.22 section 3.5: the base events of this tick)
    -- (v0.22 L_HSNAP: where update() runs relative to the physics step - the player's move since the last update() in
    -- physics steps: ~1 when update() runs before the step, ~0 after it; walking ticks only)
    local pvl = VecLength(GetPlayerVelocity())
    if HC.ppDrv and pvl > 1 then push(HC.order, VecLength(VecSub(pp0, HC.ppDrv)) / (pvl / 60), 30) end
    local mp = BV.mp == true
    local veh, dead = hasBit(flags, LF_VEHICLE), hasBit(flags, LF_DEAD)
    local pt = GetPlayerTransform()
    local anim = engineCall(GetPlayerAnimator)
    if type(anim) ~= "number" then anim = 0 end
    local rig = engineCall(GetPlayerRig)
    if type(rig) ~= "number" then rig = 0 end
    local water = engineCall(IsPointInWater, VecAdd(pt.pos, Vec(0, BV.WATER_UP, 0))) == true
    local fly = engineCall(GetPlayerParam, "flyMode") == true
    -- (section 5: on death the filters are restored at once, read again 30 ticks after it ends)
    if dead then PM.deadWait = 30 elseif PM.deadWait > 0 then PM.deadWait = PM.deadWait - 1 end
    -- the self-test (section 6.3): started at a body-mode-1 situation, interrupted = inconclusive (retried, never a fail)
    local wantTest = ((wantH and HC.fail == 0) or (wantB and BC.off == 0)) and not mp
    if HC.ST then
        local run = wantTest and active and not veh and not dead and rig == 0 and not gapNow and not HC.ST.aborted
        if run then HC.stTick() else HC.stEnd(6) end
    elseif wantTest and (HC.sel == 0 or (HC.sel == 6 and HC.incl < 5)) and active and cal.used == 4 and not veh
        and not dead and rig == 0 and not water and not fly and PM.deadWait == 0 then
        HC.stBegin(pt)
    end
    -- what is on (permanent fails, multiplayer, the self-test result)
    local handsOn = wantH and HC.fail == 0 and not mp and HC.sel == 1 and HC.var > 0
    if HC.sel == 1 and wantB and BC.off == 0 and (HC.var ~= 1 or hasBit(PM.bits, 256)) then BC.off = 4 end
    local shinsOn = wantB and BC.off == 0 and not mp and HC.sel == 1
    if handsOn and HC.var == 3 and not hands.varC and hands.spawned and not hands.failed then
        spawnHands({ varC = true })            -- (variant C: the blocky pose shapes without collide="false")
    end
    -- the situation
    local base = active and not veh and not dead and not mp and phys.base ~= nil and phys.baseTick == heartbeat
    local gloves = (nat.handStyle or 0) == 2 and hands.spawned and not hands.failed and not hasBit(nat.perf, PF.NO_HANDS)
        and ctl ~= nil
    local sitH = base and gloves
    if BC.bonesAnim ~= anim then
        BC.bonesAnim, BC.bonesOk = anim, false
        local names = (anim ~= 0) and engineCall(GetBoneNames, anim) or nil
        if type(names) == "table" then
            local have = {}
            for i = 1, #names do have[names[i]] = true end
            BC.bonesOk = have.leg_lower_l and have.leg_lower_r and have.foot_l and have.foot_r or false
        end
    end
    local sitB = base and rig == 0 and not water and not fly and anim ~= 0 and BC.bonesOk
    local tracked = { r = ctl ~= nil and hasBit(ctl.hv, 4), l = ctl ~= nil and hasBit(ctl.hv, 1) }
    local need = HC.ST ~= nil or (handsOn and sitH and (tracked.r or tracked.l)) or (shinsOn and sitB)
    local pmOk = need and PM.deadWait == 0 and HC.pmOn(anim)
    handsOn = handsOn and HC.fail == 0
    shinsOn = shinsOn and BC.off == 0
    -- safety rules (hands): player shove, pick fights, ground fights
    local sp = VecLength(GetPlayerVelocity())
    if handsOn and HC.vPrev and sp - HC.vPrev > 4 and not (InputDown and InputDown("jump") == true)
        and not hasBit(jump.gi, 16) then
        local eye = VecAdd(pt.pos, Vec(0, 1.7, 0))
        for _, side in ipairs({ "r", "l" }) do
            local h = HC[side]
            if HC.solid(side) and validBody(h.body) then
                local c = GetBodyTransform(h.body).pos
                local y = clamp(c[2], pt.pos[2], eye[2])
                if VecLength(VecSub(c, Vec(pt.pos[1], y, pt.pos[3]))) < 0.6 then
                    HC.logAdd(HC.shoveLog)
                    if HC.logCount(HC.shoveLog, 10) >= 2 then HC.fail = 6 end
                    break
                end
            end
        end
    end
    HC.vPrev = sp
    local pick = GetPlayerPickBody and GetPlayerPickBody() or 0
    local ib, gb = GetPlayerInteractBody(), GetPlayerGrabBody()
    for _, side in ipairs({ "r", "l" }) do
        local h = HC[side]
        if handsOn and h.body and (pick == h.body or ib == h.body or gb == h.body) then
            h.pickRun = (h.pickRun or 0) + 1
            if h.pickRun >= 30 then
                h.pickRun = 0
                h.ghostUntil = math.max(h.ghostUntil or -1, now + HC.PICK_OFF)
                HC.logAdd(HC.pickLog)
                if not h.noq then
                    h.noq = true
                    local list = (HC.var == 1 and { h.shape }) or (HC.var == 2 and h.shapes) or hands.shapes[side] or {}
                    for _, s in pairs(list) do engineCall(SetTag, s, "noquery") end
                    PM.bit(128)
                end
                if HC.logCount(HC.pickLog, 60) > HC.PICK_MAX then HC.fail = 5 end
            end
        else
            h.pickRun = 0
        end
    end
    local g = (handsOn or shinsOn) and playerGroundBody() or 0
    if g ~= 0 and engineCall(IsBodyDynamic, g) == true then
        local gv = engineCall(GetBodyVelocity, g)
        if type(gv) == "table" and type(gv[3]) == "number" and VecLength(gv) > BC.FIGHT_V then
            for i = 1, 4 do
                local t, side = (i <= 2) and HC or BC, (i % 2 == 1) and "r" or "l"
                local h = t[side]
                local near = false
                if (h.st == 1 or h.st == 2) and validBody(h.body) then
                    local ct, pts = GetBodyTransform(h.body), HC.pts(t, side)
                    for k = 1, #pts do      -- (the box's centre / ends: within FIGHT_D of the ground body's surface)
                        local c = TransformToParentPoint(ct, Vec(pts[k][1], pts[k][2], pts[k][3]))
                        local hit, p = engineCall(GetBodyClosestPoint, g, c)
                        if hit == true and type(p) == "table" and VecLength(VecSub(p, c)) - 0.05 <= BC.FIGHT_D then
                            near = true
                        end
                    end
                end
                if near then
                    if t == HC and now >= (h.ghostUntil or -1) then
                        h.ghostUntil = now + BC.FIGHT_OFF
                        HC.logAdd(HC.fightLog)
                        if HC.logCount(HC.fightLog, BC.FIGHT_WIN) >= BC.FIGHT_N then HC.fail = 10 end
                    elseif t == BC and now >= BC.fightUntil then
                        BC.fightUntil, BC.fightN = now + BC.FIGHT_OFF, BC.fightN + 1
                        HC.logAdd(BC.fightLog)
                        if HC.logCount(BC.fightLog, BC.FIGHT_WIN) >= BC.FIGHT_N then BC.off = 7 end
                    end
                end
            end
        end
    end
    handsOn = handsOn and HC.fail == 0
    shinsOn = shinsOn and BC.off == 0
    -- the hands
    local lh = nat.leftHanded == 1
    local main = lh and "l" or "r"
    local toolTrig = hasBit(PM.bits, 256) and GetToolBody() ~= 0 and ctl ~= nil
        and ((lh and ctl.ltrig or ctl.rtrig) > 0.15 or (lh and ctl.lsq or ctl.rsq) > 0.15 or hasBit(ctl.buttons, 4))
    local ghostAll = GetPlayerGrabBody() ~= 0 or hands.safetyHide
    for _, side in ipairs({ "r", "l" }) do
        local h = HC[side]
        if HC.ST then
            h.st = wantH and 6 or 0
        elseif not handsOn then
            -- (deleted - C: only its filters 0/0 -; the state digit is OFF only when the option is off, PARKED for
            -- every other cause: multiplayer, a fail, the self-test not passed / given up after 5 inconclusive runs)
            HC.drop(HC, side)
            if wantH then HC[side].st = 5 end
        elseif not (sitH and pmOk and tracked[side]) or (HC.var == 3 and (hands.skin ~= 2 or not validBody(hands.body[side])
            or engineCall(IsBodyDynamic, hands.body[side]) ~= true))     -- (C: blocky dynamic gloves only)
            or (HC.var == 2 and not hands.shown[side]) then   -- (B: a visible core without its glove - deleted, R-9)
            HC.park(HC, side)
        else
            local tgt, jumped = HC.target(side, phys.liveBase or phys.base, dt)   -- (v0.22 3.2: the live base)
            -- (variant B: one copy of the shown pose; another pose shown -> respawned where the old copy WAS, with its
            -- velocity and state - no snap to the target, which may lie inside what the hand rests on (review
            -- R21-VARB-POSE-RESPAWN-THROUGH, R-9); the grace / pick-off ghost time, the hold and the drive state carry
            -- over)
            local keep, at = nil, tgt
            if HC.var == 2 and h.body and hands.shown[side] and hands.shown[side] ~= h.pose then
                if validBody(h.body) and h.st >= 1 and h.st <= 4 then
                    at = GetBodyTransform(h.body)
                    keep = { ghostUntil = h.ghostUntil, wasHeld = h.wasHeld, hapticAt = h.hapticAt, st = h.st,
                             rvel = h.rvel, lead = h.lead, drvRel = h.drvRel, prevLoc = h.prevLoc, snapT = h.snapT,
                             stuckT = h.stuckT, vel = engineCall(GetBodyVelocity, h.body),
                             avel = engineCall(GetBodyAngularVelocity, h.body) }
                else
                    keep = { ghostUntil = h.ghostUntil, wasHeld = h.wasHeld, hapticAt = h.hapticAt }
                end
                HC.drop(HC, side)
                h = HC[side]
            end
            if (HC.var == 3 and h.body ~= hands.body[side]) or not validBody(h.body) then
                if not hcolSpawn(side, at) then
                    HC.fail = 7
                    HC.drop(HC, side)
                else
                    h = HC[side]
                    h.prevRel, h.prevTgt, h.tgtRel, h.tgtRot = VecSub(tgt.pos, pt.pos), tgt.pos, VecSub(tgt.pos, pt.pos),
                        tgt.rot
                    h.prevLoc = TransformToLocalPoint(phys.liveBase or phys.base, tgt.pos)
                    h.epoch = HC.baseEpoch
                    if keep then
                        for k, v in pairs(keep) do h[k] = v end
                        h.vel, h.avel = nil, nil
                        if type(keep.vel) == "table" then engineCall(SetBodyVelocity, h.body, keep.vel) end
                        if type(keep.avel) == "table" then engineCall(SetBodyAngularVelocity, h.body, keep.avel) end
                    end
                end
            end
            if h.body then
                -- (a ghost: the engine grab, the pick safety's hidden gloves, the tool hand on trigger when query-
                -- visible, and a variant-C glove that is not shown - it is not moved (parkOwnBody), so it must not
                -- collide either, e.g. the right glove during the bounds check after the variant-C respawn)
                local e = HC.rules(HC, side, tgt, jumped, now, dt, ghostAll or (toolTrig and side == main)
                    or (HC.var == 3 and not hands.shown[side]), phys[side].hold ~= nil)
                if h.st == 1 or h.st == 2 then HC.errAdd(math.min(e * 1000, 999), h.st == 2) end
            end
        end
    end
    -- the shins
    shinTick(dt, now, shinsOn, sitB and pmOk, false, anim)
    -- the way OUT (section 5): every collider 0/0 (above), then the animator filters, then the mask
    local on = HC.ST ~= nil
    for i = 1, 4 do
        local t, side = (i <= 2) and HC or BC, (i % 2 == 1) and "r" or "l"
        local st = t[side].st
        if st >= 1 and st <= 4 then on = true end
    end
    if not on then
        if PM.filt then pmAnimFilters(false) end
        if PM.applied then pmRestore("off") end
    end
end

-- Section 6.3, tick: the self-test starts (the gate passed). ST1 = the player mask and the animator filters (they must
-- be ours before any test body gets 64); ST5 (no motion): probe bits 1 pelvis dynamic, 2 an animator shape found by an
-- unfiltered physical query, 64 the pelvis bone within 1.2 m; bit 32 SetBodyGravityScale exists. The test spot P = 3 m
-- below the feet (2.5 m above the eye when wet there; wet too: postponed, inconclusive); the static plate (allowStatic,
-- filter (16, 64)) with its top at P and the ST4 / ST3 test collider (a variant A copy, filter 0/0, gravity 0) above it.
-- Every test body is a BODY tagged tdvr_probe.
function HC.stBegin(pt)
    if not pmApply() then HC.offAll(2) return end
    local ok = pmAnimFilters(true)
    if ok == false then HC.offAll(3) return end
    if ok == nil and not PM.recheck() then return end
    if type(SetBodyGravityScale) == "function" then PM.bit(32) end
    local anim = engineCall(GetPlayerAnimator)
    if type(anim) == "number" and anim ~= 0 then
        local pel = engineCall(GetBoneBody, anim, "pelvis")
        if type(pel) == "number" and pel ~= 0 and engineCall(IsBodyDynamic, pel) == true then PM.bit(1) end
        local pw = engineCall(GetBoneWorldTransform, anim, "pelvis")
        if type(pw) == "table" and type(pw.pos) == "table" and type(pw.pos[3]) == "number" then
            engineCall(QueryRequire, "physical")
            engineCall(QueryInclude, "player animator")
            local hit, _, _, s = engineCall(QueryClosestPoint, pw.pos, 0.3)
            local sb = (hit == true and type(s) == "number" and s ~= 0) and engineCall(GetShapeBody, s) or 0
            if type(sb) == "number" and sb ~= 0 and engineCall(GetBodyAnimator, sb) == anim then PM.bit(2) end
            if VecLength(VecSub(pw.pos, pt.pos)) <= 1.2 then PM.bit(64) end
        end
    end
    local P = VecAdd(pt.pos, Vec(0, -3, 0))
    local function wet(p)
        return engineCall(IsPointInWater, p) == true or engineCall(IsPointInWater, VecAdd(p, Vec(0, 0.3, 0))) == true
    end
    if wet(P) then
        P = VecAdd(GetPlayerEyeTransform().pos, Vec(0, 2.5, 0))
        if wet(P) then
            HC.sel, HC.incl = 6, HC.incl + 1
            return
        end
    end
    local T = { phase = "mass", P = P, top = P[2], live = {}, n = 0, plateDyn = false }
    T.plate = HC.stPlate(T, false)
    if T.plate == 0 then
        HC.stEnd(3)
        return
    end
    local col, shapes = HC.spawn(HC.stXml(1), Transform(VecAdd(P, Vec(0, 0.6, 0))))
    if col == 0 or #shapes == 0 then
        HC.stEnd(3)
        return
    end
    T.col, T.colShape, T.live[col] = col, shapes[1], true
    engineCall(SetShapeLocalTransform, T.colShape, Transform(Vec(-0.05, -0.05, -0.05)))
    engineCall(SetShapeCollisionFilter, T.colShape, 0, 0)
    engineCall(SetBodyGravityScale, col, 0)
    engineCall(SetShapeDensity, T.colShape, 1)
    T.start = GetBodyTransform(col)
    T.cal = { shapes = { T.colShape }, d = 1, tries = 0, n = 0, target = HC.MASS }
    HC.ST, HC.sel = T, 5
    HC.r.st, HC.l.st = nat.handCollide and 6 or 0, nat.handCollide and 6 or 0
end
-- the test plate: static (allowStatic) or, for the rig retry, dynamic held by constraints (gravity 0); top face at P
function HC.stPlate(T, dyn)
    local b, shapes = HC.spawn('<body tags="tdvr_probe nomerge" dynamic="' .. (dyn and "true" or "false")
        .. '"><voxbox size="4 1 4" tags="tdvr_probe unbreakable"/></body>', Transform(VecAdd(T.P, Vec(-0.2, -0.1, -0.2))))
    if b == 0 then return 0 end
    for i = 1, #shapes do engineCall(SetShapeCollisionFilter, shapes[i], 16, 64) end
    if dyn then engineCall(SetBodyGravityScale, b, 0) end
    T.live[b] = true
    T.plateStart = GetBodyTransform(b)
    return b
end
-- the XML of a test copy: 0 the control box (no shape tags), 1 variant A, 2 variant B (the 80 % fist copy), 3 variant C
-- (the blocky fist spawned without collide="false"); body tagged tdvr_probe
function HC.stXml(kind)
    local x = '<body tags="tdvr_probe nomerge" dynamic="true">'
    if kind == 0 then return x .. '<voxbox size="1 1 1"/></body>' end
    if kind == 1 then
        return x .. '<voxbox size="1 1 ' .. ((hands.skin == 2) and "3" or "1") .. '" density="1" tags="tdvr_hcolshape '
            .. 'unbreakable nocull nonav invisible noquery"/></body>'
    end
    local file, pre = HC.file()
    if kind == 2 then
        return x .. '<vox tags="tdvr_hcolshape unbreakable nocull nonav noquery" file="' .. file .. '" object="' .. pre
            .. 'fist_r" scale="' .. tostring(0.8 * hands.voxel) .. '"/></body>'
    end
    return x .. '<vox tags="tdvr_probeshape unbreakable nocull noquery nonav" file="MOD/hands_blocky.vox" object='
        .. '"blk_fist_r" scale="' .. tostring(hands.voxel) .. '"/></body>'
end
-- the variants to try: A, B, and C only with blocky dynamic gloves (handBodyStatic false and the glove dynamic)
function HC.stVariants()
    local v = { 1, 2 }
    if hands.skin == 2 and not handBodyStatic() and validBody(hands.body.r)
        and engineCall(IsBodyDynamic, hands.body.r) == true then
        v[3] = 3
    end
    return v
end
-- Section 6.3, tick: the steps that spawn or delete (never from update()): a body lost -> code 3; T.wait = "ctl" (the
-- control box, the dynamic plate for the retry), "var" (the next variant's copy), "done" (passed: everything deleted),
-- "fail" (T.code). Each drop starts 0.25 m above the plate top (the shape's lowest point), filter (64, 16), gravity 1.
function HC.stTick()
    local T = HC.ST
    for b in pairs(T.live) do
        if not validBody(b) then HC.stEnd(3) return end
    end
    if T.wait == "ctl" or T.wait == "var" then
        if T.col then
            engineCall(Delete, T.col)
            T.live[T.col] = nil
            T.col = nil
        end
        if T.drop then
            engineCall(Delete, T.drop)
            T.live[T.drop] = nil
            T.drop = nil
        end
        local kind
        if T.wait == "ctl" then
            if T.dynPlate and not T.plateDyn then
                engineCall(Delete, T.plate)
                T.live[T.plate] = nil
                T.plateDyn = true
                T.plate = HC.stPlate(T, true)
                if T.plate == 0 then HC.stEnd(3) return end
            end
            kind, T.what = 0, 0
        else
            T.idx = T.idx + 1
            if T.idx > #T.vars then HC.stEnd(2) return end
            kind = T.vars[T.idx]
            T.what = kind
        end
        local b, shapes = HC.spawn(HC.stXml(kind), Transform(VecAdd(T.P, Vec(0, 1, 0))))
        if b == 0 or #shapes == 0 then HC.stEnd(3) return end
        T.drop, T.dropShape, T.live[b] = b, shapes[1], true
        local lo, hi = Vec(0, 0, 0), Vec(0.1, 0.1, 0.1)
        if kind == 1 then
            lo, hi = Vec(-0.05, -0.05, -0.05), Vec(0.05, 0.05, ((hands.skin == 2) and 0.25 or 0.05))
        elseif kind >= 2 then
            local part = handPart("fist", "r")
            local s = (kind == 2) and 0.8 or 1
            local vs = s * hands.voxel * 0.1
            lo = Vec(-s * part[4], -s * part[5], -s * part[6])
            hi = VecAdd(lo, Vec(part[1] * vs, part[2] * vs, part[3] * vs))
        end
        if kind >= 1 then engineCall(SetShapeLocalTransform, T.dropShape, Transform(lo)) end
        T.dropLo, T.dropHi = lo, hi                     -- (the drop's body-space box: its lowest point, ST2)
        for i = 1, #shapes do engineCall(SetShapeCollisionFilter, shapes[i], 64, 16) end
        engineCall(SetBodyGravityScale, b, 1)
        engineCall(SetBodyTransform, b, Transform(Vec(T.P[1] - (lo[1] + hi[1]) * 0.5, T.top + 0.25 - lo[2],
            T.P[3] - (lo[3] + hi[3]) * 0.5)))
        engineCall(SetBodyVelocity, b, Vec(0, 0, 0))
        T.phase, T.n, T.wait = "drop", 0, nil
    elseif T.wait == "done" then
        HC.stEnd(1)
    elseif T.wait == "fail" then
        HC.stEnd(T.code)
    end
end
-- Section 6.3 ST6, update(): is the passing drop T.drop (centre c) found by an unfiltered physical query - only
-- QueryRequire("physical") and the plate rejected, like toolanimation.lua - by QueryClosestPoint(c, 0.05) or a
-- QueryRaycast from 0.5 m beside it through c? The test spot is usually inside the level (3 m below the feet), whose
-- shapes are as close as the drop and would answer first: each query is repeated with every body it hit so far
-- rejected too (the world body included), up to 8 rounds. true = either found it; false = both ran out of hits without
-- it; nil = unknown (rounds used up, or a hit that cannot be rejected).
function HC.stQvis(T, c)
    local res = {}
    for q = 1, 2 do
        local rej, seen, out = {}, {}, nil
        for round = 1, 8 do
            engineCall(QueryRequire, "physical")
            engineCall(QueryRejectBody, T.plate)
            for i = 1, #rej do engineCall(QueryRejectBody, rej[i]) end
            local hit, s
            if q == 1 then
                local a, _, _, sh = engineCall(QueryClosestPoint, c, 0.05)
                hit, s = a, sh
            else
                local a, _, _, sh = engineCall(QueryRaycast, VecAdd(c, Vec(0.5, 0, 0)), Vec(-1, 0, 0), 1.0, 0)
                hit, s = a, sh
            end
            if hit ~= true then out = false break end
            local b = (type(s) == "number" and s ~= 0) and engineCall(GetShapeBody, s) or 0
            if b == T.drop then out = true break end
            if type(b) ~= "number" or b == 0 or seen[b] then break end      -- (cannot be rejected: unknown)
            seen[b], rej[#rej + 1] = true, b
        end
        if out == true then return true end
        res[q] = out
    end
    if res[1] == false and res[2] == false then return false end
    return nil
end

-- Section 6.3, the end of a run: every test body deleted (FindBodies / FindShapes "tdvr_probe"), the code kept (1 pass;
-- 6 inconclusive, retried at the next gate up to 5 runs; any other: hand and body collision off, reason 4). The mask /
-- filters are given back by hcolTick when no collider is on.
function HC.stEnd(code)
    local list = engineCall(FindBodies, "tdvr_probe", true)
    if type(list) == "table" then
        for i = 1, #list do engineCall(Delete, list[i]) end
    end
    local shapes = engineCall(FindShapes, "tdvr_probe", true)
    if type(shapes) == "table" then
        local wb = engineCall(GetWorldBody)
        for i = 1, #shapes do
            local b = engineCall(GetShapeBody, shapes[i])
            if type(b) == "number" and b ~= 0 and b ~= wb then engineCall(Delete, b) end
        end
    end
    HC.ST, HC.sel = nil, code
    if code == 6 then HC.incl = HC.incl + 1 end
    if code ~= 1 and code ~= 6 then
        HC.var = 0
        HC.offAll(4)
    end
    if code ~= 1 then HC.r.st, HC.l.st, BC.r.st, BC.l.st = 0, 0, 0, 0 end
end

-- Section 6.3, update() (one call per physics step) while the self-test runs (~1.5 s; the visible gloves keep the v0.20
-- path meanwhile). ST4 mass: the test collider's density calibrated to HC.MASS (HC.calib; else HC.massScale = m / MASS).
-- ST3 impulse units: the collider held 15 steps by ConstrainPosition(c, 0, centre, start, 10, k * m * 9.81 / 60) with
-- gravity 1: k = 1.05, 4, 70 -> the first that holds (drift < 0.05 m) is kHold (impCode 1 / 2 / 3; none: 4, off); the
-- negative control k = 0.5 must drift > 0.1 m (else 0.25, 0.1: impCode 5 with the smallest that holds; 0.1 holds too, or
-- a stronger-than-1.05 k needed: 6, off); impScale = kHold / 1.05 (ConstrainOrientation's unit ASSUMED the same). ST2:
-- 30 steps of a drop onto the plate, pass = the shape's lowest point within 0.02 m of the plate top; the control box
-- first (fails on the static plate -> once more on a dynamic one; fails there too -> code 7), then the variants A, B, C;
-- the first that passes is the variant, ST6 measured on it (bit 256: found by an unfiltered physical query - only
-- QueryRequire("physical") and the plate rejected - a closest point or a ray from 0.5 m beside it). Spawns and deletes
-- wait for the tick (T.wait).
function colSelfTest(dt)
    local T = HC.ST
    if not T or T.wait then return end
    if T.plateDyn and validBody(T.plate) then             -- (the rig retry's dynamic plate, held where it was spawned)
        local pc = GetBodyTransform(T.plate)
        engineCall(ConstrainPosition, T.plate, 0, pc.pos, T.plateStart.pos, 10, 1000)
        engineCall(ConstrainOrientation, T.plate, 0, pc.rot, T.plateStart.rot, 10, 1000)
    end
    if T.phase == "mass" then
        HC.calib(T.col, T.cal)
        if T.cal.done then
            local m = T.cal.m or 0
            HC.mass = m
            -- (diagnostic only: every live collider calibrates its own density and scales its own F by h.ms,
            -- driveColliders)
            HC.massScale = (m > 0 and math.abs(m - HC.MASS) > HC.MASS * 0.1) and m / HC.MASS or 1
            T.phase, T.k, T.kind, T.n = "imp", 1, "pos", 15
            T.ks = { pos = { 1.05, 4, 70 }, neg = { 0.5, 0.25, 0.1 } }
        else
            return
        end
    end
    if T.phase == "imp" then
        if T.n >= 15 then
            if T.trialK then                       -- (a trial ended: its drift decides)
                local drift = VecLength(VecSub(GetBodyTransform(T.col).pos, T.start.pos))
                local nextK = nil
                if T.kind == "pos" then
                    if drift < 0.05 then
                        T.kHold, HC.imp = T.trialK, T.k
                        T.kind, T.k = "neg", 1
                        nextK = 1
                    elseif T.k < 3 then
                        T.k = T.k + 1
                        nextK = T.k
                    else
                        HC.imp, T.wait, T.code = 4, "fail", 4
                    end
                else
                    if drift > 0.1 then                -- (the control moved: kHold stands)
                        HC.impScale = T.kHold / 1.05
                        engineCall(SetBodyGravityScale, T.col, 0)
                        -- (v0.22 section 2.4: ST3b next, the impulse unit measured directly)
                        engineCall(SetBodyTransform, T.col, T.start)
                        engineCall(SetBodyVelocity, T.col, Vec(0, 0, 0))
                        engineCall(SetBodyAngularVelocity, T.col, Vec(0, 0, 0))
                        T.phase, T.n = "st3b", 0
                    elseif HC.imp ~= 1 and HC.imp ~= 5 or T.k >= 3 then
                        HC.imp, T.wait, T.code = 6, "fail", 4
                    else
                        T.kHold, HC.imp = T.trialK, 5
                        T.k = T.k + 1
                        nextK = T.k
                    end
                end
                if not nextK then T.trialK = nil return end
            end
            T.trialK, T.n = T.ks[T.kind][T.k], 0
            engineCall(SetBodyTransform, T.col, T.start)
            engineCall(SetBodyVelocity, T.col, Vec(0, 0, 0))
            engineCall(SetBodyAngularVelocity, T.col, Vec(0, 0, 0))
            engineCall(SetBodyGravityScale, T.col, 1)
            T.mass = engineCall(GetBodyMass, T.col)
            if type(T.mass) ~= "number" or T.mass <= 0 then T.mass = HC.MASS end
        end
        local c = GetBodyTransform(T.col)
        engineCall(SetBodyActive, T.col, true)
        engineCall(ConstrainPosition, T.col, 0, c.pos, T.start.pos, 10, T.trialK * T.mass * 9.81 / 60)
        T.n = T.n + 1
        return
    end
    -- v0.22 (docs/V022_PLAN.md section 2.4) ST3b: gravity 0, filter 0/0, three steps of ConstrainPosition toward + 1 m X
    -- with the impulse cap I = 0.05 N*s; the 4th step reads the velocity: N = m * |dv| / (3 * I), the engine's impulse
    -- per unit asked. Used for 0.9 <= N <= 10 with dv within 10 deg of +X: with impCode 5 (the ST3 reading below 1)
    -- and NHP_STEADY impScale = min(1, 1 / N), else logged only (HC.st3bN, the L_HCOL digit).
    if T.phase == "st3b" then
        T.n = T.n + 1
        if T.n == 1 then
            local v0 = engineCall(GetBodyVelocity, T.col)
            T.v0 = (type(v0) == "table" and type(v0[3]) == "number") and v0 or Vec(0, 0, 0)
        end
        if T.n <= 3 then
            local c = GetBodyTransform(T.col)
            engineCall(SetBodyActive, T.col, true)
            engineCall(ConstrainPosition, T.col, 0, c.pos, VecAdd(c.pos, Vec(1, 0, 0)), 100, 0.05)
            return
        end
        local v = engineCall(GetBodyVelocity, T.col)
        local dv = (type(v) == "table" and type(v[3]) == "number") and VecSub(v, T.v0) or Vec(0, 0, 0)
        local dl = VecLength(dv)
        local N = (T.mass or HC.MASS) * dl / (3 * 0.05)
        HC.st3bN = N
        -- (review F6 / R22-ST3B-OVERRIDE: ST3b is the authority over ST3's bracket on purpose. ST3's impCode 5 only says
        -- "the hold needed less than asked" - kHold / 1.05, 0.24..0.48 - and that reading includes contact and solver
        -- effects; ST3b measures the impulse unit directly with nothing touching. So any N >= 0.9 (within noise of 1
        -- or more) replaces ST3's scale, even N ~ 1, which can raise impScale up to ~4x over ST3's: the v0.21 hands
        -- ran at ST3's 0.24..0.48 and had no punch ("hand has no power"). Never stronger than asked: impScale <= 1.)
        if HC.imp == 5 and nat.handSteady == true and N >= 0.9 and N <= 10 and dl > 1e-9
            and dv[1] / dl >= math.cos(math.rad(10)) then
            HC.impScale = math.min(1, 1 / N)
        end
        T.wait, T.vars, T.idx = "ctl", HC.stVariants(), 0
        return
    end
    if T.phase == "drop" then
        T.n = T.n + 1
        if T.n <= 30 then return end
        -- (pass: the box's lowest point within 0.02 m of the plate top - from the drop's known body-space box and its
        -- body transform, not GetShapeBounds: the engine's AABB carries a margin of its own, handBoundsCheck)
        local bt = GetBodyTransform(T.drop)
        local pass = validBody(T.drop) and math.abs(HC.lowest(bt, T.dropLo, T.dropHi) - T.top) <= 0.02
        if T.what == 0 then
            if pass then T.wait = "var"
            elseif not T.dynPlate then T.dynPlate, T.wait = true, "ctl"
            else T.wait, T.code = "fail", 7 end
        elseif pass then
            local c = TransformToParentPoint(bt, VecScale(VecAdd(T.dropLo, T.dropHi), 0.5))
            if HC.stQvis(T, c) ~= false then PM.bit(256) end      -- (unknown counts as visible: the safe side)
            HC.var, T.wait = T.what, "done"
        else
            T.wait = "var"
        end
    end
end

-- Section 6.4, update() right after holdHands: the self-test's step (colSelfTest), else for each collider in FREE /
-- BLOCKED / HELD / GHOST (filter 0/0 in the last two, and for this step after a fast-guard reset, PM.fast):
--   tgt = player pos + tgtRel (tick), clamped against static geometry when more than CLAMP_STEP away (FREE / BLOCKED);
--   F = the strength's force * the collider's mass ratio, F_WEAK within GROUND_WEAK of playerGroundBody(), a = F / m;
--   vmax = min(clamp(sqrt(2 a d) + |rvel|, VMIN, VMAX) + |player velocity| (not within GROUND_NOVEL), VCAP);
--   SetBodyActive; ConstrainPosition(body, 0, c, tgt, vmax, F dt impScale); ConstrainOrientation(body, 0, c.rot,
--   tgt.rot, W, T dt impScale). The density calibration of a new collider runs here too (one try per step).
-- v0.22 (docs/V022_PLAN.md sections 2-3): with NHP_STEADY a solid hand's target is swept against static geometry
-- whenever it moves more than CLAMP_MIN (clampSweep: collide and slide; a clamp counted once per contact onset), and while
-- the sweep holds it pressed (the final step < 1 cm) it is driven with F_REST / T_BLOCK only; with NHP_PUNCH each solid
-- hand that did not snap this tick then looks for a punch (punchStep, after its drive). Off: the v0.21 drive exactly.
function driveColliders(dt)
    HC.updAt = HC.clock
    if type(dt) ~= "number" or dt <= 0 then return end
    HC.uclock = HC.uclock + dt
    if HC.ST then colSelfTest(dt) return end
    if not (HC.r.body or HC.l.body or BC.r.body or BC.l.body) then return end
    if PUNCH.pend then                  -- (v0.22: each hand's last punch's gain, one step after its impulse)
        -- (review R22-PUNCH-GAIN-BIAS: only the velocity change ALONG the impulse - the hand still pressing on, the
        -- contacts and gravity add sideways / vertical parts that read as gain; never below 0)
        local pend = PUNCH.pend
        PUNCH.pend = nil
        for _, side in ipairs({ "r", "l" }) do
            local pd = pend[side]
            local v = pd and engineCall(GetBodyVelocity, pd.b)
            if pd and pd.u and type(v) == "table" and type(v[3]) == "number" and pd.imp > 1e-9 then
                push(PUNCH.gains, math.max(0, VecDot(VecSub(v, pd.v0), pd.u)) * pd.m / pd.imp, 9)
            end
        end
    end
    local ghost = PM.fast()
    local pp = GetPlayerTransform().pos
    HC.ppDrv = pp                       -- (the player's position this step's targets are built from: HC.rules, R-8)
    local pv = VecLength(GetPlayerVelocity())
    local g = playerGroundBody()
    for i = 1, 4 do
        local t, side = (i <= 2) and HC or BC, (i % 2 == 1) and "r" or "l"
        local h = t[side]
        if h.body and h.st >= 1 and h.st <= 4 and h.tgtRel and validBody(h.body) then
            local isB = t == BC
            if h.cal and not h.cal.done then
                HC.calib(h.body, h.cal)
                if h.cal.done then
                    local m = h.cal.m or 0
                    h.ms = (m > 0 and math.abs(m - h.cal.target) > h.cal.target * 0.1) and m / h.cal.target or 1
                end
            end
            local solid = h.st == 1 or h.st == 2
            HC.applyF(t, side, solid and not ghost)
            local c = GetBodyTransform(h.body)
            local tp = VecAdd(pp, h.tgtRel)
            local d = VecLength(VecSub(tp, c.pos))
            local rest = false
            if solid and not isB and nat.handSteady == true then
                local lim = false
                if d > HC.CLAMP_MIN then
                    local raw = tp
                    tp, lim = clampSweep(side, c, tp)
                    if lim then
                        h.clampOff, h.clampAt = VecSub(tp, raw), HC.clock
                        if not h.clampOn then HC.logAdd(HC.clampLog) end      -- (once per contact onset)
                        d = VecLength(VecSub(tp, c.pos))
                        rest = d < 0.01
                    end
                end
                h.clampOn = lim
            elseif solid and d > HC.CLAMP_STEP then
                tp = clampStatic(c.pos, tp, not isB)
                d = VecLength(VecSub(tp, c.pos))
            end
            local gd = math.huge
            if g ~= 0 then
                local hit, gp = engineCall(GetBodyClosestPoint, g, c.pos)
                if hit == true and type(gp) == "table" and type(gp[3]) == "number" then
                    gd = VecLength(VecSub(gp, c.pos)) - 0.05
                end
            end
            -- (ms = the collider's mass / its target mass when it could not be calibrated - and variant C's glove mass /
            -- HC.MASS -: F is scaled by it and m is the body's real mass, so a = F / m = the strength's force / MASS
            -- whatever the collider weighs, and the vmax brake below matches the force)
            local ms = h.ms or 1
            local m = (h.cal and h.cal.m and h.cal.m > 0) and h.cal.m or (isB and BC.MASS or HC.MASS) * ms
            local F = HC.force(t) * ms
            if gd <= HC.GROUND_WEAK then F = math.min(F, HC.F_WEAK * ms) end
            if rest then F = HC.F_REST * ms end   -- (v0.22: pressed against a wall, nothing left to slide)
            local vmax = clamp(math.sqrt(2 * F / m * d) + (h.rvel and VecLength(h.rvel) or 0), HC.VMIN,
                isB and BC.VMAX or HC.VMAX)
            vmax = math.min(vmax + ((gd <= HC.GROUND_NOVEL) and 0 or pv), isB and BC.VCAP or HC.VCAP)
            engineCall(SetBodyActive, h.body, true)
            engineCall(ConstrainPosition, h.body, 0, c.pos, tp, vmax, F * dt * HC.impScale)
            engineCall(ConstrainOrientation, h.body, 0, c.rot, h.tgtRot, isB and BC.W or HC.W,
                (rest and HC.T_BLOCK or (isB and BC.T or HC.T)) * dt * HC.impScale)
            if not isB and solid and nat.handPunch == true and h.snapAt ~= HC.clock then
                punchStep(side, dt, HC.uclock)
            end
        end
    end
end

-- v0.22 (docs/V022_PLAN.md section 3.3), update(): the hand collider's step from c (its transform) to tp, swept against
-- STATIC geometry and slid along it. Pass 1: from each HC.pts point p a QueryRaycast(p - dir * SW_BACK, dir, d + SW_BACK,
-- SW_R) ("physical static", our bodies / the player / the character rejected); a hit counts only at dist >= 1 mm with
-- its normal against the step (dot < -0.05; no normal: -dir), so pulling away from or sliding along a touched surface is
-- never clamped; travel = the smallest dist - SW_BACK -
-- (SW_HALF - SW_R) - SW_GAP, n = that hit's normal. A hit: the step stops at travel, and the remainder's part along the
-- wall (rest - n * dot(rest, n)) is swept once more from there (pass 2, no further slide: a corner stops the hand).
-- Returns the target and whether the sweep limited the step. Up to 5 points x 2 passes per hand and step.
function clampSweep(side, c, tp)
    local d = VecLength(VecSub(tp, c.pos))
    if d <= HC.CLAMP_MIN then return tp, false end
    local pts = HC.pts(HC, side)
    local function sweep(from, dir, len)
        local travel, n = nil, nil
        for i = 1, #pts do
            local p = TransformToParentPoint(Transform(from, c.rot), Vec(pts[i][1], pts[i][2], pts[i][3]))
            hcolQueryFilter()
            engineCall(QueryRequire, "physical static")
            local hit, dist, nrm = engineCall(QueryRaycast, VecSub(p, VecScale(dir, HC.SW_BACK)), dir, len + HC.SW_BACK,
                HC.SW_R)
            -- (review F1 / LUA22-1: only a hit that blocks the step - not an overlap at the cast's start (dist < 1 mm: a
            -- hand touching a wall and pulled away starts its sphere inside it) and not a surface the step leaves or runs
            -- along (its normal not against dir); the physical collider still stops a real penetration)
            local nv = (type(nrm) == "table" and type(nrm[3]) == "number" and VecLength(nrm) > 0.5) and VecNormalize(nrm)
                or nil
            if hit == true and type(dist) == "number" and dist >= 1e-3 and (not nv or VecDot(nv, dir) < -0.05) then
                local tr = dist - HC.SW_BACK - (HC.SW_HALF - HC.SW_R) - HC.SW_GAP
                if not travel or tr < travel then
                    travel = tr
                    n = nv or VecScale(dir, -1)
                end
            end
        end
        return travel, n
    end
    local dir = VecScale(VecSub(tp, c.pos), 1 / d)
    local travel, n = sweep(c.pos, dir, d)
    if not travel then return tp, false end
    local hitLimited = VecAdd(c.pos, VecScale(dir, math.max(0, math.min(travel, d))))
    local rest = VecSub(tp, hitLimited)
    local slide = VecSub(rest, VecScale(n, VecDot(rest, n)))
    local sl = VecLength(slide)
    if sl <= HC.CLAMP_MIN then return hitLimited, true end
    local sdir = VecScale(slide, 1 / sl)
    local t2 = sweep(hitLimited, sdir, sl)
    return VecAdd(hitLimited, VecScale(sdir, t2 and math.max(0, math.min(t2, sl)) or sl)), true
end

-- v0.22 (docs/V022_PLAN.md section 2.2), update() after the side's drive (NHP_PUNCH and NHP_COLLIDE, single-player, a
-- solid hand that did not snap this tick): a fast hit with the solid hand knocks a loose body away. Contact: a dynamic
-- physical shape within D of the collider (QueryClosestPoint at each HC.pts point, hcolQueryFilter); not a static body,
-- the ground body, a held / engine-grabbed body, the player's vehicle or one of ours. The approach speed vn = (the hand's
-- mean own velocity over two ticks + 0.3 * the player's velocity - the body's velocity at the hit) along -n, capped at
-- VCAP; a punch needs vn > V AND the hand's mean own approach >= VOWN (walking into a crate with still hands is no punch), at
-- the contact's onset (no contact with that body for SEP) and GAP after the last punch of that body. J = min((1 + E) *
-- mu * vn, JMAX) with mu = M m / (M + m) (M, JMAX by hand_strength), along the hit normal turned AIM toward the hand's
-- motion, LIFT * J up (unless aimed down), * NEAR_K near the player, never toward the player, |imp| <= m * DVMAX;
-- ApplyBodyImpulse at the hit (nothing on the player or the collider). Every onset is logged (L_PUNCH).
function punchStep(side, dt, now)
    local h = HC[side]
    local P = PUNCH
    if not (nat.handPunch == true and nat.handCollide == true) or BV.mp or not (h.st == 1 or h.st == 2)
        or not validBody(h.body) then return end
    local c = GetBodyTransform(h.body)
    local pts = HC.pts(HC, side)
    local best = nil
    for i = 1, #pts do
        local p = TransformToParentPoint(c, Vec(pts[i][1], pts[i][2], pts[i][3]))
        hcolQueryFilter()
        engineCall(QueryRequire, "physical dynamic")
        local hit, hp, nrm, s = engineCall(QueryClosestPoint, p, 0.05 + P.D)
        if hit == true and type(hp) == "table" and type(hp[3]) == "number" and type(s) == "number" and s ~= 0 then
            local dd = VecLength(VecSub(p, hp))
            if dd - 0.05 <= P.D and (not best or dd < best.d) then best = { d = dd, p = p, hp = hp, nrm = nrm, s = s } end
        end
    end
    if not best then return end
    local b = engineCall(GetShapeBody, best.s)
    if type(b) ~= "number" or b == 0 or engineCall(IsBodyDynamic, b) ~= true then return end
    if b == playerGroundBody() or b == GetPlayerGrabBody() or isOwnBody(b) or isColliderBody(b) then return end
    if (phys.r.hold and phys.r.hold.body == b) or (phys.l.hold and phys.l.hold.body == b) then return end
    local veh = GetPlayerVehicle()
    if veh ~= 0 and (b == engineCall(GetVehicleBody, veh) or engineCall(GetBodyVehicle, b) == veh) then return end
    -- (review R22-PUNCH-ONSET-LOST: a tick without the hand's own velocity - HC.target clears h.rvel on a jumped tick -
    -- neither starts nor uses up a contact's onset)
    if not h.rvel then return end
    -- (the onset: no contact of this hand with b for SEP)
    local onset = h.touchB ~= b or now - (h.touchAt or -1e9) > P.SEP
    h.touchB, h.touchAt = b, now
    if not onset then return end
    local n
    if best.d < 0.001 then
        n = (type(best.nrm) == "table" and type(best.nrm[3]) == "number" and VecLength(best.nrm) > 0.5)
            and VecNormalize(best.nrm) or Vec(0, 1, 0)
    else
        n = VecScale(VecSub(best.p, best.hp), 1 / best.d)
    end
    local rv = h.rvelPrev and VecScale(VecAdd(h.rvel, h.rvelPrev), 0.5) or h.rvel
    local v = VecAdd(rv, VecScale(GetPlayerVelocity(), 0.3))
    local bv = engineCall(GetBodyVelocityAtPos, b, best.hp)
    if type(bv) ~= "table" or type(bv[3]) ~= "number" then bv = Vec(0, 0, 0) end
    local into = VecScale(n, -1)
    local vn = math.min(VecDot(VecSub(v, bv), into), P.VCAP)
    P.onsetLog[#P.onsetLog + 1] = { HC.clock, vn }
    if vn <= P.V or VecDot(rv, into) < P.VOWN then return end   -- (review F4: the averaged own velocity)
    if now - (P.T[b] or -1e9) < P.GAP then
        P.skipLog[#P.skipLog + 1] = { HC.clock, 1 }
        return
    end
    local m = engineCall(GetBodyMass, b)
    if type(m) ~= "number" or m <= 0 then return end
    local k = clamp((nat.handStrength or 0) + 1, 1, 3)
    local M = P.M[k]
    local J = math.min((1 + P.E) * (M * m / (M + m)) * vn, P.JMAX[k])
    local dir = into
    local vl = VecLength(v)
    if vl > 1e-6 then dir = VecAdd(VecScale(into, 1 - P.AIM), VecScale(v, P.AIM / vl)) end
    if VecLength(dir) < 1e-6 then dir = into end
    dir = VecNormalize(dir)
    -- (the player: feet to eye; never toward it, J * NEAR_K for a body this near it)
    local feet = GetPlayerTransform().pos
    local up = 1.7
    local rel = clamp(best.hp[2] - feet[2], 0, up)
    local toP = VecSub(Vec(feet[1], feet[2] + rel, feet[3]), best.hp)
    local tl = VecLength(toP)
    if tl > 1e-6 and VecDot(dir, VecScale(toP, 1 / tl)) > 0.5 then
        P.skipLog[#P.skipLog + 1] = { HC.clock, 2 }
        return
    end
    for i = 0, 2 do
        local q = Vec(feet[1], feet[2] + up * i * 0.5, feet[3])
        local hit, cp = engineCall(GetBodyClosestPoint, b, q)
        if hit == true and type(cp) == "table" and type(cp[3]) == "number" and VecLength(VecSub(cp, q)) <= P.NEAR then
            J = J * P.NEAR_K
            break
        end
    end
    local imp = VecScale(dir, J)
    if dir[2] > -0.3 then imp = VecAdd(imp, Vec(0, P.LIFT * J, 0)) end
    local il = VecLength(imp)
    if il > m * P.DVMAX then imp, il = VecScale(imp, m * P.DVMAX / il), m * P.DVMAX end
    local v0 = engineCall(GetBodyVelocity, b)
    -- (review R22-PUNCH-GAIN-BIAS: one pending reading per hand; u = the impulse's direction, the gain is read along it)
    P.pend = P.pend or {}
    P.pend[side] = { b = b, v0 = (type(v0) == "table" and type(v0[3]) == "number") and v0 or Vec(0, 0, 0), imp = il, m = m,
                     u = (il > 1e-9) and VecScale(imp, 1 / il) or nil }
    engineCall(ApplyBodyImpulse, b, best.hp, imp)
    P.T[b] = now
    P.log[#P.log + 1] = { HC.clock, J, vn }
    pulse((side == "l") and 1 or 2, 0.6, 0.04)
end

-- Section 6.4: the target `to` seen from the collider centre `from`, clamped against STATIC geometry only (dynamic props
-- are never clamped: punches hit them): hcolQueryFilter, QueryRequire("physical static"), a QueryRaycast of radius RAY_R;
-- a hit -> RAY_GAP before it (counted for a hand, `count`: L_HCOL_EV).
function clampStatic(from, to, count)
    local d = VecSub(to, from)
    local l = VecLength(d)
    if l < 1e-6 then return to end
    local dir = VecScale(d, 1 / l)
    hcolQueryFilter()
    engineCall(QueryRequire, "physical static")
    local hit, dist = engineCall(QueryRaycast, from, dir, l, HC.RAY_R)
    if hit == true and type(dist) == "number" then
        if count then HC.logAdd(HC.clampLog) end
        return VecAdd(from, VecScale(dir, math.max(0, dist - HC.RAY_GAP)))
    end
    return to
end

-- Section 6.6: the hand frame of `side`'s collider: GetBodyTransform(collider) * LOCAL^-1 (nil without one).
function physHandT(side)
    local h = HC[side]
    if not (h and h.body and validBody(h.body)) then return nil end
    return TransformToParentTransform(GetBodyTransform(h.body), Transform(VecScale(HC.loc(side), -1)))
end

-- Section 6.6: "where your real hand is" - the 12 edges of a 0.10 m cube at t (DrawLine, the line-hand path).
function drawHandGhost(t)
    local function corner(i)
        return TransformToParentPoint(t, Vec((i % 2) * 0.1 - 0.05, (math.floor(i / 2) % 2) * 0.1 - 0.05,
            math.floor(i / 4) * 0.1 - 0.05))
    end
    for a = 0, 7 do
        for _, k in ipairs({ 1, 2, 4 }) do
            if math.floor(a / k) % 2 == 0 then DrawLine(corner(a), corner(a + k), 0.85, 0.9, 1, 0.7) end
        end
    end
end

-- Section 6.6, render / placeHandsAndLaser with the controller hand t of `side` (the target refreshed with the render
-- base): FREE / BLOCKED only. e = |collider centre - target centre|; variant A: visual = lerp / slerp(t, physHandT, w), w
-- = clamp((e - E0) / (E1 - E0), 0, 1), nil (the v0.20 placement exactly) while w = 0; B / C: physHandT (the visible
-- core / the glove is the collider; one frame of lag accepted). e > GHOST_LINE: the outline cube at the controller hand
-- t (not at the led / palm-offset target e is measured to). The
-- choice is kept in HC[side].vis (the replica follows it, placeToolReplica).
-- v0.22 (docs/V022_PLAN.md sections 3.2 / 3.4, NHP_STEADY): tLive = the controller hand from the LIVE base (on a held
-- right-eye frame the camera's base is the left frame's; the collider lives in the world of now). The target is
-- refreshed from tLive without the lead; the visible hand is, while the sweep limited the step in the last 0.1 s (a
-- static wall), the controller hand moved by the clamp (h.clampOff) at once (h.w = 1: pure geometry, no physics noise);
-- otherwise the collider pose through a first-order filter (OMEGA; reset beyond 0.3 m) blended with h.w, which ramps at
-- W_RATE toward 1 while BLOCKED (a dynamic contact) and 0 otherwise (never 0 -> 1 in one frame); then the held-frame
-- correction base * live^-1 (HC.visBase / visLive). Off: the v0.21 visual exactly.
function hcolVisual(side, t, tLive)
    local h = HC[side]
    if not h then return nil end
    h.vis = nil
    if not HC.solid(side) or not validBody(h.body) then return nil end
    if nat.handSteady == true then return hcolVisual22(side, t, tLive or t) end
    local tgt = TransformToParentTransform(t, Transform(HC.loc(side)))
    if h.lead then tgt = Transform(VecAdd(tgt.pos, h.lead), tgt.rot) end
    h.tgtRel, h.tgtRot = VecSub(tgt.pos, GetPlayerTransform().pos), tgt.rot
    local e = VecLength(VecSub(GetBodyTransform(h.body).pos, tgt.pos))
    if e > HC.GHOST_LINE then drawHandGhost(t) end          -- (at the controller hand: "where your real hand is")
    local w = (HC.var == 1) and clamp((e - HC.E0) / (HC.E1 - HC.E0), 0, 1) or 1
    if w <= 0 then return nil end
    local p = physHandT(side)
    if not p then return nil end
    if w < 1 then p = Transform(VecAdd(t.pos, VecScale(VecSub(p.pos, t.pos), w)), quatToward(t.rot, p.rot, w)) end
    h.vis = p
    return p
end

-- (hcolVisual's NHP_STEADY path, v0.22 section 3.4)
function hcolVisual22(side, t, tl)
    local h = HC[side]
    local tgt = TransformToParentTransform(tl, Transform(HC.loc(side)))
    h.tgtRel, h.tgtRot = VecSub(tgt.pos, GetPlayerTransform().pos), tgt.rot
    local e = VecLength(VecSub(GetBodyTransform(h.body).pos, tgt.pos))
    if e > HC.GHOST_LINE then drawHandGhost(t) end          -- (at the controller hand: "where your real hand is")
    local p = physHandT(side)
    if not p then return nil end
    local dt = HC.vdt or 0
    local f = h.filt
    if not f or VecLength(VecSub(f.pos, p.pos)) > 0.3 then
        f = p
    else
        local a = 1 - math.exp(-HC.OMEGA * dt)
        f = Transform(VecAdd(f.pos, VecScale(VecSub(p.pos, f.pos), a)), quatToward(f.rot, p.rot, a))
    end
    h.filt = f
    local pose
    if h.clampOff and HC.clock - (h.clampAt or -1e9) <= 0.1 then
        h.w = 1
        pose = Transform(VecAdd(tl.pos, h.clampOff), tl.rot)
    else
        local want, w = (h.st == 2) and 1 or 0, h.w or 0
        if w < want then w = math.min(want, w + HC.W_RATE * dt) elseif w > want then w = math.max(want, w - HC.W_RATE * dt) end
        h.w = w
        pose = f
    end
    local w = h.w
    if w <= 0 then return nil end
    local v = pose
    if w < 1 then v = Transform(VecAdd(tl.pos, VecScale(VecSub(pose.pos, tl.pos), w)), quatToward(tl.rot, pose.rot, w)) end
    if HC.visBase and HC.visLive and HC.visBase ~= HC.visLive then
        v = TransformToParentTransform(HC.visBase, TransformToLocalTransform(HC.visLive, v))
    end
    h.vis = v
    return v
end

-- Section 9, every tick from writeStatus: L_HCOL (237) stR + 10 stL + 100 fail + 1e4 selftest + 1e5 impCode + 1e6
-- variant; L_HCOL_ERR (238) median mm * 1e6 + p95 mm * 1e3 + blocked % over the FREE / BLOCKED ticks of the last 5 s (-1
-- none; recomputed every ERR_EVERY s from the ring buffer, written every tick); L_HCOL_EV (239) snaps * 1e6 + ghost
-- entries * 1e3 + static clamps (last 5 s, each <= 999); L_BODY_COL (249) stR + 10 stL + 100 reason + 1000 ground fights
-- + 1e5 sole clearance cm (99 unknown) + 1e7 body turns (last 5 s) + 1e9 shin ghost entries (<= 99) + 1e11 shin snaps
-- (<= 9, both the last 5 s) + 1e12 shin rotation source in the last 5 s (0 none, 1 the leg_lower body, 2 QuatAlignXZ, 3
-- both); L_PHYS_PROBE (250) probe bits + 1000 m0 (999 unknown) + 1e6 current mask (999) + 1e9 round(hand mass * 10)
-- (<= 99) + 1e11 GetPlayerBodies' shapes + 1e13 GetEntityChildren(animator)'s shapes (each <= 98, 99 not measured).
-- (L_BODY_VIS, 243, is written by hideForeignTools.)
function writeDiag21()
    local f = HC.fail
    if f == 0 then
        if not (nat.valid and nat.handCollide) then f = 1
        elseif BV.mp then f = 9
        elseif (nat.handStyle or 0) ~= 2 or hands.failed or hasBit(nat.perf, PF.NO_HANDS) then f = 8
        elseif hands.blkFail then f = 7 end
    end
    HC.why = f
    -- (v0.22 section 2.4: + 1e7 round(impScale * 100) + 1e10 round(ST3b N * 10), 0 not measured)
    W(L6.HCOL, HC.r.st + 10 * HC.l.st + 100 * f + 1e4 * HC.sel + 1e5 * HC.imp + 1e6 * HC.var
        + 1e7 * clamp(math.floor(HC.impScale * 100 + 0.5), 0, 999) + 1e10 * clamp(math.floor(HC.st3bN * 10 + 0.5), 0, 99))
    if HC.errAt == nil or HC.clock - HC.errAt >= HC.ERR_EVERY or HC.clock < HC.errAt then
        HC.errAt = HC.clock
        HC.errTrim()
        local n, cap, errs, blocked = HC.errN, HC.ERR_CAP, {}, 0
        for k = 1, n do
            local i = (HC.errHead + k - 2) % cap + 1
            errs[k] = HC.errMm[i]
            blocked = blocked + HC.errBl[i]
        end
        if n > 0 then
            table.sort(errs)
            local med = (n % 2 == 1) and errs[(n + 1) / 2] or (errs[n / 2] + errs[n / 2 + 1]) * 0.5
            local p95 = errs[math.max(1, math.ceil(n * 0.95))]
            HC.errW = math.min(math.floor(med + 0.5), 999) * 1e6 + math.min(math.floor(p95 + 0.5), 999) * 1e3
                + math.floor(blocked * 100 / n + 0.5)
        else
            HC.errW = -1
        end
    end
    W(L6.HCOL_ERR, HC.errW)
    W(L6.HCOL_EV, math.min(HC.logCount(HC.snapLog, 5), 999) * 1e6 + math.min(HC.logCount(HC.ghostLog, 5), 999) * 1e3
        + math.min(HC.logCount(HC.clampLog, 5), 999))
    local r = BC.off
    if r == 0 then
        if not (nat.valid and nat.bodyCollide) then r = 1
        elseif BV.mp then r = 8
        elseif BC.bonesAnim ~= -1 and not BC.bonesOk then r = 5
        elseif BC.r.st == 5 or BC.l.st == 5 then r = 6 end
    end
    BC.reason = r
    local sole = (BC.r.st >= 1 and BC.r.st <= 4 or BC.l.st >= 1 and BC.l.st <= 4) and BC.sole or 99
    local src = ((HC.clock - BC.srcAt[1] <= 5) and 1 or 0) + ((HC.clock - BC.srcAt[2] <= 5) and 2 or 0)
    W(L8.BODY_COL, BC.r.st + 10 * BC.l.st + 100 * r + 1000 * math.min(BC.fightN, 99) + 1e5 * sole
        + 1e7 * math.min(#BV.turnLog, 99) + 1e9 * math.min(HC.logCount(BC.ghostLog, 5), 99)
        + 1e11 * math.min(HC.logCount(BC.snapLog, 5), 9) + 1e12 * src)
    local cur = engineCall(GetPlayerParam, "CollisionMask")
    PM.cur = (type(cur) == "number" and cur >= 0 and cur <= 255) and cur or -1
    if type(SetBodyGravityScale) == "function" then PM.bit(32) end
    -- (the hand mass capped at 9.9 kg so it never reaches the counts above it; the counts: 99 = not measured)
    local nb = (PM.bodiesN >= 0) and math.min(PM.bodiesN, 98) or 99
    local nk = (PM.kidsN >= 0) and math.min(PM.kidsN, 98) or 99
    W(L8.PHYS_PROBE, PM.bits + 1000 * ((PM.m0 >= 0) and PM.m0 or 999) + 1e6 * ((PM.cur >= 0) and PM.cur or 999)
        + 1e9 * math.min(math.floor(HC.mass * 10 + 0.5), 99) + 1e11 * nb + 1e13 * nk)
    writeDiag22()
end

-- v0.22 (docs/V022_PLAN.md section 5), every tick from writeDiag21: L_HSNAP (235) = the hand snaps of the last 5 s by
-- kind (event + 100 geometric + 1e4 SNAP_NOW + 1e6 SNAP_T + 1e8 teleport, each <= 99) + 1e10 round(the median update
-- order ratio * 100) (<= 999); L_PUNCH (242) = punches in 5 s + 100 max J + 1e5 max vn (dm/s) + 1e8 gated (GAP / toward
-- the player) + 1e10 gain (0 not measured, else round(median gain * 10) + 1, <= 99: a measured 0 - the engine ignoring
-- ApplyBodyImpulse - reads 1, never like 'not measured'; review T22-PUNCH-GAIN-UNTESTED) + 1e12 contact onsets in 5 s
-- (<= 9) + 1e13 max vn over them (dm/s, <= 99);
-- L_BODY_COPY (215, bodyCopyDiag).
function writeDiag22()
    local k = HC.snapK
    local function n5(list, cap) return math.min(HC.logCount(list, 5), cap) end
    local ord = (#HC.order > 0) and clamp(math.floor(median(HC.order) * 100 + 0.5), 0, 999) or 0
    W(L5.HSNAP, n5(k[1], 99) + 100 * n5(k[2], 99) + 1e4 * n5(k[3], 99) + 1e6 * n5(k[4], 99) + 1e8 * n5(k[5], 99)
        + 1e10 * ord)
    local P = PUNCH
    local function trim(list)
        while #list > 0 and list[1][1] < HC.clock - 60 do table.remove(list, 1) end
    end
    trim(P.log)
    trim(P.onsetLog)
    trim(P.skipLog)
    local n, jmax, vmax = 0, 0, 0
    for i = 1, #P.log do
        local r = P.log[i]
        if r[1] > HC.clock - 5 then n, jmax, vmax = n + 1, math.max(jmax, r[2]), math.max(vmax, r[3]) end
    end
    local on, vall = 0, 0
    for i = 1, #P.onsetLog do
        local r = P.onsetLog[i]
        if r[1] > HC.clock - 5 then on, vall = on + 1, math.max(vall, r[2]) end
    end
    local sk = 0
    for i = 1, #P.skipLog do
        if P.skipLog[i][1] > HC.clock - 5 then sk = sk + 1 end
    end
    local gain = (#P.gains > 0) and clamp(math.floor(median(P.gains) * 10 + 0.5), 0, 98) + 1 or 0
    W(L6.PUNCH, math.min(n, 99) + 100 * clamp(math.floor(jmax + 0.5), 0, 999)
        + 1e5 * clamp(math.floor(vmax * 10 + 0.5), 0, 999) + 1e8 * math.min(sk, 99) + 1e10 * gain + 1e12 * math.min(on, 9)
        + 1e13 * clamp(math.floor(vall * 10 + 0.5), 0, 99))
    bodyCopyDiag()
end

-- ---------------------------------------------------------------------------------------------
-- diagnostics
-- ---------------------------------------------------------------------------------------------
-- (TOOL_CODES: see the tool replica section)
function updateDiagnostics()
    if InputPressed("usetool") then diag.usetool = diag.usetool + 1 end
    if InputPressed("grab") then diag.grab = diag.grab + 1 end
    if InputPressed("interact") then diag.interact = diag.interact + 1 end
    if InputPressed("lmb") then diag.lmb = diag.lmb + 1 end
    if InputPressed("rmb") then diag.rmb = diag.rmb + 1 end
    W(L_CNT_USETOOL, diag.usetool); W(L_CNT_GRAB, diag.grab); W(L_CNT_INTERACT, diag.interact)
    W(L_CNT_LMB, diag.lmb); W(L_CNT_RMB, diag.rmb)
    local st = 0
    local body = GetToolBody()
    if GetPlayerCanUseTool() then st = st + 1 end
    if body ~= 0 then st = st + 2 end
    if GetPlayerGrabBody() ~= 0 then st = st + 4 end
    if GetPlayerInteractBody() ~= 0 then st = st + 8 end
    if toolTarget then st = st + 16 end
    if GetPlayerPickBody and GetPlayerPickBody() ~= 0 then st = st + 32 end
    W(L_TOOL_STATE, st)
    toolTarget = nil
end

-- Engine state (why tools may not work), the selected tool and the user's graphics options.
function updateEngineDiagnostics(dt)
    local s = 0
    if GetBool("game.player.interactive") then s = s + 1 end
    if GetBool("game.player.canusetool") then s = s + 2 end
    if GetBool("game.player.cangrab") then s = s + 4 end
    if GetBool("game.player.caninteract") then s = s + 8 end
    if GetBool("game.player.picking") then s = s + 16 end
    if GetBool("game.player.disableinput") then s = s + 32 end
    if GetBool("game.disableinput") then s = s + 64 end
    if IsPlayerDisabled then
        local ok, dis = pcall(IsPlayerDisabled)
        if ok and dis then s = s + 128 end
    end
    local tool = ""
    if GetPlayerTool then tool = GetPlayerTool() or "" else tool = GetString("game.player.tool") end
    local hasTool = tool ~= "" and tool ~= "none"
    if hasTool then s = s + 256 end
    if GetBool("game.thirdperson") then s = s + 512 end
    W(LX.ENGINE_STATE, s)
    W(LX.TOOL_CODE, hasTool and (TOOL_CODES[tool] or 99) or 0)
    perf.optTimer = perf.optTimer + dt
    if perf.optTimer >= 1 then
        perf.optTimer = 0
        local o = 0
        if GetInt("options.gfx.barrel") ~= 0 then o = o + 1 end
        if GetInt("options.gfx.dof") ~= 0 then o = o + 2 end
        if GetInt("options.gfx.motionblur") ~= 0 then o = o + 4 end
        -- the user's head bob / tool sway, also while forced to 0 (v0.5 review F6)
        if (optUserValue(1) or 0) > 0 then o = o + 8 end
        if (optUserValue(2) or 0) ~= 0 then o = o + 16 end
        if GetInt("options.gfx.vsync") ~= 0 then o = o + 32 end
        W(LX.OPTIONS, o)
        W(LX.QUALITY_SCALE, GetInt("options.gfx.quality") * 1000 + GetInt("options.gfx.renderscale"))
    end
    -- update() calls per tick, averaged over ~1 s
    perf.winUpdates = perf.winUpdates + perf.updates
    perf.updates = 0
    perf.winTicks = perf.winTicks + 1
    perf.winTime = perf.winTime + dt
    if perf.winTime >= 1 then
        perf.ups = perf.winUpdates / perf.winTicks
        perf.winUpdates, perf.winTicks, perf.winTime = 0, 0, 0
    end
    W(LX.UPDATES_PER_TICK, perf.ups)
    W(LX.GAME_FPS, GetFps and GetFps() or 0)
end

-- v0.6: the head's heading and pitch in the world (degrees): the forward of the head pose (N_HEAD_P) through the
-- base's rotation (the VR heading bodyYaw). Looking almost straight up or down has no heading: the player's yaw.
function headYawPitch(base)
    local hp = readPose(N_HEAD_P)
    local f = QuatRotateVec(base.rot, QuatRotateVec(Quat(hp[4], hp[5], hp[6], hp[7]), Vec(0, 0, -1)))
    local yaw, pitch = yawPitchOf(VecNormalize(f))
    if f[1] * f[1] + f[3] * f[3] < 0.01 then yaw = GetPlayerYaw() end
    return yaw, pitch
end

-- v0.6 L_WALK_YAW: the player's yaw minus the head's (signed) while walking (> 0.3 m/s horizontally); kept otherwise.
function updateWalkYaw(headYaw)
    local v = GetPlayerVelocity()
    if v[1] * v[1] + v[3] * v[3] > 0.09 then jump.walkYaw = angleDiff(GetPlayerYaw(), headYaw) end
    W(L2.WALK_YAW, jump.walkYaw)
end

-- Aim the player's own look direction (which built-in tools, grabbing and interacting use) and put the
-- tool in the hand. Hand mode: the player looks from its eye at the point the controller laser hits,
-- so engine hits land where the laser points. v0.8 (docs/V08_PLAN.md section 2): the yaw only in precise moments
-- (setPlayerAim); the v0.6 move_dir = head look (the player turned to the head in lazy aim so that walking followed
-- the view, blended over 0.2 s) is gone: native rotates the left stick by the head instead (input.cpp, from
-- L_BASE_YAW and L_PLAYER_YAW), so walking needs no player turn at all.
local function updateAimAndTool(cam, base, held, dt)
    local leftHanded = nat.leftHanded == 1
    local aimBit = leftHanded and 2 or 8
    local gripBit = leftHanded and 1 or 4
    local hv = ctl.hv
    local aimed = false
    local precise, situation = preciseAim(dt)
    local noAim = hasBit(nat.perf, PF.NO_AIM)
    local headYaw = headYawPitch(base)
    aimState.since = aimState.since + dt

    if nat.aimMode == 1 and hasBit(hv, aimBit) then
        local hand = localToWorld(base, leftHanded and ctl.laim or ctl.raim, nat.worldScale)
        local dir = VecNormalize(QuatRotateVec(hand.rot, Vec(0, 0, -1)))
        local origin = hand.pos
        local dist = 100
        if not hasBit(nat.perf, PF.NO_LASER) then
            -- The carried object is held on the look ray; the laser must pass through it, or the aim would
            -- chase the object (the game's own scripts reject the grabbed body the same way). Same for the
            -- gloves, the v0.6 tool replica and the bodies the hands hold. Filters apply to the next query only, so
            -- they are set right before it.
            local gb = GetPlayerGrabBody()
            if gb ~= 0 then QueryRejectBody(gb) end
            rejectOwnBodies(true)
            -- (v0.10, docs/V010_PLAN.md section 2: nor the player's own animated body, which a hand-held laser starting
            -- beside the chest can graze; guarded, older builds lack QueryRejectPlayer)
            engineCall(QueryRejectPlayer)
            local hit, d = QueryRaycast(origin, dir, 100)
            if hit then dist = d end
        end
        local target = VecAdd(origin, VecScale(dir, dist))
        if nat.laser == 1 and not hasBit(nat.perf, PF.NO_LASER) then laserTarget = target end
        local eyePos = GetPlayerEyeTransform().pos
        local toTarget = VecSub(target, eyePos)
        if VecLength(toTarget) > 0.3 and not noAim then
            -- Look from the eye at the laser hit, so the game's look ray (tools, grab, interact) goes
            -- through exactly the point the laser marks, near or far. Only a hit almost straight
            -- below/above the eye (< 0.4 m horizontally) has an unstable heading: blend to the hand's
            -- own heading there.
            local tyaw, pitch = yawPitchOf(VecNormalize(toTarget))
            local horiz = math.sqrt(toTarget[1] * toTarget[1] + toTarget[3] * toTarget[3])
            local hlen = math.sqrt(dir[1] * dir[1] + dir[3] * dir[3])
            local yaw = tyaw
            if horiz < 0.4 then
                if hlen > 0.1 then
                    local hyaw = yawPitchOf(Vec(dir[1] / hlen, 0, dir[3] / hlen))
                    local w = clamp((horiz - 0.15) / 0.25, 0, 1)
                    yaw = hyaw + angleDiff(tyaw, hyaw) * w
                else
                    yaw = GetPlayerYaw()   -- pointing straight down: keep the current heading
                end
            end
            setPlayerAim(yaw, pitch, precise, situation)
            aimed = true
        end
        if hasBit(hv, gripBit) and not hasBit(nat.perf, PF.NO_TOOL) then
            placeToolInHand(cam, base, held, dt)
        end
    elseif nat.aimMode == 0 and not noAim then
        -- Head aim: aim along the render camera's axis, where the game draws its crosshair (the camera
        -- is the head direction pitched by the small shared offset the native part applies).
        local fwd = QuatRotateVec(cam.rot, Vec(0, 0, -1))
        local yaw, pitch = yawPitchOf(VecNormalize(fwd))
        setPlayerAim(yaw, pitch, precise, situation)
        aimed = true
    end
    updateWalkYaw(headYaw)
    return aimed
end

-- Tool switching with the right stick (flick down = next tool, up = previous). Uses the same order
-- as the game's own HUD (enabled, selectable tools sorted by group, then index) and the same locks.
local lockToolFrames = 1000   -- frames since game.input.locktool was last seen (read in draw, after all ticks)

local function cycleTool(dir)
    if lockToolFrames < 3 or GetBool("game.input.locktool") or GetBool("game.player.grabbing")
        or GetBool("game.vehicle.interactive") then
        return
    end
    local cur = string.lower(GetString("game.player.tool"))
    local lockedGroup = nil
    if GetBool("game.player.toolselectlocked") and cur ~= "" and cur ~= "none" then
        lockedGroup = GetInt("game.tool." .. cur .. ".group")
    end
    local list = {}
    local ids = ListKeys("game.tool")
    for i = 1, #ids do
        local id = ids[i]
        local k = "game.tool." .. id
        local ok = GetBool(k .. ".enabled") and (not HasKey(k .. ".selectable") or GetBool(k .. ".selectable"))
        if lockedGroup and GetInt(k .. ".group") ~= lockedGroup then ok = false end
        if ok or string.lower(id) == cur then
            list[#list + 1] = { id = id, index = GetInt(k .. ".index"), group = GetInt(k .. ".group"), ok = ok }
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.index < b.index
    end)
    local pos = 0
    for i = 1, #list do
        if string.lower(list[i].id) == cur then pos = i break end
    end
    if pos == 0 then pos = (dir > 0) and 0 or (#list + 1) end
    -- step to the next selectable tool (the current one may be in the list only to find our place)
    for _ = 1, #list do
        pos = pos + dir
        if pos < 1 then pos = #list elseif pos > #list then pos = 1 end
        if list[pos].ok then
            if string.lower(list[pos].id) ~= cur then
                SetString("game.player.tool", list[pos].id)
                pulse((nat.leftHanded == 1) and 1 or 2, 0.2, 0.02)
            end
            return
        end
    end
end

local function updateToolSwitch()
    local ry = nat.rstickY or 0
    local rx = nat.rstickX or 0
    if snapArmed and math.abs(ry) > 0.7 and math.abs(ry) > math.abs(rx) then
        snapArmed = false
        if ry < 0 then cycleTool(1) else cycleTool(-1) end
    end
end

-- Re-arm the right stick once it is back near the centre (shared by snap turn and tool switching).
local function rearmRightStick()
    local rx, ry = nat.rstickX or 0, nat.rstickY or 0
    if rx * rx + ry * ry < 0.09 then snapArmed = true end
end

-- v0.6 jump (docs/V06_PLAN.md section 4), every tick before the aim: counts InputPressed("jump"); on an A press
-- (N_BUTTONS bit0 edge) while VR controls the view on foot it arms the yaw teleport protection (0.7 s, see
-- setPlayerAim) and watches 3 ticks: if the game did not jump (no InputPressed("jump"), vertical velocity < 0.5 m/s)
-- and the player is on the ground, jump_assist (N_JUMP_ASSIST) adds 4.6 m/s upwards. L_JUMP = jumps*1000 + assists.
-- v0.6 review F5: the A edge means "jump" only while A is bound to the jump key (N_CAM_OPTS bit1, from the ini's
-- bind_a): otherwise neither the guard nor the assist act (every A press would launch the player). v0.8: the assist
-- also acts while IsPlayerGrounded is unavailable (playerGrounded nil) and the vertical velocity is ~0 (< 0.1 m/s);
-- L_GAME_INPUT_SEEN counts the ticks in which the game's own jump / crouch input is down (jump.gi, every tick).
-- v0.10 (docs/V010_PLAN.md section 3): the v0.9 headset session had the game see jump once and no assist at all, cause
-- unknown, so every stage is counted (L_JUMP_A: A edges seen here * 1000 + assists; L_JUMP_WHY: why the last A edge got
-- no assist; L_GROUND: what said grounded at its decision) and the assist is more robust: it watches 2 ticks (the edge's
-- tick and the next; v0.9: 3) and "grounded" is IsPlayerGrounded() == true OR our own ground probe (groundProbe; the
-- v0.8 rule "IsPlayerGrounded unavailable and vertical velocity ~0" is replaced by the probe).
function updateJump(dt, flags)
    local j = jump
    if hasBit(j.gi, 16) then j.seenJump = j.seenJump + 1 end
    if hasBit(j.gi, 64) then j.seenCrouch = j.seenCrouch + 1 end
    W(L3.GAME_INPUT_SEEN, j.seenJump * 1000 + math.min(j.seenCrouch, 999))
    local pressed = InputPressed and InputPressed("jump") == true
    if pressed then j.jumps = j.jumps + 1 end
    local a = nat.valid and hasBit(nat.raw[N_BUTTONS] or 0, 1)
    local edge = a and not j.aDown
    j.aDown = a
    if edge then j.aEdges = j.aEdges + 1 end
    -- (v0.12, docs/V012_PLAN.md section 3: L_JUMP_VMAX, the highest vertical velocity within 0.6 s after the last A edge,
    -- the edge's tick included: how high a short press really jumps; the assist's own velocity shows from the next tick)
    local vy = GetPlayerVelocity()[2] * 100
    if edge then
        j.vT, j.vmax = 0, vy
    elseif j.vT then
        j.vT = j.vT + dt
        if j.vT <= 0.6 then j.vmax = math.max(j.vmax, vy) else j.vT = nil end
    end
    W(L6.JUMP_VMAX, j.vmax)
    j.guard = math.max(0, j.guard - dt)
    local grounded = playerGrounded()
    if grounded == false then j.air = j.air + dt else j.air = 0 end
    if not active or hasBit(flags, LF_VEHICLE) or not hasBit(nat.camOpts, 2) then
        -- (an edge here, or one still watched when VR stops / the player enters a vehicle: 5; A not bound: 4)
        if edge or j.wait > 0 then j.why = (not active or hasBit(flags, LF_VEHICLE)) and 5 or 4 end
        -- (v0.16 review LUA16-TELEPORT-JUMP-INPUT: with A not bound to jump the guard is kept - armed by the game's own
        -- jump input below, it runs out on its own; VR off or a vehicle still drops it)
        j.wait = 0
        if not active or hasBit(flags, LF_VEHICLE) then j.guard = 0 end
    else
        if edge then j.guard, j.wait, j.why = 0.7, 2, 6 end
        if j.wait > 0 then
            local v = GetPlayerVelocity()
            if pressed or v[2] >= 0.5 then
                j.wait, j.why = 0, 1           -- the game jumped
                jumpGround()
            else
                j.wait = j.wait - 1
                if j.wait == 0 then
                    local ok = jumpGround()
                    if nat.jumpAssist ~= 1 then
                        j.why = 3
                    elseif not ok then
                        j.why = 2
                    else
                        SetPlayerVelocity(Vec(v[1], math.max(v[2], 0) + 4.6, v[3]))
                        j.assists, j.why = j.assists + 1, 0
                    end
                end
            end
        end
    end
    -- v0.16 review LUA16-TELEPORT-JUMP-INPUT: the game's own jump press (InputPressed, or the jump input's down edge)
    -- arms the 0.7 s yaw teleport guard whatever the jump is bound to - not only an A press with A bound to space - so
    -- the ticks between the press and lift-off (still grounded) get no teleport either. No assist from it (the assist
    -- rules stay as specified: A edges only).
    local ji = hasBit(j.gi, 16)
    if active and not hasBit(flags, LF_VEHICLE) and (pressed or (ji and not j.jiDown)) then
        j.guard = math.max(j.guard, 0.7)
    end
    j.jiDown = ji
    W(L2.JUMP, j.jumps * 1000 + j.assists)
    W(L4.JUMP_A, math.min(j.aEdges, 999) * 1000 + math.min(j.assists, 999))
    W(L4.JUMP_WHY, j.why)
    W(L4.GROUND, j.ground)
end

-- v0.10 (section 3): "grounded" for the jump assist at an A edge's decision, also recorded in jump.ground (L_GROUND = own
-- probe * 10 + IsPlayerGrounded: 0 false, 1 true, 2 unavailable). The API is taken raw (pcall; true is never overruled,
-- playerGrounded's 5 s ladder verdict only turns false into unknown). Returns IsPlayerGrounded() == true or the probe.
function jumpGround()
    local api = 2
    if IsPlayerGrounded then
        local ok, g = pcall(IsPlayerGrounded)
        if ok and g == true then api = 1 elseif ok and g == false then api = 0 end
    end
    local own = groundProbe()
    jump.ground = (own and 10 or 0) + api
    return api == 1 or own
end

-- v0.10 (section 3) our own ground probe: QueryRequire("physical"), the player and our own bodies rejected, a ray from the
-- player's feet + up * 0.25 down 0.45 m (a step's height below the feet; up = GetPlayerUp, guarded as in attachEye).
-- true = it hits something.
function groundProbe()
    if not QueryRaycast then return false end
    local up = Vec(0, 1, 0)
    local u = engineCall(GetPlayerUp)
    if type(u) == "table" and type(u[3]) == "number" and VecLength(u) > 0.5 then up = VecNormalize(u) end
    engineCall(QueryRequire, "physical")
    engineCall(QueryRejectPlayer)
    -- (v0.10 review lua-jump-1: also the bodies the physical hands hold and the body the engine carries: an object the
    -- player holds under the feet is not ground, or every A press in mid-air would be assisted)
    rejectOwnBodies(true)
    local gb = engineCall(GetPlayerGrabBody)
    if type(gb) == "number" and gb ~= 0 then QueryRejectBody(gb) end
    return engineCall(QueryRaycast, VecAdd(GetPlayerTransform().pos, VecScale(up, 0.25)), VecScale(up, -1), 0.45) == true
end

local function updateHaptics(dt)
    local toolHand = (nat.leftHanded == 1) and 1 or 2
    if InputPressed("usetool") and GetPlayerCanUseTool() then pulse(toolHand, 0.35, 0.04) end
    if InputDown("usetool") and GetPlayerCanUseTool() then
        useToolTimer = useToolTimer + dt
        if useToolTimer > 0.12 then useToolTimer = 0; pulse(toolHand, 0.12, 0.05) end
    else
        useToolTimer = 0
    end
    local grab = GetPlayerGrabBody()
    if grab ~= 0 and lastGrab == 0 then pulse(toolHand, 0.3, 0.03) end
    lastGrab = grab
    if GetEventCount("playerhurt") > 0 then pulse(1, 0.6, 0.12); pulse(2, 0.6, 0.12) end
    if GetEventCount("explosion") > 0 then pulse(1, 0.4, 0.1); pulse(2, 0.4, 0.1) end
end

-- VR heading bookkeeping when the camera override starts or stops.
function updateHeading(isActive, wasActive)
    if isActive and not wasActive then
        if not headingSet then
            -- First activation: make the current head direction match where the player looks.
            local hp = readPose(N_HEAD_P)
            local f = QuatRotateVec(Quat(hp[4], hp[5], hp[6], hp[7]), Vec(0, 0, -1))
            local headYaw = 0
            if f[1] * f[1] + f[3] * f[3] > 1e-4 then headYaw = yawPitchOf(VecNormalize(Vec(f[1], 0, f[3]))) end
            bodyYaw = GetPlayerYaw() - headYaw
            headingSet = true
        elseif lastActiveYaw then
            -- Resuming after pause/map/menus: keep the world where it was, but follow any rotation a
            -- script applied to the player meanwhile (respawn, teleport).
            bodyYaw = bodyYaw + angleDiff(GetPlayerYaw(), lastActiveYaw)
        end
    elseif wasActive and not isActive then
        lastActiveYaw = GetPlayerYaw()
    end
end

-- Vehicle enter/exit heading bookkeeping. Called first by both updateActive and render(), so whichever
-- sees the change first applies it before computing a camera.
function updateVehicleHeading(flags)
    local inVehicle = hasBit(flags, LF_VEHICLE)
    if inVehicle and not wasInVehicle then vehicleYawOffset = 0 end   -- a new ride starts facing forward
    if not inVehicle and wasInVehicle and lastVehicleBaseYaw then
        bodyYaw = lastVehicleBaseYaw    -- keep looking the same way when leaving the vehicle
    end
    wasInVehicle = inVehicle
    return inVehicle
end

-- Eye source (L_EYE_SRC, read by playerEyePos). If GetPlayerEyeTransform() follows our camera offset, a VR
-- base built from it adds the offset again every frame and the view walks away from the body (the probes
-- cannot see it, since the image still equals C). The v0.4 headset test showed it (7.5 cm eye drift while
-- SetPlayerCameraOffsetTransform was measured, none with SetCameraOffsetTransform). eyeSrc.off is the world
-- translation of the offset the engine composed last (submitCamera). Each tick, with drift = raw eye minus the
-- player position (horizontal):
-- * |drift - off| < 1 cm with |off| > 1 cm for 10 ticks: the eye contains exactly our offset -> eye - off (1);
--   10 ticks that contradict it (no fit with an informative offset, or a decontaminated height far from the
--   learned one) or a clean raw eye with an informative offset drop it again;
-- * otherwise the raw eye (0) while the drift is small, else the player x/z with the eye height (2, the v0.4
--   fallback), or, once a standing eye height has been learned (source 0 ticks with a drift <= 1 cm and source 1
--   ticks, on foot, not crouching) and the
--   player is not crouching, the player position + that height (3). Hysteresis (v0.5 review): the fallback starts
--   after 5 ticks with a drift > 1 cm (at once when the drift fits our offset) and ends after 30 ticks with a
--   drift < 0.3 cm in which the offset was
--   informative (or there was none), so the base does not jump between the two every tick. While method 3 composes
--   the offset (SetPlayerCameraOffsetTransform, which moved the eye in the v0.4 test) the raw eye is not trusted
--   until those 30 ticks have shown it clean: its height could contain the offset's vertical part.
-- L_EYE_DRIFT keeps its v0.4 meaning (raw horizontal drift, cm); L_EYE_FIT = |drift - off| (cm), -1 n/a (render()
-- replaces it with its own fit, see eyeSourceRender).
function updateEyeSource(flags)
    local s = eyeSrc
    local e, p = GetPlayerEyeTransform().pos, GetPlayerTransform().pos
    local dx, dz = e[1] - p[1], e[3] - p[3]
    local drift = math.sqrt(dx * dx + dz * dz) * 100
    local o = s.off
    local ofs = o and math.sqrt(o[1] * o[1] + o[3] * o[3]) * 100 or 0
    s.fit = -1
    if o then
        local fx, fz = dx - o[1], dz - o[3]
        s.fit = math.sqrt(fx * fx + fz * fz) * 100
    end
    local crouch = false
    if GetPlayerCrouch then
        local ok, c = pcall(GetPlayerCrouch)
        crouch = ok and type(c) == "number" and c > 0.05
    end
    local trueY = e[2] - (o and o[2] or 0)
    local heightOk = s.heightN < 30 or crouch or math.abs(trueY - p[2] - s.height) < 0.1
    local informative = ofs > 1
    local fits = s.fit >= 0 and s.fit < 1 and heightOk
    if fits and informative then s.run = s.run + 1 else s.run = 0 end
    if s.run >= 10 then s.latched = true end
    if s.latched then
        if fits or (not informative and heightOk) then s.miss = 0 else s.miss = s.miss + 1 end
        if s.miss >= 10 or (drift < 0.5 and informative) then s.latched, s.miss = false, 0 end
    end
    if cal.used == 3 and s.used ~= 3 then s.bad, s.lo = true, 0 end   -- method 3 starts: raw eye unproven
    s.used = cal.used
    if drift > 1 then s.hi = s.hi + 1 else s.hi = 0 end
    if drift < 0.3 and (informative or not o) then s.lo = s.lo + 1 else s.lo = 0 end
    if s.hi >= 5 or (fits and informative) then s.bad = true elseif s.lo >= 30 then s.bad = false end
    s.fb = (s.heightN >= 30 and not crouch) and 3 or 2
    if s.latched then s.src = 1
    elseif s.bad then s.src = s.fb
    else s.src = 0 end
    if (s.src == 1 or (s.src == 0 and s.hi == 0)) and not crouch and not hasBit(flags, LF_VEHICLE) then
        local h = ((s.src == 1) and trueY or e[2]) - p[2]
        s.height = s.height and (s.height + (h - s.height) * 0.05) or h
        s.heightN = s.heightN + 1
    end
    s.use, s.useOff, s.teleAt = s.src, s.off, aimState.teleports
    W(LX.EYE_DRIFT, drift)
    -- (v0.9: 4 = "model", the base comes from attachEye while attach is in use; the sources above keep being tracked
    -- for the other users of playerEyePos and for a fallback to method 2)
    W(L2.EYE_SRC, (cal.method == 4 and not hasBit(flags, LF_VEHICLE)) and 4 or s.src)
    W(L2.EYE_FIT, s.fit)
end

-- render(), on foot, before anything uses the eye: re-checks source 1 where it is used (v0.5 review). tick checked
-- the eye against the last render's offset; if the engine recomputes the eye between tick and render with the offset
-- tick just sent, render's eye contains that one instead (in stereo the other eye's: the base would be off by the
-- IPD and the probes cannot see it). Of the two, the offset that explains the raw eye within 1 cm is subtracted;
-- if neither does, render uses the fallback source. L_EYE_FIT then holds render's fit (cm).
function eyeSourceRender()
    local s = eyeSrc
    if s.src ~= 1 then return end
    local e, p = GetPlayerEyeTransform().pos, GetPlayerTransform().pos
    local best, bo = nil, nil
    for i = 1, 2 do
        local o = (i == 1) and s.off or s.tickOff
        if o then
            local fx, fz = e[1] - p[1] - o[1], e[3] - p[3] - o[3]
            local f = math.sqrt(fx * fx + fz * fz) * 100
            if not best or f < best then best, bo = f, o end
        end
    end
    s.rfit = best or -1
    if best and best < 1 then s.use, s.useOff = 1, bo else s.use, s.useOff = s.fb, nil end
    W(L2.EYE_FIT, s.rfit)
end

-- Game options forced while VR controls the view (N_FIX_OPTIONS bit0 head bob, bit1 tool sway): render() cancels
-- the head bob only while it composes on the player camera (not when that contains our own offset, see
-- renderCameraFrame), and tick never does; tool sway moves the tool away from the hand. The user's value is kept
-- in this Lua state and in savegame.mod (so a quit or crash with the forced value in place is repaired at the next
-- script start). Restored after 2 s without VR (wall clock:
-- the game's dt may stand still in menus), at once when the game is paused, in a menu level or the player is dead
-- (the user may open the options or quit from there), when VR is switched off (F10, N_MODE 0) or the bit is
-- cleared. A script start decides once the native part has found the new table (a fresh table reads 0 until then)
-- or after 3 s without it: VR active then (a quickload while VR runs) adopts the stored value, otherwise it is
-- restored. A restore writes the original only while the option still reads our forced 0; any other value is the
-- user's change and is kept (v0.5 review O1). Likewise a non-zero value found when forcing again that differs
-- from the stored one is the user's new choice: it becomes the original. Every engine call is guarded: a refused
-- write is only reported (L_OPT_WRITE: bit0/2 write attempted, bit1/3 reads 0 now, bit4 restored) and retried once
-- per second. L_OPT_ORIG publishes the stored originals, and L_OPTIONS shows the user's values while forced.
local optFix = {
    keys = { { key = "options.input.headbob", save = "savegame.mod.tdvr.orig_headbob" },
             { key = "options.input.toolsway", save = "savegame.mod.tdvr.orig_toolsway" } },
    orig = {}, retry = { 0, 0 }, tried = { false, false }, idle = 0, started = false, restored = false,
    idleSince = nil,   -- os.clock() when VR stopped controlling the view (nil: active, or no os.clock)
    bootAt = nil, boot = 0,   -- script start (os.clock) / seconds since it, for the startup decision's 3 s grace
}

function optGet(key)
    if not GetInt then return nil end
    local ok, v = pcall(GetInt, key)
    if ok and type(v) == "number" then return v end
    return nil
end

function optSet(key, v)
    if SetInt then pcall(SetInt, key, v) end
end

function optHasSaved(key)
    if not HasKey then return false end
    local ok, v = pcall(HasKey, key)
    return ok and v == true
end

-- Writes the original back only while the option still reads 0 (our forced value; nil: cannot read, written anyway).
-- Any other value is the user's own change (options menu while paused, or before this script ran): adopted, the
-- stored key cleared, nothing written.
function optRestore(i)
    local k, v = optFix.keys[i], optFix.orig[i]
    if v == nil then return end
    local cur = optGet(k.key)
    if cur ~= nil and cur ~= 0 then
        if ClearKey then pcall(ClearKey, k.save) end
    else
        optSet(k.key, v)
        if optGet(k.key) == v then
            optFix.restored = true
            if ClearKey then pcall(ClearKey, k.save) end   -- kept if the write was refused: retried at the next start
        end
    end
    optFix.orig[i], optFix.tried[i], optFix.retry[i] = nil, false, 0
end

-- The user's own value of option i: the stored original while it is forced, else what the game has (nil: unknown).
function optUserValue(i)
    local v = optFix.orig[i]
    if v ~= nil then return v end
    return optGet(optFix.keys[i].key)
end

function updateGameOptions(dt, flags)
    local f = optFix
    local fix = nat.valid and (nat.fixOptions or 0) or 0
    local now = perf.clock
    if not f.started then
        if now then
            f.bootAt = f.bootAt or now
            f.boot = now - f.bootAt
        else
            f.boot = f.boot + dt
        end
    end
    if not f.started and (perf.alive or f.boot >= 3) then   -- (v0.5 review O2: not on the fresh table's first tick)
        f.started = true
        for i = 1, 2 do
            if optHasSaved(f.keys[i].save) then
                f.orig[i] = optGet(f.keys[i].save)
                if not active then optRestore(i) end
            end
        end
    end
    if active then
        f.idle, f.idleSince = 0, nil
    elseif now then
        f.idleSince = f.idleSince or now
        f.idle = now - f.idleSince
    else
        f.idle = f.idle + dt
    end
    local vrOff = perf.alive and nat.mode == 0
    -- states the level can be left from (pause menu, menu level, death screen): restore at once (v0.5 review F1)
    local paused = hasBit(flags, LF_PAUSED) or hasBit(flags, LF_MENU_LEVEL) or hasBit(flags, LF_DEAD)
    local bits = 0
    for i = 1, 2 do
        local k = f.keys[i]
        if active and hasBit(fix, i) then
            local v = optGet(k.key)
            f.retry[i] = f.retry[i] - dt
            if v and v ~= 0 and f.retry[i] <= 0 then
                f.retry[i] = 1
                if f.orig[i] ~= v then          -- first time, or changed since it was forced (the user's choice)
                    f.orig[i] = v
                    optSet(k.save, v)
                end
                optSet(k.key, 0)
                f.tried[i], f.restored = true, false
            end
        elseif f.orig[i] ~= nil and (active or vrOff or paused or f.idle >= 2) then
            optRestore(i)
        end
        if f.tried[i] then bits = bits + ((i == 1) and 1 or 4) end
        if optGet(k.key) == 0 then bits = bits + ((i == 1) and 2 or 8) end
    end
    if f.restored then bits = bits + 16 end
    W(L2.OPT_WRITE, bits)
    -- the stored originals, so the native log keeps them (v0.5 review O4): headbob*100 + toolsway, -1 none
    if f.orig[1] ~= nil or f.orig[2] ~= nil then
        W(L2.OPT_ORIG, (optUserValue(1) or 0) * 100 + (optUserValue(2) or 0))
    else
        W(L2.OPT_ORIG, -1)
    end
end

-- ---------------------------------------------------------------------------------------------
-- v0.9 camera method attach (docs/V09_PLAN.md section 1) and the walk direction diagnostic (section 3)
-- ---------------------------------------------------------------------------------------------
-- Section 1.2: the VR base's eye while attach is in use on foot (nil otherwise: computeBase uses playerEyePos). Nothing
-- the camera can contaminate: the player position + GetPlayerUp() * (1.7 - 0.85 * crouch) (data/script/toolanimation.lua:
-- standing eye 1.7 m, crouched 0.85 m), crouch = GetPlayerCrouch() clamped to 0..1 (guarded; unavailable: 0). With the
-- camera attached to the world, GetPlayerEyeTransform / GetPlayerCameraTransform may follow our camera (the v0.4 eye
-- drift) and a base built from them would feed back; L_ATT_EYEDIFF shows how far the model is from the engine's camera.
function attachEye()
    if cal.method ~= 4 then return nil end
    return modelEye()
end

-- v0.22 (docs/V022_PLAN.md section 1.8): the model eye in any camera method (the body's head offset, bodyMode).
function modelEye()
    local up = Vec(0, 1, 0)
    if GetPlayerUp then
        local ok, u = pcall(GetPlayerUp)
        if ok and type(u) == "table" and type(u[3]) == "number" and VecLength(u) > 0.5 then up = VecNormalize(u) end
    end
    local crouch = 0
    if GetPlayerCrouch then
        local ok, c = pcall(GetPlayerCrouch)
        if ok and type(c) == "number" and c == c then crouch = clamp(c, 0, 1) end
    end
    return VecAdd(GetPlayerTransform().pos, VecScale(up, 1.7 - 0.85 * crouch))
end

-- Section 1.1: wb = GetWorldBody(), W = its transform (normally identity), O = W^-1 * C; AttachCameraTo(wb, false),
-- SetCameraFov(hfov), SetCameraOffsetTransform(O, false) (script_defs.lua: "attach current camera transform for this
-- frame to body or shape ... place camera around any body or shape without lag"). Every call guarded. Returns O and W,
-- nil if a function is missing or fails (the caller falls back: att state 5).
function attachSubmit(cam)
    if not (GetWorldBody and AttachCameraTo and GetBodyTransform and SetCameraOffsetTransform and SetCameraFov) then
        return nil
    end
    local ok, wb = pcall(GetWorldBody)
    if not ok or type(wb) ~= "number" then return nil end
    local okW, w = pcall(GetBodyTransform, wb)
    if not okW or type(w) ~= "table" or type(w.pos) ~= "table" or type(w.rot) ~= "table" then return nil end
    local o = TransformToLocalTransform(w, cam)
    if not pcall(AttachCameraTo, wb, false) or not pcall(SetCameraFov, nat.hfov)
        or not pcall(SetCameraOffsetTransform, o, false) then return nil end
    return o, w
end

-- (Re)starts attach (state 1 on the first request, 6 after an inconclusive blame check): method 4, fresh view check.
function attachRestart()
    cal.method, cal.world, cal.tickO, cal.renderO = 4, false, nil, nil
    att.errs, att.n, att.bad, att.dead, att.ok = {}, 0, 0, 0, 0
    att.eyeDiffs, att.aimVsCam = {}, {}   -- (v0.9 review SPEC-4: the new trial's medians from its own frames only)
    att.failErr = nil
end

-- A failure (3 view, 4 tools, 5 API missing) switches THIS script instance to method 2 (offset, local) with all the v0.8
-- behaviour; the next level / quickload is a new script instance and starts with attach again.
function attachFail(state)
    -- (v0.9 review ATT-4: a view failure keeps its median for L_ATT_VIEWERR: it happens ~1.5 s into a level and the
    -- native [lua2] line, written every few seconds, would otherwise never show how bad the attach view was)
    if state == 3 then
        att.failErr = median(att.errs)
        att.viewFails, att.retryT = att.viewFails + 1, 0   -- (v0.22 section 4.2: the retry counts them)
    end
    att.state, att.blame = state, nil
    cal.method, cal.world, cal.tickO, cal.renderO = 2, false, nil, nil
end

-- toolSel = a tool is selected (GetPlayerTool not "" / "none"), alive = the engine has its tool working (a tool body,
-- or GetPlayerCanUseTool; in method 1 the v0.7 log had neither, tool=0x10).
function attachToolState()
    local tool = GetPlayerTool and GetPlayerTool() or GetString("game.player.tool")
    local sel = type(tool) == "string" and tool ~= "" and tool ~= "none"
    return sel, GetToolBody() ~= 0 or GetPlayerCanUseTool() == true
end

-- Section 1.3, tick (VR active, on foot, before this tick's camera). Tool check while attach is in use, not grabbing,
-- the tools not locked by a script (game.input.locktool), not airborne and not in water (v0.9 review lua-aim-2): a
-- selected tool that is not alive for 1.0 s in a row is a tentative failure: method 2 and the BLAME CHECK: the tool
-- alive (on the ground) within 1.5 s in method 2 -> attach really disables the tools (state 4, final); still not
-- alive (the tool was off for another reason) -> attach again (state 6). A second tool
-- failure in this instance is final at once (state 4). Confirm (state 2): 2 s with the tool selected and alive and the
-- view check's median (30 frames) < 2 deg.
function attachTick(dt, flags)
    if cal.mode ~= 4 or hasBit(flags, LF_VEHICLE) then return end
    local sel, alive = attachToolState()
    if att.blame then
        att.blame = att.blame + dt
        -- (v0.9 review lua-aim-2: "alive" convicts attach only on the ground: stepping off a ladder or out of the
        -- water during the blame check would bring the tool back for its own reason)
        if sel and alive and playerGrounded() ~= false then
            attachFail(4)
        elseif att.blame >= 1.5 then
            att.blame, att.state = nil, 6
            attachRestart()
        end
        return
    end
    -- v0.22 (docs/V022_PLAN.md section 4.2): after a view failure (state 3, at most 3 times per script instance) attach
    -- is tried again (state 7, a fresh 30-frame trial) once the ticks have been clean - on foot (this is not called in a
    -- vehicle), not zoomed, the last draw not gated - for ATT_RETRY[viewFails] s in a row; the 4th failure is final.
    -- (review R22-ATT-RETRY-PERSISTENT: a frustum / foreign-camera mismatch the cap stopped gating (att.raw ~= 0 with
    -- gate 0) is no clean tick either - a retry then would only show a bad attach view for another 30 frames)
    if att.state == 3 and att.viewFails <= 3 then
        if active and not attZoomed() and att.gate == 0 and (att.raw or 0) == 0 then att.retryT = att.retryT + dt
        else att.retryT = 0 end
        if att.retryT >= (ATT_RETRY[att.viewFails] or 1e9) then
            att.state, att.retries, att.retryT = 7, att.retries + 1, 0
            attachRestart()
        end
    end
    if cal.method ~= 4 then return end
    -- (v0.22 section 4.1: a scope zoom pauses the tool check - a scoped rifle has no tool body, no tool failure)
    if GetPlayerGrabBody() ~= 0 or attZoomed() or lockToolFrames < 3 or GetBool("game.input.locktool") then
        att.dead, att.ok = 0, 0
        return
    end
    -- (v0.9 review lua-aim-2: also paused while airborne (a ladder: the API has no ladder query, see playerStill) or in
    -- water, the jump guard's / teleportBlocked's predicates: the game may lower the tool there itself, and a second
    -- such stretch would be final for the level; a tool really disabled by attach is caught on the ground)
    if playerGrounded() == false or playerInWater() then
        att.dead, att.ok = 0, 0
        return
    end
    if sel and not alive then att.dead = att.dead + dt else att.dead = 0 end
    if att.dead >= 1 then
        att.dead, att.ok, att.toolFails = 0, 0, att.toolFails + 1
        if att.toolFails >= 2 then attachFail(4) return end
        att.blame = 0
        cal.method, cal.world, cal.tickO, cal.renderO = 2, false, nil, nil
        return
    end
    if att.state ~= 2 and sel and alive and #att.errs >= 30 and median(att.errs) < 2 then att.ok = att.ok + dt
    else att.ok = 0 end
    if att.ok >= 2 then att.state, att.ok = 2, 0 end
end

-- Section 1.3, draw() of a frame whose camera was attached (cal.used 4), e = its record, err = its probe error (< 0: not
-- measured). View check on measured frames: after 30, a median > 3 deg -> state 3; later a rolling 30-frame median > 5
-- deg for 2 s (dt sum) -> state 3. L_ATT_EYEDIFF: |model eye - GetPlayerCameraTransform().pos| (cm; not on a held-base
-- frame, its base is the other eye's). L_AIM_VS_CAM: the angle between GetPlayerAimInfo(eye, 50)'s direction and C's
-- forward, i.e. where the engine fires tools in attach mode (compare L_AIM_ERR, the angle to the player's look).
-- v0.22 (docs/V022_PLAN.md section 4.1): a gated frame (gate ~= 0) keeps the eye diff / aim samples, then counts as no
-- view sample (att.bad 0, nothing into att.errs / att.n).
function attachDraw(e, err, gate)
    if cal.used ~= 4 or not e or not e.bx then return end
    local eye = Vec(e.bx, e.by, e.bz)
    if not e.held then
        local pc = readPlayerCamera()
        if pc then push(att.eyeDiffs, VecLength(VecSub(eye, pc.pos)) * 100, 30) end
    end
    if GetPlayerAimInfo then
        local ok, _, _, _, dir = pcall(GetPlayerAimInfo, eye, 50)
        if ok and type(dir) == "table" and type(dir[3]) == "number" and VecLength(dir) > 0.5 then
            local f = QuatRotateVec(e.rot, Vec(0, 0, -1))
            push(att.aimVsCam, math.deg(math.acos(clamp(VecDot(VecNormalize(dir), f), -1, 1))), 30)
        end
    end
    if gate and gate ~= 0 then att.bad = 0 return end
    if not err or err < 0 or cal.method ~= 4 then return end
    push(att.errs, err, 30)
    att.n = att.n + 1
    local med = median(att.errs)
    if att.n == 30 and med > 3 then attachFail(3) return end
    if att.n > 30 and med > 5 then att.bad = att.bad + perf.lastDt else att.bad = 0 end
    if att.bad >= 2 then attachFail(3) end
end

-- v0.22 (docs/V022_PLAN.md section 4.1): the player looks through a zoom (game.player.tool.zoom > 1.001, the value
-- data/ui/hud.lua reads) or a scope (game.player.tool.scope).
function attZoomed()
    local z = GetFloat("game.player.tool.zoom")
    return (type(z) == "number" and z > 1.001) or GetBool("game.player.tool.scope") == true
end

-- v0.22 (docs/V022_PLAN.md section 4.1), draw() before measureCamera, on foot: is this frame a view sample at all? The
-- v0.21 headset log lost the attach camera for the level to a rifle scope (the 4x zoom narrowed the rendered frustum: the
-- probes, projected with our hfov, read 62.5 deg). Reason (att.gate): 2 zoom - attZoomed(), and for 0.3 s after it
-- (att.zoomEnd); 1 frustum - the measured tangents th / tv more than 3 % off ours (the C++ SubmittedFov check; both 0:
-- not measured); 3 foreign camera - GetCameraTransform() more than 2 m from this frame's camera. 1 / 3 without 2 for more
-- than ATT_GATE_MAX s in a row stop gating until a clean frame (a real failure is still judged as in v0.21). Gated
-- frames are counted (att.gateN); att.narrow = the frustum is > 3 % narrower (the scope_zoom check, flatScopeTick).
function attachGate(e, th, tv, c)
    local a = att
    local z = GetFloat("game.player.tool.zoom")
    a.zoom = (type(z) == "number" and z == z) and z or 0
    local now = HC.clock
    local reason = 0
    if attZoomed() then
        a.zoomEnd, a.zoomTool, reason = now + 0.3, true, 2
    elseif now < a.zoomEnd then
        reason = 2
    end
    local raw = 0
    a.narrow, a.narrowOk = false, false
    if e and e.hfov and e.hfov > 0 and th and tv and th > 0 and tv > 0 then
        local w, h = UiWidth(), UiHeight()
        local tanH = math.tan(math.rad(e.hfov) * 0.5)
        if w > 0 and h > 0 then
            if math.abs(th / tanH - 1) > 0.03 or math.abs(tv / (tanH * h / w) - 1) > 0.03 then raw = 1 end
            a.narrow, a.narrowOk = th < tanH * 0.97, true
        end
    end
    if raw == 0 and e and e.pos and c and c.pos and VecLength(VecSub(c.pos, e.pos)) > 2 then raw = 3 end
    a.raw = raw                         -- (review R22-ATT-RETRY-PERSISTENT: also when capped; the retry waits for 0)
    if reason == 2 then
        a.gateT = 0
    elseif raw ~= 0 then
        a.gateT = a.gateT + (perf.lastDt or 0)
        if a.gateT > ATT_GATE_MAX then a.capped = true end
        if not a.capped then reason = raw end
    else
        a.gateT, a.capped = 0, false
    end
    a.gate = reason
    if reason ~= 0 then a.gateN = a.gateN + 1 end
    return reason
end

-- v0.22 (docs/V022_PLAN.md section 4.3), scope_zoom = no (NCO_FLAT_SCOPE): the picture stays normal while the player
-- aims through a scope. While VR is active on foot with a zoom tool selected (ZOOM_TOOLS, or any tool G2 fired for since
-- it was selected: att.zoomTool, cleared on a tool change), every tick SetToolAllowedZoom(1.0) (guarded; whatever the
-- zoom reads, so a working call never lets the zoom start), and the check: the zoom reading > 1.05 or the measured
-- frustum > 3 % narrower (att.narrow) for 0.5 s in a row -> att.flatFail, no more calls in this Lua state (the gate still
-- protects attach). A narrow frustum counts only when it is NEW (review LUA22-5): narrowBase = the first measurement
-- after the tool was selected, cleared by any normal frame after it - a frustum that was already narrow (a mismatch that
-- has nothing to do with zoom, the v0.21 log's 'measured frustum differs' after a reload) never trips flatFail. The scope overlay (hud.lua draws its ring while game.player.tool.scope is true): the flag is set false
-- in tick, update and draw ("where") while it reads true; whether our clear (from update / tick) still held when our draw
-- read it - the read nearest to hud.lua's draw - or the flag was back is logged (L_ATT_GATE).
function flatScopeTick(where, dt)
    local a = att
    if not (nat.valid and nat.flatScope == true) then return end
    local tool = GetPlayerTool and (GetPlayerTool() or "") or GetString("game.player.tool")
    if tool ~= a.tool then a.tool, a.zoomTool, a.narrowBase = tool, false, nil end
    if not (active and not a.flatFail and not cal.inVehicle and (ZOOM_TOOLS[tool] or a.zoomTool)) then
        if where == "tick" then a.flatBadT = 0 end
        return
    end
    if where == "tick" then
        engineCall(SetToolAllowedZoom, 1.0)
        if a.narrowOk and (a.narrowBase == nil or not a.narrow) then a.narrowBase = a.narrow end
        local z = GetFloat("game.player.tool.zoom")
        local narrow = a.narrow and a.narrowBase == false
        if (type(z) == "number" and z > 1.05) or narrow then a.flatBadT = a.flatBadT + (dt or 0) else a.flatBadT = 0 end
        if a.flatBadT >= 0.5 then a.flatFail = true end
    end
    local on = GetBool("game.player.tool.scope") == true
    if where == "draw" and a.cleared then
        if on then a.backAt = HC.clock else a.heldAt = HC.clock end
        a.cleared = false
    end
    if on then
        a.scopeAt = HC.clock
        SetBool("game.player.tool.scope", false)
        if where ~= "draw" then a.cleared = true end
    end
end

-- ---------------------------------------------------------------------------------------------
-- v0.10 hide the player character and every foreign tool render in attach (docs/V010_PLAN.md section 1)
-- ---------------------------------------------------------------------------------------------
-- The v0.9 headset test showed some tools DOUBLE in attach: the replica in the hand and a second rifle floating at chest
-- height, while GetToolBody()'s shapes carried our "invisible" tag. Most likely, with the camera not at the eye
-- (AttachCameraTo) the engine draws the player character in third person with its held tool; script_defs.lua documents
-- SetPlayerHidden() for exactly such custom cameras. Every tick (after this tick's camera) and in render() (after its
-- camera): while VR is active on foot and this frame's camera was attached (cal.used 4), SetPlayerHidden() (guarded) if
-- hide_player is set (N_CAM_OPTS bit2, NCO_HIDE_PLAYER), and every foreign tool render near the eye is hidden
-- (hideForeignTools, independent of the bit). Anything else: the foreign shapes we hid are shown again.
-- v0.22 (docs/V022_PLAN.md section 1.9): back to v0.20 - SetPlayerHidden whenever hide_player is set (the visible body
-- is our copy, not the engine's character); BV.sph = it was called this tick (the L_BODY_VIS digit; also by
-- updateActive in a vehicle).
function hidePlayer(flags, fromRender)
    local on = active and not hasBit(flags, LF_VEHICLE) and cal.used == 4
    if on and hasBit(nat.camOpts, 4) then
        engineCall(SetPlayerHidden)
        BV.sph = true
    end
    hideForeignTools(on, fromRender)
end

-- One of our own bodies: a glove, the tool replica, or anything tagged tdvr_* (ListTags, guarded; stale copies of an
-- earlier Lua state carry the tags but not our handles).
function isOwnBody(b)
    if isGloveBody(b) or b == replica.body then return true end
    if HasTag and (HasTag(b, "tdvr_hand") == true or HasTag(b, "tdvr_tool") == true or HasTag(b, "tdvr_body") == true) then
        return true                       -- (v0.22: the body copies, tdvr_body=<bone>)
    end
    local tags = engineCall(ListTags, b)
    if type(tags) == "table" then
        for i = 1, #tags do
            if type(tags[i]) == "string" and string.sub(tags[i], 1, 5) == "tdvr_" then return true end
        end
    end
    return false
end

-- on: QueryRequire("tool") and QueryAabbShapes(eye -/+ 2.5 m) around the model eye (attachEye; both guarded). Every shape
-- of a body that is neither ours (isOwnBody) nor GetToolBody() (whose shapes keep the replica logic, hideEngineTool) is
-- tagged "invisible" (again each time: a tool script may clear it) and remembered in replica.foreign like replica.hidden:
-- true = it was visible and we hid it, false = it was already hidden (left alone; true once found shown since). Off: the
-- remembered shapes we hid are untagged (unhideForeignTools). From tick: L_TOOLBODIES / L_TOOLHID.
-- v0.10 review LTH-1 / LUA-TOOLQ-1 / SPEC-1: queries include every layer except tool and player by default
-- (script_defs.lua QueryInclude; the game's own hud.lua pairs QueryRequire with QueryInclude("player tool")), so the
-- query also calls QueryInclude("tool") (guarded) or it would find no tool render at all. Safety (LUA-TOOLQ-1): an engine
-- that ignores the layer filter would list the level around the eye; a list with a shape of GetWorldBody() or more than
-- 256 shapes is only counted (L_TOOLBODIES shows it), nothing is tagged.
-- v0.10 review LTH-3 / SPEC-4: every shape we tag also gets "tdvr_hid" (our ownership survives a quicksave); a shape
-- found with it is ours (foreign true), see unhideForeignTools / clearForeignTags.
-- v0.11 (docs/V011_PLAN.md section 4): the v0.10 headset log had no foreign tool-layer shape near the eye and the second
-- tool still drawn, so the player character's own animator shapes are hidden as well. Each query now calls
-- QueryInclude("tool player animator"). The tool-layer query is the v0.10 one (QueryRequire("tool")); a second box query
-- with QueryRequire("animator") (only while GetPlayerAnimator() ~= 0) lists the animator shapes: one query without a
-- required layer would list the whole level around the eye (the world body: the safety rule would tag nothing), and the
-- tool-layer filter alone never returns the player's body. A shape is hidden if its body is foreign (not ours, not
-- GetToolBody()) AND (it is in the tool layer OR GetBodyAnimator(body) is GetPlayerAnimator()). Shapes of any OTHER
-- animator (robots, NPCs) are never touched, even in the tool layer. Each list has its own safety check (a world-body
-- shape or more than 256 shapes: that list is only counted). The same remember / "tdvr_hid" / untag logic; L_TOOLBODIES /
-- L_TOOLHID count the animator shapes too; L_PLAYERSHAPES = the player-animator shapes we keep hidden this tick.
-- v0.12 (docs/V012_PLAN.md section 1): the v0.11 headset log had the animator query return the player character's 21
-- bodies (with the third-person tool in its hands, the "second tool" moving with the head) and nothing tagged: the list
-- safety rule aborted the ANIMATOR list (it holds world-body shapes), although its per-shape qualification (the body's
-- animator is the player's) is itself safe. Now the tool-layer query is v0.10's exactly (QueryInclude("tool"),
-- QueryRequire("tool"), the list safety rule kept) and the animator query (QueryInclude("player animator"),
-- QueryRequire("animator"), only while GetPlayerAnimator() ~= 0) has NO list-level abort: every shape is checked on its
-- own, a world-body shape is skipped, and only shapes of a foreign body whose animator is the player's are tagged.
-- L_ANIM_FOUND = the player-animator shapes the animator query found this tick (hidden or not).
-- v0.12 review L12-ANIM-DIRECT-SCAN: the player animator's shapes are also scanned directly, GetEntityChildren(
-- GetPlayerAnimator(), "", true, "shape") (script_defs.lua; guarded, a non-table result ignored, a list longer than
-- 1024 shapes ignored): the same per-shape rule as the animator list (foreignScan animOnly), so player-character
-- shapes outside the 2.5 m box or outside the "animator" query layer are hidden too. L_ANIM_FOUND counts each
-- player-animator shape once, whichever source found it (q.animSeen). The direct list never sets the engine-tool digit
-- of L_TOOLBODIES (that is the box query's finding).
-- v0.22 (docs/V022_PLAN.md section 1.9): the v0.21 untag path is gone (the engine re-hid the character every frame):
-- every shape of the engine's character is hidden as in v0.20; the visible body is our copy (bodyCopyShow). Only the
-- proxy shapes are still left as the engine has them while the copy is shown (BV.mode 1 / 2: q.cls = the animator cache
-- BV.cls, -1 a proxy). From tick: BV.hidden and L_BODY_VIS (243; for Lua 22 shown = the copy shapes shown, the 1e7
-- digit the P3 retags / s, + 1e14 ltfix).
function hideForeignTools(on, fromRender)
    local r = replica
    local q = { bodies = 0, engine = 0, anim = 0, animSeen = {} }
    local nPlayer = 0
    local v = BV
    if on then
        local eye = attachEye() or GetPlayerEyeTransform().pos
        local ext = Vec(2.5, 2.5, 2.5)
        q.seen, q.tag, q.done, q.player = {}, {}, {}, {}
        if v.mode == 1 or v.mode == 2 or v.why == 20 then q.cls = v.cls end   -- (shown, or about to be)
        q.tb, q.wb, q.pa = GetToolBody(), engineCall(GetWorldBody), engineCall(GetPlayerAnimator)
        if type(q.pa) ~= "number" then q.pa = 0 end
        engineCall(QueryInclude, "tool")
        engineCall(QueryRequire, "tool")
        foreignScan(engineCall(QueryAabbShapes, VecSub(eye, ext), VecAdd(eye, ext)), q, false)
        if q.pa ~= 0 then
            engineCall(QueryInclude, "player animator")
            engineCall(QueryRequire, "animator")
            foreignScan(engineCall(QueryAabbShapes, VecSub(eye, ext), VecAdd(eye, ext)), q, true)
            -- (v0.12 review L12-ANIM-DIRECT-SCAN: the animator's own shapes, wherever they are)
            local kids = engineCall(GetEntityChildren, q.pa, "", true, "shape")
            if type(kids) == "table" and #kids <= 1024 then foreignScan(kids, q, true, true) end
        end
        for i = 1, #q.tag do
            local s = q.tag[i]
            local tagged = HasTag ~= nil and HasTag(s, "invisible") == true
            local mine = HasTag ~= nil and HasTag(s, "tdvr_hid") == true
            if r.foreign[s] == nil then r.foreign[s] = mine or not tagged
            elseif not tagged then r.foreign[s] = true end
            if not tagged then SetTag(s, "invisible") end
            if r.foreign[s] and not mine then SetTag(s, "tdvr_hid") end
            if q.player[s] and r.foreign[s] then nPlayer = nPlayer + 1 end
        end
    else
        unhideForeignTools()
    end
    if fromRender then return end
    local bodies, engine = q.bodies, q.engine
    r.fBodies, r.fEngine, r.fPlayer = bodies, engine, nPlayer
    local hid = 0
    for s, ours in pairs(r.foreign) do
        if ours and validBody(s) then hid = hid + 1 end
    end
    -- (our replicas alive: a FindBodies scan only every 2 s of game time, the review GLOVE-QUICKLOAD-LEFTOVER rule: no
    -- scene-wide search per tick)
    if r.fRepAt == nil or phys.clock - r.fRepAt >= 2 or phys.clock < r.fRepAt then
        local reps = FindBodies and FindBodies("tdvr_tool", true)
        r.fReps, r.fRepAt = type(reps) == "table" and #reps or 0, phys.clock
    end
    -- (v0.10 review NAT-L4-1: the foreign count is capped at 99 so it cannot spill into the engine / replica digits)
    W(L4.TOOLBODIES, math.min(bodies, 99) + 100 * engine + 10000 * r.fReps)
    W(L4.TOOLHID, hid)
    W(L5.PLAYERSHAPES, nPlayer)
    W(L6.ANIM_FOUND, q.anim)
    -- v0.21 (docs/V021_PLAN.md section 9): L_BODY_VIS = mode + 10 why + 1000 shown + 1e5 hidden + 1e7 (v0.22: the P3
    -- retags / s) (each at most 99) + 1e9 SetPlayerHidden called this tick + 1e10 proxy shapes (<= 99) + 1e12 attachments
    -- shown + 1e13 attachments hidden (each <= 9; the animator cache's counts) + v0.22 1e14 ltfix (<= 9). shown = the
    -- copy shapes shown (BV.shown, bodyCopyShow), hidden = the engine character's shapes we keep hidden.
    v.hidden = nPlayer
    W(L7.BODY_VIS, v.mode + 10 * v.why + 1000 * math.min(v.shown, 99) + 1e5 * math.min(nPlayer, 99)
        + 1e7 * math.min(BCOPY.retags, 99) + 1e9 * (v.sph and 1 or 0) + 1e10 * math.min(v.proxies, 99)
        + 1e12 * math.min(v.att[1], 9) + 1e13 * math.min(v.att[2], 9) + 1e14 * math.min(BCOPY.ltfix, 9))
end

-- v0.11 (section 4): one box query's list (nil: the query failed) into q (see hideForeignTools): GetToolBody() among it ->
-- q.engine 1; every shape of a foreign body (not ours, not tb, not the world body) that qualifies is counted (q.bodies,
-- per body) and, if the list is safe (no world-body shape, at most 256 shapes), queued once in q.tag (q.done = the
-- queued set; q.player[s] = it is a player-animator shape). Qualifies: its body's animator (GetBodyAnimator, guarded;
-- 0 none) is GetPlayerAnimator() (q.pa ~= 0), or, in the tool-layer list (animOnly false), it has no animator.
-- v0.12 (docs/V012_PLAN.md section 1): the animator list (animOnly) is always "safe": a world-body shape in it is only
-- skipped and its length is not limited (each shape qualifies on its own body's animator); q.anim counts its
-- player-animator shapes (L_ANIM_FOUND). The animator is checked before isOwnBody (the cheaper test first; same set).
-- v0.12 review L12-ANIM-DIRECT-SCAN: direct = the list is GetEntityChildren's (no query): GetToolBody() in it does not
-- set q.engine; q.anim counts a shape once over both lists (q.animSeen).
function foreignScan(list, q, animOnly, direct)
    if type(list) ~= "table" then return end
    local safe, pend = animOnly or #list <= 256, {}
    for i = 1, #list do
        local s = list[i]
        local b = engineCall(GetShapeBody, s)
        if type(b) == "number" and b ~= 0 then
            if b == q.tb then
                if not direct then q.engine = 1 end
            elseif b == q.wb then
                if not animOnly then safe = false end
            else
                local a = engineCall(GetBodyAnimator, b)
                if type(a) ~= "number" then a = 0 end
                local player = a ~= 0 and a == q.pa
                if (player or (a == 0 and not animOnly)) and not isOwnBody(b) then
                    if not q.seen[b] then q.seen[b], q.bodies = true, q.bodies + 1 end
                    -- (v0.22 section 1.9: while the copy is shown - q.cls, see hideForeignTools - a proxy shape is left
                    -- as the engine has it; every other player shape is hidden as in v0.20)
                    local c = (player and q.cls) and q.cls[s] or nil
                    if c == -1 then
                        -- (a proxy shape: never tagged, untagged or counted while the body is shown)
                    else
                        pend[#pend + 1] = s
                        if player then q.player[s] = true end
                    end
                    if player and animOnly and not q.animSeen[s] then q.animSeen[s], q.anim = true, q.anim + 1 end
                end
            end
        end
    end
    if not safe then return end
    for i = 1, #pend do
        local s = pend[i]
        if not q.done[s] then q.done[s], q.tag[#q.tag + 1] = true, s end
    end
end

-- Shows the foreign tool shapes we hid again: only those still valid and still tagged (by us: a shape that was already
-- hidden when we found it is never touched), then forgets them all. v0.10 review LTH-3 / SPEC-4: our "tdvr_hid" marker
-- is removed with the tag, and every shape still carrying it (FindShapes, only on this transition) is shown as well.
function unhideForeignTools()
    if next(replica.foreign) == nil then return end
    for s, ours in pairs(replica.foreign) do
        if ours and validBody(s) then
            if HasTag(s, "invisible") == true then RemoveTag(s, "invisible") end
            RemoveTag(s, "tdvr_hid")
        end
    end
    replica.foreign = {}
    clearForeignTags()
end

-- v0.10 review LTH-3 / SPEC-4: untags every shape in the scene that carries our "tdvr_hid" marker ("invisible" and the
-- marker; FindShapes guarded). Once per Lua state (updateToolReplica's r.cleaned block: a quickload restores our tags
-- without replica.foreign) and when attach ends (unhideForeignTools).
function clearForeignTags()
    local list = FindShapes and engineCall(FindShapes, "tdvr_hid", true)
    if type(list) ~= "table" then return end
    for i = 1, #list do
        RemoveTag(list[i], "invisible")
        RemoveTag(list[i], "tdvr_hid")
    end
end

-- v0.10 review LTH-2 / SPEC-2: a shape of the current tool body tb that hideForeignTools hid while it was not
-- GetToolBody() (a tick with GetToolBody() 0, or a tool switch with the old body still near the eye) is handed back to
-- the replica logic: our tag (foreign true, or our "tdvr_hid" marker) is removed and the shape forgotten, so
-- buildToolReplica / hideEngineTool see its real state (visible) instead of "the tool script keeps it hidden".
function adoptForeignToolShapes(tb)
    if tb == 0 then return end
    local shapes = engineCall(GetBodyShapes, tb)
    if type(shapes) ~= "table" then return end
    local r = replica
    for i = 1, #shapes do
        local s = shapes[i]
        local mine = HasTag ~= nil and HasTag(s, "tdvr_hid") == true
        if r.foreign[s] ~= nil or mine then
            if r.foreign[s] == true or mine then
                if HasTag ~= nil and HasTag(s, "invisible") == true then RemoveTag(s, "invisible") end
                RemoveTag(s, "tdvr_hid")
            end
            r.foreign[s] = nil
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- v0.21 the visible body and legs (docs/V021_PLAN.md section 4); v0.22 drawn by our copy (docs/V022_PLAN.md section 1)
-- ---------------------------------------------------------------------------------------------
-- With show_body (N_CAM_OPTS bit3, NCO_SHOW_BODY) the player sees a body and legs: v0.22 (docs/V022_PLAN.md section 1)
-- draws them with COPY bodies spawned from the character's own vox files (BODY_MODELS, bodyCopyBuild) and placed at the
-- engine's bones every render (bodyCopyPlace); the engine's character stays hidden as in v0.20 (hidePlayer,
-- hideForeignTools). bodyMode decides every tick what is shown (BV.mode), bodyCopyShow tags our copies, bodyTurn turns the
-- player (and so the character) toward where the head looks. Without the bit nothing here acts (mode 0, the v0.20
-- behaviour).
-- BV constants: LEAN / DUCK (m) = the head offset from the player column / below the model eye that shows the legs
-- only (mode 2, why 13 / 14), LEAN_ALL (m) = the lean that hides everything (mode 3, why 12), HYS (m) / HYS_DEG (deg) =
-- their hysteresis, EYE_HIDE / EYE_SHOW (m) = the near-eye rule (a shown shape whose box comes this close to the camera
-- is hidden, shown again only beyond EYE_SHOW), YAW (deg) for YAW_T (s) = the head turned this far from the body turns
-- the body, YAW_SNAP (deg) = a bodyYaw change in one tick (snap / smooth turn) that turns it at once, TURN_GAP (s) =
-- between two turns, TURN_WAIT (s) = a wanted turn blocked this long, or body_turn off, with the head more than
-- YAW_LEGS (deg) away -> mode 2 (why 15), WATER_UP (m) = the water test point above the player's feet, BONES =
-- the SHOW bones (1: shown in modes 1 and 2 - pelvis, legs, feet, toes; 2: mode 1 only - stomach, chest), NEED = the
-- bones the character must have (the SHOW ones and head; else why 9).
-- BV state: mode / why (the L_BODY_VIS digits), mp = engineCall(IsMultiplayer) == true this tick (read while any v0.21
-- part is wanted; only true counts), sph = SetPlayerHidden was called this tick, cam = the camera position of the
-- current scan (tick: updateActive's, render: render's), clock (s, game dt). The animator cache (rebuilt when
-- GetPlayerAnimator(), its shape count or a shape in its list changes: a respawn or a character change): anim, n,
-- cls = shape -> 1 / 2 (as BONES) / 0 hidden / -1 a proxy shape (never shown, untagged or counted), bonesOk, att = {
-- shown, hidden } attachments (classified by the nearest bone), proxies; v0.22 attShown = the shown attachment shapes
-- (bodyCopyAttach pairs them), copyKey / copyId = the body copy's rebuild key and character id. near = COPY shape ->
-- hidden by the near-eye rule now; shown / hidden = copy shapes shown / engine player shapes hidden by the last tick's
-- scan; lean / duck /
-- leanAll / legs = the hysteresis states. Turn: yawD = head yaw - player yaw (deg), yawT = s above YAW, blockT = s a
-- wanted turn was blocked, lastTurn = clock of the last turn, prevYaw = bodyYaw last tick, turns = turns (cumulative),
-- turnLog = their clocks over the last 5 s (L_BODY_COL).
BV = { LEAN = 0.25, DUCK = 0.30, LEAN_ALL = 0.55, HYS = 0.05, HYS_DEG = 10, EYE_HIDE = 0.18, EYE_SHOW = 0.24,
       YAW = 50, YAW_T = 0.3, YAW_SNAP = 20, YAW_LEGS = 75, TURN_GAP = 0.5, TURN_WAIT = 1,
       WATER_UP = 1.0,
       BONES = { pelvis = 1, leg_upper_l = 1, leg_upper_r = 1, leg_lower_l = 1, leg_lower_r = 1, foot_l = 1, foot_r = 1,
                 toes_l = 1, toes_r = 1, stomach = 2, chest = 2 },
       NEED = { "pelvis", "stomach", "chest", "leg_upper_l", "leg_upper_r", "leg_lower_l", "leg_lower_r", "foot_l",
                "foot_r", "toes_l", "toes_r", "head" },
       mode = 0, why = 0, mp = false, sph = false, cam = nil, clock = 0,
       anim = 0, n = -1, cls = {}, bonesOk = false, att = { 0, 0 }, proxies = 0, attShown = {}, copyKey = -1, copyId = "",
       near = {}, shown = 0, hidden = 0,
       lean = false, duck = false, leanAll = false, legs = false,
       yawD = 0, yawT = 0, blockT = 0, lastTurn = -1000, prevYaw = nil, turns = 0, turnLog = {} }

-- Section 4.1 / 4.2, every tick before hidePlayer (tick; BV.cam = this tick's camera, set by updateActive). Modes: 0 =
-- show_body off (nothing new, the v0.20 path); 1 = torso + legs; 2 = legs only (pelvis and legs: why 13 lean, 14 duck,
-- 15 the head turned far from the body, see bodyTurn); 3 = everything hidden (why 16 multiplayer, 6 dead, 3 vehicle, 2
-- inactive, 4 riding (GetPlayerRig), 5 water, 7 third person, 8 fly mode, 10 no animator, 9 bones missing, v0.22 17 the
-- copy failed, 18 the engine re-hides our copies, 19 the hidden character is not animated, 20 building - until the first
-- placement; then 12 a lean beyond LEAN_ALL; checked in this order, the first wins; 11 is no longer written). v0.22
-- (docs/V022_PLAN.md section 1): the modes only tag OUR copy (bodyCopyShow); why 2 is only "not active" (the copy is
-- right in camera method 2 too); the head offset uses the model eye in any method (modelEye); the copy is (re)built
-- per animator, character id and SHOW-bone shape count (bodyCopyBuild; its attachments alone re-paired when their
-- count changes, bodyCopyAttach) and deleted with show_body off or in multiplayer.
-- The head offset is the camera position minus the model eye (modelEye, which includes the game's crouch). The
-- show / hide classes are cached per animator (BV.cls): a shape of a body whose `bone` tag is a SHOW bone is shown with
-- it; a shape tagged `attachment`, or one of a body without a `bone` tag, goes with the bone whose GetBoneWorldTransform
-- is nearest to its GetShapeBounds centre (pelvis / legs / feet / toes: shown; anything else: hidden); `proxy` shapes are
-- left alone. Shapes not in the animator's GetEntityChildren list are hidden as before.
function bodyMode(flags, dt)
    local v = BV
    v.clock = v.clock + (dt or 0)
    local show = nat.valid and nat.showBody == true
    v.mp = false
    if nat.valid and (nat.showBody or nat.handCollide or nat.bodyCollide) then
        v.mp = engineCall(IsMultiplayer) == true
    end
    -- (bodyTurn runs only in active ticks: its timers and the last heading start again after a pause / menu, so a
    -- heading changed meanwhile is no snap turn)
    if not active then v.prevYaw, v.yawT, v.blockT, v.legs = nil, 0, 0, false end
    -- (v0.22 section 1.11: show_body off or multiplayer delete the copies)
    if (not show or v.mp) and (#BCOPY.list > 0 or BCOPY.key ~= -1) then bodyCopyDelete() end
    if not show then
        v.mode, v.why, v.lean, v.duck, v.leanAll = 0, 0, false, false, false
        return
    end
    local anim = engineCall(GetPlayerAnimator)
    if type(anim) ~= "number" then anim = 0 end
    if anim ~= 0 then
        local kids = engineCall(GetEntityChildren, anim, "", true, "shape")
        if type(kids) ~= "table" or #kids > 1024 then kids = {} end
        local stale = anim ~= v.anim or #kids ~= v.n
        for i = 1, #kids do
            if stale then break end
            stale = v.cls[kids[i]] == nil
        end
        if stale then
            v.anim, v.n, v.cls, v.att, v.proxies, v.attShown = anim, #kids, {}, { 0, 0 }, 0, {}
            local names = engineCall(GetBoneNames, anim)
            if type(names) ~= "table" then names = {} end
            local have = {}
            for i = 1, #names do have[names[i]] = true end
            v.bonesOk = true
            for i = 1, #v.NEED do
                if not have[v.NEED[i]] then v.bonesOk = false end
            end
            local wb, bones = engineCall(GetWorldBody), nil
            for i = 1, #kids do
                local s, c = kids[i], 0
                local b = engineCall(GetShapeBody, s)
                if engineCall(HasTag, s, "proxy") == true then
                    c, v.proxies = -1, v.proxies + 1
                elseif type(b) == "number" and b ~= 0 and b ~= wb then
                    local bone = engineCall(GetTagValue, b, "bone")
                    if type(bone) == "string" and bone ~= "" and engineCall(HasTag, s, "attachment") ~= true then
                        c = v.BONES[bone] or 0
                    else
                        -- an attachment: the nearest bone (its world position) to the shape's box centre
                        if not bones then
                            bones = {}
                            for k = 1, #names do
                                local t = engineCall(GetBoneWorldTransform, anim, names[k])
                                if type(t) == "table" and type(t.pos) == "table" and type(t.pos[3]) == "number" then
                                    bones[#bones + 1] = { names[k], t.pos }
                                end
                            end
                        end
                        local mn, mx = engineCall(GetShapeBounds, s)
                        local best, bd = nil, math.huge
                        if type(mn) == "table" and type(mx) == "table" and type(mn[3]) == "number"
                            and type(mx[3]) == "number" then
                            local ctr = VecScale(VecAdd(mn, mx), 0.5)
                            for k = 1, #bones do
                                local d = VecLength(VecSub(ctr, bones[k][2]))
                                if d < bd then best, bd = bones[k][1], d end
                            end
                        end
                        c = (best and v.BONES[best] == 1) and 1 or 0
                        v.att[(c == 1) and 1 or 2] = v.att[(c == 1) and 1 or 2] + 1
                        if c == 1 then v.attShown[#v.attShown + 1] = s end
                    end
                end
                v.cls[s] = c
            end
            -- (v0.22 section 1.4: the copy's rebuild key and the character, read again with the cache)
            v.copyKey, v.copyId = BCOPY.keyOf(anim), bodyCopyId()
        end
        -- (v0.22 section 1.4: build the copy for this animator / character / SHOW-bone shape count; a failure locks why
        -- 17 for this animator and character; a changed attachment count re-pairs the attachments alone)
        local B = BCOPY
        if active and not v.mp and v.bonesOk then
            if anim ~= B.anim or v.copyId ~= B.id then B.lock = false end
            if not B.lock and (anim ~= B.anim or v.copyId ~= B.id or v.copyKey ~= B.key) then
                bodyCopyBuild(anim, v.copyId, v.copyKey)
            elseif not B.lock and #v.attShown ~= B.attN then
                bodyCopyAttach(anim)
            end
        end
    end
    local why = 0
    if v.mp then why = 16
    elseif hasBit(flags, LF_DEAD) then why = 6
    elseif hasBit(flags, LF_VEHICLE) then why = 3
    elseif not active then why = 2        -- (v0.22: the copy is right in camera method 2 too)
    else
        local rig = engineCall(GetPlayerRig)
        if type(rig) == "number" and rig ~= 0 then why = 4
        elseif engineCall(IsPointInWater, VecAdd(GetPlayerTransform().pos, Vec(0, v.WATER_UP, 0))) == true then why = 5
        elseif hasBit(flags, LF_THIRDPERSON) then why = 7
        elseif engineCall(GetPlayerParam, "flyMode") == true then why = 8
        elseif anim == 0 then why = 10
        elseif not v.bonesOk then why = 9
        elseif BCOPY.lock and BCOPY.anim == anim then why = 17
        elseif BCOPY.retagLock then why = 18
        elseif BCOPY.animOk == 2 then why = 19
        elseif not BCOPY.placed or BCOPY.anim ~= anim then why = 20
        end
    end
    -- the head offset (with hysteresis; reset while anything above hides the body)
    local eye = modelEye()
    if why == 0 and v.cam and eye then
        local dx, dz = v.cam[1] - eye[1], v.cam[3] - eye[3]
        local lean, duck = math.sqrt(dx * dx + dz * dz), eye[2] - v.cam[2]
        v.leanAll = lean > v.LEAN_ALL - (v.leanAll and v.HYS or 0)
        v.lean = lean > v.LEAN - (v.lean and v.HYS or 0)
        v.duck = duck > v.DUCK - (v.duck and v.HYS or 0)
    else
        v.lean, v.duck, v.leanAll = false, false, false
    end
    if why == 0 and v.leanAll then why = 12 end
    local mode = 3
    if why == 0 then
        mode = 1
        if v.lean then mode, why = 2, 13
        elseif v.duck then mode, why = 2, 14
        elseif v.legs then mode, why = 2, 15 end
    end
    v.mode, v.why = mode, why
end

-- Section 4.3, every active tick right after updateActive (the player's aim of this tick is set): with body_turn
-- (N_CAM_OPTS bit4, NCO_BODY_TURN) and the body shown (mode 1 / 2, last tick's) the player is turned to the head's yaw
-- (headYawPitch of this tick's base) once the head is more than YAW deg away for YAW_T s, or at once after a snap /
-- smooth turn of more than YAW_SNAP deg in one tick: one yaw teleport (aimTeleport with the player's pitch, its velocity
-- kept - the setPlayerAim pattern), counted in aimState.teleports and BV.turns. The view does not move (the camera
-- follows bodyYaw, not the player's yaw) and walking stays head relative (native turns the stick by L_PLAYER_YAW). Not
-- in a precise-aim tick (aimState.preciseTick), during tool use, without yaw control, with PF.NO_YAW, while
-- teleportBlocked(), while the probe runs, nor within TURN_GAP s of the last turn. The engine plays its own turn-step
-- animation. BV.legs (mode 2, why 15): the head more than YAW_LEGS deg from the body while a wanted turn has been blocked
-- for TURN_WAIT s, or body_turn is off.
function bodyTurn(dt)
    local v = BV
    local on = nat.valid and nat.bodyTurn == true
    local inMode = v.mode == 1 or v.mode == 2
    local d, headYaw = 0, nil
    if active and nat.valid and nat.showBody and phys.base and phys.baseTick == heartbeat then
        headYaw = headYawPitch(phys.base)
        d = angleDiff(headYaw, GetPlayerYaw())
    end
    local snap = v.prevYaw ~= nil and math.abs(angleDiff(bodyYaw, v.prevYaw)) > v.YAW_SNAP
    v.prevYaw = bodyYaw
    if math.abs(d) > v.YAW then v.yawT = v.yawT + (dt or 0) else v.yawT = 0 end
    local want = on and inMode and headYaw ~= nil and (v.yawT >= v.YAW_T or (snap and math.abs(d) > 1))
    if want and aimState.preciseTick ~= heartbeat and not aimState.toolUse and nat.yawControl == 1
        and not hasBit(nat.perf, PF.NO_YAW) and not teleportBlocked() and probe.step == 0
        and v.clock - v.lastTurn >= v.TURN_GAP then
        local pt, vel = GetPlayerTransform(), GetPlayerVelocity()
        aimTeleport(pt.pos, headYaw, GetPlayerPitch())
        SetPlayerVelocity(vel)
        aimState.teleports = aimState.teleports + 1
        aimState.since, aimState.teleAt = 0, heartbeat
        v.turns, v.lastTurn, v.yawT, v.blockT = v.turns + 1, v.clock, 0, 0
        v.turnLog[#v.turnLog + 1] = v.clock
        d = 0
    elseif want then
        v.blockT = v.blockT + (dt or 0)
    else
        v.blockT = 0
    end
    while #v.turnLog > 0 and v.turnLog[1] < v.clock - 5 do table.remove(v.turnLog, 1) end
    v.yawD = d
    v.legs = math.abs(d) > v.YAW_LEGS - (v.legs and v.HYS_DEG or 0) and (not on or v.blockT > v.TURN_WAIT)
end

-- ---------------------------------------------------------------------------------------------
-- v0.22 the body copy (docs/V022_PLAN.md section 1)
-- ---------------------------------------------------------------------------------------------
-- The v0.21 headset log: the engine re-hides its character every frame (why 11 from the first second), so untagging
-- it can never win. v0.22 draws the body with COPY bodies we own: one dynamic body per SHOW bone spawned from the
-- character's own vox files (BODY_MODELS, generated from data/prefab/player/*.xml: object, position, rotation, texture;
-- file player/player_<id>.vox at scale 0.5 - game files, nothing redistributed) plus one per shown attachment, each copy
-- shape paired with its engine shape (size + voxel count) and given the engine shape's local transform, then placed at
-- the engine bone body's pose every render. Shapes without a model (an unknown character, an unpaired shape) are copied
-- into a "carrier" (CopyShapeContent into a spawned 0.5 scale vox). Never a partial body: a SHOW-bone shape that cannot
-- be copied deletes the whole copy (why 17). The probes P2 (lag in physics steps), P3 (the engine re-hiding our copy),
-- P4 (align), P5 (the hidden character animated?) and P7 (do the bone bodies follow the bones?) choose the placement by
-- themselves (bodyCopySource / bodyCopyLag / bodyCopyProbe).
-- BCOPY: BONES = the 11 SHOW bones in build order; anim / id / key = what the copy was built for (key = the non-proxy,
-- non-attachment shapes on the SHOW bone bodies, BCOPY.keyOf; -1 none), attN = the shown attachment shapes it paired, list
-- = { body, bone ("att" for an attachment), cls (1 legs / 2 torso), eng = the engine body it follows, shapes = { { c =
-- copy shape, e = engine shape, lt = the engine shape's local transform } }, att = bool, at = its last placement }, src =
-- 1 generated / 2 carrier / 3 both, built / want = copy shapes paired / engine shapes to copy, fail = the failure code (1
-- Spawn, 2 voxel size, 3 carrier after a pairing failure, 4 no bones, 5 carrier API missing), lock = why 17 for this
-- animator and character, ltfix = local transforms set to the engine's, attDrop = attachments that could not be copied,
-- lag / lagCode / lagN / rms / lagS = P2 (lag in physics steps; lagCode 3 undecided; rms (m) per candidate over lagS, the
-- last 60 samples), ring = the last 4 player transforms of update() (newest first, every step), ref / refAcc / refT = the pelvis'
-- horizontal place in the player frame standing still, place = P7 (0 undecided / 1 bone bodies / 2 bone transform *
-- dRest), dRest / dAcc / dT = the bone-to-body offsets learnt standing still, dSpread / dMax / dAng / dRun = their
-- spread while running, align / alignLog = P4 (m, the last 5 s), animOk / animRange / animT / animMin / animMax = P5,
-- vis = copy shape -> shown by us, retagN / retags / retagLog / retagT / retagLock = P3 (cumulative, per second, ... why
-- 18 for this Lua state), placed = placed since the build, placeN = placements, park = where the copies were spawned,
-- gravOk = SetBodyGravityScale exists (else hidden copies are parked every tick).
BCOPY = { BONES = { "pelvis", "stomach", "chest", "leg_upper_l", "leg_upper_r", "leg_lower_l", "leg_lower_r", "foot_l",
                    "foot_r", "toes_l", "toes_r" },
          anim = 0, id = "", key = -1, attN = -1, list = {}, byShape = {}, src = 0, built = 0, want = 0, fail = 0,
          ltfix = 0, attDrop = 0, lag = 0, lagCode = 3, lagN = 0, rms = { 0, 0, 0 }, ring = {}, ref = nil, place = 0,
          dRest = {}, dSpread = 0, dT = 0, align = 0, animOk = 0, animRange = 0, animT = 0, retagLog = {}, retagT = 0,
          lock = false, placed = false, park = nil,
          lagS = {}, refAcc = nil, refT = 0, dAcc = {}, dMax = 0, dAng = 0, dRun = 0, alignLog = {}, animMin = nil,
          animMax = nil, vis = {}, retagN = 0, retags = 0, retagLock = false, placeN = 0, gravOk = true }

-- (helpers) a number for an XML attribute (no exponent); three of them
function BCOPY.num(x)
    local s = string.format("%.6f", x)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    if s == "-0" then s = "0" end
    return s
end
function BCOPY.vec(a, b, c)
    return BCOPY.num(a) .. " " .. BCOPY.num(b) .. " " .. BCOPY.num(c)
end
-- one copy vox element (section 1.4): the character's file, scale 0.5, the vox's texture (else the character's), our
-- tags, no collision
function BCOPY.voxXml(id, obj, pos, rot, tex)
    local x = '<vox file="player/player_' .. id .. '.vox" object="' .. obj .. '"'
    if pos then x = x .. ' pos="' .. pos .. '" rot="' .. rot .. '"' end
    return x .. ' scale="0.5" texture="' .. tex .. '" tags="tdvr_bodyshape unbreakable nocull noquery nonav" collide="false"/>'
end
-- GetShapeSize x, y, z and GetShapeVoxelCount as one string (the pairing key; nil: no size)
function BCOPY.sizeKey(s)
    local x, y, z = engineCall(GetShapeSize, s)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    local n = engineCall(GetShapeVoxelCount, s)
    return x .. "," .. y .. "," .. z .. "," .. ((type(n) == "number") and tostring(n) or "?")
end
-- the shapes of an engine bone body that are copied with the bone (no proxy, no attachment)
function BCOPY.engShapes(b)
    local out = {}
    local sh = engineCall(GetBodyShapes, b)
    if type(sh) ~= "table" then return out end
    for i = 1, #sh do
        if engineCall(HasTag, sh[i], "proxy") ~= true and engineCall(HasTag, sh[i], "attachment") ~= true then
            out[#out + 1] = sh[i]
        end
    end
    return out
end
-- the rebuild key: the non-proxy, non-attachment shapes on the 11 SHOW bone bodies (not BV.n: a tool or attachment
-- change must not respawn the bones)
function BCOPY.keyOf(anim)
    local n = 0
    for i = 1, #BCOPY.BONES do
        local b = engineCall(GetBoneBody, anim, BCOPY.BONES[i])
        if type(b) == "number" and b ~= 0 then n = n + #BCOPY.engShapes(b) end
    end
    return n
end
-- Spawn(xml, away, true) as the tool replica: GetBodyShapes order, dynamic, at rest at `at`, gravity 0, every shape
-- invisible (until placed), filter 0/0, unbreakable, nocull; (0, {}) when no body
function BCOPY.spawn(xml, at)
    local b, shapes = HC.spawn(xml, at)
    if b == 0 then return 0, {} end
    local listed = engineCall(GetBodyShapes, b)
    if type(listed) == "table" and #listed > 0 then shapes = listed end
    if engineCall(IsBodyDynamic, b) == false then engineCall(SetBodyDynamic, b, true) end
    placeOwnBody(b, at)
    BCOPY.gravOk = SetBodyGravityScale ~= nil
    engineCall(SetBodyGravityScale, b, 0)
    for i = 1, #shapes do
        local s = shapes[i]
        engineCall(SetTag, s, "invisible")
        engineCall(SetShapeCollisionFilter, s, 0, 0)
        engineCall(SetTag, s, "unbreakable")
        engineCall(SetTag, s, "nocull")
        BCOPY.vis[s] = false
    end
    return b, shapes
end
-- src: 1 generated, 2 carrier, 3 both
function BCOPY.addSrc(k)
    BCOPY.src = (BCOPY.src == 0 or BCOPY.src == k) and k or 3
end
-- a copy shape's local transform set to its engine shape's once when they differ (> 2 mm / > 1 deg): ltfix
function BCOPY.fixLt(pr)
    local lc = engineCall(GetShapeLocalTransform, pr.c)
    local le = engineCall(GetShapeLocalTransform, pr.e)
    if type(lc) ~= "table" or type(le) ~= "table" or type(lc.pos) ~= "table" or type(le.pos) ~= "table" then return end
    pr.lt = le
    if VecLength(VecSub(lc.pos, le.pos)) > 0.002 or quatAngle(lc.rot, le.rot) > 1 then
        engineCall(SetShapeLocalTransform, pr.c, le)
        BCOPY.ltfix = BCOPY.ltfix + 1
    end
end
-- the build failed: nothing left behind, why 17 for this animator and character
function BCOPY.failed(code)
    bodyCopyDelete(true)
    BCOPY.fail, BCOPY.lock = code, true
    return false
end
-- the probes start again for a new copy
function BCOPY.resetProbes()
    local B = BCOPY
    B.lag, B.lagCode, B.lagN, B.rms, B.lagS = 0, 3, 0, { 0, 0, 0 }, {}
    B.ref, B.refAcc, B.refT = nil, nil, 0
    B.place, B.dRest, B.dAcc, B.dT, B.dSpread, B.dMax, B.dAng, B.dRun = 0, {}, {}, 0, 0, 0, 0, 0
    B.align, B.alignLog = 0, {}
    B.animOk, B.animRange, B.animT, B.animMin, B.animMax = 0, 0, 0, nil, nil
end

-- Section 1.3: the character's id - game.player.character.path (playerbody.lua: player/player_<id>.xml), else
-- GetPlayerCharacter(0), else savegame.player.character, else sven_lagom (the game's default); a path, "player_" and
-- ".xml" stripped.
function bodyCopyId()
    local function norm(s)
        if type(s) ~= "string" or s == "" then return nil end
        s = string.match(s, "[^/]+$") or s
        s = string.gsub(s, "%.xml$", "")
        s = string.gsub(s, "^player_", "")
        if s == "" then return nil end
        return s
    end
    local p = GetString("game.player.character.path")
    local id = (type(p) == "string") and string.match(p, "player_(.-)%.xml$") or nil
    if id == "" then id = nil end
    if not id then id = norm(engineCall(GetPlayerCharacter, 0)) end
    if not id then id = norm(GetString("savegame.player.character")) end
    return id or "sven_lagom"
end

-- Section 1.4: builds the copy of animator anim's character id (key = BCOPY.keyOf): the old copy deleted, per SHOW bone
-- the generated body (BODY_MODELS[id].bones[bone], each vox at its XML pos / rot with its texture) spawned 500 m below
-- the player, its shapes checked for the 0.5 voxel scale (replicaScaleCode) and paired with the bone body's engine
-- shapes (bodyCopyPair); a scale mismatch or an unpaired copy shape drops that generated body; every engine shape left
-- goes to a carrier (bodyCopyCarrier). Then the attachments (bodyCopyAttach). Returns true when built.
function bodyCopyBuild(anim, id, key)
    local B = BCOPY
    bodyCopyDelete(true)
    B.anim, B.id, B.key, B.lock = anim, id, key, false
    B.list, B.byShape, B.vis = {}, {}, {}
    B.built, B.want, B.fail, B.ltfix, B.attDrop, B.src, B.attN = 0, 0, 0, 0, 0, 0, -1
    B.placed, B.placeN = false, 0
    BV.near = {}
    BCOPY.resetProbes()
    B.ring = {}                           -- (review V22-BODY-RING-STALE: no player frame of an earlier copy)
    if not (Spawn and GetEntityType) then return BCOPY.failed(1) end
    local model = BODY_MODELS[id]
    local away = Transform(VecAdd(GetPlayerTransform().pos, Vec(0, -500, 0)))
    B.park = away
    for i = 1, #B.BONES do
        local bone = B.BONES[i]
        local eng = engineCall(GetBoneBody, anim, bone)
        if type(eng) ~= "number" or eng == 0 then return BCOPY.failed(4) end
        local cls = BV.BONES[bone] or 1
        local es = BCOPY.engShapes(eng)
        B.want = B.want + #es
        local left, genSpawned = es, false
        local rows = model and model.bones[bone]
        if rows and #es > 0 then
            local x = '<body tags="tdvr_body=' .. bone .. ' nomerge" dynamic="true">'
            for k = 1, #rows do
                local r = rows[k]
                x = x .. BCOPY.voxXml(id, r[1], BCOPY.vec(r[2], r[3], r[4]), BCOPY.vec(r[5], r[6], r[7]), r[8] or model.tex)
            end
            local b, shapes = BCOPY.spawn(x .. "</body>", away)
            if b ~= 0 then
                genSpawned = true
                local code = (#shapes == 0) and -1 or nil
                for k = 1, #shapes do code = code or replicaScaleCode(shapes[k], 0.5) end
                local prs, rest = nil, nil
                if not code then prs, rest = bodyCopyPair(shapes, es) end
                if prs then
                    B.list[#B.list + 1] = { body = b, bone = bone, cls = cls, eng = eng, shapes = prs, att = false }
                    B.built = B.built + #prs
                    BCOPY.addSrc(1)
                    left = rest
                else
                    engineCall(Delete, b)
                    for k = 1, #shapes do B.vis[shapes[k]] = nil end
                end
            end
        end
        for k = 1, #left do
            local en, why = bodyCopyCarrier(left[k], bone, away)
            if not en then
                if why == 1 and genSpawned then why = 3 end
                return BCOPY.failed(why)
            end
            en.cls, en.eng = cls, eng
            B.list[#B.list + 1] = en
            B.built = B.built + 1
            BCOPY.addSrc(2)
        end
    end
    bodyCopyAttach(anim)
    return true
end

-- Section 1.5: pairs every copy shape cs[i] (GetBodyShapes order) with an unused engine shape of es of the same
-- GetShapeSize x, y, z AND GetShapeVoxelCount (ties in list order); a copy shape without one -> nil (the generated body is
-- dropped). Returns the pairs { c, e, lt } (local transforms fixed, BCOPY.fixLt) and the engine shapes left over. No
-- palette or tint step: the copy uses the character's own file and texture.
function bodyCopyPair(cs, es)
    local used, out, ek = {}, {}, {}
    for k = 1, #es do ek[k] = BCOPY.sizeKey(es[k]) end
    for i = 1, #cs do
        local kc = BCOPY.sizeKey(cs[i])
        local hit = nil
        for k = 1, #es do
            if not used[k] and kc ~= nil and ek[k] == kc then hit = k break end
        end
        if not hit then return nil, es end
        used[hit] = true
        out[#out + 1] = { c = cs[i], e = es[hit] }
    end
    local rest = {}
    for k = 1, #es do
        if not used[k] then rest[#rest + 1] = es[k] end
    end
    for i = 1, #out do BCOPY.fixLt(out[i]) end
    return out, rest
end

-- Section 1.4 (attachments, matched by shape, never by bone): the old attachment copies deleted; every BODY_MODELS[id].att
-- entry spawned once (one vox, no transform); each shown attachment engine shape (BV.attShown) pairs with an unused
-- candidate of the same size + voxel count (a second identical engine shape spawns that entry again), the copy then
-- follows the ENGINE body holding that shape with the engine shape's local transform; unused candidates are deleted at
-- once; a shape without a candidate goes to a carrier, and when that fails too it is dropped (attDrop: a missing radio is
-- no reason to hide the body).
function bodyCopyAttach(anim)
    local B = BCOPY
    local keep = {}
    for i = 1, #B.list do
        local en = B.list[i]
        if en.att then
            engineCall(Delete, en.body)
            for k = 1, #en.shapes do B.vis[en.shapes[k].c] = nil end
            B.built = B.built - #en.shapes
        else
            keep[#keep + 1] = en
        end
    end
    B.list = keep
    B.want = B.want - math.max(B.attN, 0)
    B.attDrop = 0
    local es = BV.attShown or {}
    B.attN = #es
    B.want = B.want + #es
    if #es == 0 then return end
    local model = BODY_MODELS[B.id]
    local away = B.park or Transform(VecAdd(GetPlayerTransform().pos, Vec(0, -500, 0)))
    local function spawnAtt(a)
        local b, shapes = BCOPY.spawn('<body tags="tdvr_body=att nomerge" dynamic="true">'
            .. BCOPY.voxXml(B.id, a[1], nil, nil, a[2] or model.tex) .. "</body>", away)
        if b ~= 0 and #shapes > 0 then return { b = b, s = shapes[1], k = BCOPY.sizeKey(shapes[1]), a = a } end
        if b ~= 0 then engineCall(Delete, b) end
        return nil
    end
    local cands = {}
    if model then
        for i = 1, #model.att do
            local c = spawnAtt(model.att[i])
            if c then cands[#cands + 1] = c end
        end
    end
    for i = 1, #es do
        local e = es[i]
        local ke = BCOPY.sizeKey(e)
        local c = nil
        for k = 1, #cands do
            if not cands[k].used and ke ~= nil and cands[k].k == ke then c = cands[k] break end
        end
        if not c and ke ~= nil then
            for k = 1, #cands do
                if cands[k].k == ke then
                    c = spawnAtt(cands[k].a)
                    if c then cands[#cands + 1] = c end
                    break
                end
            end
        end
        local eb = engineCall(GetShapeBody, e)
        if c then
            c.used = true
            local pr = { c = c.s, e = e }
            BCOPY.fixLt(pr)
            B.list[#B.list + 1] = { body = c.b, bone = "att", cls = 1, eng = eb, shapes = { pr }, att = true }
            B.built = B.built + 1
            BCOPY.addSrc(1)
        else
            local en = bodyCopyCarrier(e, "att", away)
            if en then
                en.cls, en.eng, en.att = 1, eb, true
                B.list[#B.list + 1] = en
                B.built = B.built + 1
                BCOPY.addSrc(2)
            else
                B.attDrop = B.attDrop + 1
            end
        end
    end
    for k = 1, #cands do
        if not cands[k].used then
            engineCall(Delete, cands[k].b)
            B.vis[cands[k].s] = nil
        end
    end
end

-- Section 1.6: a carrier for engine shape e: a body with one 0.5 scale vox (player_sven_lagom.vox pelvis), then
-- CopyShapeContent(e, c), CopyShapePalette(e, c), SetShapeLocalTransform(c, e's) (after the copy: the resize moves the
-- shape) and the voxel check (c's voxel size within 5 % of e's). Returns the list entry, or nil and the failure code
-- (1 no body, 2 voxel size, 5 API missing).
function bodyCopyCarrier(e, bone, away)
    if not (CopyShapeContent and GetShapeLocalTransform and SetShapeLocalTransform) then return nil, 5 end
    local b, shapes = BCOPY.spawn('<body tags="tdvr_body=' .. bone .. ' nomerge" dynamic="true">'
        .. BCOPY.voxXml("sven_lagom", "pelvis", nil, nil, "12 0.5") .. "</body>", away)
    if b == 0 or #shapes == 0 then
        if b ~= 0 then engineCall(Delete, b) end
        return nil, 1
    end
    local c = shapes[1]
    engineCall(CopyShapeContent, e, c)
    engineCall(CopyShapePalette, e, c)
    local lt = engineCall(GetShapeLocalTransform, e)
    if type(lt) == "table" then engineCall(SetShapeLocalTransform, c, lt) end
    local _, _, _, vc = engineCall(GetShapeSize, c)
    local _, _, _, ve = engineCall(GetShapeSize, e)
    if type(vc) ~= "number" or type(ve) ~= "number" or math.abs(vc - ve) > ve * 0.05 then
        engineCall(Delete, b)
        BCOPY.vis[c] = nil
        return nil, 2
    end
    return { body = b, bone = bone, cls = 1, eng = 0, shapes = { { c = c, e = e, lt = lt } }, att = false }
end

-- Section 1.11: deletes every copy (ours and any FindBodies("tdvr_body") a quickload left). keep = the failure path (the
-- key and animator kept, so the lock holds); otherwise the copy is rebuilt when it is wanted again.
function bodyCopyDelete(keep)
    local B = BCOPY
    for i = 1, #B.list do engineCall(Delete, B.list[i].body) end
    local old = engineCall(FindBodies, "tdvr_body", true)
    if type(old) == "table" then
        for i = 1, #old do engineCall(Delete, old[i]) end
    end
    B.list, B.byShape, B.vis, B.ring = {}, {}, {}, {}
    B.built, B.placed = 0, false
    BV.shown = 0
    if not keep then B.key, B.attN, B.anim, B.id = -1, -1, 0, "" end
end

-- Section 1.7: the player frame of a player transform t (the on-foot animator convention: turned 180 deg about Y)
function BCOPY.pf(t)
    return Transform(t.pos, QuatRotateQuat(t.rot, QuatEuler(0, 180, 0)))
end
-- F0 = the player frame now; F1 / F2 = those of the player 1 / 2 physics steps back (the lag candidates). The ring holds
-- GetPlayerTransform() of EVERY update() (review V22-BODY-RING-STALE / LUA22-2: a ring pushed only on a move kept the
-- last walking frames - and their yaw - while standing or turning in place, so a decided lag shifted / turned the copy).
-- Which entries those are depends on where update() runs relative to the physics step. BCOPY.ordN learns it while the
-- player moves faster than 0.5 m/s: the newest entry within 1 mm of now -> after (+1), about one step of motion away
-- (|v| / 60 +- 50 %) -> before (-1); capped at +-10, decided at +-3. After: the candidates are the 2nd / 3rd entries;
-- before: the 1st / 2nd. Undecided: the 2nd / 3rd when the newest entry equals now (1 mm and 0.5 deg), else the 1st / 2nd.
-- Standing still or after a turn has settled every candidate equals F0 (the re-root is the identity); a tick-time turn
-- (bodyTurn) is re-rooted onto the yaw of now until the steps catch up. A candidate more than BCOPY.FAR from now (a
-- teleport) or missing: nil (no re-root).
BCOPY.FAR, BCOPY.ordN = 1, 0
function BCOPY.frames()
    local B = BCOPY
    local pt = GetPlayerTransform()
    local r = B.ring
    local i0 = 0
    if r[1] then
        local d = VecLength(VecSub(r[1].pos, pt.pos))
        local s = VecLength(GetPlayerVelocity()) / 60
        if s > 0.5 / 60 then
            if d <= 0.001 then B.ordN = math.min(B.ordN + 1, 10)
            elseif math.abs(d - s) <= 0.5 * s then B.ordN = math.max(B.ordN - 1, -10) end
        end
        if B.ordN >= 3 then i0 = 1
        elseif B.ordN > -3 and d <= 0.001 and quatAngle(r[1].rot, pt.rot) <= 0.5 then i0 = 1 end
    end
    local function cand(e)
        if not e or VecLength(VecSub(e.pos, pt.pos)) > B.FAR then return nil end
        return B.pf(e)
    end
    return B.pf(pt), cand(r[i0 + 1]), cand(r[i0 + 2])
end
-- the copies' bodies as one array (QueryRejectBodies, rejectOwnBodies): rebuilt when BCOPY.list was replaced or grew
BCOPY.bodies, BCOPY.bodiesOf = {}, nil
function BCOPY.bodyArray()
    local B = BCOPY
    if B.bodiesOf ~= B.list or #B.bodies ~= #B.list then
        local t = {}
        for i = 1, #B.list do t[i] = B.list[i].body end
        B.bodies, B.bodiesOf = t, B.list
    end
    return B.bodies
end
-- the source pose of bone `bone` (engine body eng): place 0 / 1 its bone body's transform, place 2 the bone transform
-- * dRest (P7); nil unknown
function BCOPY.srcBone(bone, eng)
    local B = BCOPY
    if B.place == 2 and B.dRest[bone] then
        local bt = engineCall(GetBoneWorldTransform, B.anim, bone)
        if type(bt) == "table" and type(bt.pos) == "table" then return TransformToParentTransform(bt, B.dRest[bone]) end
    end
    local b = eng or engineCall(GetBoneBody, B.anim, bone)
    if type(b) ~= "number" or b == 0 then return nil end
    local t = engineCall(GetBodyTransform, b)
    if type(t) == "table" and type(t.pos) == "table" and type(t.rot) == "table" then return t end
    return nil
end
-- D = bone^-1 * bone body (P7)
function BCOPY.dOf(bone)
    local bt = engineCall(GetBoneWorldTransform, BCOPY.anim, bone)
    local b = engineCall(GetBoneBody, BCOPY.anim, bone)
    if type(bt) ~= "table" or type(bt.pos) ~= "table" or type(b) ~= "number" or b == 0 then return nil end
    local t = engineCall(GetBodyTransform, b)
    if type(t) ~= "table" or type(t.pos) ~= "table" then return nil end
    return TransformToLocalTransform(bt, t)
end

-- Section 1.7, update() (once per physics step): GetPlayerTransform() into BCOPY.ring (newest first, 4 entries) on EVERY
-- step - the player frames the lag is counted in (physics steps; BCOPY.frames). Cleared on a build, a delete and a
-- player teleport (HC.tele). (Review R22-TELE-OPTION-COUPLING: HC.tele is only computed with hand or body collision on,
-- so the ring also tests each push itself: the player moved more than HC.JUMP beyond its velocity * one physics step
-- since the newest entry - respawn, vehicle exit, a script teleport - clears it first.)
function bodyCopyRing()
    if not (nat.valid and nat.showBody == true) or #BCOPY.list == 0 then return end
    local t = GetPlayerTransform()
    local r = BCOPY.ring
    if r[1] and VecLength(VecSub(VecSub(t.pos, r[1].pos), VecScale(GetPlayerVelocity(), 1 / 60))) > HC.JUMP then
        BCOPY.ring = {}
        r = BCOPY.ring
    end
    table.insert(r, 1, t)
    if #r > 4 then r[5] = nil end
end

-- Section 1.7 P7 (render, before P2): D = bone^-1 * bone body; standing still (< 0.1 m/s) for 1 s the mean D of every
-- SHOW bone is learnt (dRest; rotation of the last sample); running (> 3 m/s horizontal) the spread of D against dRest
-- for pelvis and foot_r is kept, and every 5 s of running: within 1 cm and 3 deg -> place 1 (the bone bodies follow the
-- bones), else place 2 (the bone transform * dRest; attachments hidden).
function bodyCopySource(dt)
    local B = BCOPY
    if #B.list == 0 or B.anim == 0 then return end
    dt = dt or 0
    local pv = GetPlayerVelocity()
    if VecLength(pv) < 0.1 then
        B.dT = B.dT + dt
        for i = 1, #B.BONES do
            local bone = B.BONES[i]
            local D = BCOPY.dOf(bone)
            if D then
                local a = B.dAcc[bone] or { p = Vec(0, 0, 0), n = 0 }
                a.p, a.n, a.r = VecAdd(a.p, D.pos), a.n + 1, D.rot
                B.dAcc[bone] = a
            end
        end
        if B.dT >= 1 then
            for bone, a in pairs(B.dAcc) do
                if a.n > 0 then B.dRest[bone] = Transform(VecScale(a.p, 1 / a.n), a.r) end
            end
            B.dAcc, B.dT = {}, 0
        end
    else
        B.dAcc, B.dT = {}, 0
    end
    if pv[1] * pv[1] + pv[3] * pv[3] > 9 and B.dRest.pelvis and B.dRest.foot_r then
        for _, bone in ipairs({ "pelvis", "foot_r" }) do
            local D = BCOPY.dOf(bone)
            if D then
                B.dMax = math.max(B.dMax, VecLength(VecSub(D.pos, B.dRest[bone].pos)))
                B.dAng = math.max(B.dAng, quatAngle(D.rot, B.dRest[bone].rot))
            end
        end
        B.dRun = B.dRun + dt
        if B.dRun >= 5 then
            B.dSpread = B.dMax
            B.place = (B.dMax <= 0.01 and B.dAng <= 3) and 1 or 2
            B.dRun, B.dMax, B.dAng = 0, 0, 0
        end
    end
end

-- Section 1.7 P2 (render, before placing) and 1.10 P5: the pelvis (from the current source) in the player frames F0 / F1
-- / F2, horizontal; standing still for 1 s its mean in F0 is the reference; running (> 3 m/s horizontal) each candidate
-- k's squared distance to it is a sample, and every 60 samples lag = the k with the smallest RMS when that is under half
-- the second smallest and the second is > 4 cm (lagCode k), else lag 0 (lagCode 3). P5: the range of foot_r's position
-- in F0 over 5 s of walking (> 1 m/s): under 1 mm -> animOk 2 (why 19), else 1.
function bodyCopyLag(dt)
    local B = BCOPY
    if #B.list == 0 or B.anim == 0 then return end
    dt = dt or 0
    local F0, F1, F2 = BCOPY.frames()
    local pel = BCOPY.srcBone("pelvis")
    local pv = GetPlayerVelocity()
    local h2 = pv[1] * pv[1] + pv[3] * pv[3]
    if pel then
        local function hl(F)
            local l = TransformToLocalPoint(F, pel.pos)
            return l[1], l[3]
        end
        if VecLength(pv) < 0.1 then
            local x, z = hl(F0)
            local a = B.refAcc or { 0, 0, 0 }
            a[1], a[2], a[3] = a[1] + x, a[2] + z, a[3] + 1
            B.refAcc, B.refT = a, B.refT + dt
            if B.refT >= 1 then B.ref, B.refAcc, B.refT = { a[1] / a[3], a[2] / a[3] }, nil, 0 end
        else
            B.refAcc, B.refT = nil, 0
        end
        if h2 > 9 and B.ref and F1 and F2 then
            local smp = {}
            local Fs = { F0, F1, F2 }
            for k = 1, 3 do
                local x, z = hl(Fs[k])
                smp[k] = (x - B.ref[1]) ^ 2 + (z - B.ref[2]) ^ 2
            end
            local L = B.lagS
            L[#L + 1] = smp
            if #L > 60 then table.remove(L, 1) end
            B.lagN = B.lagN + 1
            if B.lagN >= 60 then
                B.lagN = 0
                local rms = { 0, 0, 0 }
                for k = 1, 3 do
                    local sum = 0
                    for i = 1, #L do sum = sum + L[i][k] end
                    rms[k] = math.sqrt(sum / #L)
                end
                B.rms = rms
                local o = { 1, 2, 3 }
                table.sort(o, function(a, b) return rms[a] < rms[b] end)
                if rms[o[1]] < 0.5 * rms[o[2]] and rms[o[2]] > 0.04 then
                    B.lag, B.lagCode = o[1] - 1, o[1] - 1
                else
                    B.lag, B.lagCode = 0, 3
                end
            end
        end
    end
    local foot = BCOPY.srcBone("foot_r")
    if foot and h2 > 1 then
        local l = TransformToLocalPoint(F0, foot.pos)
        if not B.animMin then
            B.animMin, B.animMax = VecCopy(l), VecCopy(l)
        else
            for i = 1, 3 do
                B.animMin[i], B.animMax[i] = math.min(B.animMin[i], l[i]), math.max(B.animMax[i], l[i])
            end
        end
        B.animT = B.animT + dt
        if B.animT >= 5 then
            local r = 0
            for i = 1, 3 do r = math.max(r, B.animMax[i] - B.animMin[i]) end
            B.animRange, B.animOk = r, (r < 0.001) and 2 or 1
            B.animT, B.animMin, B.animMax = 0, nil, nil
        end
    end
end

-- Section 1.8 (every tick after bodyMode, and in render before placing): the modes tag only OUR copy shapes - mode 1
-- every copy, 2 the legs (cls 1: pelvis, legs, feet, toes and the attachments), 3 none; attachments not with place 2;
-- nothing before the first placement; the near-eye rule (nearEye, 0.18 / 0.24 m per shape) with BV.cam. SetTag /
-- RemoveTag only on a change (BCOPY.vis). P3: a shape we left visible found tagged invisible again is a retag (counted,
-- untagged again while wanted). From tick: BV.shown.
-- (review R22-TICK-SHOW-ORDER: while render() runs, tick's call takes render's near-eye verdict (BV.near) as it is - the
-- copies still sit at last frame's pose, a verdict from there would feed render's hysteresis and flip the tags; from
-- tick only (no render) it runs after the tick's own placement)
function bodyCopyShow(fromRender)
    local B, v = BCOPY, BV
    if #B.list == 0 then
        if not fromRender then v.shown = 0 end
        return
    end
    local m, n = v.mode, 0
    local judge = fromRender or not drawInRender
    for i = 1, #B.list do
        local en = B.list[i]
        local ok = B.placed and ((m == 1) or (m == 2 and en.cls == 1))
        if en.att and B.place == 2 then ok = false end
        for k = 1, #en.shapes do
            local s = en.shapes[k].c
            local want = ok
            if want then
                local near
                if judge then
                    near = nearEye(s, v.cam, v.near[s])
                    v.near[s] = near or nil
                else
                    near = v.near[s] == true
                end
                if near then want = false end
            end
            local cur = B.vis[s] == true
            if cur and engineCall(HasTag, s, "invisible") == true then
                B.retagN = B.retagN + 1
                cur = false
            end
            if want ~= cur then
                if want then engineCall(RemoveTag, s, "invisible") else engineCall(SetTag, s, "invisible") end
            end
            B.vis[s] = want
            if want then n = n + 1 end
        end
    end
    if not fromRender then v.shown = n end
end

-- Section 1.8: a shape whose GetShapeBounds box comes within BV.EYE_HIDE of cam (BV.EYE_SHOW once near: hysteresis)
function nearEye(s, cam, wasNear)
    if not cam then return false end
    local mn, mx = engineCall(GetShapeBounds, s)
    if type(mn) ~= "table" or type(mx) ~= "table" or type(mn[3]) ~= "number" or type(mx[3]) ~= "number" then return false end
    local dx = math.max(mn[1] - cam[1], 0, cam[1] - mx[1])
    local dy = math.max(mn[2] - cam[2], 0, cam[2] - mx[2])
    local dz = math.max(mn[3] - cam[3], 0, cam[3] - mx[3])
    return math.sqrt(dx * dx + dy * dy + dz * dz) < (wasNear and BV.EYE_SHOW or BV.EYE_HIDE)
end

-- Section 1.7 (render, before bodyCopyShow; from tick only when render does not run): every copy at its source S (P7),
-- re-rooted onto the player frame of now when the bones lag k physics steps (P2: F0 * Fk^-1 * S), and on a held
-- right-eye frame moved by base * live^-1 (the copies sit where the hands and the tool replica are drawn on both eyes).
-- Only while the copy is shown or waits for its first placement (why 20); hidden copies stay where they were (gravity 0).
-- placeOwnBody: dynamic bodies, velocities zeroed - never a static body moved per frame. P4: every 6th placement the
-- largest copy-vs-engine shape distance (before the held correction).
function bodyCopyPlace(base, live, held)
    local B, v = BCOPY, BV
    if #B.list == 0 or B.anim == 0 then return end
    if not (v.mode == 1 or v.mode == 2 or v.why == 20) then return end
    local F0, F1, F2 = BCOPY.frames()
    local Fk = (B.lag == 1 and F1) or (B.lag == 2 and F2) or nil
    local corr = held and base and live and base ~= live
    local doAlign = B.placeN % 6 == 0
    B.placeN = B.placeN + 1
    local amax = 0
    for i = 1, #B.list do
        local en = B.list[i]
        if not (en.att and B.place == 2) then
            local S
            if en.att then
                local t = engineCall(GetBodyTransform, en.eng)
                if type(t) == "table" and type(t.pos) == "table" then S = t end
            else
                S = BCOPY.srcBone(en.bone, en.eng)
            end
            if S then
                local T = S
                if Fk then T = TransformToParentTransform(F0, TransformToLocalTransform(Fk, S)) end
                if doAlign then
                    for k = 1, #en.shapes do
                        local pr = en.shapes[k]
                        local wt = engineCall(GetShapeWorldTransform, pr.e)
                        if pr.lt and type(wt) == "table" and type(wt.pos) == "table" then
                            amax = math.max(amax, VecLength(VecSub(TransformToParentPoint(T, pr.lt.pos), wt.pos)))
                        end
                    end
                end
                if corr then T = TransformToParentTransform(base, TransformToLocalTransform(live, T)) end
                placeOwnBody(en.body, T)
                en.at = T
            end
        end
    end
    if doAlign then B.alignLog[#B.alignLog + 1] = { v.clock, amax } end
    B.placed = true
end

-- render(): the probes and the placement with render's base (live = the base of now on a held frame); the near-eye rule
-- (bodyCopyShow) AFTER the placement, so it judges the copies where this frame draws them (review F3)
function bodyCopyRender(dt, base, live, held)
    if #BCOPY.list == 0 then return end
    bodyCopySource(dt)
    bodyCopyLag(dt)
    bodyCopyPlace(base, live, held)
    bodyCopyShow(true)
end

-- Every tick after bodyCopyShow: P3 - the retags of the last second (BCOPY.retags, the L_BODY_VIS 1e7 digit); more than
-- 5 / s for 2 s -> why 18 for this Lua state (no flicker). Without SetBodyGravityScale hidden copies are put back at
-- their last place every tick.
function bodyCopyProbe(dt)
    local B, v = BCOPY, BV
    local log = B.retagLog
    log[#log + 1] = { v.clock, B.retagN }
    while #log > 1 and log[1][1] < v.clock - 1 do table.remove(log, 1) end
    B.retags = B.retagN - log[1][2]
    if B.retags > 5 then B.retagT = B.retagT + (dt or 0) else B.retagT = 0 end
    if B.retagT >= 2 then B.retagLock = true end
    if not B.gravOk and #B.list > 0 and not (v.mode == 1 or v.mode == 2) then
        for i = 1, #B.list do parkOwnBody(B.list[i].body, B.list[i].at or B.park) end
    end
end

-- Section 5: L_BODY_COPY (215) = built + 100 want + 1e4 source + 1e5 attachments dropped + 1e6 lagCode + 1e7 animated (0
-- unknown, 1 yes, 2 no) + 1e8 fail + 1e9 place + 1e10 align cm + 1e11 dSpread cm + 1e12 / 1e13 / 1e14 rms0 / 1 / 2 cm
-- (each cm digit <= 9; align = the largest of the last 5 s).
function bodyCopyDiag()
    local B = BCOPY
    while #B.alignLog > 0 and B.alignLog[1][1] < BV.clock - 5 do table.remove(B.alignLog, 1) end
    local a = 0
    for i = 1, #B.alignLog do a = math.max(a, B.alignLog[i][2]) end
    B.align = a
    local function cm(x) return clamp(math.floor(x * 100 + 0.5), 0, 9) end
    W(L3.BODY_COPY, math.min(B.built, 99) + 100 * math.min(B.want, 99) + 1e4 * B.src + 1e5 * math.min(B.attDrop, 9)
        + 1e6 * B.lagCode + 1e7 * B.animOk + 1e8 * math.min(B.fail, 9) + 1e9 * B.place + 1e10 * cm(B.align)
        + 1e11 * cm(B.dSpread) + 1e12 * cm(B.rms[1]) + 1e13 * cm(B.rms[2]) + 1e14 * cm(B.rms[3]))
end

-- Section 3 (L_WALK_ERR), every tick: on foot, horizontal speed > 1 m/s and exactly one of the game's move inputs down
-- (L_GAME_INPUT bits up 1 / down 2 / left 4 / right 8): the signed angle (deg) from the direction that input means
-- relative to the PLAYER yaw to the horizontal velocity (yawPitchOf convention, positive = left: the input's direction is
-- player yaw + 0 / 180 / +90 (the player's left) / -90 (right)). Near 0: the engine moves relative to the player yaw;
-- near camera yaw - player yaw: relative to the camera (attach would then double-rotate the stick).
function updateWalkErr(flags)
    if hasBit(flags, LF_VEHICLE) then return end
    local v = GetPlayerVelocity()
    if v[1] * v[1] + v[3] * v[3] <= 1 then return end
    local gi, off = jump.gi % 16, nil
    if gi == 1 then off = 0 elseif gi == 2 then off = 180 elseif gi == 4 then off = 90 elseif gi == 8 then off = -90
    else return end
    local vyaw = yawPitchOf(VecNormalize(Vec(v[1], 0, v[3])))
    push(jump.walkErrs, angleDiff(vyaw, GetPlayerYaw() + off), 30)
end

-- Everything done while the VR camera is active. Returns true if the player's aim was set.
function updateActive(dt, flags)
    local inVehicle = updateVehicleHeading(flags)
    if nat.recenter ~= lastRecenter then
        if lastRecenter >= 0 and inVehicle then vehicleYawOffset = 0 end   -- face the vehicle's front again
        lastRecenter = nat.recenter
    end
    if inVehicle then                     -- the VR camera sits where the driver's head is drawn
        SetPlayerHidden()
        BV.sph = true                     -- (v0.21: the L_BODY_VIS digit)
    end

    rearmRightStick()
    local turn = turnDelta(dt)
    if turn ~= 0 and nat.turnMode ~= 1 then HC.baseEpoch = HC.baseEpoch + 1 end   -- (v0.22 3.5: a snap turn)
    if inVehicle then
        vehicleYawOffset = vehicleYawOffset + turn   -- look around inside the vehicle
    else
        bodyYaw = bodyYaw + turn
    end
    RequestFirstPerson(false)
    DisableMotionBlur()
    updateCameraMode()
    -- (v0.9: may switch to method 2 before this tick's camera. v0.9 review ATT-2: the check is suspended in a vehicle:
    -- its "1.0 s / 2 s in a row" timers restart, a dead stretch before the vehicle must not add to one after it)
    if not inVehicle then attachTick(dt, flags) else att.dead, att.ok = 0, 0 end
    -- Order: the camera we want (pure maths) -> the player's aim and the tool -> apply the camera. The
    -- offset methods are relative to the player's final look direction, read back from the engine (lazy
    -- aim and the dead band mean the commanded yaw is not the actual one).
    local cam, base, held = computeCamera(flags)
    phys.base, phys.baseTick = base, heartbeat   -- (the physical hands take the hand poses from this base)
    -- (v0.22 section 3.2: the solid hands' physics from the LIVE base - a held right-eye base is the other frame's)
    phys.liveBase = (held and nat.handSteady == true) and computeBase(flags) or base
    BV.cam = cam.pos                      -- (v0.21 section 4.1: the head offset and the near-eye rule, bodyMode)
    local aimed = false
    laserTarget = nil
    if not inVehicle then
        aimed = updateAimAndTool(cam, base, held, dt)
        updateToolSwitch()
    end
    submitCamera(cam, flags, false)
    if not drawInRender then
        HC.vdt = dt
        placeHandsAndLaser(base, false, (nat.handSteady == true) and phys.liveBase or nil)
        placeToolReplica(base)
    end
    updateHaptics(dt)
    return aimed
end

-- v0.7 review (L_GAME_INPUT, every tick): what the game itself sees as held this tick, InputDown of up, down, left,
-- right, jump, usetool, crouch as bit0..6 (each call guarded; 0 without InputDown). With background input the native
-- side posts the keys to a game window that is not in the foreground; this tells whether the game took them.
local GAME_INPUT_KEYS = { "up", "down", "left", "right", "jump", "usetool", "crouch" }
function gameInputBits()
    if not InputDown then return 0 end
    local b = 0
    for i = 1, #GAME_INPUT_KEYS do
        local ok, down = pcall(InputDown, GAME_INPUT_KEYS[i])
        if ok and down == true then b = b + 2 ^ (i - 1) end
    end
    return b
end

-- Status slots written once per tick.
function writeStatus()
    if active then
        local m = cal.used
        if m ~= 1 then m = m + (cal.usedWorld and 10 or 0) end
        -- P not the player camera (v0.9: attach has no P)
        if m ~= 1 and m ~= 4 and (cal.analyticP or not drawInRender) then m = m + 100 end
        -- base from the player position (v0.9: always with attach, the model eye)
        if (eyeSrc.src >= 2 or m == 4) and not cal.inVehicle then m = m + 1000 end
        if cal.state == 2 and cal.aimUnverified then m = m + 2000 end         -- aim check not verified
        if cal.aimOnly then m = m + 4000 end   -- v0.6 review F1: aim ray > 10 deg off, no other method passed: kept
        if aimState.trio then m = m + 8000 end -- v0.7: yaw teleports by the v0.6 trio (aimTeleport / aimCheck)
        W(LX.CAM_METHOD, m)
        W(LX.CAM_STATE, cal.state)
    else
        W(LX.CAM_METHOD, 0)
        W(LX.CAM_STATE, 0)
    end
    W(LX.AIM_TELEPORTS, aimState.teleports)
    W(LX.TOOL_FRAME, toolCal.frame)
    W(LX.PERF_ACK, nat.valid and nat.perf or 0)
    -- v0.8 L3 (docs/V08_PLAN.md section 5)
    W(L3.AIMCHK_YAWERR, aimState.yawErr)
    W(L3.AIMCHK_PITCHERR, aimState.pitchErr)
    W(L3.AIMCHK_N, aimState.checks * 1000 + math.min(aimState.checks - aimState.passed, 999))
    W(L3.TELE_REASON, aimState.byPrecise * 1000 + math.min(aimState.byForced, 999))
    W(L3.HAND_BODY, handBodyStatic() and 1 or 0)
    writeV09Status()
    writeProbeStatus()                    -- (v0.12 L6, docs/V012_PLAN.md section 6)
    writeDiag21()                         -- (v0.21 section 9: 237..239, 249, 250)
end

-- v0.9 L3 slots 206..213 (docs/V09_PLAN.md section 4), from tick (writeStatus) and draw (their values change there).
-- L_ATT_STATE is 0 while attach is not requested (camera_method) or the player is in a vehicle (the override).
-- v0.9 review SPEC-4: the three attach medians only while attach is in use (method 4 and the last camera attached), -1
-- otherwise: after a failure (states 3/4/5), during a blame check and in a vehicle they would be frozen old values.
function writeV09Status()
    local st = att.state
    if (nat.camMethod or 0) ~= 4 or cal.inVehicle then st = 0 end
    local live = cal.method == 4 and cal.used == 4
    W(L3.ATT_STATE, st)
    -- (v0.9 review ATT-4: after a view failure (state 3) VIEWERR keeps the failing median; EYEDIFF / AIM_VS_CAM -1)
    W(L3.ATT_VIEWERR, live and median(att.errs) or (att.state == 3 and att.failErr) or -1)
    W(L3.ATT_EYEDIFF, live and median(att.eyeDiffs) or -1)
    W(L3.AIM_VS_CAM, live and median(att.aimVsCam) or -1)
    W(L3.PSEL, cal.psel + 10 * math.min(cal.pInf, 99))
    W(L3.PERR_PC, cal.errPc)
    W(L3.PERR_AN, cal.errAn)
    W(L3.WALK_ERR, #jump.walkErrs > 0 and median(jump.walkErrs) or -999)
    -- v0.22 (docs/V022_PLAN.md section 5): L_ATT_GATE = reason (+4 flatFail) + 10 retries + 100 zoom + 1e5 gated frames +
    -- 1e10 scope flag seen in the last 5 s + 1e11 the clear (1 held at our next read, 2 back every time)
    local now = HC.clock
    local sc = (now - att.scopeAt <= 5) and 1 or 0
    local clr = 0
    if sc == 1 then
        if now - att.heldAt <= 5 then clr = 1 elseif now - att.backAt <= 5 then clr = 2 end
    end
    W(L3.ATT_GATE, att.gate + (att.flatFail and 4 or 0) + 10 * math.min(att.retries, 3)
        + 100 * clamp(math.floor(att.zoom * 100 + 0.5), 0, 999) + 1e5 * math.min(att.gateN, 99999) + 1e10 * sc + 1e11 * clr)
end

function tick(dt)
    local t0 = (os and os.clock) and os.clock() or nil
    perf.clock = t0
    -- A quickload re-runs this file (file-level locals reset) without calling init() again.
    if not B then init() end
    heartbeat = heartbeat + 1
    if BONELAB and BONELAB.tick then pcall(BONELAB.tick) end
    W(L_HEARTBEAT, heartbeat)
    -- v0.6 review N1: no "near / holding" survives a tick that fails before updateHandPhysics publishes it (native reads
    -- between ticks: a completed tick still publishes its final value, a Lua error leaves 0 and the grips go to the game)
    W(LX.HANDS_NEAR, 0)
    readNative()
    updateFlagHolds()
    perf.lastDt = dt
    BV.sph = false                        -- (v0.21: SetPlayerHidden called this tick, L_BODY_VIS)
    -- v0.21 (docs/V021_PLAN.md sections 5 / 6.7): once per Lua state, on its first tick (a quickload re-runs this file;
    -- not in init(): restored bodies and the player's params may not exist yet there) and before any spawn: leftover
    -- collider / self-test bodies deleted, the player's CollisionMask given back what a crashed state left cleared
    if not PM.started then
        PM.started = true
        deleteColliders()
        bodyCopyDelete()                  -- (v0.22 section 1.11: stale body copies of an earlier Lua state)
        pmRestore("start")
    end

    if nat.valid and nat.hb ~= lastNativeHb then
        lastNativeHb = nat.hb
        staleTicks = 0
    else
        staleTicks = staleTicks + 1
    end
    local nativeAlive = nat.valid and staleTicks < 30
    perf.alive = nativeAlive

    local flags = computeFlags()
    if nativeAlive then flags = flags + LF_NATIVE_ALIVE end
    jump.gi = gameInputBits()
    W(LX.GAME_INPUT, jump.gi)
    updateWalkErr(flags)                  -- (v0.9 L_WALK_ERR)

    local wantVR = nativeAlive and (nat.mode == MODE_MONO or nat.mode == MODE_STEREO) and nat.seq > 0
    local blocked = hasBit(flags, LF_PAUSED) or hasBit(flags, LF_MAP) or hasBit(flags, LF_SCREEN)
        or hasBit(flags, LF_MENU_LEVEL) or hasBit(flags, LF_PHOTOMODE) or hasBit(flags, LF_ANIMATING)
        or hasBit(flags, LF_CINEMATIC) or hasBit(flags, LF_DEAD) or hasBit(flags, LF_UI_INTERACTIVE)

    local wasActive = active
    active = wantVR and not blocked
    aimCheck(active and wasActive and not hasBit(flags, LF_VEHICLE), dt)   -- (v0.7: before anything sets the aim)
    -- (before the v0.5 diagnostics: an error repeating there must not keep the options forced, v0.5 review O3)
    updateGameOptions(dt, flags)
    updateHeading(active, wasActive)
    appliedSeq = -1
    -- render() ran since the last tick: let it place the hands and draw the laser.
    drawInRender = renderCalls ~= renderCallsAtTick
    renderCallsAtTick = renderCalls
    measureToolDist()
    updateEyeSource(flags)
    if nat.valid then snapshotControllers() end
    aimState.toolUse = active and toolInUse()   -- (v0.6 review F1/F2: aim band, aim samples)
    use19(dt)                             -- (v0.19 section 1: the in-use timer, before the replica decides who is seen)
    updateJump(dt, flags)
    updateHands(dt)
    updateToolReplica(flags)              -- (v0.6, before the laser query that rejects the replica)
    probeUpdate(dt, flags)                -- (v0.12 section 2: after the replica's shown state, before the aim and tool)
    actUpdate(dt, flags)                  -- (v0.15 section 1: the actuator test, its pulse sent before the placement)
    local aimed = false
    local teleports = aimState.teleports
    if active then
        aimed = updateActive(dt, flags)
        bodyTurn(dt)                      -- (v0.21 section 4.3: after this tick's aim, its teleport counted below)
        flatScopeTick("tick", dt)         -- (v0.22 section 4.3: scope_zoom = no)
        flags = flags + LF_CAMERA_OVERRIDE   -- "Lua controls the view" (override or offset)
    else
        eyeSrc.off, eyeSrc.tickOff = nil, nil   -- no camera offset this frame (render() sends none either)
        cal.sentO, cal.renderO, cal.tickO = nil, nil, nil
        att.dead, att.ok = 0, 0   -- (v0.9 review ATT-2: the tool check is suspended (pause, map, UI): restart its timers)
    end
    aimState.teleTick = aimState.teleports ~= teleports
    bodyMode(flags, dt)                   -- (v0.21 section 4.1: what of the body is shown, before hidePlayer)
    if active and not drawInRender and not hasBit(flags, LF_VEHICLE) and #BCOPY.list > 0 then
        bodyCopySource(dt)                -- (v0.22 section 1.7: from tick only while render() does not run)
        bodyCopyLag(dt)
        bodyCopyPlace(phys.base, phys.base, false)
    end
    bodyCopyShow(false)                   -- (v0.22 section 1.8: the copy's tags; review R22-TICK-SHOW-ORDER: after the
                                          -- tick's own placement, render's near-eye verdict while render() runs)
    bodyCopyProbe(dt)                     -- (v0.22 section 1.10: P3)
    hidePlayer(flags, false)              -- (v0.10 section 1: after this tick's camera, cal.used; also when inactive)
    -- (v0.8: after the aim, so a yaw teleport of this tick is in it: native rotates the left stick by the head from
    -- L_BASE_YAW and L_PLAYER_YAW, docs/V08_PLAN.md section 2)
    W(L_PLAYER_YAW, GetPlayerYaw())
    W(L_PLAYER_PITCH, GetPlayerPitch())
    hcolTick(dt, flags)                   -- (v0.21 sections 6-7: the solid hands' and shins' targets and states)
    if HC.tele == true then BCOPY.ring = {} end   -- (v0.22 review: no re-root across a player teleport)
    updateHandPhysics(dt, flags)          -- (v0.6, with the base updateActive used; lets go of everything when inactive)

    updateDiagnostics()
    updateEngineDiagnostics(dt)
    writeStatus()
    W(L_AIM_ACTIVE, aimed and 1 or 0)
    W(L_FLAGS, flags)
    W(L_WORLD_SCALE, nat.worldScale or 1)
    W(L_ERROR, errorCode)
    -- this tick plus the render() calls since the last tick
    W(LX.LUA_MS, t0 and ((os.clock() - t0) * 1000 + perf.renderMs) or -1)
    perf.renderMs = 0
end

-- Runs right before the frame is drawn: re-apply the camera with the post-physics player position.
-- Offsets are not stackable, so this replaces the tick's value.
function render(dt)
    local t0 = (os and os.clock) and os.clock() or nil
    renderCalls = renderCalls + 1
    if not B then return end
    W(L_RENDER_CALLS, renderCalls)
    if active then
        local flags = computeFlags()
        updateVehicleHeading(flags)
        if not hasBit(flags, LF_VEHICLE) then eyeSourceRender() end
        local cam, base, held = computeCamera(flags)
        -- (v0.22 sections 1.7 / 3.2: on a held right-eye frame the base of now, for the solid hands and the body copy)
        local live = held and computeBase(flags) or base
        -- (before submitCamera: the eye source must still subtract the offset the raw eye contains)
        if not hasBit(flags, LF_VEHICLE) then
            retoolInRender(cam, base)
            actRender(cam, base)  -- (v0.15 sections 1-2: the pulse / placement again, after every script's tick)
        end
        -- (v0.13 section 1: the visible-offset test / the state-2 offset again, after every tick's SetToolOffset)
        if probe.vofs.sentAt == heartbeat then vofsOffset() end
        submitCamera(cam, flags, true)
        BV.cam = cam.pos          -- (v0.21 section 4.2: the near-eye rule with render's camera)
        hidePlayer(flags, true)   -- (v0.10 section 1: again with render's camera, a tool script may have shown a shape)
        if drawInRender then
            HC.vdt = dt or 0
            placeHandsAndLaser(base, true, (nat.handSteady == true) and live or nil)
            placeToolReplica(base)
            if not hasBit(flags, LF_VEHICLE) then bodyCopyRender(dt, base, live, held) end   -- (v0.22 section 1.7)
        end
    end
    if t0 then perf.renderMs = perf.renderMs + (os.clock() - t0) * 1000 end
end

-- The native part's on-screen message (automatic performance test), centred in the image: two short lines
-- (one long line is wider than what one eye sees of the image). Only while the native heartbeat is alive.
-- v0.15 (docs/V015_PLAN.md section 4): N_MSG 2 (NMSG_RENDER_SIZE; native shows it for 6 s once per game start when
-- render_size is wanted but the game window is borderless / fullscreen - Teardown re-creates its back buffer only in
-- Window mode): "For a sharper picture: Teardown Options > Display > Window", in two lines the same way.
function drawMessage()
    local msg = nat.msg
    if not perf.alive or (msg ~= 1 and msg ~= 2) then return end
    if not (UiPush and UiPop and UiTranslate and UiAlign and UiFont and UiText) then return end
    local a, b = "For a sharper picture:", "NVIDIA DSR 2.25x + Fullscreen 2880x1620"
    if msg == 1 then
        local arg = nat.msgArg or 0
        a = string.format("VR performance test %d/%d", math.floor(arg / 100), math.floor(arg % 100))
        b = "please stand still and look ahead"
    end
    UiPush()
    UiTranslate(UiWidth() * 0.5, UiHeight() * 0.5 - 20)
    UiAlign("center middle")
    UiFont("regular.ttf", 28)
    if UiColor then UiColor(1, 1, 1, 1) end
    UiText(a)
    UiTranslate(0, 40)
    UiText(b)
    UiPop()
end

-- v0.11 (docs/V011_PLAN.md section 4) draw-time engine tool diagnostics: the v0.10 headset log had a second tool drawn
-- although no foreign tool-layer shape was near the eye and GetToolBody()'s shapes were tagged at tick time, so this
-- looks at the frame as it is drawn. While attach is in use on foot (this frame's camera attached, cal.used 4):
-- L_ENGTOOL_VIS counts frames (at most 99999) in which a valid shape of GetToolBody() is NOT tagged invisible while the
-- replica is shown; L_ENGTOOL_POS = the engine tool body's position in the render camera (GetCameraTransform) frame,
-- right * 1e6 + up * 1e3 + forward, each part clamp(round(cm) + 500, 0, 999) (500 = 0 cm); L_ENGTOOL_HAND = engine tool
-- body -> right grip (the frame's own base, hist[#hist]) in cm. Both -1 otherwise (no tool body, no attach, no tracked
-- right grip for the hand distance). L_THIRDPERSON (every draw, guarded) = GetBool("game.thirdperson") + 10 * (a player
-- animator) + 100 * (a player rig).
function engineToolDraw()
    local r, pos, hand = replica, -1, -1
    local tb = (active and appliedSeq >= 0 and cal.used == 4 and not cal.inVehicle) and GetToolBody() or 0
    if tb ~= 0 then
        if r.shown then
            local shapes = engineCall(GetBodyShapes, tb)
            local vis = false
            if type(shapes) == "table" then
                for i = 1, #shapes do
                    if validBody(shapes[i]) and HasTag ~= nil and HasTag(shapes[i], "invisible") ~= true then vis = true end
                end
            end
            if vis then r.engVis = math.min(r.engVis + 1, 99999) end
        end
        local bt = engineCall(GetBodyTransform, tb)
        if type(bt) == "table" and type(bt.pos) == "table" and type(bt.pos[3]) == "number" then
            local l = TransformToLocalPoint(GetCameraTransform(), bt.pos)
            local function part(m) return clamp(math.floor(m * 100 + 0.5) + 500, 0, 999) end
            pos = part(l[1]) * 1000000 + part(l[2]) * 1000 + part(-l[3])
            local e = hist[#hist]
            if ctl and hasBit(ctl.hv, 4) and e and e.bx then
                local base = Transform(Vec(e.bx, e.by, e.bz), QuatAxisAngle(Vec(0, 1, 0), e.byaw))
                hand = VecLength(VecSub(localToWorld(base, ctl.rgrip, nat.worldScale).pos, bt.pos)) * 100
            end
        end
    end
    W(L5.ENGTOOL_VIS, r.engVis)
    W(L5.ENGTOOL_POS, pos)
    W(L5.ENGTOOL_HAND, hand)
    local anim = engineCall(GetPlayerAnimator)
    local rig = engineCall(GetPlayerRig)
    W(L5.THIRDPERSON, (GetBool("game.thirdperson") and 1 or 0) + ((type(anim) == "number" and anim ~= 0) and 10 or 0)
        + ((type(rig) == "number" and rig ~= 0) and 100 or 0))
end

function draw()
    if not B then return end
    -- game.input.locktool is set per frame by other scripts' ticks; draw runs after all of them.
    if GetBool("game.input.locktool") then lockToolFrames = 0 else lockToolFrames = lockToolFrames + 1 end
    drawCount = drawCount + 1
    W(L_DRAW_COUNT, drawCount)
    W(L_UI_W, UiWidth())
    W(L_UI_H, UiHeight())
    drawMessage()
    engineToolDraw()   -- (v0.11 section 4; also while inactive: then the "none" values)
    if not active or appliedSeq < 0 then
        probe.rc = nil
        att.gate = 0          -- (v0.22: no gated frame while inactive)
        W(L_ACK_SEQ, -1)
        W(L_MEAS_TANH, 0)
        W(L_MEAS_TANV, 0)
        W(LX.CAM_ERR, -1)
        W(LX.AIM_ERR, -1)
        camDbgFrame(nil)
        return
    end
    -- Which of our recent cameras did the engine actually use for this frame? Normally the one
    -- applied this frame; a strict match against an older one reveals a one-frame camera delay.
    -- (1 cm: the engine camera may carry a little bob/shake now.)
    local c = GetCameraTransform()
    -- (v0.12 section 2: the camera the engine places this frame's tool override with, the probe's reference 3)
    probe.rc = (not cal.inVehicle) and Transform(VecCopy(c.pos), c.rot) or nil
    local strict = nil
    for k = #hist, 1, -1 do
        local h = hist[k]
        local dp = VecLength(VecSub(c.pos, h.pos))
        local dq = math.abs(c.rot[1] * h.rot[1] + c.rot[2] * h.rot[2] + c.rot[3] * h.rot[3] + c.rot[4] * h.rot[4])
        if dp < 0.01 and dq > 0.99995 then strict = h; break end
    end
    local ack = strict or hist[#hist]
    W(L_ACK_SEQ, ack.seq)
    W(L_ACK_EYE, ack.eye)
    W(L_HFOV_USED, ack.hfov)
    W(L_BASE_X, ack.bx); W(L_BASE_Y, ack.by); W(L_BASE_Z, ack.bz); W(L_BASE_YAW, ack.byaw)

    -- Measure the frustum the engine really rendered (horizontal/vertical half-angle tangents).
    local w, h = UiWidth(), UiHeight()
    local dR = TransformToLocalVec(c, UiPixelToWorld(w, h * 0.5))
    local dT = TransformToLocalVec(c, UiPixelToWorld(w * 0.5, 0))
    local th, tv = 0, 0
    if dR[3] < -1e-4 then th = dR[1] / -dR[3] end
    if dT[3] < -1e-4 then tv = dT[2] / -dT[3] end
    W(L_MEAS_TANH, th)
    W(L_MEAS_TANV, tv)

    -- Camera method self-calibration / monitoring (on foot only; vehicles always use the override).
    if not cal.inVehicle then
        -- (v0.22 section 4.1: a scope zoom, a frustum or a camera that is not ours is no view sample)
        local gate = attachGate(hist[#hist], th, tv, c)
        local err = measureCamera(strict, gate)
        camDbgFrame(hist[#hist], err, c)
        toolRendered(c, strict, err)   -- the camera the tool override of this frame was rendered with
        attachDraw(hist[#hist], err, gate)   -- (v0.9: attach view check and diagnostics, section 1.3)
        if gate == 0 then pselDraw(hist[#hist], c, strict) end   -- (v0.9: offset mode P-source learning, section 2)
        W(LX.CAM_ERR, median(cal.recent))
        W(LX.AIM_ERR, cal.aimErr)
    else
        att.gate = 0
        W(LX.CAM_ERR, -1)
        W(LX.AIM_ERR, -1)
        camDbgFrame(nil)
    end

    flatScopeTick("draw", 0)   -- (v0.22 section 4.3: the scope overlay flag, after every script's tick)
    writeV09Status()
    if nat.aimMode == 1 then SetBool("hud.aimdot", false) end

    if nat.debug == 1 then
        DebugWatch("VR mode", nat.mode)
        DebugWatch("VR seq/ack", tostring(nat.seq) .. " / " .. tostring(ack.seq))
        DebugWatch("VR eye", nat.eye)
        DebugWatch("VR hfov", nat.hfov)
        DebugWatch("VR measured tanH/tanV", string.format("%.3f / %.3f", th, tv))
        DebugWatch("VR body yaw", bodyYaw)
        DebugWatch("VR player yaw/pitch", string.format("%.1f / %.1f", GetPlayerYaw(), GetPlayerPitch()))
        DebugWatch("VR hands valid", nat.handsValid)
        DebugWatch("VR render() calls", renderCalls)
        DebugWatch("VR camera method/state/err", string.format("%d%s%s / %d / %.2f", cal.used, cal.usedWorld and "w" or "",
            cal.analyticP and "a" or "", cal.state, median(cal.recent)))
        DebugWatch("VR attach state / view / eye diff / aim vs cam / psel n errPc errAn / walk err", string.format(
            "%d / %.2f / %.1f / %.1f / %d %d %.2f %.2f / %.1f", att.state, B[L3.ATT_VIEWERR], B[L3.ATT_EYEDIFF],
            B[L3.AIM_VS_CAM], cal.psel, cal.pInf, cal.errPc, cal.errAn, B[L3.WALK_ERR]))
        DebugWatch("VR aim err / bad s / teleports / deferred / check yaw pitch", string.format(
            "%.2f / %.1f / %d / %d / %.1f %.1f", cal.aimErr, cal.aimBad, aimState.teleports, aimState.limited,
            aimState.yawErr, aimState.pitchErr))
        DebugWatch("VR eye source tick/render / fit tick/render", string.format("%d/%d / %.2f/%.2f", eyeSrc.src,
            eyeSrc.use, eyeSrc.fit, eyeSrc.rfit))
        DebugWatch("VR P pick / body / jumps / assists / tele blocked / walk yaw", string.format(
            "%d%s / %s / %d / %d / %d / %.1f", cal.pPick - 1, cal.analyticP and "a" or "", handBodyStatic() and "static"
            or "dynamic", jump.jumps, jump.assists, jump.blocked, jump.walkYaw))
        DebugWatch("VR camera worst / ctx", string.format("%.2f / 0x%X", B[L2.CAMDBG_WORST], B[L2.CAMDBG_CTX]))
        DebugWatch("VR option writes", string.format("0x%X", B[L2.OPT_WRITE]))
        DebugWatch("VR tool frame / spreads F1 E P C M / K / fist", string.format("%d / %.1f %.1f %.1f %.1f %.1f / %.1f / %.1f",
            B[L2.TOOL_FRAME2], toolCal.spread[1], toolCal.spread[2], toolCal.spread[3], toolCal.spread[4], toolCal.spreadM,
            toolCal.kLen, toolCal.fist))
        DebugWatch("VR hands state/count", string.format("0x%X / %d", B[LX.HANDS_STATE], hands.count))
        DebugWatch("VR hands size check / bounds err / voxel", string.format("%d / %.1f / %.1f", hands.mapping, hands.bErr,
            hands.voxelMm / 10))
        DebugWatch("VR tool replica / shapes / hand near / grabs / throws / pushes", string.format("%d / %d / 0x%X / %d / %d / %d",
            replica.state, replica.n, phys.near, phys.grabs, phys.throws, phys.pushes))
        DebugWatch("VR replica fail code / picks / tool corr cm / grip latch / arms / asleep / ground", string.format(
            "%d / %d / %.1f / 0x%X / %d / %d / %d", replica.failN, replica.picks, B[L2.TOOL_CORR], nat.gripLatch or 0,
            phys.arms, phys.sleep, phys.ground))
        DebugWatch("VR v0.10 foreign tools / engine in query / hand q hit / rej static mass other / A why ground",
            string.format("%d / %d / %d %d / %d %d %d / %d %d %d", replica.fBodies, replica.fEngine, phys.q, phys.qHit,
            phys.rej[1], phys.rej[2], phys.rej[3], jump.aEdges, jump.why, jump.ground))
        DebugWatch("VR v0.11 hand any cm kind / palm-eye / engine tool vis pos hand / thirdperson / player shapes",
            string.format("%d %d / %d / %d %d %d / %d / %d", B[L5.HAND_ANYDIST], B[L5.HAND_ANYKIND], B[L5.HAND_PALM_EYE],
            B[L5.ENGTOOL_VIS], B[L5.ENGTOOL_POS], B[L5.ENGTOOL_HAND], B[L5.THIRDPERSON], B[L5.PLAYERSHAPES]))
        -- (v0.21, docs/V021_PLAN.md section 9: the kept probe / self-test / self-check values are in diag.prb, their
        -- slots carry the v0.21 diagnostics)
        local prb = diag.prb
        DebugWatch("VR v0.12 anim found / probe state ref+10*runs axes / tool err / jump vmax", string.format(
            "%d / %d %d %d / %.1f / %.0f", B[L6.ANIM_FOUND], prb.probeState, prb.probeRef, prb.probeAxes,
            B[L6.TOOL_ERR], B[L6.JUMP_VMAX]))
        DebugWatch("VR v0.14 vofs / servo state err rotErr c cw / diverged / tool shown", string.format(
            "%d / %d %.1f %.1f %.1f %.1f / %d / %d", prb.vofsState, B[L7.SERVO_STATE], B[L7.SERVO_ERR],
            B[L7.SERVO_ROTERR], VecLength(probe.servo.c) * 100, math.deg(VecLength(probe.servo.cw)),
            probe.servo.diverged, B[L7.TOOL_SHOWN]))
        -- (v0.17, docs/V017_PLAN.md section 4: 249..251 are the rotation control's self-check and the jitter now)
        DebugWatch("VR v0.17 act / rotctl ab / jitter mm / place err rotErr c / base", string.format(
            "%d / %d %d / %.1f / %.1f %.1f %.1f / %d", B[L8.ACT], prb.rotctl, prb.rotctlAb, B[L8.JITTER],
            B[L8.PLACE_ERR], B[L8.PLACE_ROTERR], VecLength(probe.act.c) * 100, B[L8.BASE_P]))
        -- (v0.18, docs/V018_PLAN.md section 2: the teleport-timing predictor and its score EMAs)
        DebugWatch("VR v0.18 tpPred / EMA A B cm", string.format("%d / %.2f %.2f", B[L8.TP_PRED],
            probe.act.tpEA * 100, probe.act.tpEB * 100))
        -- (v0.19, docs/V019_PLAN.md sections 1-2: the flow - 0 v0.18, 1 parked, 2 at the hand -, the in-use time left,
        -- the tool shown (0 replica, 1 engine) and whether the current tool is held by its handle)
        DebugWatch("VR v0.19 flow / use s / shown / handle", string.format("%d / %.2f / %d / %s", probe.act.m19,
            probe.act.u19, B[L7.TOOL_SHOWN], tostring(handleTool19(GetPlayerTool and (GetPlayerTool() or "")
            or GetString("game.player.tool")))))
        -- (v0.21, docs/V021_PLAN.md section 4: the visible body - mode, why, shapes shown / hidden, fights per second,
        -- SetPlayerHidden this tick, multiplayer; attachments shown / hidden, proxy shapes, bones; head - body yaw,
        -- turns, the blocky hands' extras / fallback)
        local bv = BV
        DebugWatch("VR v0.21 body mode why / shown hidden / retags/s / sph mp / attach / proxies / bones / yaw turns",
            string.format("%d %d / %d %d / %d / %s %s / %d %d / %d / %s / %.0f %d", bv.mode, bv.why, bv.shown,
            bv.hidden, BCOPY.retags, tostring(bv.sph), tostring(bv.mp), bv.att[1], bv.att[2], bv.proxies,
            tostring(bv.bonesOk), bv.yawD, bv.turns))
        DebugWatch("VR v0.22 copy built/want src fail / lag place anim / gate retries / punch", string.format(
            "%d/%d %d %d / %d %d %d / %d %d / %d", BCOPY.built, BCOPY.want, BCOPY.src, BCOPY.fail, BCOPY.lagCode,
            BCOPY.place, BCOPY.animOk, att.gate, att.retries, #PUNCH.log))
        DebugWatch("VR v0.21 hands skin / extras ok / blocky failed / varC", string.format("%d / %s / %s / %s",
            hands.skin, tostring(hands.extraOk), tostring(hands.blkFail), tostring(hands.varC)))
        -- (risks 17 / 18: GetPlayerBodies' vs GetEntityChildren's shape count, the shin rotation source ticks)
        DebugWatch("VR v0.21 bodies / children / shinrot body aligned", string.format("%d / %d / %d %d", PM.bodiesN,
            PM.kidsN, BC.src[1], BC.src[2]))
    end
end

-- BonelabVR additions
function bonelab_init()
    -- placeholder for bonelab style features
end

function draw()
    if BONELAB and BONELAB.drawVRMenu then
        local paused = GetBool and GetBool("game.paused")
        local path = GetString and GetString("level.path") or ""
        if paused or path == "" then pcall(BONELAB.drawVRMenu) end
    end
    -- draw VR UI in world space if in VR
end

-- Load bonelab core
dofile("MOD/bonelab_core.lua")
if BONELAB and BONELAB.init then pcall(BONELAB.init) end
