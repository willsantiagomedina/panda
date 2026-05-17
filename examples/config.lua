-- panda config (Lua-style table)
-- path: ~/.config/panda/config.lua

return {
  -- defaults used by `panda daemon` and `panda tile`
  scope = "all-main-display", -- focused-app | all-main-display
  layout = "bsp",             -- bsp | grid | master-stack
  border = true,

  -- polling/debounce tuning (seconds)
  performance = {
    focus_poll_interval = 0.08,
    snapshot_poll_interval = 0.75,
    observer_snapshot_poll_interval = 0.20,
    command_poll_interval = 0.02,
    relayout_immediate_delay = 0.01,
    relayout_burst_delay = 0.04,
    burst_window = 0.12,
    min_relayout_interval = 0.03,
    self_event_suppression_window = 0.20,
    swap_double_tap_window = 0.35,
  },

  -- Desktop commands are Panda-managed virtual workspaces, independent of
  -- macOS Mission Control Spaces. These chords are daemon hotkey defaults.
  desktop = {
    switch_prev = "ctrl+left",
    switch_next = "ctrl+right",
    move_prev = "ctrl+shift+left",
    move_next = "ctrl+shift+right",
    switch_1 = "ctrl+1",
    switch_2 = "ctrl+2",
    switch_3 = "ctrl+3",
    switch_4 = "ctrl+4",
    switch_5 = "ctrl+5",
    switch_6 = "ctrl+6",
    switch_7 = "ctrl+7",
    switch_8 = "ctrl+8",
    switch_9 = "ctrl+9",
  },

  -- Optional global hotkeys handled directly by panda daemon.
  -- You can remove this block if you prefer skhd/aerospace/etc.
  shortcuts = {
    focus_left = "alt+h",
    focus_down = "alt+j",
    focus_up = "alt+k",
    focus_right = "alt+l",

    swap_left = "alt+shift+h",
    swap_down = "alt+shift+j",
    swap_up = "alt+shift+k",
    swap_right = "alt+shift+l",

    desktop_prev = "alt+cmd+left",
    desktop_next = "alt+cmd+right",
    desktop_move_prev = "alt+cmd+shift+left",
    desktop_move_next = "alt+cmd+shift+right",

    desktop_1 = "option+1",
    desktop_2 = "option+2",
    desktop_3 = "option+3",
    desktop_4 = "option+4",
    desktop_5 = "option+5",
    desktop_6 = "option+6",

    border_toggle = "alt+b",
  },
}
