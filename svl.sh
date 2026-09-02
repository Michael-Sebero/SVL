#!/usr/bin/env bash
# Void Linux TUI installer - BIOS or UEFI (auto-detected), glibc, single-disk

### RE-EXEC UNDER BASH IF INVOKED WITH SH ###
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -uo pipefail

### DEFAULTS - EDIT BEFORE HOSTING ###
HOSTNAME_VAL="void"
LOCALE_LINE="en_US.UTF-8 UTF-8"
LANG_VAL="en_US.UTF-8"
KEYMAP_VAL="us"
TZ_VAL="UTC"
EFI_SIZE="1024M"
BIOS_BOOT_SIZE="1M"
SWAP_SIZE="15G"
REPO="https://repo-default.voidlinux.org/current"
ARCH="x86_64"
USER_GROUPS="wheel,users,audio,video,input,storage,optical,cdrom,network,kvm,plugdev"
LOG="/var/tmp/void-install.log"
MIRROR_RATE_CANDIDATES=3
MIRROR_RATE_SECS=4

BACKTITLE="Simple Void Linux"
HAVE_DIALOG=0
WORKDIR=""
MIRROR_PID=""
BOOT_MODE=""
DISK="" BOOT_PART="" SWAP_PART="" ROOT_PART=""
FS_CHOICE="" ENCRYPT="no" LUKS_UUID=""
DE_CHOICE="" GPU_VENDOR="unknown"
USERNAME="" USERPASS="" ROOTPASS="" LUKS_PASS=""

part() { case "$1" in *[0-9]) printf '%sp%s' "$1" "$2" ;; *) printf '%s%s' "$1" "$2" ;; esac; }

cleanup_and_exit() {
  local code="${1:-1}"
  swapoff "$SWAP_PART" >/dev/null 2>&1 || true
  if [ "$ENCRYPT" = "yes" ]; then cryptsetup close void_root >/dev/null 2>&1 || true; fi
  umount -R /mnt >/dev/null 2>&1 || true
  exit "$code"
}

die() {
  if [ "$HAVE_DIALOG" = "1" ]; then
    # Pinned to /dev/tty: same command-substitution issue ask() below works around.
    dialog --backtitle "$BACKTITLE" --title "Error" --msgbox "$*\n\nLog: $LOG" 12 65 1>/dev/tty
  else
    echo "ERROR: $*" >&2
  fi
  cleanup_and_exit 1
}

# dialog draws to stdout and writes the answer to stderr - stdout is pinned
# to /dev/tty so a caller like VAR=$(get_password ...) doesn't swallow the UI.
ask() { dialog "$@" 1>/dev/tty 2>"$WORKDIR/ans"; }

### PROGRESS DISPLAY (BOX-DRAWN, NO PERCENTAGE GAUGE) ###
# TOTAL_PARTS must match the number of run_part calls in main().
TOTAL_PARTS=3
CURRENT_PART=0
PROGRESS_BOX_LINES=6
# Spinner shown beside "Part X/Y" while a step runs; swapped for check/cross when done.
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPINNER_IDX=0

