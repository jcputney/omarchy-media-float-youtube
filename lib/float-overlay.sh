# Shared machinery for the floating, pinned mpv overlays (plex-float,
# twitch-float). Sourced, never executed.
#
# One overlay runs at a time, so the socket, pid file and size preference are
# shared: whichever overlay is up, the same hide/show and resize keys drive it.
#
# Callers must set OVERLAY_APP_NAME (used in notifications) before sourcing, and
# pass their own app id to overlay_mpv_args.

OVERLAY_CLASS_RE="^(PlexFloat|TwitchFloat|YouTubeFloat)$"

RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/float-overlay"
SOCKET="$RUN_DIR/mpv.sock"
POS_FILE="$RUN_DIR/position"
PID_FILE="$RUN_DIR/session.pid"
STOP_FLAG="$RUN_DIR/stop"
LOG="$RUN_DIR/session.log"
SPECIAL_WS="special:floatoverlay"

OVERLAY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/float-overlay"
SIZE_FILE="$OVERLAY_CONFIG_DIR/size"

MARGIN=40
MIN_WIDTH=320
PRESETS=(small medium large huge)

mkdir -p "$RUN_DIR" "$OVERLAY_CONFIG_DIR"

note() { notify-send -a "${OVERLAY_APP_NAME:-Overlay}" "${OVERLAY_APP_NAME:-Overlay}" "$1" >/dev/null 2>&1 || true; }
die() { note "$1"; printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }

# ── Hyprland ────────────────────────────────────────────────────────────────
# Hyprland 0.56 parses `hyprctl dispatch` arguments as Lua and wraps them in
# hl.dispatch(...), so dispatchers are built with hl.dsp.* rather than passed as
# the old "name arg1,arg2" strings. Those old strings are a Lua syntax error.
dispatch() { hyprctl dispatch "$1" >/dev/null; }

overlay_address() {
  hyprctl -j clients 2>/dev/null \
    | jq -r --arg re "$OVERLAY_CLASS_RE" '.[] | select(.class | test($re)) | .address' | head -1
}

overlay_field() { # overlay_field <jq-path>
  hyprctl -j clients | jq -r --arg re "$OVERLAY_CLASS_RE" \
    ".[] | select(.class | test(\$re)) | $1" | head -1
}

overlay_rect() { # "x y w h" in global logical pixels
  hyprctl -j clients | jq -r --arg re "$OVERLAY_CLASS_RE" \
    '.[] | select(.class | test($re)) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -1
}

set_pinned() { # set_pinned <address> <true|false>; pin is a toggle, so check first
  local addr="$1" want="$2"
  [[ "$(overlay_field .pinned)" == "$want" ]] && return 0
  dispatch "hl.dsp.window.pin(\"address:$addr\")"
}

# ── mpv ─────────────────────────────────────────────────────────────────────

mpv_cmd() {
  [[ -S $SOCKET ]] || return 1
  printf '%s\n' "$1" | timeout 3 socat - "UNIX-CONNECT:$SOCKET" 2>/dev/null
}

mpv_get() {
  mpv_cmd "$(printf '{"command":["get_property","%s"]}' "$1")" \
    | jq -r 'select(.error == "success") | .data' 2>/dev/null | head -1
}

overlay_mpv_args() { # overlay_mpv_args <app-id> <title>; sets OVERLAY_MPV_ARGS
  OVERLAY_MPV_ARGS=(
    --wayland-app-id="$1"
    --title="$2"
    --force-media-title="$2"
    --input-ipc-server="$SOCKET"
    --force-window=immediate
    --keep-open=no
    --idle=no
    --hwdec=auto-safe
  )
}

# ── Sizing ──────────────────────────────────────────────────────────────────
# The overlay is an ordinary floating window, so SUPER + right-drag resizes it
# by hand. These presets exist so it can be resized from the keyboard too, and
# so the size carries into the next thing you play.
#
# Heights follow the real video aspect rather than a hardcoded 16:9.

saved_preset() { cat "$SIZE_FILE" 2>/dev/null || echo medium; }

