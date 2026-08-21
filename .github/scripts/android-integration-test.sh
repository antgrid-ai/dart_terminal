#!/usr/bin/env bash
#
# Runs the ghostty_vte_flutter Android integration suite on a connected
# emulator and classifies a failure rather than merely reporting one.
#
# This lives in a file rather than inline in vte.yml because
# reactivecircus/android-emulator-runner executes its `script:` input one line
# per `sh -c` invocation: multi-line constructs are a syntax error there, and
# even `cd` does not persist from one line to the next.
#
# Background. Runs fail with the whole test file "failing to load", seconds
# after install and before a single test body has run. Three messages have been
# seen for what is one fault:
#
#     getVersion: (-32000) Service connection disposed
#     getVersion: (112) Service has disappeared
#     Failed to start Dart Development Service
#
# All three mean the VM service connection died mid-handshake, differing only
# in how far DDS had got. dds.dart documents failedToStart as "the connection
# to the remote VM service terminates unexpectedly during Dart Development
# Service startup", and raises 112 from one place - client.dart forwards a
# request to a peer that is already closed and turns the StateError into
# kServiceDisappeared. None of them is a timeout: that path exists (a 5s wrap
# in integration_test_device.dart) but throws TimeoutException, which we have
# never seen.
#
# What dies is the adb socket, not the app. A captured failure shows the app
# rendering normally right up to the end -
#
#     4263 I Choreographer: Skipped 31 frames!
#     4263 D FlutterJNI: Sending viewport metrics to the engine.
#      436 I adbd: host-18: already offline
#      436 W adbd: timeout expired while flushing socket, closing
#
# - with no crash, no tombstone, and no kill. The VM service is reached over an
# adb forward, so a dropped transport looks exactly like a dead app from the
# tool's side.
#
# flutter_tools only starts streaming device logs AFTER that connection
# succeeds, so a genuine crash inside this window has its logcat discarded and
# the cause becomes unrecoverable. Capturing it here is the point: a crash on
# device must fail the job, while a lost transport may be repaired and retried.

set -u

readonly APP_PKG=com.example.example
readonly EXAMPLE_DIR=pkgs/vte/ghostty_vte_flutter/example
readonly TEST_TARGET=integration_test/touch_terminal_e2e_test.dart
readonly MAX_ATTEMPTS=2

# Evidence that our own app died, as opposed to any other process on the
# device. An emulator kills background processes (Chrome sandbox helpers and
# the like) constantly, and matching those would fail the job for somebody
# else's death.
#
# Matched against the whole log rather than per line, because a native crash
# spans several lines: the kernel truncates a thread name to 15 characters, so
# com.example.example appears in a "Fatal signal" line as "example.example",
# and the full package name shows up only in the tombstone header.
#
# Written out literally rather than derived from $APP_PKG - getting a literal
# backslash through bash's ${var//./...} substitution is one quoting layer too
# many to be worth it here.
readonly CRASH_RE='>>> com\.example\.example <<<|Process: com\.example\.example|Killing [0-9]+:com\.example\.example|lowmemorykiller.*example\.example|Fatal signal.*example\.example|#[0-9]+ pc .*(libghostty|libportable_pty)'

# The signature of the handshake dropping before any test ran. Kept as an
# explicit list rather than "the file failed to load" so that a Dart
# compile error - which also fails to load, but deterministically - is still
# reported as the test failure it is instead of costing a retry.
readonly HANDSHAKE_RE='Service has disappeared|Service connection disposed|Failed to start Dart Development Service'

cd "$EXAMPLE_DIR" || exit 2

# Output goes to a file rather than through `tee` so that the exit status is
# the test runner's, without depending on bash-only PIPESTATUS/pipefail.
run_suite() {
  adb logcat -c || true
  if flutter test "$TEST_TARGET" >test-output.log 2>&1; then
    cat test-output.log
    return 0
  fi
  cat test-output.log
  return 1
}

attempt=1
while true; do
  if run_suite; then
    exit 0
  fi

  adb logcat -d -v threadtime >logcat.txt 2>/dev/null || true
  echo "::group::logcat (attempt ${attempt}/${MAX_ATTEMPTS})"
  tail -n 500 logcat.txt || true
  echo "::endgroup::"

  # An empty log means adb could not reach the device at all, so the closed
  # socket was the emulator connection going away rather than the app dying
  # behind it. The two are indistinguishable from the tool's side, so say it.
  if [ ! -s logcat.txt ]; then
    echo "Device log is empty - adb lost the emulator, so this is an emulator-connection drop, not an app crash."
    adb devices -l || true
  fi

  if grep -qE "$CRASH_RE" logcat.txt; then
    echo "Device log shows ${APP_PKG} crashed or was killed - this is not a lost handshake."
    grep -nE "$CRASH_RE" logcat.txt | head -n 40
    exit 1
  fi

  # A real test failure must never be retried away.
  if ! grep -qE "$HANDSHAKE_RE" test-output.log; then
    echo "Tests failed on their own merits; not retrying."
    exit 1
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Lost the VM service handshake ${attempt} times in a row."
    exit 1
  fi

  # Reset transports the server has already marked offline - the exact state
  # adbd reports when this fires. Cheaper and less disruptive than restarting
  # the adb server, which the emulator action is also talking to.
  echo "Resetting the adb transport before retrying; the socket, not the app, is what broke."
  adb reconnect offline || true
  adb wait-for-device || true
  adb devices -l || true

  attempt=$((attempt + 1))
  echo "Lost the VM service handshake with a clean device log; retrying (${attempt}/${MAX_ATTEMPTS})."
done
