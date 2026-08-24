#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
controller_source="${PROJECTORCTL_SOURCE:-$repo_root/src/projectorctl.sh}"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export HOME="$test_root/home"
export PROJECTORCTL_RUNTIME_DIR="$test_root/run"
export PROJECTORCTL_LAYOUT_FILE="$test_root/layout.lua"
export PROJECTORCTL_DRM_ROOT="$test_root/drm"
mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$controller_source"
state_file="$PROJECTORCTL_RUNTIME_DIR/state.json"
pending_guard_file="$PROJECTORCTL_RUNTIME_DIR/recovery.pending"

pass_count=0

pass() {
	printf 'ok %d - %s\n' "$((++pass_count))" "$1"
}

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"

	[[ "$actual" == "$expected" ]] || fail "$message (wanted '$expected', got '$actual')"
	pass "$message"
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local message="$3"

	[[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
	pass "$message"
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	local message="$3"

	[[ "$haystack" != *"$needle"* ]] || fail "$message (found '$needle')"
	pass "$message"
}

monitors_three='[
	{"id":0,"name":"eDP-1","description":"Laptop panel","disabled":false,"dpmsStatus":true,"width":1920,"height":1080,"refreshRate":60,"scale":1,"transform":0,"x":0,"y":0,"mirrorOf":-1},
	{"id":1,"name":"HDMI-A-1","description":"Projector","disabled":false,"dpmsStatus":true,"width":1920,"height":1080,"refreshRate":60,"scale":1,"transform":0,"x":1920,"y":0,"mirrorOf":0},
	{"id":2,"name":"DP-2","description":"Dock display","disabled":false,"dpmsStatus":true,"width":2560,"height":1440,"refreshRate":60,"scale":1,"transform":0,"x":3840,"y":0,"mirrorOf":-1}
]'

write_state builtin eDP-1 DP-2 "" info
select_outputs "$monitors_three"
assert_eq eDP-1 "$BUILTIN_OUTPUT" "finds the laptop panel"
assert_eq DP-2 "$EXTERNAL_OUTPUT" "keeps the remembered external display"

rm -f "$state_file"
select_outputs "$monitors_three"
assert_eq HDMI-A-1 "$EXTERNAL_OUTPUT" "prefers HDMI when there is no remembered display"

virtual_only="$(jq -c '.[0:1] + [{
	"id": 8,
	"name": "HEADLESS-1",
	"description": "Remote output",
	"disabled": false,
	"dpmsStatus": true,
	"width": 1920,
	"height": 1080,
	"refreshRate": 60,
	"scale": 1,
	"transform": 0,
	"x": 1920,
	"y": 0,
	"mirrorOf": -1
}]' <<< "$monitors_three")"
select_outputs "$virtual_only"
assert_eq "" "$EXTERNAL_OUTPUT" "does not offer a headless output as a projector"
assert_eq 1 "$(active_output_count "$virtual_only")" "does not count a headless output as a visible fallback"

mirrored_pair="$(jq -c '.[0:2]' <<< "$monitors_three")"
output_is_mirroring "$mirrored_pair" HDMI-A-1 eDP-1 || fail "recognizes Hyprland's numeric mirror id"
pass "recognizes Hyprland's numeric mirror id"

TEST_MONITORS="$mirrored_pair"
monitor_json() {
	printf '%s\n' "$TEST_MONITORS"
}

status="$(status_json)"
assert_eq duplicate "$(jq -r .mode <<< "$status")" "reports a two-screen mirror as duplicate"

TEST_MONITORS="$monitors_three"
status="$(status_json)"
assert_eq extended "$(jq -r .mode <<< "$status")" "does not hide a third active display behind duplicate mode"

write_state external eDP-old HDMI-A-1 "" info
TEST_MONITORS='[
	{"id":4,"name":"eDP-2","description":"Replacement laptop panel","disabled":false,"dpmsStatus":true,"width":1920,"height":1200,"refreshRate":60,"scale":1,"transform":0,"x":0,"y":0,"mirrorOf":-1}
]'
focus_output() { return 0; }
refresh_wallpaper() { return 0; }
notify_recovery() { return 0; }
safe_recover "test recovery" || fail "recovery accepts the replacement laptop panel"
assert_eq eDP-2 "$(state_field builtin)" "recovery forgets a laptop output that no longer exists"