preset_width() { # preset_width <preset> <monitor-logical-width>
  case "$1" in
    small)  echo $(( $2 / 6 )) ;;
    large)  echo $(( $2 / 3 )) ;;
    huge)   echo $(( $2 / 2 )) ;;
    *)      echo $(( $2 / 4 )) ;;   # medium
  esac
}

overlay_monitor_geom() { # "x y logical_w logical_h" of the monitor showing the overlay
  # Worked out from the window's centre rather than read from the client's
  # .monitor field: Hyprland does not reassign .monitor when a window is moved
  # across screens by an absolute-coordinate dispatch, so that field goes stale
  # and the overlay gets anchored to the corner of the monitor it used to be on.
  local ox oy ow oh cx cy
  read -r ox oy ow oh < <(overlay_rect) || return 1
  [[ -n ${oh:-} ]] || return 1
  cx=$(( ox + ow / 2 ))
  cy=$(( oy + oh / 2 ))
  hyprctl -j monitors | jq -r --argjson cx "$cx" --argjson cy "$cy" '
    [ .[] | select(
        $cx >= .x and $cx < (.x + ((.width / .scale) | floor)) and
        $cy >= .y and $cy < (.y + ((.height / .scale) | floor))
      ) ] as $hit
    | ( if ($hit | length) > 0 then $hit[0] else .[0] end )
    | "\(.x) \(.y) \((.width / .scale) | floor) \((.height / .scale) | floor)"'
}

video_aspect() {
  local a
  a="$(mpv_get video-params/aspect 2>/dev/null || true)"
  [[ $a =~ ^[0-9]+(\.[0-9]+)?$ ]] || a="1.777778"
  printf '%s\n' "$a"
}

apply_size() { # apply_size <width-in-logical-px>
  local addr w h a mx my mw mh ox oy ow oh nx ny
  addr="$(overlay_address)"
  [[ -n $addr ]] || return 0
  read -r mx my mw mh < <(overlay_monitor_geom) || return 0
  [[ -n ${mh:-} ]] || return 0

  a="$(video_aspect)"
  w="$1"
  if (( w > mw - 2 * MARGIN )); then w=$(( mw - 2 * MARGIN )); fi
  if (( w < MIN_WIDTH )); then w=$MIN_WIDTH; fi
  h="$(awk -v w="$w" -v a="$a" 'BEGIN { printf "%d", w / a }')"
  if (( h > mh - 2 * MARGIN )); then
    h=$(( mh - 2 * MARGIN ))
    w="$(awk -v h="$h" -v a="$a" 'BEGIN { printf "%d", h * a }')"
  fi

  # Keep whichever corner it currently sits nearest, so resizing doesn't yank
  # the window back across the screen if you've dragged it somewhere else.
  read -r ox oy ow oh < <(overlay_rect) || return 0
  if (( (ox + ow / 2 - mx) * 2 > mw )); then nx=$(( mx + mw - w - MARGIN )); else nx=$(( mx + MARGIN )); fi
  if (( (oy + oh / 2 - my) * 2 > mh )); then ny=$(( my + mh - h - MARGIN )); else ny=$(( my + MARGIN )); fi

  dispatch "hl.dsp.window.resize({x=$w, y=$h, window=\"address:$addr\"})"
  dispatch "hl.dsp.window.move({x=$nx, y=$ny, window=\"address:$addr\"})"
}

apply_saved_size() {
  local mx my mw mh
  read -r mx my mw mh < <(overlay_monitor_geom) || return 0
  [[ -n ${mw:-} ]] || return 0
  apply_size "$(preset_width "$(saved_preset)" "$mw")"
}

overlay_apply_size_when_ready() {
  (
    for _ in $(seq 1 60); do
      if [[ -n "$(overlay_address)" && -S $SOCKET ]]; then
        sleep 0.4
        apply_saved_size
        break
      fi
      sleep 0.25
    done
  ) >/dev/null 2>&1 &
}

