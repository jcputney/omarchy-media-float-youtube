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

# ── Private files ───────────────────────────────────────────────────────────
# Credentials live in files on a path anyone on this machine can predict, so
# both halves of the traffic need a guarantee. Reading judges the descriptor
# rather than the name, because checking a path and then opening it leaves a
# window in which the two are different files. Writing never opens the
# destination at all: it fills a temporary in the same directory and renames it
# over the top, and rename(2) replaces the name itself, so a symlink planted
# there is overwritten rather than followed.

PRIVATE_MAX_BYTES=262144

private_read() { # private_read <file>; its bytes, or nothing
  local f="${1:-}" fd uid mode
  [[ -n $f ]] || return 1
  exec {fd}< "$f" 2>/dev/null || return 1
  # Everything below asks about the descriptor already open, not about $f.
  # /proc/self/fd/N resolves to the inode this process is holding, whatever the
  # name has become since.
  if [[ ! -f /proc/self/fd/$fd ]]; then exec {fd}<&-; return 1; fi
  read -r uid mode < <(stat -L -c '%u %a' "/proc/self/fd/$fd" 2>/dev/null) \
    || { exec {fd}<&-; return 1; }
  # Ours, and private. A credential file that anyone else can read is not one
  # we should go on using as though it were secret.
  if [[ $uid != "$EUID" ]] || (( 8#$mode & 8#077 )); then
    exec {fd}<&-; return 1
  fi
  head -c "$PRIVATE_MAX_BYTES" <&"$fd"
  exec {fd}<&-
}

private_write() { # private_write <file>; content on stdin
  local f="${1:-}" dir tmp
  [[ -n $f ]] || return 1
  dir="${f%/*}"; [[ $dir == "$f" ]] && dir="."
  ( umask 077; mkdir -p "$dir" ) || return 1
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# A hand-written config is shell-shaped because that is what people expect to
# write, but reading it is not a reason to run it. This picks a value out of
# KEY=VALUE text: last assignment wins, the way sourcing would have behaved,
# and nothing in the file is ever executed.
conf_value() { # conf_value <file> <key>; the value, or nothing
  local f="${1:-}" key="${2:-}" v
  [[ -n $f && -n $key ]] || return 1
  v="$(private_read "$f" 2>/dev/null | awk -v k="$key" '
        { sub(/\r$/, "") }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" {
          sub("^[[:space:]]*(export[[:space:]]+)?" k "=", ""); val = $0
        }
        END { if (val != "") print val }')" || return 1
  [[ -n $v ]] || return 1
  # One layer of matching quotes, since that is how a config is often written.
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# ── Credentials as data ─────────────────────────────────────────────────────
# A token reaches curl inside a config file, where a quote or a newline would
# end the value and start a fresh directive — one that could re-route the very
# request carrying the credential. Escaping for that syntax is possible and
# easy to get subtly wrong, so nothing is escaped: a value outside the set
# every real Plex and Twitch token is drawn from is refused instead. The same
# set is safe as an HTTP header value, which is the other place these go.
TOKEN_MAX_LEN=512

# Remote text that reaches a terminal, stripped of the bytes that could move
# the cursor or repaint the line. Done once, on the way in, so everything
# downstream is already safe to print.
safe_text() { # safe_text <value>
  printf '%s' "${1:-}" | tr -d '\000-\010\013\014\016-\037\177' | head -c 200
}

# A count from a remote response that is not a plain number is not a count.
# Bash re-evaluates a variable's contents inside (( )), so an unchecked value
# from a response body is an expression, not just a number.
num_or() { # num_or <value> <default>
  [[ ${1:-} =~ ^[0-9]{1,9}$ ]] && printf '%s' "$1" || printf '%s' "${2:-0}"
}

# A value that becomes part of a query string. Anything outside this set could
# end the parameter and begin another one, which is a different request from
# the one being made.
url_safe() { # url_safe <value>
  [[ ${1:-} =~ ^[A-Za-z0-9._~-]{1,128}$ ]]
}

# A path a remote response asked for. It has to stay under the root it was
# given: no climbing out, no query of its own, nothing that ends an argument.
valid_path_ref() { # valid_path_ref <path>
  local r="${1:-}"
  [[ $r == /* && ${#r} -le 512 ]] || return 1
  [[ $r != *".."* ]] || return 1
  [[ $r =~ ^[A-Za-z0-9._~/%+-]+$ ]]
}

valid_token() { # valid_token <value>
  local t="${1:-}"
  (( ${#t} > 0 && ${#t} <= TOKEN_MAX_LEN )) || return 1
  [[ $t =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

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

# ── Fetching remote bytes ───────────────────────────────────────────────────
# Nothing reads a remote body without all three bounds. A deadline alone still
# lets a fast server hand back gigabytes, and --max-filesize only refuses a
# response that declares its length up front, so the ceiling is enforced a
# second time on the way in.
FETCH_CONNECT_TIMEOUT=5
FETCH_MAX_TIME=15

# Secret-bearing curl options — an auth header, a form field — go here rather
# than in argv, which any process of this user can read out of /proc for as
# long as the request runs. It is fed to curl as a config on stdin, written by
# a shell builtin so there is no second process whose arguments could be read
# either. Callers set it with `local` so it dies with the function.
#
# Each redirect hop is its own curl invocation with its own copy of this, and
# each hop is re-checked by fetch_guard first, so a credential cannot be
# carried across an authority change the guard would refuse.
FETCH_CURL_CONFIG=""
FETCH_MAX_BYTES=8388608    # 8 MiB — far above any poster or thumbnail
# 32 MiB. A real Plex movie library answers /library/sections/<k>/all with
# about 5 MiB, so this is roughly six times the largest honest response and
# still a hard stop. Tools with smaller answers narrow it locally.
API_MAX_BYTES=33554432

# Where a fetch is allowed to go. Each tool overrides this, and it is asked
# again about every redirect target, so a redirect cannot walk out of the policy
# the first URL satisfied. Deny by default: a tool that has not thought about it
# fetches nothing.
fetch_guard() { return 1; }

# Refuses anything that is not a public address. Loopback and the private
# ranges are where a redirect would point to reach something on this machine or
# this network that the tool has no business reading.
is_public_ip() { # is_public_ip <address>
  local ip="${1:-}"
  case "$ip" in
    ""|0.0.0.0|255.255.255.255) return 1 ;;
    127.*|10.*|192.168.*|169.254.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;  # CGNAT
    ::1|::) return 1 ;;
    [fF][cCdD]*:*) return 1 ;;   # unique local
    [fF][eE][89abAB]*:*) return 1 ;;   # link local
    ::[fF][fF][fF]:*) return 1 ;;      # v4-mapped: judge it as v4 instead
    *) return 0 ;;
  esac
}

# Resolves the host once, checks that address, and hands back a --resolve pin so
# the request goes to the address that was checked. Without the pin a second
# lookup could answer differently and land somewhere the check never saw.
public_pin() { # public_pin <host> <port>; echoes host:port:address
  local host="$1" port="$2" ip
  while read -r ip; do
    [[ -n $ip ]] || continue
    is_public_ip "$ip" || return 1
    printf '%s:%s:%s\n' "$host" "$port" "$ip"
    return 0
  done < <(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  return 1
}

url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u%%\?*}"; printf '%s' "${u%%:*}"; }
url_scheme() { printf '%s' "${1%%://*}"; }
url_port() {
  local a="${1#*://}"; a="${a%%/*}"; a="${a%%\?*}"
  case "$a" in
    *:*) printf '%s' "${a##*:}" ;;
    *)   [[ $(url_scheme "$1") == https ]] && printf '443' || printf '80' ;;
  esac
}

# Redirects are followed by hand, one hop at a time. curl cannot be asked to
# check where it is going, and -L would carry a custom header — a Plex token is
# a custom header — to whatever host a redirect names. curl strips
# Authorization across origins; it does not strip anything else.
FETCH_MAX_HOPS=3

bounded_fetch() { # bounded_fetch <out-file> <url> [extra curl args…]
  local out="$1" url="$2"; shift 2
  local tmp hdr hop=0 code loc pin host port
  tmp="$(mktemp "$out.XXXXXX")" || return 1
  hdr="$tmp.hdr"

  while :; do
    fetch_guard "$url" || { rm -f "$tmp" "$hdr"; return 1; }

    pin=()
    host="$(url_host "$url")"; port="$(url_port "$url")"
    if [[ ${FETCH_REQUIRE_PUBLIC:-1} == 1 ]]; then
      local spec
      spec="$(public_pin "$host" "$port")" || { rm -f "$tmp" "$hdr"; return 1; }
      pin=(--resolve "$spec")
    fi

    : > "$hdr"
    printf '%s' "${FETCH_CURL_CONFIG:-}" \
    | curl -sS -K - "$@" "${pin[@]}" \
      --proto '=https,http' --max-redirs 0 \
      --connect-timeout "$FETCH_CONNECT_TIMEOUT" \
      --max-time "$FETCH_MAX_TIME" \
      --max-filesize "$FETCH_MAX_BYTES" \
      -D "$hdr" "$url" 2>/dev/null \
    | head -c "$FETCH_MAX_BYTES" > "$tmp"

    code="$(awk 'toupper($1) ~ /^HTTP/ { c = $2 } END { print c }' "$hdr")"
    case "$code" in
      30[1237])
        (( hop++ < FETCH_MAX_HOPS )) || break
        loc="$(awk 'tolower($1) == "location:" { $1 = ""; sub(/^ /, ""); print }' "$hdr" \
               | tr -d "\r" | tail -1)"
        case "$loc" in
          http://*|https://*) url="$loc" ;;
          /*)                 url="$(url_scheme "$url")://$host:$port$loc" ;;
          *)                  break ;;   # relative or absent: refuse to guess
        esac
        continue
        ;;
      2*) [[ -s $tmp ]] && { mv -f "$tmp" "$out"; rm -f "$hdr"; return 0; } ;;
    esac
    break
  done

  rm -f "$tmp" "$hdr"
  return 1
}

# Reads a bounded API body. Callers buffer the whole thing into a variable and
# hand it to jq, so the ceiling has to apply before that, not after.
bounded_body() { # bounded_body <url> [extra curl args…]
  local url="$1"; shift
  printf '%s' "${FETCH_CURL_CONFIG:-}" \
  | curl -fsS -K - "$@" \
      --connect-timeout "$FETCH_CONNECT_TIMEOUT" \
      --max-time "$FETCH_MAX_TIME" \
      --max-filesize "$API_MAX_BYTES" \
      "$url" 2>/dev/null | head -c "$API_MAX_BYTES"
}

# An https URL whose host is one of the ones named, or a subdomain of one.
# Anything else — another scheme, another host, a bare path — is refused.
host_allowed() { # host_allowed <url> <allowed-host>…
  local url="$1" host h; shift
  [[ $url == https://* ]] || return 1
  host="${url#https://}"; host="${host%%/*}"; host="${host%%\?*}"; host="${host%%:*}"
  [[ -n $host ]] || return 1
  for h in "$@"; do
    [[ $host == "$h" || $host == *".$h" ]] && return 0
  done
  return 1
}

# Downloads once, then serves the copy. A refresh that fails keeps the old file
# rather than blanking artwork that was fine a moment ago. Where it is allowed
# to fetch from is fetch_guard's decision, on every hop.
cache_image() { # cache_image <url> [extra curl args…]; echoes the local path
  local url="$1"; shift
  local f
  mkdir -p "$THUMB_DIR"
  f="$THUMB_DIR/$(printf %s "$url" | md5sum | cut -c1-32).img"
  if [[ ! -s $f ]] \
     || (( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) > THUMB_TTL )); then
    bounded_fetch "$f" "$url" "$@" || [[ -s $f ]] || return 1
  fi
  printf '%s\n' "$f"
}

# ── Tool hooks ──────────────────────────────────────────────────────────────
# A row's image column is an opaque reference, not a URL: only the tool knows
# whether it is a Plex library path needing an auth header or a CDN link that
# must match an allowlist. The tool turns it into a local file; nothing else
# ever hands a remote URL to an image loader.
resolve_image() { return 1; }

# Tools with facts too slow to bake into a row list override this. It receives
# the row's value columns and prints what it has, or nothing.
detail_for() { return 0; }
FLOAT_HAS_DETAIL=0

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

# The image column stays an opaque reference here. It used to be turned into a
# URL with the caller's prefix and suffix, which is how a Plex token ended up in
# this file and then in an image loader; now the tool resolves it to a local
# file, one row at a time.
#
# Every string is capped and the array is capped. A row file is written by the
# tool a few lines above, so this is not where an attack starts — but it is what
# the picker parses, and a parser with no limits is one bad feed away from
# holding the whole shell.
ROWS_MAX=5000
ROWS_LABEL_MAX=512
ROWS_IMAGE_MAX=1024
ROWS_INFO_MAX=8192
ROWS_VALUE_MAX=1024

rows_to_json() { # rows_to_json <tsv-file>
  jq -R -s \
    --argjson n "$ROWS_MAX" --argjson lm "$ROWS_LABEL_MAX" \
    --argjson im "$ROWS_IMAGE_MAX" --argjson fm "$ROWS_INFO_MAX" \
    --argjson vm "$ROWS_VALUE_MAX" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { label:    ((.[0] // "")[0:$lm]),
          imageRef: ((.[1] // "-") | if . == "-" then "" else .[0:$im] end),
          info:     (((.[2] // "") | gsub("\u001f"; "\n"))[0:$fm]),
          value:    ((.[3:] | join("\t"))[0:$vm]) } ][0:$n]' "$1"
}

# ── Going back ──────────────────────────────────────────────────────────────
# A menu with a level above it passes `back` as pick's third argument. Escape
# then answers with this sentinel instead of cancelling, and a "← Back" row
# carries the same value for the mouse and for the fzf fallback. The caller
# pops one level and loops; a menu that does not ask for it is unchanged.
FLOAT_BACK='__float_back__'

back_row() { printf '\u2190  Back\t-\t\t%s\n' "$FLOAT_BACK"; }

is_back() { [[ ${1:-} == "$FLOAT_BACK" ]]; }

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

summon_pick() { # summon_pick <rows-file> <prompt> [back]; echoes the chosen value
  local rowsf="$RUN_DIR/picker-rows.json" sel="$RUN_DIR/picker-sel" \
        don="$RUN_DIR/picker-done" payload backv=""
  [[ ${3:-} == back ]] && backv="$FLOAT_BACK"
  ( umask 077; rows_to_json "$1" > "$rowsf" ) || return 1
  rm -f "$don"; : > "$sel"
  # The payload says whether to ask for detail, never what to run. The picker
  # builds the argv itself from the plugin it was loaded out of, so a payload
  # from anywhere else cannot name a program.
  payload="$(jq -nc --arg r "$rowsf" --arg s "$sel" --arg d "$don" --arg p "$2" \
    --arg b "$backv" --argjson dt "$([[ ${FLOAT_HAS_DETAIL:-0} == 1 ]] && echo true || echo false)" \
    '{rowsFile:$r, selectionFile:$s, doneFile:$d, prompt:$p, backValue:$b,
      detail:$dt}')"
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

# The menu is named as a command and its arguments, not as a string for a shell
# to parse. It only ever re-enters this tool at one of its own _tui entry
# points, so there was nothing for a shell to add — only a way for a path with
# a space in it to become two words, and a construct that reads like an
# arbitrary-command sink to anything auditing this.
run_menu() { # run_menu <command> [args…]; echoes whatever the TUI emitted
  : > "$PICKER_OUT"
  if [[ -z ${FLOAT_PICKER_MODE:-} ]]; then
    if overlay_picker_available; then FLOAT_PICKER_MODE=overlay
    else FLOAT_PICKER_MODE=fzf; fi
  fi
  if [[ $FLOAT_PICKER_MODE == overlay ]]; then
    FLOAT_PICKER_MODE=overlay FLOAT_PICKER_OUT="$PICKER_OUT" \
      "$@" >/dev/null 2>&1 || true
    cat "$PICKER_OUT" 2>/dev/null || true
  else
    FLOAT_PICKER_MODE=fzf run_picker "$@"
  fi
}

pick() { # pick <rows-file> <prompt> [back]; echoes the value columns of the pick
  if [[ ${FLOAT_PICKER_MODE:-fzf} == overlay ]]; then summon_pick "$1" "$2" "${3:-}"
  else fzf_pick "$1" "$2" "${3:-}"; fi
}

ask() { # ask <prompt>; free text typed by the user
  if [[ ${FLOAT_PICKER_MODE:-fzf} == overlay ]]; then summon_ask "$1"
  else fzf_ask "$1"; fi
}

run_picker() { # run_picker <command> [args…]; echoes whatever the TUI emitted
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
    -e "$@" >/dev/null 2>&1 || true
  cat "$PICKER_OUT" 2>/dev/null || true
}

picker_emit() { printf '%s\n' "$*" > "${FLOAT_PICKER_OUT:?picker_emit outside a picker}"; }
emit() { picker_emit "$@"; }

fzf_pick() { # fzf_pick <rows-file> <prompt> [back]; echoes fields 4..n of the pick
  local rows="$1" prompt="$2" back="${3:-}" sel
  # Escape and an empty answer are the same gesture here, and both mean "up a
  # level" when there is one.
  dismissed() { [[ $back == back ]] && { printf '%s\n' "$FLOAT_BACK"; return 0; }; return 1; }
  [[ -s $rows ]] || return 1
  # The back row is first so it is visible without scrolling, so start the
  # cursor below it — otherwise Enter on an untouched list means "go back".
  local start=(); [[ $back == back ]] && start=(--bind=load:down)
  sel="$(fzf --delimiter=$'\t' --with-nth=1 \
      "$(picker_fzf_colors)" \
      "${start[@]}" \
      --prompt="$prompt " \
      --height=100% --layout=reverse --info=inline --border=none --no-multi \
      --preview="$SELF _preview {2} {3} {}" \
      --preview-window="right,48%,border-left" \
      < "$rows")" || { dismissed; return $?; }
  [[ -n $sel ]] || { dismissed; return $?; }
  printf '%s\n' "$sel" | cut -f4-
}

fzf_ask() { # fzf_ask <prompt>; free text typed by the user
  fzf --print-query "$(picker_fzf_colors)" --prompt="$1 " \
      --height=100% --layout=reverse --info=hidden --border=none --no-multi \
      < /dev/null 2>/dev/null | head -1
}

render_preview() { # render_preview <image-ref|-> <info|-> [raw-row]
  local ref="${1:--}" info="${2:--}" row="${3:-}" cols lines rows f
  cols=${FZF_PREVIEW_COLUMNS:-40}
  lines=${FZF_PREVIEW_LINES:-20}
  if [[ $ref != "-" && -n $ref ]]; then
    f="$(resolve_image "$ref" 2>/dev/null || true)"
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
  # fzf kills the running preview when the cursor moves on, so a slow lookup
  # only ever finishes for the row someone stopped at. That is the debounce.
  if [[ -n $row && ${FLOAT_HAS_DETAIL:-0} == 1 ]]; then
    local detail
    detail="$(detail_for "$(printf '%s' "$row" | cut -f4-)" 2>/dev/null || true)"
    if [[ -n $detail ]]; then
      printf '\n%s\n' "$detail" | fold -s -w "$cols"
    fi
  fi
}