# Colors/cursor control only enabled on a real, capable terminal, so nothing
# leaks into $LOG on a redirected/non-interactive run.
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  TUI_LIVE=1
  # xterm-256 color 65 approximates Void's brand green (Viridian, #478061);
  # falls back to plain ANSI green on 8/16-color terminals.
  if [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
    C_BORDER=$(tput setaf 65)
  else
    C_BORDER=$(tput setaf 2)
  fi
  C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_OK=$(tput setaf 2); C_FAIL=$(tput setaf 1); C_RESET=$(tput sgr0); EL_SEQ=$(tput el)
else
  TUI_LIVE=0
  C_BORDER=""; C_BOLD=""; C_DIM=""; C_OK=""; C_FAIL=""; C_RESET=""; EL_SEQ=""
fi

# Terminal width, clamped so box_width()/progress_paint() math never goes negative.
term_width() {
  local w
  w=$(tput cols 2>/dev/null) || w=80
  [ "$w" -ge 44 ] 2>/dev/null || w=44
  printf '%s' "$w"
}

# Box width proportional to the terminal, capped at 78 cols and floored at 36
# so header text always fits; progress_paint() centers it within term_width().
box_width() {
  local w target; w=$(term_width)
  target=$((w - 4))
  [ "$target" -le 78 ] || target=78
  [ "$target" -ge 36 ] || target=36
  printf '%s' "$target"
}

fmt_elapsed() {
  local s="$1" h m
  h=$((s / 3600)); m=$(((s % 3600) / 60)); s=$((s % 60))
  if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"
  else printf '%d:%02d' "$m" "$s"
  fi
}

# Repeats a (possibly multi-byte UTF-8) character "$1" "$2" times. A plain
# bash loop, not tr/substring: those are byte-wise and can split a box-drawing char.
repeat_char() {
  local ch="$1" n="$2" out="" i
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

# Paints the boxed status display (spinner, part label, elapsed time, latest
# log line), padded to exact width so a shorter repaint leaves no stray text.
# Repainted in place by run_part().
progress_paint() {
  local msg="$1" elapsed="$2" activity="$3" style="${4:-}"
  local width; width=$(box_width)
  local inner=$((width - 2))       # columns between the two side borders
  local content=$((inner - 2))     # inner width minus the "| "/" |" padding
  local outer; outer=$(term_width)
  local padn=$(( (outer - width) / 2 ))
  [ "$padn" -ge 0 ] || padn=0
  local pad; pad=$(printf '%*s' "$padn" '')

  local hline; hline=$(repeat_char '─' "$inner")
  local top="${pad}${C_BORDER}┌${hline}┐${C_RESET}${EL_SEQ}"
  local mid="${pad}${C_BORDER}├${hline}┤${C_RESET}${EL_SEQ}"
  local bot="${pad}${C_BORDER}└${hline}┘${C_RESET}${EL_SEQ}"
  local side_l="${pad}${C_BORDER}│${C_RESET} "
  local side_r=" ${C_BORDER}│${C_RESET}${EL_SEQ}"

  local icon
  case "$style" in
    ok)   icon="${C_OK}✓${C_RESET}" ;;
    fail) icon="${C_FAIL}✗${C_RESET}" ;;
    *)    icon="${C_BORDER}${SPINNER_FRAMES[$((SPINNER_IDX % ${#SPINNER_FRAMES[@]}))]}${C_RESET}" ;;
  esac
  local part_label="Part ${CURRENT_PART}/${TOTAL_PARTS}"
  local time_label; time_label="Elapsed Time: $(fmt_elapsed "$elapsed")"
  local head_gap=$((content - 2 - ${#part_label} - ${#time_label}))
  [ "$head_gap" -ge 1 ] || head_gap=1
  local head_pad; head_pad=$(printf '%*s' "$head_gap" '')

  msg=$(printf '%s' "$msg" | cut -c1-"$content")
  local msg_pad=$((content - ${#msg})); [ "$msg_pad" -ge 0 ] || msg_pad=0

  activity=$(printf '%s' "$activity" | cut -c1-"$content")
  local activity_color="$C_DIM"
  case "$style" in
    ok)   activity_color="$C_OK" ;;
    fail) activity_color="$C_FAIL" ;;
  esac
  local act_pad=$((content - ${#activity})); [ "$act_pad" -ge 0 ] || act_pad=0

  printf '%s\n' "$top"
  printf '%s%s %s%s%s%s%s%s%s%s\n' \
    "$side_l" "$icon" "$C_BOLD" "$part_label" "$C_RESET" "$head_pad" "$C_DIM" "$time_label" "$C_RESET" "$side_r"
  printf '%s\n' "$mid"
  printf '%s%s%s%s%*s%s\n' "$side_l" "$C_BOLD" "$msg" "$C_RESET" "$msg_pad" '' "$side_r"
  printf '%s%s%s%s%*s%s\n' "$side_l" "$activity_color" "$activity" "$C_RESET" "$act_pad" '' "$side_r"
  printf '%s\n' "$bot"
}

run_part() {
  local msg="$1"; shift
  CURRENT_PART=$((CURRENT_PART + 1))
  # stdin closed so an unexpected prompt fails fast (EOF) instead of hanging invisibly.
  ( "$@" ) >>"$LOG" 2>&1 </dev/null &
  local pid=$! start_ts=$SECONDS elapsed=0 line rc

  [ "$TUI_LIVE" = "1" ] && tput civis 2>/dev/null
  printf '\n'
  SPINNER_IDX=0
  progress_paint "$msg" 0 "Working..."
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.4
    elapsed=$((SECONDS - start_ts))
    SPINNER_IDX=$((SPINNER_IDX + 1))
    # Surfaces the last non-blank line of $LOG as "still working" activity text.
    line=$(tail -c 500 "$LOG" 2>/dev/null | tr '\r' '\n' \
             | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p}' | tail -n 1)
    [ -n "$line" ] || line="Working..."
    if [ "$TUI_LIVE" = "1" ]; then tput cuu "$PROGRESS_BOX_LINES" 2>/dev/null; printf '\r'; fi
    progress_paint "$msg" "$elapsed" "$line"
  done

  # Resolved before the final paint so a failure never flashes a false "Done."
  elapsed=$((SECONDS - start_ts))
  wait "$pid"
  rc=$?
  if [ "$TUI_LIVE" = "1" ]; then tput cuu "$PROGRESS_BOX_LINES" 2>/dev/null; printf '\r'; fi
  if [ "$rc" -eq 0 ]; then
    progress_paint "$msg" "$elapsed" "Done." "ok"
  else
    progress_paint "$msg" "$elapsed" "Failed - see $LOG" "fail"
  fi
  [ "$TUI_LIVE" = "1" ] && tput cnorm 2>/dev/null
  printf '\n'

  [ "$rc" -eq 0 ] || die "Step failed: $msg (see $LOG)"
}

### PREFLIGHT (PLAIN TERMINAL, DIALOG NOT AVAILABLE YET) ###

preflight_root() { [ "$(id -u)" -eq 0 ] || { echo "ERROR: run this script as root." >&2; exit 1; }; }

detect_boot_mode() {
  if [ -d /sys/firmware/efi/efivars ]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
}

bootstrap_xbps() {
  command -v xbps-install >/dev/null 2>&1 && return 0
  echo "xbps-install not found, fetching a static copy..." >&2
  local tmp; tmp=$(mktemp -d)
  local url="https://repo-default.voidlinux.org/static/xbps-static-latest.${ARCH}-musl.tar.xz"
  ( curl -fsSL "$url" -o "$tmp/xbps-static.tar.xz" 2>/dev/null \
    || wget -qO "$tmp/xbps-static.tar.xz" "$url" ) \
    || { echo "ERROR: could not download static xbps from $url" >&2; exit 1; }
  tar -xJf "$tmp/xbps-static.tar.xz" -C "$tmp"
  export PATH="$tmp/usr/bin:$PATH"
  command -v xbps-install >/dev/null 2>&1 || { echo "ERROR: static xbps bootstrap failed." >&2; exit 1; }
}

# Prints response time in seconds for an https URL (non-2xx counts as
# failure); tries curl first, falls back to wget --spider.
time_url() {
  local url="$1" out code t
  if command -v curl >/dev/null 2>&1; then
    out=$(curl -o /dev/null -s -w '%{http_code} %{time_total}' \
            --connect-timeout 2 --max-time 5 -I "$url" 2>/dev/null) || return 1
    code="${out%% *}"; t="${out#* }"
    case "$code" in
      2??) printf '%s' "$t" ;;
      *)   return 1 ;;
    esac
  elif command -v wget >/dev/null 2>&1; then
    local start end
    start=$(date +%s%N)
    wget -q --spider --timeout=5 --tries=1 "$url" 2>/dev/null || return 1
    end=$(date +%s%N)
    awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", (e - s) / 1000000000 }'
  else
    return 1
  fi
}

# Prints measured transfer rate in bytes/sec for a URL, capped at
# MIRROR_RATE_SECS; latency alone (time_url above) doesn't predict throughput.
rate_url() {
  local url="$1" tmp start end bytes
  tmp=$(mktemp)
  start=$(date +%s%N)
  if command -v curl >/dev/null 2>&1; then
    timeout "$MIRROR_RATE_SECS" curl -o "$tmp" -s --connect-timeout 2 "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    timeout "$MIRROR_RATE_SECS" wget -qO "$tmp" "$url" 2>/dev/null
  else
    rm -f "$tmp"; return 1
  fi
  end=$(date +%s%N)
  bytes=$(wc -c < "$tmp" 2>/dev/null); bytes=${bytes:-0}
  rm -f "$tmp"
  [ "$bytes" -gt 0 ] || return 1
  awk -v b="$bytes" -v s="$start" -v e="$end" 'BEGIN { printf "%.0f", b / ((e - s) / 1000000000) }'
}

# Picks the fastest Void mirror and writes it to $WORKDIR/mirror; launched in
# the background (see main()) so probing overlaps the TUI prompts. Two
# rounds: a cheap latency pass narrows the field, then real download rate re-ranks it.
select_mirror() {
  local list_url="https://xmirror.voidlinux.org/raw/mirrors.lst"
  local raw=""
  raw=$(curl -fsSL --connect-timeout 3 --max-time 8 "$list_url" 2>/dev/null) \
    || raw=$(wget -qO- --timeout=8 --tries=1 "$list_url" 2>/dev/null) \
    || true

  # mirrors.lst is tab-separated: region, url, location, tier.
  local -a candidates=()
  local region url location tier
  if [ -n "$raw" ]; then
    # shellcheck disable=SC2034  # location/tier unused but required to parse the format
    while IFS=$'\t' read -r region url location tier; do
      case "$region" in ''|'#'*) continue ;; esac
      [ -n "$url" ] && candidates+=("$url")
    done <<<"$raw"
  fi
  # Fallback list if the live mirror list couldn't be fetched.
  if [ "${#candidates[@]}" -eq 0 ]; then
    candidates=(
      "https://repo-fastly.voidlinux.org/"
      "https://repo-fi.voidlinux.org/"
      "https://repo-de.voidlinux.org/"
      "https://mirrors.summithq.com/voidlinux/"
      "https://repo-default.voidlinux.org/"
    )
  fi

  # Round 1: time every candidate in parallel, filter down to top MIRROR_RATE_CANDIDATES.
  local tdir; tdir=$(mktemp -d)
  local n=0 c
  for c in "${candidates[@]}"; do
    n=$((n + 1))
    ( t=$(time_url "${c%/}/current/${ARCH}-repodata")
      [ -n "$t" ] && printf '%s\t%s\n' "$t" "$c" > "$tdir/$n"
    ) &
  done
  wait

  local -a finalists=()
  local u
  while IFS= read -r u; do
    finalists+=("$u")
  done < <(cat "$tdir"/* 2>/dev/null | sort -n | head -n "$MIRROR_RATE_CANDIDATES" | cut -f2)
  rm -rf "$tdir"
  [ "${#finalists[@]}" -eq 0 ] && return

  # Round 2: re-rank finalists by real download rate, sequential so they
  # don't fight each other for the same local uplink.
  local best="" best_rate=-1 r
  for c in "${finalists[@]}"; do
    r=$(rate_url "${c%/}/current/${ARCH}-repodata") || continue
    [ "$r" -gt "$best_rate" ] && { best_rate="$r"; best="$c"; }
  done
  [ -z "$best" ] && best="${finalists[0]}"

  printf '%s\n' "${best%/}" > "$WORKDIR/mirror"
}

preflight_tools() {
  local need=()
  command -v dialog     >/dev/null 2>&1 || need+=(dialog)
  command -v sgdisk     >/dev/null 2>&1 || need+=(gptfdisk)
  command -v wipefs     >/dev/null 2>&1 || need+=(util-linux)
  command -v partprobe  >/dev/null 2>&1 || need+=(parted)
  command -v lspci      >/dev/null 2>&1 || need+=(pciutils)
  command -v cryptsetup >/dev/null 2>&1 || need+=(cryptsetup)
  command -v mkfs.f2fs  >/dev/null 2>&1 || need+=(f2fs-tools)
  command -v mkfs.xfs   >/dev/null 2>&1 || need+=(xfsprogs)
  command -v mkfs.btrfs >/dev/null 2>&1 || need+=(btrfs-progs)
  # xtools-minimal has xgenfstab/xchroot without pulling in git like full xtools does.
  command -v xgenfstab  >/dev/null 2>&1 || need+=(xtools-minimal)
  if [ "${#need[@]}" -gt 0 ]; then
    echo "Installing host-side tools: ${need[*]}" >&2
    xbps-install -Sy "${need[@]}" >>"$LOG" 2>&1 \
      || { echo "ERROR: failed to install: ${need[*]}" >&2; exit 1; }
  fi
  command -v dialog >/dev/null 2>&1 && HAVE_DIALOG=1
}

detect_gpu() {
  local pci; pci=$(lspci -nnk 2>/dev/null | grep -iE 'vga|3d|display' || true)
  if   grep -qiE 'amd|ati|advanced micro devices|radeon' <<<"$pci"; then GPU_VENDOR="amd"
  elif grep -qi 'intel' <<<"$pci"; then GPU_VENDOR="intel"
  elif grep -qi 'nvidia' <<<"$pci"; then GPU_VENDOR="nvidia"
  else GPU_VENDOR="unknown"
  fi
}

# Reads vconsole.keymap/locale.LANG from /proc/cmdline (set by void-mklive at
# boot). KEYMAP_VAL is only applied once confirmed to name a real keymap
# under /usr/share/kbd/keymaps; LANG_VAL/LOCALE_LINE skip that check since
# xbps-reconfigure glibc-locales no-ops on an unrecognized locale.
detect_locale_keymap() {
  [ -r /proc/cmdline ] || return 0
  local -a args=()
  read -ra args < /proc/cmdline
  local a km=""
  for a in "${args[@]}"; do
    case "$a" in
      vconsole.keymap=?*) km="${a#vconsole.keymap=}" ;;
      locale.LANG=?*)
        LANG_VAL="${a#locale.LANG=}"
        case "$LANG_VAL" in
          *.*) LOCALE_LINE="$LANG_VAL ${LANG_VAL##*.}" ;;
          *)   LOCALE_LINE="$LANG_VAL UTF-8" ;;
        esac ;;
    esac
  done
  if [ -n "$km" ] && find /usr/share/kbd/keymaps -name "$km.map.gz" -print -quit 2>/dev/null | grep -q .; then
    KEYMAP_VAL="$km"
  fi
}

# Dark theme accented in Void's brand green so the dialog wizard matches the
# run_part() progress boxes; shadow off since it just looks like a smudge on black.
setup_theme() {
  cat > "$WORKDIR/dialogrc" <<'EOF'
use_shadow = OFF
use_colors = ON
screen_color = (GREEN,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (GREEN,BLACK,ON)
border_color = (GREEN,BLACK,ON)
button_active_color = (BLACK,GREEN,ON)
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (BLACK,GREEN,ON)
button_key_inactive_color = (GREEN,BLACK,ON)
button_label_active_color = (BLACK,GREEN,ON)
button_label_inactive_color = (WHITE,BLACK,ON)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (GREEN,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (GREEN,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,GREEN,ON)
tag_color = (GREEN,BLACK,ON)
tag_selected_color = (BLACK,GREEN,ON)
tag_key_color = (GREEN,BLACK,ON)
tag_key_selected_color = (BLACK,GREEN,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = (BLACK,GREEN,ON)
uarrow_color = (GREEN,BLACK,ON)
darrow_color = (GREEN,BLACK,ON)
border2_color = (GREEN,BLACK,ON)
inputbox_border2_color = (GREEN,BLACK,ON)
menubox_border2_color = (GREEN,BLACK,ON)
EOF
  export DIALOGRC="$WORKDIR/dialogrc"
}

# Clears dialog's last screen (it never clears on its own) and optionally
# holds a message before the caller paints next; no-op unless TUI_LIVE=1.
transition_screen() {
  local msg="${1:-}"
  [ "$TUI_LIVE" = "1" ] || return 0
  tput sgr0 2>/dev/null
  clear 2>/dev/null
  if [ -n "$msg" ]; then
    local cols rows col row
    cols=$(term_width); rows=$(tput lines 2>/dev/null || echo 24)
    col=$(( (cols - ${#msg}) / 2 )); [ "$col" -ge 0 ] || col=0
    row=$((rows / 2))
    tput cup "$row" "$col" 2>/dev/null
    printf '%s%s%s%s' "$C_BORDER" "$C_BOLD" "$msg" "$C_RESET"
    sleep 0.6
    tput sgr0 2>/dev/null
    clear 2>/dev/null
  fi
}

### TUI SCREENS ###

welcome_screen() {
  local mode_label="Legacy BIOS"
  [ "$BOOT_MODE" = "uefi" ] && mode_label="UEFI"
  dialog --backtitle "$BACKTITLE" --title "Welcome" --msgbox \
"This will erase a disk of your choosing and install a full Void Linux system (glibc, runit).\n\nDetected boot mode: $mode_label\nDetected keymap: $KEYMAP_VAL\nDetected locale: $LANG_VAL\n\nPress OK to begin." 14 60
}

get_username() {
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --inputbox "Choose a username:" 10 60 \
      || die "Installation cancelled."
    USERNAME=$(<"$WORKDIR/ans")
    if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$USERNAME" != "root" ]; then break; fi
    dialog --backtitle "$BACKTITLE" --msgbox "Invalid username: use lowercase letters, digits, - or _, starting with a letter or _." 8 65
  done
}

get_hostname() {
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --inputbox "Choose a hostname:" 10 60 "$HOSTNAME_VAL" \
      || die "Installation cancelled."
    HOSTNAME_VAL=$(<"$WORKDIR/ans")
    if [[ "$HOSTNAME_VAL" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then break; fi
    dialog --backtitle "$BACKTITLE" --msgbox "Invalid hostname: use lowercase letters, digits, or -, starting and ending with a letter or digit." 8 65
  done
}

get_password() {
  local prompt="$1" p1 p2
  while true; do
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --insecure --passwordbox "$prompt" 10 60 \
      || die "Installation cancelled."
    p1=$(<"$WORKDIR/ans")
    ask --backtitle "$BACKTITLE" --title "Account Setup (1/5)" --insecure --passwordbox "Confirm password:" 10 60 \
      || die "Installation cancelled."
    p2=$(<"$WORKDIR/ans")
    if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then printf '%s' "$p1"; return 0; fi
    # Bypasses ask(); needs the same /dev/tty fix.
    dialog --backtitle "$BACKTITLE" --msgbox "Passwords were empty or did not match. Try again." 8 60 1>/dev/tty
  done
}

select_drive() {
  local args=() line dev size model
  while IFS= read -r line; do
    dev=$(awk '{print $1}' <<<"$line")
    size=$(awk '{print $2}' <<<"$line")
    model=$(cut -d' ' -f3- <<<"$line")
    args+=("$dev" "$size  $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL -e7,11)
  [ "${#args[@]}" -gt 0 ] || die "No disks found."

  ask --backtitle "$BACKTITLE" --title "Select Disk (2/5)" --menu "Choose the drive to install Void Linux on:" 18 70 8 "${args[@]}" \
    || die "Installation cancelled."
  DISK=$(<"$WORKDIR/ans")

  dialog --backtitle "$BACKTITLE" --title "Confirm" --yesno "ALL DATA on $DISK will be permanently erased.\n\nContinue?" 10 60 \
    || die "Installation cancelled."

  BOOT_PART=$(part "$DISK" 1)
  SWAP_PART=$(part "$DISK" 2)
  ROOT_PART=$(part "$DISK" 3)
}

select_filesystem() {
  local boot_note="$EFI_SIZE EFI"
  [ "$BOOT_MODE" = "bios" ] && boot_note="$BIOS_BOOT_SIZE BIOS boot"
  ask --backtitle "$BACKTITLE" --title "Partitioning (3/5)" --default-item "f2fs" \
    --menu "Filesystem for the main system ($boot_note + $SWAP_SIZE swap already set aside):" 15 65 4 \
    f2fs "F2FS" ext4 "EXT4" xfs "XFS" btrfs "BTRFS" \
    || die "Installation cancelled."
  FS_CHOICE=$(<"$WORKDIR/ans")

  if dialog --backtitle "$BACKTITLE" --title "Partitioning (3/5)" --yesno "Encrypt the main system with LUKS?" 8 60; then
    ENCRYPT="yes"
    LUKS_PASS=$(get_password "Enter the LUKS encryption password:")
  else
    ENCRYPT="no"
  fi
}

select_de() {
  ask --backtitle "$BACKTITLE" --title "Desktop Environment (4/5)" --default-item "kde" \
    --menu "Choose a desktop environment:" 15 60 5 \
    kde "KDE Plasma" gnome "GNOME" xfce "XFCE" mate "MATE" cinnamon "Cinnamon" \
    || die "Installation cancelled."
  DE_CHOICE=$(<"$WORKDIR/ans")
}

### HEAVY LIFTING ###

do_partitioning() {
  wipefs -af "$DISK"
  sgdisk -Z "$DISK"
  sgdisk -o "$DISK"
  # Partition 1: EFI System Partition (UEFI), or a raw BIOS boot partition
  # GRUB embeds core.img into (legacy BIOS + GPT).
  if [ "$BOOT_MODE" = "uefi" ]; then
    sgdisk -n 1:0:"+$EFI_SIZE" -t 1:ef00 -c 1:"EFI System" "$DISK"
  else
    sgdisk -n 1:0:"+$BIOS_BOOT_SIZE" -t 1:ef02 -c 1:"BIOS boot" "$DISK"
  fi
  sgdisk -n 2:0:"+$SWAP_SIZE" -t 2:8200 -c 2:"Linux swap"  "$DISK"
  if [ "$ENCRYPT" = "yes" ]; then
    sgdisk -n 3:0:0 -t 3:8309 -c 3:"Linux LUKS" "$DISK"
  else
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux root" "$DISK"
  fi
  partprobe "$DISK" >/dev/null 2>&1 || true
  udevadm settle --timeout=10 2>/dev/null || sleep 2

  if [ "$BOOT_MODE" = "uefi" ]; then
    mkfs.vfat -F32 -n EFI "$BOOT_PART"
  fi
  mkswap -L swap "$SWAP_PART"
  swapon "$SWAP_PART"

  local target="$ROOT_PART"
  if [ "$ENCRYPT" = "yes" ]; then
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks1 --batch-mode "$ROOT_PART" --key-file=-
    LUKS_UUID=$(blkid -o value -s UUID "$ROOT_PART")
    echo "$LUKS_UUID" > "$WORKDIR/luks_uuid"
    printf '%s' "$LUKS_PASS" | cryptsetup luksOpen "$ROOT_PART" void_root --key-file=-
    target="/dev/mapper/void_root"
  fi

  case "$FS_CHOICE" in
    # No -O extra_attr: GRUB can't read F2FS boot files from a partition with it enabled.
    f2fs)   mkfs.f2fs -f -l void "$target" ;;
    ext4)   mkfs.ext4 -F -L void "$target" ;;
    xfs)    mkfs.xfs -f -L void "$target" ;;
    btrfs)  mkfs.btrfs -f -L void "$target" ;;
  esac

  mount "$target" /mnt
  if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p /mnt/boot/efi
    mount "$BOOT_PART" /mnt/boot/efi
  fi
}

build_pkg_list() {
  PKGS=(base-system linux dbus NetworkManager elogind)
  if [ "$BOOT_MODE" = "uefi" ]; then
    PKGS+=(grub-x86_64-efi)
  else
    PKGS+=(grub)
  fi
  case "$GPU_VENDOR" in
    amd)    PKGS+=(linux-firmware-amd mesa-dri vulkan-loader mesa-vulkan-radeon) ;;
    intel)  PKGS+=(linux-firmware-intel mesa-dri vulkan-loader mesa-vulkan-intel) ;;
    nvidia) PKGS+=(mesa-dri) ;;
    *)      PKGS+=(mesa-dri) ;;
  esac
  PKGS+=(xorg-minimal xorg-fonts xterm)
  # Installed unconditionally, for every DE. Pulls in wireplumber as a
  # dependency but still needs an autostart entry to launch (see write_chroot_script).
  PKGS+=(pipewire wget git)
  case "$FS_CHOICE" in
    f2fs)  PKGS+=(f2fs-tools) ;;
    xfs)   PKGS+=(xfsprogs) ;;
    btrfs) PKGS+=(btrfs-progs) ;;
  esac
  [ "$ENCRYPT" = "yes" ] && PKGS+=(cryptsetup)
  case "$DE_CHOICE" in
    kde)      PKGS+=(kde-plasma kde-baseapps plasma-nm sddm) ;;
    gnome)    PKGS+=(gnome gnome-apps gdm) ;;
    xfce)     PKGS+=(xfce4 lightdm lightdm-gtk3-greeter network-manager-applet) ;;
    mate)     PKGS+=(mate mate-extra lightdm lightdm-gtk3-greeter network-manager-applet) ;;
    cinnamon) PKGS+=(cinnamon lightdm lightdm-gtk3-greeter network-manager-applet) ;;
  esac
}

do_bootstrap() {
  mkdir -p /mnt/var/db/xbps/keys
  cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
  build_pkg_list
  XBPS_ARCH="$ARCH" xbps-install -Sy -R "$REPO" -r /mnt "${PKGS[@]}"
}

write_chroot_script() {
  # Every value double-quoted: install.conf is sourced later, and LOCALE_LINE
  # has a space ("en_US.UTF-8 UTF-8") that would otherwise break `source` and
  # leave it unset, which kills the chroot script under `set -u`.
  cat > /mnt/root/install.conf <<EOF
HOSTNAME_VAL="$HOSTNAME_VAL"
LOCALE_LINE="$LOCALE_LINE"
LANG_VAL="$LANG_VAL"
KEYMAP_VAL="$KEYMAP_VAL"
TZ_VAL="$TZ_VAL"
USER_GROUPS="$USER_GROUPS"
FS_CHOICE="$FS_CHOICE"
ENCRYPT="$ENCRYPT"
DE_CHOICE="$DE_CHOICE"
BOOT_MODE="$BOOT_MODE"
DISK="$DISK"
ROOT_PART="$ROOT_PART"
LUKS_UUID="$LUKS_UUID"
EOF

  mkdir -p /mnt/root/secrets
  chmod 700 /mnt/root/secrets
  printf '%s' "$USERNAME" > /mnt/root/secrets/username
  printf '%s' "$USERPASS" > /mnt/root/secrets/userpass
  printf '%s' "$ROOTPASS" > /mnt/root/secrets/rootpass
  [ "$ENCRYPT" = "yes" ] && printf '%s' "$LUKS_PASS" > /mnt/root/secrets/luks_pass
  chmod 600 /mnt/root/secrets/*

  cat > /mnt/root/chroot-setup.sh <<'CHROOT_SCRIPT'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
source /root/install.conf
USERNAME=$(cat /root/secrets/username)
USERPASS=$(cat /root/secrets/userpass)
ROOTPASS=$(cat /root/secrets/rootpass)

chown root:root /
chmod 755 /

echo "$HOSTNAME_VAL" > /etc/hostname
echo "KEYMAP=$KEYMAP_VAL" >> /etc/rc.conf
ln -sf "/usr/share/zoneinfo/$TZ_VAL" /etc/localtime

# rc.conf's KEYMAP only covers the virtual console, not Xorg (Void has no
# systemd/localectl bridge) - set XkbLayout explicitly or every greeter falls
# back to "us", making a correctly typed password look wrong at login.
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<XKBCONF
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$KEYMAP_VAL"
EndSection
XKBCONF

echo "$LOCALE_LINE" >> /etc/default/libc-locales
echo "LANG=$LANG_VAL" > /etc/locale.conf
xbps-reconfigure -f glibc-locales

# Fixes chpasswd silently no-op'ing: Void ships /etc/pam.d/chpasswd as a copy
# of chage's (pam_permit.so), so no password from setup ever gets written -
# repoint it at pam_unix.so, same as /etc/pam.d/passwd.
sed -i 's/^password.*pam_permit\.so/password\trequired\tpam_unix.so sha512 shadow nullok/' /etc/pam.d/chpasswd

printf 'root:%s\n' "$ROOTPASS" | chpasswd
useradd -m -G "$USER_GROUPS" -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USERPASS" | chpasswd

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

mkdir -p /etc/runit/runsvdir/default
# Enabled straight into runsvdir/default, not /var/service - this chroot targets an unbooted system.
ln -sf /etc/sv/dbus /etc/runit/runsvdir/default/
# Enabled outright: Void's default D-Bus-activation-on-demand can race the
# greeter's PAM session phase and produce a generic "Login failed".
ln -sf /etc/sv/elogind /etc/runit/runsvdir/default/
ln -sf /etc/sv/NetworkManager /etc/runit/runsvdir/default/

# pipewire ships binaries + wireplumber as a dependency, but nothing starts
# it. Starting it from rc.local (before any session exists) orphans its
# sockets when elogind remounts /run/user/$UID at first login - use XDG
# Desktop Autostart instead so it starts inside the session. USER_GROUPS
# already grants /dev/snd access via "audio".
mkdir -p /etc/xdg/autostart
for f in pipewire pipewire-pulse wireplumber; do
  ln -sf "/usr/share/applications/$f.desktop" /etc/xdg/autostart/
done

case "$DE_CHOICE" in
  kde)      ln -sf /etc/sv/sddm   /etc/runit/runsvdir/default/ ;;
  gnome)    ln -sf /etc/sv/gdm    /etc/runit/runsvdir/default/ ;;
  xfce|mate|cinnamon) ln -sf /etc/sv/lightdm /etc/runit/runsvdir/default/ ;;
esac

# No DE above ships a browser, and librewolf isn't in Void's official repos
# (forks aren't accepted there) - fetched from a third-party repo instead,
# kept as its own step so a failure here can't take down the whole install.
mkdir -p /etc/xbps.d
echo 'repository=https://github.com/index-0/librewolf-void/releases/latest/download/' > /etc/xbps.d/20-librewolf.conf
# -y doesn't cover the separate "trust this new signing key" prompt, which
# run_part's closed stdin would EOF on and fail - pipe yes in to answer both.
yes | xbps-install -Suy librewolf \
  || echo "WARNING: librewolf install failed - run 'xbps-install -Su librewolf' after rebooting to try again." >&2

if [ "$ENCRYPT" = "yes" ]; then
  LUKS_PASS=$(cat /root/secrets/luks_pass)
  grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub 2>/dev/null \
    || echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
  sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=\"#GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$LUKS_UUID #" /etc/default/grub

  # Keyfile embedded into the initramfs so the LUKS password is only typed once, at GRUB.
  dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key 2>/dev/null
  printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "$ROOT_PART" /boot/volume.key --key-file=-
  chmod 000 /boot/volume.key
  chmod -R g-rwx,o-rwx /boot
  echo "void_root  $ROOT_PART  /boot/volume.key  luks" >> /etc/crypttab
  mkdir -p /etc/dracut.conf.d
  echo 'install_items+=" /boot/volume.key /etc/crypttab "' > /etc/dracut.conf.d/10-crypt.conf
fi

if [ "$BOOT_MODE" = "uefi" ]; then
  if ! grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void" --removable --no-nvram
  fi
else
  grub-install --target=i386-pc "$DISK"
fi

xbps-reconfigure -fa

rm -rf /root/secrets /root/install.conf /root/chroot-setup.sh
CHROOT_SCRIPT
  chmod 700 /mnt/root/chroot-setup.sh
}

do_configure() {
  xgenfstab -U /mnt > /mnt/etc/fstab
  # f2fs's default flush_merge option breaks Void's read-only boot remount
  # (fsck) into an emergency shell; stripping it is a no-op on other filesystems.
  sed -i -e 's/flush_merge,//' -e 's/,flush_merge//' -e 's/\bflush_merge\b//' /mnt/etc/fstab
  # Safeguard for future steps that might need DNS; not required today, so failure here is non-fatal.
  cp /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true
  write_chroot_script
  xchroot /mnt /bin/bash /root/chroot-setup.sh
}

finish_screen() {
  # Copies the log onto the new system before reboot; the live environment (and $LOG) disappears with it.
  mkdir -p /mnt/var/log 2>/dev/null
  cp "$LOG" /mnt/var/log/void-install.log 2>/dev/null || true
  swapoff "$SWAP_PART" >/dev/null 2>&1 || true
  if [ "$ENCRYPT" = "yes" ]; then cryptsetup close void_root >/dev/null 2>&1 || true; fi
  umount -R /mnt >/dev/null 2>&1 || true
  for n in 3 2 1; do
    dialog --backtitle "$BACKTITLE" --title "Complete (5/5)" --infobox \
"Installation complete.\n\nRemove installation media now.\nRebooting in $n..." 9 55
    sleep 1
  done
}

main() {
  : > "$LOG" 2>/dev/null || LOG="/tmp/void-install.log"; : > "$LOG"
  preflight_root
  detect_boot_mode
  bootstrap_xbps

  WORKDIR=$(mktemp -d)
  trap '[ "$TUI_LIVE" = "1" ] && tput cnorm 2>/dev/null; rm -rf "$WORKDIR"' EXIT

  # Launched now so mirror probing overlaps installing host tools and the TUI
  # prompts below; output routed to $LOG so nothing corrupts the dialog screen.
  select_mirror >>"$LOG" 2>&1 </dev/null &
  MIRROR_PID=$!

  preflight_tools
  setup_theme
  detect_gpu
  detect_locale_keymap

  welcome_screen
  get_username
  get_hostname
  USERPASS=$(get_password "Password for $USERNAME:")
  ROOTPASS=$(get_password "Root password:")
  select_drive
  select_filesystem
  select_de

  transition_screen "Starting installation..."

  run_part "Partitioning $DISK..." do_partitioning
  [ -f "$WORKDIR/luks_uuid" ] && LUKS_UUID=$(<"$WORKDIR/luks_uuid")

  wait "$MIRROR_PID" 2>/dev/null || true
  [ -s "$WORKDIR/mirror" ] && REPO="$(<"$WORKDIR/mirror")/current"

  run_part "Installing base system and packages..." do_bootstrap
  run_part "Configuring the new system..." do_configure

  finish_screen
  reboot
}

main "$@"
