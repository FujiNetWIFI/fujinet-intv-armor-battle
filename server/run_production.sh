#!/bin/sh
# Production launch on the shared host (fujinet.online): relay on the
# game's assigned port, registered as a room on the FujiNet Lobby.
#
# Port assignments (one per game on the shared host):
#   9100 Baseball  9101 Auto Racing  9102 NFL Football (9103 probe)
#   9104 Armor Battle  9105 echo latency probe  9106 Utopia
#
# The Lobby entry ("room") carries the game's name, appkey and the client
# ROM the INTV Lobby client boots; override any of it via the environment:
#   LOBBY_URL, LOBBY_APPKEY, LOBBY_SERVERURL, LOBBY_CLIENT_URL
# Everything defaults correctly for this game -- a bare run is a correct
# production start.  Never run this against a test/rig setup; local rigs
# must stay unregistered (make rig forces 127.0.0.1 and no --lobby-enabled).
set -e
cd "$(dirname "$0")/.."

exec python3 server/intv_relay_server.py \
    --port "${PORT:-9104}" \
    --lobby-enabled \
    ${LOBBY_URL:+--lobby-url "$LOBBY_URL"} \
    ${LOBBY_APPKEY:+--lobby-appkey "$LOBBY_APPKEY"} \
    ${LOBBY_SERVERURL:+--lobby-serverurl "$LOBBY_SERVERURL"} \
    ${LOBBY_CLIENT_URL:+--lobby-client-url "$LOBBY_CLIENT_URL"} \
    "$@"
