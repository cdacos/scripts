#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000

sleep 2

DEV_ID=$(wpctl status | grep -A1 "Devices:" | grep "Built-in Audio" | grep -o '[0-9]*' | head -1)
wpctl set-profile "$DEV_ID" 4
sleep 1
SINK_ID=$(wpctl status | grep "HDMI" | grep -o '[0-9]*' | head -1)
[ -n "$SINK_ID" ] && wpctl set-default "$SINK_ID" && wpctl set-volume "$SINK_ID" 1.0
