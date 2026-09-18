#!/usr/bin/env bash
# Print an unused TCP port on 127.0.0.1.
# Small TOCTOU window is unavoidable; callers retry once on bind failure.
set -euo pipefail
exec python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
