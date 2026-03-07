#!/bin/bash
sudo systemctl restart seatd
sudo chvt 2
cage -d -s -- ~/jellyfin.sh