cmd_size() {
  local arg="${1:-cycle}" cur i n
  cur="$(saved_preset)"
  case "$arg" in
    small|medium|large|huge) cur="$arg" ;;
    larger|smaller|cycle|next)
      n=${#PRESETS[@]}
      i=0
      for i in "${!PRESETS[@]}"; do
        [[ ${PRESETS[$i]} == "$cur" ]] && break
      done
      case "$arg" in
        larger)  if (( i < n - 1 )); then i=$(( i + 1 )); fi ;;
        smaller) if (( i > 0 )); then i=$(( i - 1 )); fi ;;
        *)       i=$(( (i + 1) % n )) ;;
      esac
      cur="${PRESETS[$i]}"
      ;;
    *) die "Unknown size: $arg (small|medium|large|huge|larger|smaller|cycle)" ;;
  esac
  printf '%s\n' "$cur" > "$SIZE_FILE"
  if [[ -n "$(overlay_address)" ]]; then
    apply_saved_size
    note "Overlay: $cur"
  else
    note "Overlay: $cur (applies next time you play something)"
  fi
}

# ── Hide / show ─────────────────────────────────────────────────────────────
# Hiding parks the window on a special workspace; showing brings it back and
# re-pins it. Each step is given a moment to settle, and the result is checked,
# because a pin and a workspace move issued back to back can occasionally land
# out of order and leave the overlay in the state it started in.

overlay_set_state() { # overlay_set_state <address> <show|hide>
  local addr="$1" want="$2" ws
  if [[ $want == show ]]; then
    dispatch "hl.dsp.window.move({workspace=\"$(hyprctl -j activeworkspace | jq -r .id)\", window=\"address:$addr\", silent=true})"
    sleep 0.25
    set_pinned "$addr" true
  else
    set_pinned "$addr" false
    sleep 0.25
    dispatch "hl.dsp.window.move({workspace=\"$SPECIAL_WS\", window=\"address:$addr\", silent=true})"
  fi
  sleep 0.35
  ws="$(overlay_field .workspace.name)"
  if [[ $want == hide ]]; then
    [[ $ws == "$SPECIAL_WS" ]]
  else
    [[ $ws != "$SPECIAL_WS" ]]
  fi
}

cmd_toggle() {
  local addr want
  addr="$(overlay_address)"
  [[ -n $addr ]] || die "Nothing is playing"
  if [[ "$(overlay_field .workspace.name)" == "$SPECIAL_WS" ]]; then want=show; else want=hide; fi
  overlay_set_state "$addr" "$want" || overlay_set_state "$addr" "$want"
}

# ── Session lifecycle ───────────────────────────────────────────────────────

# pkill -f matches on the whole command line, so it will happily kill a shell
# that merely mentions the pattern — including this one. Match, then skip
# ourselves and our parent before killing.
kill_matching() {
  [[ ${1:-} == "--" ]] && shift
  local pid comm
  for pid in $(pgrep -f -- "$1" 2>/dev/null || true); do
    [[ $pid == "$$" || $pid == "${PPID:-0}" ]] && continue
    # A shell whose command line merely mentions the pattern is not the target.
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in sh|bash|zsh|fish|dash|pgrep|grep|awk|sed) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done
}

stop_existing() {
  if [[ -f $PID_FILE ]]; then
    local old
    old="$(cat "$PID_FILE")"
    if [[ -n $old && $old != "$$" ]] && kill -0 "$old" 2>/dev/null; then
      touch "$STOP_FLAG"
      kill -- "-$old" 2>/dev/null || kill "$old" 2>/dev/null || true
      sleep 0.5
    fi
  fi
  kill_matching -- "--wayland-app-id=PlexFloat"
  kill_matching -- "--wayland-app-id=TwitchFloat"
  kill_matching -- "streamlink --twitch-disable-ads --stdout"
  rm -f "$STOP_FLAG"
}

cmd_quit() {
  touch "$STOP_FLAG"
  # Grab the exact position first; a scrobble loop's copy can be seconds stale.
  local pos pid i
  pos="$(mpv_get time-pos 2>/dev/null || true)"
  [[ -n ${pos:-} && $pos != null ]] && printf '%s\n' "${pos%.*}" > "$POS_FILE"
  mpv_cmd '{"command":["quit"]}' >/dev/null 2>&1 || true
  # Give the session time to finish up (e.g. write progress back to Plex). It
  # exits on its own once mpv is gone.
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n $pid ]]; then
    for i in $(seq 1 24); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
  fi
  stop_existing
}

