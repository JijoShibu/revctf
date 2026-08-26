# revctf sandbox image — isolation for the two stages that EXECUTE the target.
#
# Built by install.sh during its one-time network window; lib/sandbox.sh only ever checks
# that it exists and fails with a clear, actionable error if it does not.
#
# WHAT IS AND IS NOT BAKED IN HERE
#
# The isolation contract lives in lib/sandbox.sh, as `docker run` flags, NOT in this file:
#
#   --network=none --read-only --cap-drop=ALL --security-opt no-new-privileges
#   --user nobody --pids-limit --memory --rm
#
# That is deliberate. A contract baked into an image is invisible at the call site and
# survives no rebuild; a contract expressed as run flags is auditable in the process table
# and is what the harness asserts against. The image supplies tools, nothing more.
#
# strace is here as well as ltrace: deviation D9 extends the sandbox to every stage that
# executes the target, and strace runs the binary just as directly.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ltrace strace coreutils \
 && rm -rf /var/lib/apt/lists/*

# No ENTRYPOINT. lib/sandbox.sh passes the full command, so the image cannot silently
# reinterpret what it was asked to run.
USER nobody
