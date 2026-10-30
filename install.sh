#!/bin/bash
GAME="$HOME/.local/share/Steam/steamapps/common/Teardown"
cp dxgi.dll "$GAME/"
cp -r Lua "$GAME/mods/TeardownBonelabVR"
cp teardown_vr.ini "$GAME/teardown_vr.ini"
