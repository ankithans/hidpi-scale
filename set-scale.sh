#!/bin/zsh
# Scale every connected monitor listed in models.conf (matched by exact EDID
# vendor+model via lsmon), each mirrored to a virtual display. Monitors not
# listed in models.conf are never touched.
#
# Usage: ./set-scale.sh [native|small|medium|large]
#        ./set-scale.sh <looks-like height, e.g. 1296>
# With no argument, uses the last size you picked (default: medium).
#   native = panel resolution   small = ~7% more space
#   medium = 20% more space     large = 33% more space
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # displayplacer; launchd PATH lacks it

ARG="${1:-$(cat size.pref 2>/dev/null)}"
ARG="${ARG:-medium}"
N=0; D=0; HREQ=0
case "$ARG" in
  native) N=1;  D=1 ;;
  small)  N=16; D=15 ;;
  medium) N=6;  D=5 ;;
  large)  N=4;  D=3 ;;
  <->x<->) HREQ="${ARG#*x}" ;;   # explicit WxH: use the height
  <->)     HREQ="$ARG" ;;        # height only
  *) echo "usage: $0 [native|small|medium|large|<height>]"; exit 1 ;;
esac
[[ -n "$1" ]] && echo "$1" > size.pref

# "Looks like" resolution for a panel at the chosen step. Integer math must
# match vdisplay.m's mode generation exactly. A numeric height snaps to the
# nearest step for that panel.
calc_res() {  # $1 = panel WxH  → echoes "W H"
  local pw="${1%x*}" ph="${1#*x}" n=$N d=$D
  if (( n == 0 )); then
    local best=999999 fn fd h diff
    for pair in "1 1" "16 15" "6 5" "4 3"; do
      fn="${pair% *}"; fd="${pair#* }"
      h=$(( (ph * fn + fd / 2) / fd )); h=$(( h - h % 2 ))
      diff=$(( h > HREQ ? h - HREQ : HREQ - h ))
      (( diff < best )) && { best=$diff; n=$fn; d=$fd; }
    done
  fi
  local w=$(( (pw * n + d / 2) / d )); w=$(( w - w % 2 ))
  local h=$(( (ph * n + d / 2) / d )); h=$(( h - h % 2 ))
  echo "$w $h"
}

# Our virtual displays (created by the vdisplay daemon)
VIRTS=("${(@f)$(./lsmon -virtual)}"); VIRTS=(${VIRTS:#})
if (( ${#VIRTS} < 2 )); then
  echo "virtual displays not found — is the vdisplay daemon running? (see install.sh)"
  exit 1
fi
VIRT1="${VIRTS[1]}"; VIRT2="${VIRTS[2]}"

# Connected matched monitors ("UUID WxH" per line)
typeset -A PANEL_OF
FOUND=()
for line in "${(@f)$(./lsmon)}"; do
  [[ -z "$line" ]] && continue
  FOUND+=("${line%% *}")
  PANEL_OF[${line%% *}]="${line##* }"
done

# Optional local.conf pins which unit goes right/left
RIGHT_DELL=""; LEFT_DELL=""
[[ -f local.conf ]] && source ./local.conf
MONS=()
[[ -n "$RIGHT_DELL" && ${FOUND[(Ie)$RIGHT_DELL]} -gt 0 ]] && MONS+=("$RIGHT_DELL")
[[ -n "$LEFT_DELL" && ${FOUND[(Ie)$LEFT_DELL]} -gt 0 ]] && MONS+=("$LEFT_DELL")
for d in "${FOUND[@]}"; do
  [[ "$d" == "$RIGHT_DELL" || "$d" == "$LEFT_DELL" ]] || MONS+=("$d")
done

if (( ${#MONS} == 0 )); then
  echo "no matched monitor connected; nothing to do"
  exit 0
fi

# Built-in screen: keep its current mode, anchor it at (0,0)
LIST=$(displayplacer list)
MB_UUID=$(echo "$LIST" | grep -B3 "Type: MacBook built in screen" | awk '/Persistent screen id:/{print $4}')
ARGS=()
RIGHT_X=0
if [[ -n "$MB_UUID" ]]; then
  MB_RES=$(echo "$LIST" | grep -A1 "Type: MacBook built in screen" | awk '/Resolution:/{print $2}')
  MB_HZ=$(echo "$LIST" | grep -A2 "Type: MacBook built in screen" | awk '/Hertz:/{print $2}')
  ARGS+=("id:$MB_UUID res:$MB_RES hz:$MB_HZ scaling:on origin:(0,0) degree:0")
  RIGHT_X="${MB_RES%x*}"
fi

# 1. Break all mirroring so groups can't merge wrongly
for d in "${MONS[@]}"; do ./mirror "$d" off >/dev/null 2>&1; done
./mirror "$VIRT2" off >/dev/null 2>&1
sleep 1

if (( ${#MONS} >= 2 )); then
  # Two monitors: MONS[1]+VIRT1 right of built-in, MONS[2]+VIRT2 left
  R=(${=$(calc_res "$PANEL_OF[${MONS[1]}]")})
  L=(${=$(calc_res "$PANEL_OF[${MONS[2]}]")})
  displayplacer "${ARGS[@]}" \
    "id:$VIRT2 res:${L[1]}x${L[2]} hz:60 scaling:on origin:(-${L[1]},0) degree:0" \
    "id:${MONS[2]} res:$PANEL_OF[${MONS[2]}] hz:60 scaling:on origin:(-${L[1]},${L[2]}) degree:0" \
    "id:$VIRT1 res:${R[1]}x${R[2]} hz:60 scaling:on origin:($RIGHT_X,0) degree:0" \
    "id:${MONS[1]} res:$PANEL_OF[${MONS[1]}] hz:60 scaling:on origin:($RIGHT_X,${R[2]}) degree:0" \
    >/dev/null
  sleep 1
  ./mirror "${MONS[2]}" "$VIRT2" >/dev/null && ./mirror "${MONS[1]}" "$VIRT1" >/dev/null \
    && echo "Both monitors scaled: right looks like ${R[1]}x${R[2]}, left ${L[1]}x${L[2]}"
else
  # One monitor: monitor+VIRT1; VIRT2 parked into the same mirror set so no
  # invisible orphan desktop is left where windows could get lost
  R=(${=$(calc_res "$PANEL_OF[${MONS[1]}]")})
  PW="${PANEL_OF[${MONS[1]}]%x*}"
  displayplacer "${ARGS[@]}" \
    "id:$VIRT1 res:${R[1]}x${R[2]} hz:60 scaling:on origin:($RIGHT_X,0) degree:0" \
    "id:$VIRT2 res:${R[1]}x${R[2]} hz:60 scaling:on origin:($RIGHT_X,${R[2]}) degree:0" \
    "id:${MONS[1]} res:$PANEL_OF[${MONS[1]}] hz:60 scaling:on origin:(-$PW,0) degree:0" \
    >/dev/null
  sleep 1
  ./mirror "${MONS[1]}" "$VIRT1" >/dev/null && ./mirror "$VIRT2" "$VIRT1" >/dev/null \
    && echo "Monitor scaled: looks like ${R[1]}x${R[2]} (spare virtual parked)"
fi
