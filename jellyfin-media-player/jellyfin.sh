#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
exec 2> ~/jellyfin.sh.log

pkill -u carlos pipewire || true
pkill -u carlos wireplumber || true
sleep 1

pipewire &
wireplumber &
pipewire-pulse &
sleep 2

# Initial HDMI setup
DEV_ID=$(wpctl status | grep -A1 "Devices:" | grep "Built-in Audio" | grep -o '[0-9]*' | head -1)
wpctl set-profile "$DEV_ID" 4
sleep 1
SINK_ID=$(wpctl status | grep "HDMI" | grep -o '[0-9]*' | head -1)
wpctl set-default "$SINK_ID"
wpctl set-volume "$SINK_ID" 1.0

# Watchdog - check every 10 seconds, re-set HDMI if it reverts
while true; do
    sleep 10
    if ! wpctl status | grep -q "HDMI"; then
        DEV_ID=$(wpctl status | grep -A1 "Devices:" | grep "Built-in Audio" | grep -o '[0-9]*' | head -1)
        wpctl set-profile "$DEV_ID" 4
        sleep 1
        SINK_ID=$(wpctl status | grep "HDMI" | grep -o '[0-9]*' | head -1)
        [ -n "$SINK_ID" ] && wpctl set-default "$SINK_ID" && wpctl set-volume "$SINK_ID" 1.0
    fi
done &

exec cage -d -s -- ~/Jellyfin*.AppImage --scale-factor=2
