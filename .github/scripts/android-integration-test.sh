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
# Background. A run failed with the whole test file "failing to load", seconds
# after install and before a single test body had run:
#
#     getVersion: (-32000) Service connection disposed
#     getVersion: (112) Service has disappeared
#
# DDS raises 112 in exactly one place - client.dart forwards a request to the
# VM service peer, the peer is already closed, and the resulting StateError
# becomes kServiceDisappeared. So the app process on the device died; the tool
# did not time out. (integration_test_device.dart does wrap the connect in a
# 5s timeout, but that path throws TimeoutException, and it did not.)
#
# flutter_tools only starts streaming device logs AFTER that connection
# succeeds, so an app that dies inside this window has its logcat discarded and
# the cause becomes unrecoverable. Capturing it here is the point: a crash on
# device must fail the job, while a lost handshake may be retried.

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

# The signature of the handshake dropping before any test ran.
readonly HANDSHAKE_RE='Service has disappeared|Service connection disposed'

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
  attempt=$((attempt + 1))
  echo "Lost the VM service handshake with a clean device log; retrying (${attempt}/${MAX_ATTEMPTS})."
done