# ── Picker ──────────────────────────────────────────────────────────────────
# Menus run as fzf inside a floating ghostty window (see the FloatPicker rule in
# hypr/windows.lua). Ghostty speaks the Kitty graphics protocol, so chafa can
# draw a real thumbnail in the preview pane rather than character art.
#
# The whole navigation runs inside that one terminal: a front-end launches its
# own `_tui` entry point there, the TUI writes its answer with picker_emit, and
# the parent reads it once the window closes. That keeps multi-step browsing
# (show -> episode, category -> stream) in a single window.
#
# Rows are TSV:  <display> \t <image-url|-> \t <info|-> \t <value…>
# fzf shows only the display column; the preview pane gets fields 2 and 3; the
# selection returns fields 4 onwards. Info text uses literal \n for line breaks.

# Ghostty validates --class as a GTK application ID: it must be reverse-DNS
# with at least two dot-separated segments. A bare word is silently ignored
# and the window keeps the default com.mitchellh.ghostty class.
PICKER_CLASS="com.float.Picker"
PICKER_OUT="$RUN_DIR/picker.out"
THUMB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/float-overlay/thumbs"
THUMB_TTL=300   # live thumbnails go stale; refetch after this many seconds

# Colours come from the live Omarchy theme, so the menu follows `omarchy theme
# set` without being touched.
theme_color() { # theme_color <key> <fallback>
  local f="$HOME/.local/state/omarchy/current/theme/colors.toml" v
  v="$(sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(#[0-9a-fA-F]*\)\".*/\1/p" "$f" 2>/dev/null | head -1)"
  printf '%s\n' "${v:-$2}"
}

picker_fzf_colors() {
  local bg fg sel accent muted hi
  bg="$(theme_color background '#1e1e2e')"
  fg="$(theme_color foreground '#cdd6f4')"
  sel="$(theme_color selection '#45475a')"
  accent="$(theme_color accent '#89b4fa')"
  muted="$(theme_color dark_foreground '#6c7086')"
  hi="$(theme_color magenta '#f5c2e7')"
  printf '%s' "--color=bg:$bg,bg+:$sel,fg:$fg,fg+:$fg,hl:$accent,hl+:$accent"
  printf '%s' ",prompt:$accent,pointer:$hi,info:$muted,border:$sel,gutter:$bg,query:$fg"
}

# ── Overlay picker (Omarchy plugin) ─────────────────────────────────────────
# When the shell plugin is installed the picker is a native overlay: rows go
# out as JSON, one value comes back through a file. Everything falls back to
# the ghostty+fzf picker when the plugin is missing, so the tools still work
# outside Omarchy.

# Set by each tool before this file is sourced.
PICKER_PLUGIN_ID="${FLOAT_PICKER_PLUGIN_ID:-}"

overlay_picker_available() {
  [[ -n $PICKER_PLUGIN_ID ]] || return 1
  command -v omarchy-shell >/dev/null 2>&1 || return 1
  omarchy plugin list --json 2>/dev/null \
    | jq -e --arg i "$PICKER_PLUGIN_ID" \
        'any(.[]; .id == $i and (.enabled // false))' >/dev/null 2>&1
}

