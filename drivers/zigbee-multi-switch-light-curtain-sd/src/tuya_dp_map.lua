local M = {}

M.DP_SWITCH_1   = 1
M.DP_SWITCH_2   = 2
M.DP_SWITCH_3   = 3
M.DP_SWITCH_4   = 4
M.DP_SWITCH_5   = 5
M.DP_SWITCH_6   = 6
M.DP_MASTER     = 13
M.DP_BACKLIGHT  = 16
M.DP_CHILD_LOCK = 101

-- Alternate switch DPs used by mixed curtain/light panels (e.g. _TZE200_7a5ob7xq 4-gang).
-- On these devices the "curtain column" gangs report their on/off state via a
-- second set of DPs (0x66=102, 0x67=103) in addition to the normal DPs 0x01-0x06.
-- Map them back to their canonical switch DP so the handler can re-use the same path.
-- NOTE: applied on 4-gang panels only (6-gang uses 0x66 for something else).
M.DP_ALT_SWITCH_MAP = {
  [102] = 2,   -- 0x66  →  switch2 / gang-2
  [103] = 3,   -- 0x67  →  switch3 / gang-3  (6-gang panels)
}

-- Device-type DPs (read-only, set by hardware dip-switch)
-- Value: 0 = light, 1 = curtain
--
-- Panel layout and DP coverage (columns, not rows):
--
--   2-gang  (1×2 horizontal):
--     DT1 → both gangs {1, 2}  (UD variant = single curtain pair)
--
--   4-gang  (2×2 grid):
--     layout:  1  2
--              3  4
--     DT1 → left  column {1, 3}
--     DT2 → right column {2, 4}
--
--   6-gang  (2×3 grid):
--     layout:  1  2  3
--              4  5  6
--     DT1 → left   column {1, 4}
--     DT2 → middle column {2, 5}
--     DT3 → right  column {3, 6}

M.DP_DEVICE_TYPE_1 = 0x6F   -- 111
M.DP_DEVICE_TYPE_2 = 0x70   -- 112
M.DP_DEVICE_TYPE_3 = 0x71   -- 113

-- Curtain command DPs (write-only, 3-gang TS6001)
-- Value: 0=stop, 1=open 5min, 2=close 5min, 3=open timed, 4=close timed
M.DP_CURTAIN_1 = 0x79   -- 121
M.DP_CURTAIN_2 = 0x7A   -- 122
M.DP_CURTAIN_3 = 0x7B   -- 123

M.CURTAIN_CMD_STOP        = 0
M.CURTAIN_CMD_OPEN        = 1
M.CURTAIN_CMD_CLOSE       = 2
M.CURTAIN_CMD_OPEN_TIMED  = 3
M.CURTAIN_CMD_CLOSE_TIMED = 4

-- Human-readable type names
M.DEVICE_TYPE_NAME  = { [0] = "light",    [1] = "curtain"    }  -- schema enum values
M.DEVICE_TYPE_LABEL = { [0] = "💡 Light", [1] = "🪟 Curtain" }  -- log display only

-- For each gang count, which DP_DEVICE_TYPE_x governs which gangs
-- Table: gang_count -> list of { dp, gangs[], column_label }
--
-- 3-gang (TS6001): each gang has its OWN independent deviceType DP
--   DT1 -> gang 1 only
--   DT2 -> gang 2 only
--   DT3 -> gang 3 only
M.GANG_TYPE_MAP = {
  [2] = {
    { dp = M.DP_DEVICE_TYPE_1, gangs = {1, 2}, label = "gangs 1+2" },
  },
  [3] = { { dp = M.DP_DEVICE_TYPE_1, gangs = {1, 3}, label = "buttons 1+3" } },
  [4] = {
    { dp = M.DP_DEVICE_TYPE_1, gangs = {1, 3}, label = "left col  (1+3)" },
    { dp = M.DP_DEVICE_TYPE_2, gangs = {2, 4}, label = "right col (2+4)" },
  },
  [6] = {
    { dp = M.DP_DEVICE_TYPE_1, gangs = {1, 4}, label = "left col   (1+4)" },
    { dp = M.DP_DEVICE_TYPE_2, gangs = {2, 5}, label = "middle col (2+5)" },
    { dp = M.DP_DEVICE_TYPE_3, gangs = {3, 6}, label = "right col  (3+6)" },
  },
}

-- Map switch gang number -> curtain DP (3-gang only)
M.GANG_TO_CURTAIN_DP = {
  [1] = M.DP_CURTAIN_1,
  [2] = M.DP_CURTAIN_2,
  [3] = M.DP_CURTAIN_3,
}

-- ─────────────────────────────────────────────────────────────────────
-- COLUMN TABLE (single source of truth for curtain/light column logic)
--   key   : column id, used in device field names (curtain_state_<key> …)
--   up/dn : switch DPs of the top (up/open) and bottom (down/close) gang
--   dt    : deviceType DP that says if this column is light(0)/curtain(1)
--   comp  : curtain component id / curtain child key
--   cdp   : curtain command DP (0=stop 1=open 2=close)
--   dur   : preference name holding motor run time
-- Gang counts without an entry (1, 2, 3) are treated as all-light.
-- ─────────────────────────────────────────────────────────────────────
M.COLUMNS = {
  [2] = { { key = "left", up = 1, dn = 2, dt = M.DP_DEVICE_TYPE_1, comp = "curtain1", cdp = M.DP_CURTAIN_1, dur = "curtainDuration1", label = "buttons 1+2" } },
  [3] = {
    { key = "left", up = 1, dn = 3, dt = M.DP_DEVICE_TYPE_1, comp = "curtain1", cdp = M.DP_CURTAIN_1, dur = "curtainDuration1", label = "buttons 1+3" },
  },
  [4] = {
    { key = "left",   up = 1, dn = 3, dt = M.DP_DEVICE_TYPE_1, comp = "curtain1", cdp = M.DP_CURTAIN_1, dur = "curtainDuration1", label = "col 1+3" },
    { key = "right",  up = 2, dn = 4, dt = M.DP_DEVICE_TYPE_2, comp = "curtain2", cdp = M.DP_CURTAIN_2, dur = "curtainDuration2", label = "col 2+4" },
  },
  [6] = {
    { key = "left",   up = 1, dn = 4, dt = M.DP_DEVICE_TYPE_1, comp = "curtain1", cdp = M.DP_CURTAIN_1, dur = "curtainDuration1", label = "col 1+4" },
    { key = "middle", up = 2, dn = 5, dt = M.DP_DEVICE_TYPE_2, comp = "curtain2", cdp = M.DP_CURTAIN_2, dur = "curtainDuration2", label = "col 2+5" },
    { key = "right",  up = 3, dn = 6, dt = M.DP_DEVICE_TYPE_3, comp = "curtain3", cdp = M.DP_CURTAIN_3, dur = "curtainDuration3", label = "col 3+6" },
  },
}

-- Device field names that store each deviceType DP value
M.DT_FIELD = {
  [M.DP_DEVICE_TYPE_1] = "devtype_dp111",
  [M.DP_DEVICE_TYPE_2] = "devtype_dp112",
  [M.DP_DEVICE_TYPE_3] = "devtype_dp113",
}

return M