probe_log="$test_root/probes.log"
(
	export verification_attempts=3
	export monitor_probe_timeout=0.2
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$1" >> "$probe_log"; return 1; }
	if wait_for_output eDP-1 active; then
		exit 1
	fi
)
assert_eq 3 "$(wc -l < "$probe_log")" "display verification has a fixed probe count"
assert_eq 0.2 "$(sed -n '1p' "$probe_log")" "display verification uses the short probe timeout"

layout_log="$test_root/layouts.log"
monitors_with_headless="$(jq -c '. + [{
	"id": 8,
	"name": "HEADLESS-1",
	"description": "Remote output",
	"disabled": false,
	"dpmsStatus": true,
	"width": 1920,
	"height": 1080,
	"refreshRate": 60,
	"scale": 1,
	"transform": 0,
	"x": 6400,
	"y": 0,
	"mirrorOf": -1
}]' <<< "$monitors_three")"
TEST_MONITORS="$monitors_with_headless"
prepare_both_outputs() { return 0; }
wait_for_output() { return 0; }
wait_for_no_other_external() { return 0; }
wait_for_extended_layout() { return 0; }
output_is_mirroring() { return 0; }
run_layout() {
	printf '%s\n' "$1" > "$layout_log"
}

BUILTIN_OUTPUT=eDP-1
EXTERNAL_OUTPUT=HDMI-A-1
apply_duplicate "$monitors_with_headless" || fail "duplicate layout applies in the harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "eDP-1"' "duplicate keeps an explicit laptop rule"
assert_contains "$layout" 'output = "DP-2", disabled = true' "duplicate turns off unrelated external displays"
assert_not_contains "$layout" 'output = "HEADLESS-1"' "duplicate leaves headless outputs alone"

apply_extended "$monitors_with_headless" right || fail "extended layout applies in the harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "DP-2", disabled = true' "extend turns off unrelated external displays"

active_external_count() { printf '0\n'; }
apply_builtin_only "$monitors_with_headless" || fail "laptop-only layout applies in the harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "eDP-1", mode = "preferred", position = "0x0"' "laptop-only keeps its enable rule in the final layout"
assert_not_contains "$layout" 'output = "HEADLESS-1"' "laptop-only leaves headless outputs alone"

hypr_root="$test_root/hypr"
mkdir -p "$hypr_root/older" "$hypr_root/newer"
printf '10 wayland-2\n' > "$hypr_root/older/hyprland.lock"
printf '11 wayland-1\n' > "$hypr_root/newer/hyprland.lock"
touch -t 202601010101 "$hypr_root/older/hyprland.lock"
touch -t 202602020202 "$hypr_root/newer/hyprland.lock"
instance_is_live() { [[ -n "$1" ]]; }
use_instance() { CHOSEN_INSTANCE="$1"; }
export HYPRLAND_INSTANCE_SIGNATURE=""
export WAYLAND_DISPLAY=wayland-2
CHOSEN_INSTANCE=""
resolve_instance
assert_eq older "$CHOSEN_INSTANCE" "follows WAYLAND_DISPLAY when the signature is stale"
export WAYLAND_DISPLAY=wayland-missing
CHOSEN_INSTANCE=""
resolve_instance
assert_eq newer "$CHOSEN_INSTANCE" "falls back to the newest live Hyprland instance"

assert_eq HDMI-A-1 "$(removed_output_from_event 'monitorremoved>>HDMI-A-1')" "reads the removed output from Hyprland events"
assert_eq HDMI-A-1 "$(removed_output_from_event 'monitorremovedv2>>1,HDMI-A-1,LG TV')" "reads the removed output from v2 events"

forced_recovery_log="$test_root/forced-recovery.log"
(
	write_state external eDP-1 HDMI-A-1 "" info
	# shellcheck disable=SC2329
	safe_recover() { printf '%s\n' "$1" > "$forced_recovery_log"; }
	recover_if_needed_locked HDMI-A-1 2>/dev/null
)
assert_contains "$(<"$forced_recovery_log")" "Projector disconnected" "a removal event forces projector-only recovery"

write_state external eDP-1 HDMI-A-1 "Projector only" info
write_transition builtin eDP-1 HDMI-A-1 "Switching to laptop only"
assert_eq external "$(state_field requestedMode)" "an in-progress laptop switch keeps the previous guarded mode"
assert_eq builtin "$(state_field targetMode)" "an in-progress switch records its target mode"
assert_eq applying "$(state_field phase)" "an in-progress switch is marked as applying"
assert_eq HDMI-A-1 "$(state_field guardExternal)" "an in-progress laptop switch keeps the projector guard armed"

