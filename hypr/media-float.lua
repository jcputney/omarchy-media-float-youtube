-- Written by the media-float `setup` script. Edits here are overwritten.
--
-- Every media-float tool (plex / twitch / youtube) uses the same two window
-- rules, so each tool's setup writes this identical file. Installing a second
-- tool overwrites it with the same content, which is why installing one, two or
-- all three needs no coordination between them.
--
-- Remove it with:  <plugin-dir>/setup --uninstall

-- ── The player ──────────────────────────────────────────────────────────────
-- One mpv window, floating and pinned so it follows you across workspaces.
-- The rule only sets the opening size: once mpv reports the real video aspect
-- the tool resizes to match, so a 2.40:1 film gets a 2.40:1 window instead of
-- one with black bars. keep_aspect_ratio holds that shape during a drag.
o.window("^(PlexFloat|TwitchFloat|YouTubeFloat)$", {
  tag = "-default-opacity",
  float = true,
  pin = true,
  no_initial_focus = true,
  keep_aspect_ratio = true,
  no_dim = true,
  border_size = 0,
  opacity = "1 1",

  -- Don't blank the screen or lock while something is playing.
  idle_inhibit = "always",

  size = { "(monitor_w/4)", "(monitor_w*9/64)" },
  move = { "(monitor_w-monitor_w/4-40)", "(monitor_h-monitor_w*9/64-40)" },
})

-- ── The fallback menu ───────────────────────────────────────────────────────
-- With the shell plugin enabled the menu is a native overlay and this rule is
-- unused. Without it the menu falls back to fzf inside a ghostty window, which
-- is what can draw real thumbnails (Kitty graphics protocol) in the preview
-- pane. Floated, centred and stripped of chrome it reads as a launcher panel
-- rather than a terminal. Ghostty is launched with --class=com.float.Picker.
o.window("^com\\.float\\.Picker$", {
  tag = "-default-opacity",
  float = true,
  center = true,
  border_size = 0,
  rounding = 12,
  opacity = "1 1",
  no_dim = true,
  size = { "(monitor_w*54/100)", "(monitor_h*60/100)" },
})
