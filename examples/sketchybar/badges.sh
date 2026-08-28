#!/bin/sh
# SketchyBar (shell config) example: single item showing the total. Requires `jq`.
#
# sketchybarrc:
#   sketchybar --add event dock_badges \
#              --add item badges right \
#              --set badges script="$CONFIG_DIR/plugins/badges.sh" \
#              --subscribe badges dock_badges
#
# BADGES arrives as the JSON pushed by dock-badge-counter. Badge values are strings: numeric ones
# are summed, "99+" counts as 99, and non-numeric badges such as "•" count as 1.
if [ "$SENDER" = "dock_badges" ]; then
  total=$(printf '%s' "$BADGES" | jq -r '[.[] | (gsub("[^0-9]"; "") | tonumber? // 1)] | add // 0')
  sketchybar --set "$NAME" label="$total"
fi