transaction_recovery_log="$test_root/transaction-recovery.log"
(
	# shellcheck disable=SC2329
	safe_recover() { printf '%s\n' "$1" > "$transaction_recovery_log"; }
	recover_if_needed_locked HDMI-A-1 2>/dev/null
)
assert_contains "$(<"$transaction_recovery_log")" "Projector disconnected" "an interrupted laptop switch still recovers after unplugging"

write_state builtin eDP-1 HDMI-A-1 "Laptop display is active" info
assert_eq "" "$(state_field guardExternal)" "a committed laptop layout disarms the projector guard"

kernel_recovery_log="$test_root/kernel-recovery.log"
mkdir -p "$PROJECTORCTL_DRM_ROOT/card1-HDMI-A-1"
printf 'disconnected\n' > "$PROJECTORCTL_DRM_ROOT/card1-HDMI-A-1/status"
(
	write_state external eDP-1 HDMI-A-1 "" info
	TEST_MONITORS="$monitors_three"
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	active_monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	safe_recover() { printf '%s\n' "$1" > "$kernel_recovery_log"; }
	recover_if_needed_locked 2>/dev/null
)
assert_contains "$(<"$kernel_recovery_log")" "Kernel reported the projector disconnected" "the kernel connector catches a missing projector behind stale Hyprland state"
printf 'connected\n' > "$PROJECTORCTL_DRM_ROOT/card1-HDMI-A-1/status"

poll_recovery_log="$test_root/poll-recovery.log"
(
	write_state external eDP-1 HDMI-A-1 "" info
	TEST_MONITORS="$monitors_three"
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	active_monitor_json() { printf '[]\n'; }
	# shellcheck disable=SC2329
	safe_recover() { printf '%s\n' "$1" > "$poll_recovery_log"; }
	recover_if_needed_locked 2>/dev/null
)
assert_contains "$(<"$poll_recovery_log")" "All displays went offline" "the watchdog uses active monitors instead of stale monitor records"

dpms_log="$test_root/dpms.log"
run_lua() { printf '%s\n' "$1" >> "$dpms_log"; }
set_output_dpms eDP-1 on
set_output_dpms eDP-1 off
assert_contains "$(<"$dpms_log")" 'action = "enable"' "waking a display uses Hyprland's current DPMS action"
assert_contains "$(<"$dpms_log")" 'action = "disable"' "sleeping a display uses Hyprland's current DPMS action"

idle_check_log="$test_root/idle-check.log"
(
	write_state builtin eDP-1 HDMI-A-1 "" info
	# shellcheck disable=SC2329
	monitor_json() { printf 'called\n' > "$idle_check_log"; return 1; }
	recover_if_needed_locked
)
[[ ! -e "$idle_check_log" ]] || fail "an idle guard check queried Hyprland"
pass "the guard leaves Hyprland alone when no fail-safe is armed"

write_state external eDP-1 HDMI-A-1 "Projector only" info
if (
	# shellcheck disable=SC2329
	monitor_json() { return 1; }
	recover_if_needed_locked
); then
	fail "a guarded Hyprland outage was treated as a successful check"
fi
pass "a guarded Hyprland outage stays pending for retry"

drm_event_log="$test_root/drm-event.log"
(
	# shellcheck disable=SC2329
	emit_guard_event() { printf '%s\n' "$1" >> "$drm_event_log"; }
	handle_drm_event "monitor will print the received events"
	handle_drm_event "KERNEL[10.0] change /devices/pci/drm/card1 (drm)"
)
assert_eq check "$(<"$drm_event_log")" "a kernel DRM event queues a guard check"

rm -f "$pending_guard_file"
(
	# shellcheck disable=SC2329
	recover_if_needed_locked() { return 1; }
	guard_check 2>/dev/null || true
)
[[ -e "$pending_guard_file" ]] || fail "a failed guard check was not queued"
pass "a failed guard check is queued for retry"
rm -f "$pending_guard_file"

queue_guard_check HDMI-A-1
queue_guard_check
assert_eq HDMI-A-1 "$(<"$pending_guard_file")" "a generic retry does not overwrite a specific removal event"
rm -f "$pending_guard_file"

status_failure=""
if status_failure="$({
	# shellcheck disable=SC2329
	monitor_json() { return 1; }
	status_json
})"; then
	fail "an unavailable status returned success"
fi
assert_eq false "$(jq -r .ok <<< "$status_failure")" "an unavailable status returns error JSON and a failing exit code"

if main apply >/dev/null 2>&1; then
	fail "apply without a mode should fail"
else
	assert_eq 2 "$?" "rejects an incomplete apply command"
fi

printf '1..%d\n' "$pass_count"
