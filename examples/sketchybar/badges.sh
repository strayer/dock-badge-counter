#!/bin/sh
# SketchyBar (shell config) example: single item showing the total.
#
# sketchybarrc:
#   sketchybar --add event dock_badges \
#              --add item badges right \
#              --set badges script="$CONFIG_DIR/plugins/badges.sh" \
#              --subscribe badges dock_badges
#
# BADGES arrives as the JSON pushed by dock-badge-counter.
if [ "$SENDER" = "dock_badges" ]; then
  total=$(printf '%s' "$BADGES" | jq -r '[.[] | tonumber? // 1] | add // 0')
  sketchybar --set "$NAME" label="$total"
fi
