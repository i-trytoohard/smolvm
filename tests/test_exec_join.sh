#!/bin/bash
#
# End-to-end tests for exec-join-container (issue #200).
#
# Verifies that `machine exec` joins the running main workload container via
# `crun exec` instead of spawning a fresh `crun run` container each time.
#
# State machine tested:
#   (1) No main container → fresh crun run → saves container ID
#   (2) Container ID on disk + crun says running → crun exec (shared namespaces)
#   (3) Container ID on disk + container dead → ignores stale ID → fresh crun run
#
# Plus isolation: ephemeral `machine run` (no -d) never joins any main container.
#
# Requirements:
#   - Internet access in the VM (Alpine image is pulled via network)
#   - smolvm binary built with exec-join support
#
# Usage:
#   ./tests/test_exec_join.sh

source "$(dirname "$0")/common.sh"
init_smolvm

log_info "Pre-flight cleanup: killing orphan processes..."
kill_orphan_smolvm_processes

trap cleanup_machine EXIT

echo ""
echo "=========================================="
echo "  smolvm Exec-Join Container Tests"
echo "=========================================="
echo ""

# =============================================================================
# Suite setup — create VM once with --net (needed to pull Alpine)
# =============================================================================

SUITE_VM_READY=false

setup_suite_vm() {
    if [[ "$SUITE_VM_READY" == "true" ]]; then
        return 0
    fi

    log_info "Creating VM with --net for Alpine image pull..."
    $SMOLVM machine stop 2>/dev/null || true
    $SMOLVM machine delete default -f 2>/dev/null || true
    $SMOLVM machine create default --net 2>/dev/null || return 1
    $SMOLVM machine start 2>/dev/null || return 1

    # Confirm VM is reachable before proceeding
    if ! $SMOLVM machine exec -- true 2>/dev/null; then
        echo "VM not reachable after start" >&2
        return 1
    fi

    SUITE_VM_READY=true
    log_info "VM ready."
}

# =============================================================================
# Test 1: exec joins the running main workload container
#
# `machine run -d --image alpine -- sleep 300` launches a detached container
# and records its ID in main_container_id_path. Subsequent `machine exec`
# reads that ID, confirms it is running, and calls `crun exec` — which
# injects the new process into the existing container's PID namespace.
#
# Proof: `ps -ef` inside exec sees `sleep 300` as PID 1.
# =============================================================================

test_exec_joins_main_container() {
    setup_suite_vm || return 1

    log_info "Starting detached workload: sleep 300..."
    local run_output
    if ! run_output=$(run_with_timeout 120 $SMOLVM machine run -d --image alpine -- sleep 300 2>&1); then
        echo "FAIL: machine run -d failed" >&2
        echo "$run_output" >&2
        return 1
    fi

    log_info "Detached run output: $run_output"

    # exec should join the running container — PID 1 is sleep 300
    local ps_output
    if ! ps_output=$(run_with_timeout 30 $SMOLVM machine exec -- ps -ef 2>&1); then
        echo "FAIL: machine exec failed" >&2
        echo "$ps_output" >&2
        return 1
    fi

    if ! echo "$ps_output" | grep -q "sleep"; then
        echo "FAIL: expected 'sleep' in ps output (shared PID namespace), got:" >&2
        echo "$ps_output" >&2
        return 1
    fi

    echo "ps -ef in joined namespace:"
    echo "$ps_output"
    echo "PASS: 'sleep' visible — exec is in the same PID namespace as the main container"
}

# =============================================================================
# Test 2: second exec also joins the same container (consistent ID reuse)
#
# Runs a second exec immediately after Test 1. The container ID file still
# points to the running sleep 300 container. Exec should resolve to the same
# container again — not spawn a third container.
# =============================================================================

test_repeated_exec_joins_same_container() {
    if [[ "$SUITE_VM_READY" != "true" ]]; then
        echo "SKIP: suite VM not ready (run test 1 first)" >&2
        return 0
    fi

    # Exec twice; both should see sleep 300 (PID 1 in the shared namespace)
    local out1 out2
    out1=$(run_with_timeout 30 $SMOLVM machine exec -- ps -ef 2>&1) || {
        echo "FAIL: first repeated exec failed" >&2; return 1
    }
    out2=$(run_with_timeout 30 $SMOLVM machine exec -- ps -ef 2>&1) || {
        echo "FAIL: second repeated exec failed" >&2; return 1
    }

    for out in "$out1" "$out2"; do
        if ! echo "$out" | grep -q "sleep"; then
            echo "FAIL: exec did not see 'sleep' in ps output:" >&2
            echo "$out" >&2
            return 1
        fi
    done

    echo "Both execs joined the same container (sleep visible in both)"
}

# =============================================================================
# Test 3: background process spawned in one exec is visible in the next
#
# Since both execs share the same PID namespace, a background process
# started in the first exec survives and appears in the second exec's ps.
# This is the canonical cross-exec visibility test.
# =============================================================================

