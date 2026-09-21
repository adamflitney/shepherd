#!/bin/sh
# Shepherd increment 3: state writer.
# Reduces one hook payload into ~/.shepherd/state/<session_id>.json.
exec python3 "$(dirname "$0")/shepherd_write_state.py"