rows_to_json() { # rows_to_json <tsv-file>
  jq -R -s --arg pre "${FLOAT_PICKER_IMAGE_PREFIX:-}" \
           --arg suf "${FLOAT_PICKER_IMAGE_SUFFIX:-}" '
    split("\n")[] | select(length > 0) | split("\t")
    | { label: (.[0] // ""),
        image: ( (.[1] // "-") as $i
                 | if $i == "-" or $i == "" then ""
                   elif ($i | startswith("/")) then $pre + $i + $suf
                   else $i end ),
        info:  ((.[2] // "") | gsub("\u001f"; "\n")),
        value: (.[3:] | join("\t")) }' "$1" | jq -s .
}

PICKER_LAYER="omarchy-media-float"

picker_layer_up() {
  hyprctl -j layers 2>/dev/null | grep -q "\"$PICKER_LAYER\""
}

# Waiting on a stopwatch was wrong: a picker is open until a person decides,
# and no timeout is both long enough for them and short enough to catch a
# plugin that never loaded. Wait for the overlay to map instead — that is the
# proof it loaded — then wait on the person for as long as it takes.
await_pick() { # await_pick <selection-file> <done-file>
  local waited=0
  while (( waited < 60 )); do
    [[ -e $2 ]] && { cat "$1"; return 0; }
    picker_layer_up && break
    sleep 0.05; waited=$(( waited + 1 ))
  done
  [[ -e $2 ]] || picker_layer_up || return 1

  while [[ ! -e $2 ]]; do
    if ! picker_layer_up; then
      # finish() starts the write and hides in the same breath, so the layer
      # can vanish a beat before the file lands. Only call it a dismissal if
      # nothing shows up.
      for _ in $(seq 1 20); do [[ -e $2 ]] && break; sleep 0.05; done
      break
    fi
    sleep 0.1
  done
  [[ -e $2 ]] || return 1
  cat "$1"
}

summon_pick() { # summon_pick <rows-file> <prompt>; echoes the chosen value
  local rowsf="$RUN_DIR/picker-rows.json" sel="$RUN_DIR/picker-sel" \
        don="$RUN_DIR/picker-done" payload
  ( umask 077; rows_to_json "$1" > "$rowsf" ) || return 1
  rm -f "$don"; : > "$sel"
  payload="$(jq -nc --arg r "$rowsf" --arg s "$sel" --arg d "$don" --arg p "$2" \
    '{rowsFile:$r, selectionFile:$s, doneFile:$d, prompt:$p}')"
  omarchy-shell shell summon "$PICKER_PLUGIN_ID" "$payload" >/dev/null 2>&1 || return 1
  await_pick "$sel" "$don"
}

summon_ask() { # summon_ask <prompt>; free text typed into the overlay
  local sel="$RUN_DIR/picker-sel" don="$RUN_DIR/picker-done" payload
  rm -f "$don"; : > "$sel"
  payload="$(jq -nc --arg s "$sel" --arg d "$don" --arg p "$1" \
    '{selectionFile:$s, doneFile:$d, prompt:$p, freeText:true}')"
  omarchy-shell shell summon "$PICKER_PLUGIN_ID" "$payload" >/dev/null 2>&1 || return 1
  await_pick "$sel" "$don"
}

# ── Backend selection ───────────────────────────────────────────────────────
# The tools' menu code is written once and runs against either backend. A menu
# is a subprocess re-entering the tool at its own `_tui` entry point; it answers
# with `emit`, and run_menu reads that answer back. The only difference is where
# the child draws: in overlay mode it summons the plugin and never opens a
# window, in fzf mode it runs inside a floating ghostty.
#
# The mode is decided once, by the parent, and inherited. The child must not
# re-probe: `omarchy plugin list` is slow, and a mid-navigation flip would strand
# a menu between backends.

run_menu() { # run_menu <command-string>; echoes whatever the TUI emitted
  : > "$PICKER_OUT"
  if [[ -z ${FLOAT_PICKER_MODE:-} ]]; then
    if overlay_picker_available; then FLOAT_PICKER_MODE=overlay
    else FLOAT_PICKER_MODE=fzf; fi
  fi
  if [[ $FLOAT_PICKER_MODE == overlay ]]; then
    FLOAT_PICKER_MODE=overlay FLOAT_PICKER_OUT="$PICKER_OUT" \
      sh -c "$1" >/dev/null 2>&1 || true
    cat "$PICKER_OUT" 2>/dev/null || true
  else
    FLOAT_PICKER_MODE=fzf run_picker "$1"
  fi
}

pick() { # pick <rows-file> <prompt>; echoes the value columns of the pick
  if [[ ${FLOAT_PICKER_MODE:-fzf} == overlay ]]; then summon_pick "$1" "$2"
  else fzf_pick "$1" "$2"; fi
}

ask() { # ask <prompt>; free text typed by the user
  if [[ ${FLOAT_PICKER_MODE:-fzf} == overlay ]]; then summon_ask "$1"
  else fzf_ask "$1"; fi
}

run_picker() { # run_picker <command-string>; echoes whatever the TUI emitted
  : > "$PICKER_OUT"
  # A floating, borderless, centred window (see the FloatPicker rule in
  # hypr/windows.lua) — it reads as a launcher panel, not a terminal.
  FLOAT_PICKER_OUT="$PICKER_OUT" ghostty \
    --class="$PICKER_CLASS" \
    --gtk-single-instance=false \
    --font-size=11 \
    --window-padding-x=18 \
    --window-padding-y=16 \
    --window-decoration=none \
    --gtk-titlebar=false \
    --mouse-hide-while-typing=true \
    --command="$1" >/dev/null 2>&1 || true
  cat "$PICKER_OUT" 2>/dev/null || true
}

picker_emit() { printf '%s\n' "$*" > "${FLOAT_PICKER_OUT:?picker_emit outside a picker}"; }
emit() { picker_emit "$@"; }

fzf_pick() { # fzf_pick <rows-file> <prompt>; echoes fields 4..n of the pick
  local rows="$1" prompt="$2" sel
  [[ -s $rows ]] || return 1
  sel="$(fzf --delimiter=$'\t' --with-nth=1 \
      "$(picker_fzf_colors)" \
      --prompt="$prompt " \
      --height=100% --layout=reverse --info=inline --border=none --no-multi \
      --preview="$SELF _preview {2} {3}" \
      --preview-window="right,48%,border-left" \
      < "$rows")" || return 1
  [[ -n $sel ]] || return 1
  printf '%s\n' "$sel" | cut -f4-
}

fzf_ask() { # fzf_ask <prompt>; free text typed by the user
  fzf --print-query "$(picker_fzf_colors)" --prompt="$1 " \
      --height=100% --layout=reverse --info=hidden --border=none --no-multi \
      < /dev/null 2>/dev/null | head -1
}

render_preview() { # render_preview <image-url|-> <info|->
  local url="${1:--}" info="${2:--}" cols lines rows f
  cols=${FZF_PREVIEW_COLUMNS:-40}
  lines=${FZF_PREVIEW_LINES:-20}
  if [[ $url != "-" ]]; then
    mkdir -p "$THUMB_DIR"
    f="$THUMB_DIR/$(printf %s "$url" | md5sum | cut -c1-32).img"
    if [[ ! -s $f ]] || (( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) > THUMB_TTL )); then
      curl -fsSL --max-time 8 -o "$f" "$url" 2>/dev/null || true
    fi
    # Leave room under the image for the text block.
    rows=$(( lines * 55 / 100 ))
    (( rows < 6 )) && rows=6
    if [[ -s $f ]]; then
      # Kitty-protocol images do not advance the cursor, and chafa emits a
      # single newline. Chafa shrinks the box to the image aspect and reports
      # the row count it settled on in the placement header, so read that back
      # and pad the remaining rows; otherwise the text lands behind the image.
      local img i r
      img="$(mktemp "$RUN_DIR/preview.XXXXXX")"
      if chafa -f kitty --animate off --clear --size "${cols}x${rows}" "$f" >"$img" 2>/dev/null; then
        r="$(head -c 200 "$img" | sed -n 's/.*,r=\([0-9]\{1,4\}\),.*/\1/p')"
        cat "$img"
        for (( i = 1; i < ${r:-$rows}; i++ )); do printf '\n'; done
      fi
      rm -f "$img"
    fi
  fi
  if [[ $info != "-" ]]; then
    # Line breaks arrive as U+001F. jq's @tsv escapes backslashes, so a "\n"
    # in the info field would come out as a literal backslash-n; a control
    # character passes through untouched.
    printf '\n'
    printf '%s\n' "$info" | tr '\037' '\n' | fold -s -w "$cols"
  fi
}
