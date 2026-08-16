; Netplay wire protocol constants.  The server endpoint (SRV_SPEC /
; SRV_SPEC_LEN) is generated into build/srv_endpoint.asm from the Makefile's
; SRV_HOST / SRV_PORT variables.

; Frame type ids -- must match server/bbnet_server.py.
FT_HELLO        EQU     $01
FT_LIST         EQU     $02
FT_LOBBY        EQU     $03
FT_JOIN         EQU     $04
FT_START        EQU     $05
FT_INPUT        EQU     $06
FT_CRC          EQU     $07
FT_STATE        EQU     $08
FT_RESYNC       EQU     $09
FT_BYE          EQU     $0A
FT_PEER_LEFT    EQU     $0B
FT_PING         EQU     $0C
FT_PONG         EQU     $0D