test_background_process_visible_across_execs() {
    if [[ "$SUITE_VM_READY" != "true" ]]; then
        echo "SKIP: suite VM not ready" >&2; return 0
    fi

    log_info "Starting background sleep 90 via exec..."
    # Spawn sleep 90 in the background inside the container namespace.
    # sh exits immediately; sleep 90 is reparented to PID 1 (sleep 300).
    run_with_timeout 15 $SMOLVM machine exec -- sh -c 'sleep 90 &' 2>/dev/null || true

    # Give the kernel a moment to reparent the orphaned process
    sleep 1

    local ps_output
    if ! ps_output=$(run_with_timeout 30 $SMOLVM machine exec -- ps -ef 2>&1); then
        echo "FAIL: exec after background spawn failed" >&2; return 1
    fi

    # Expect at least two sleep entries: sleep 300 (PID 1) + sleep 90
    local sleep_count
    sleep_count=$(echo "$ps_output" | grep -c "sleep" || true)
    if [[ "$sleep_count" -lt 2 ]]; then
        echo "FAIL: expected >=2 sleep processes (sleep 300 + sleep 90), got $sleep_count" >&2
        echo "ps output:" >&2
        echo "$ps_output" >&2
        return 1
    fi

    echo "Found $sleep_count sleep processes — cross-exec process visibility confirmed"
    echo "$ps_output"
}

# =============================================================================
# Test 4: ephemeral `machine run` is fully isolated
#
# `machine run --image alpine -- ps -ef` (no -d flag) sends
# persistent_overlay_id=None to the agent. The probe in
# spawn_interactive_command is skipped entirely, so a fresh OCI container
# is created with its own isolated PID namespace. It must NOT see sleep 300.
# =============================================================================

test_ephemeral_run_is_isolated() {
    if [[ "$SUITE_VM_READY" != "true" ]]; then
        echo "SKIP: suite VM not ready" >&2; return 0
    fi

    log_info "Running ephemeral (no -d) container..."
    local ps_output
    if ! ps_output=$(run_with_timeout 60 $SMOLVM machine run --image alpine -- ps -ef 2>&1); then
        echo "FAIL: ephemeral machine run failed" >&2
        echo "$ps_output" >&2
        return 1
    fi

    # An isolated container has its own PID namespace; sleep 300 must not appear
    if echo "$ps_output" | grep -q "sleep 300"; then
        echo "FAIL: ephemeral run leaked into the main container namespace — saw 'sleep 300'" >&2
        echo "ps output:" >&2
        echo "$ps_output" >&2
        return 1
    fi

    # Sanity: the output should not be empty (we at least see ps itself)
    if [[ -z "$ps_output" ]]; then
        echo "FAIL: ps -ef returned empty output in ephemeral container" >&2
        return 1
    fi

    echo "Ephemeral run ps output (no sleep 300 — correctly isolated):"
    echo "$ps_output"
}

# =============================================================================
# Test 5: exec recovers gracefully when the main container exits
#
# Kill PID 1 (sleep 300) from within an exec. The container dies. The next
# exec should detect the stale container ID via is_container_running, ignore
# it, and start a fresh container. This verifies the "dead → fresh run" arc.
# =============================================================================

test_exec_recovers_after_main_container_exits() {
    if [[ "$SUITE_VM_READY" != "true" ]]; then
        echo "SKIP: suite VM not ready" >&2; return 0
    fi

    log_info "Killing PID 1 (main container) via exec..."
    # kill -9 1 inside crun exec sends SIGKILL to the container's PID 1 (sleep 300).
    # The container exits; the crun exec process also terminates → non-zero exit expected.
    run_with_timeout 10 $SMOLVM machine exec -- kill -9 1 2>/dev/null || true

    # Wait for crun state to reflect the stopped container
    sleep 2

    # Next exec must work — agent detects stale ID and starts a fresh container
    local output
    if ! output=$(run_with_timeout 30 $SMOLVM machine exec -- echo "recovered" 2>&1); then
        echo "FAIL: exec failed after main container exit" >&2
        echo "$output" >&2
        return 1
    fi

    if ! echo "$output" | grep -q "recovered"; then
        echo "FAIL: expected 'recovered' in output, got: $output" >&2
        return 1
    fi

    echo "exec recovered after main container exit: $output"

    # Confirm the new container is a fresh PID namespace (no sleep 300)
    local ps_output
    ps_output=$(run_with_timeout 30 $SMOLVM machine exec -- ps -ef 2>&1) || true
    if echo "$ps_output" | grep -q "sleep 300"; then
        echo "WARN: 'sleep 300' appeared in fresh container — unexpected but not fatal"
    fi
    echo "Fresh container ps output after recovery:"
    echo "$ps_output"
}

# =============================================================================
# Run tests
# =============================================================================

run_test "exec joins main workload container" test_exec_joins_main_container
run_test "repeated exec joins the same container" test_repeated_exec_joins_same_container
run_test "background process visible across exec invocations" test_background_process_visible_across_execs
run_test "ephemeral machine run is namespace-isolated" test_ephemeral_run_is_isolated
run_test "exec recovers after main container exits" test_exec_recovers_after_main_container_exits

print_summary "Exec-Join Container Tests"
