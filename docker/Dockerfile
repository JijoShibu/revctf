# Minimal sandbox image for the ltrace stage (v3 §4 item 7-8, masterplan v6 §12).
# Built by install.sh during the one-time network window; stage_ltrace.sh only ever
# checks that it exists and fails fast with a clear error if it does not.
#
# Run flags applied by stage_ltrace.sh (never baked in here):
#   --network=none --read-only --user nobody --memory=256m --pids-limit=64 --cap-drop=ALL
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ltrace coreutils \
 && rm -rf /var/lib/apt/lists/*

USER nobody
ENTRYPOINT ["/usr/bin/timeout"]
