#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
controller_source="${PROJECTORCTL_SOURCE:-$repo_root/src/projectorctl.sh}"
controller_lib_dir="${PROJECTORCTL_LIB_DIR:-$(dirname -- "$controller_source")/lib}"
test_root="$(mktemp -d)"
test_shell_pid="$BASHPID"
trap '[[ $BASHPID != "$test_shell_pid" ]] || rm -rf "$test_root"' EXIT

export HOME="$test_root/home"
export PROJECTORCTL_RUNTIME_DIR="$test_root/run"
export PROJECTORCTL_LAYOUT_FILE="$test_root/layout.lua"
export PROJECTORCTL_PRIVATE_LAYOUT_FILE="$test_root/private-layout.lua"
export PROJECTORCTL_DRM_ROOT="$test_root/drm"
mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$controller_source"
state_file="$PROJECTORCTL_RUNTIME_DIR/state.json"
pending_guard_file="$PROJECTORCTL_RUNTIME_DIR/recovery.pending"

pass_count=0
pass() { printf 'ok %d - %s\n' "$((++pass_count))" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

assert_eq() {
	[[ "$2" == "$1" ]] || fail "$3 (wanted '$1', got '$2')"
	pass "$3"
}

assert_contains() {
	[[ "$1" == *"$2"* ]] || fail "$3 (missing '$2')"
	pass "$3"
}

assert_not_contains() {
	[[ "$1" != *"$2"* ]] || fail "$3 (found '$2')"
	pass "$3"
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
assert_eq HDMI-A-1 "$EXTERNAL_OUTPUT" "prefers HDMI without a remembered display"
output_is_mirroring "$(jq -c '.[0:2]' <<< "$monitors_three")" HDMI-A-1 eDP-1 || fail "did not recognize mirror id"
pass "recognizes Hyprland's numeric mirror id"

layout_log="$test_root/layouts.log"
run_layout() { printf '%s\n' "$1" > "$layout_log"; }
wait_for_layout() { return 0; }
BUILTIN_OUTPUT=eDP-1
EXTERNAL_OUTPUT=HDMI-A-1

apply_builtin_only "$monitors_three" || fail "Private layout failed in harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "", disabled = true' "Private mode denies unknown outputs"
assert_contains "$layout" 'output = "eDP-1", mode = "preferred"' "Private mode explicitly keeps the laptop active"
assert_contains "$layout" 'output = "HDMI-A-1", disabled = true' "Private mode disables the projector"
assert_contains "$layout" 'output = "DP-2", disabled = true' "Private mode disables every other output"
assert_not_contains "$layout" 'mirror = "eDP-1"' "Private mode never leaves a mirror rule"
assert_contains "$(<"$PROJECTORCTL_PRIVATE_LAYOUT_FILE")" 'output = "", disabled = true' "Private baseline persists across sessions"

apply_duplicate "$monitors_three" || fail "Present layout failed in harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "", disabled = true' "Present mode remains deny-by-default"
assert_contains "$layout" 'output = "HDMI-A-1"' "Present mode explicitly enables the selected projector"
assert_contains "$layout" 'mirror = "eDP-1"' "Present mode mirrors from the laptop"
assert_contains "$layout" 'output = "DP-2", disabled = true' "Present mode disables unrelated outputs"
assert_not_contains "$(<"$PROJECTORCTL_PRIVATE_LAYOUT_FILE")" 'mirror = "eDP-1"' "Present mode never persists sharing across sessions"

apply_extended "$monitors_three" right || fail "Extend layout failed in harness"
layout="$(<"$layout_log")"
assert_contains "$layout" 'output = "HDMI-A-1", mode = "preferred", position = "auto-right"' "Extend delegates placement to Hyprland"
assert_contains "$layout" 'output = "DP-2", disabled = true' "Extend disables unrelated outputs"

if apply_mode_locked external > "$test_root/external.json"; then
	fail "projector-only remained available"
else
	assert_eq 2 "$?" "projector-only is rejected"
fi
assert_contains "$(<"$test_root/external.json")" "Projector-only was removed" "projector-only explains the safe replacement"

controller_text="$({
	sed -n '1,999p' "$controller_source"
	find "$controller_lib_dir" -type f -name '*.sh' -print0 | xargs -0 sed -n '1,999p'
})"
assert_not_contains "$controller_text" 'moveworkspacetomonitor' "controller has no raw workspace relocation"
assert_not_contains "$controller_text" 'workspace.move' "controller has no Lua workspace relocation"
assert_not_contains "$controller_text" 'dpms({' "controller does not hide the laptop with DPMS"

TEST_MONITORS="$(jq -c '.[0:2]' <<< "$monitors_three")"
monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
status="$(status_json)"
assert_eq duplicate "$(jq -r .mode <<< "$status")" "reports Present as a mirror"
assert_eq 'Present / mirror' "$(jq -r .modeLabel <<< "$status")" "uses the presentation label"

TEST_MONITORS='[
	{"id":0,"name":"eDP-1","disabled":false,"dpmsStatus":true,"width":1920,"height":1080,"x":0,"y":0,"mirrorOf":-1},
	{"id":1,"name":"HDMI-A-1","disabled":true,"dpmsStatus":false,"width":1920,"height":1080,"x":0,"y":0,"mirrorOf":-1}
]'
status="$(status_json)"
assert_eq builtin "$(jq -r .mode <<< "$status")" "reports the fail-closed Private layout"
assert_contains "$(jq -r .message <<< "$status")" "external outputs are disabled" "status explains the privacy boundary"

probe_log="$test_root/probes.log"
# Restore the real verifier after the layout-construction harness above.
# shellcheck source=/dev/null
source "$controller_lib_dir/hyprland.sh"
(
	trap - EXIT
	export verification_attempts=3 monitor_probe_timeout=0.2
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$1" >> "$probe_log"; return 1; }
	wait_for_layout builtin eDP-1 || true
)
assert_eq 3 "$(wc -l < "$probe_log")" "layout verification has a fixed probe count"
assert_eq 0.2 "$(sed -n '1p' "$probe_log")" "layout verification uses short bounded probes"

hypr_root="$test_root/hypr"
mkdir -p "$hypr_root/older" "$hypr_root/newer"
printf '10 wayland-2\n' > "$hypr_root/older/hyprland.lock"
printf '11 wayland-1\n' > "$hypr_root/newer/hyprland.lock"
touch -t 202601010101 "$hypr_root/older/hyprland.lock"
touch -t 202602020202 "$hypr_root/newer/hyprland.lock"
instance_is_live() { [[ -n "$1" ]]; }
use_instance() { CHOSEN_INSTANCE="$1"; }
export HYPRLAND_INSTANCE_SIGNATURE="" WAYLAND_DISPLAY=wayland-2
CHOSEN_INSTANCE=""
resolve_instance
assert_eq older "$CHOSEN_INSTANCE" "follows WAYLAND_DISPLAY when the signature is stale"
export WAYLAND_DISPLAY=wayland-missing
resolve_instance
assert_eq newer "$CHOSEN_INSTANCE" "falls back to the newest live Hyprland instance"

assert_eq HDMI-A-1 "$(removed_output_from_event 'monitorremoved>>HDMI-A-1')" "reads v1 removal events"
assert_eq HDMI-A-1 "$(removed_output_from_event 'monitorremovedv2>>1,HDMI-A-1,LG TV')" "reads v2 removal events"

recovery_log="$test_root/recovery.log"
(
	trap - EXIT
	write_state duplicate eDP-1 HDMI-A-1 "Presenting" info
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$recovery_log"; }
	recover_if_needed_locked HDMI-A-1
)
assert_contains "$(<"$recovery_log")" "Private mode was restored" "unplugging a presentation restores Private mode"

interrupted_log="$test_root/interrupted.log"
(
	trap - EXIT
	write_state builtin eDP-1 HDMI-A-1 "Private" info
	write_transition duplicate eDP-1 HDMI-A-1 "Switching"
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$interrupted_log"; }
	recover_if_needed_locked
)
assert_contains "$(<"$interrupted_log")" "interrupted display change" "an interrupted transition fails closed"

idle_log="$test_root/idle.log"
(
	trap - EXIT
	write_state builtin eDP-1 HDMI-A-1 "Private" info
	# shellcheck disable=SC2329
	monitor_json() { printf called > "$idle_log"; return 1; }
	recover_if_needed_locked
)
[[ ! -e "$idle_log" ]] || fail "idle guard queried Hyprland"
pass "the guard does not poll Hyprland in Private mode"

rm -f "$pending_guard_file"
(
	trap - EXIT
	# shellcheck disable=SC2329
	recover_if_needed_locked() { return 1; }
	guard_check 2>/dev/null || true
)
[[ -e "$pending_guard_file" ]] || fail "failed guard check was not queued"
pass "a failed guard check is queued for retry"

status_failure=""
# shellcheck disable=SC2329
if status_failure="$({ monitor_json() { return 1; }; status_json; })"; then
	fail "unavailable status returned success"
fi
assert_eq false "$(jq -r .ok <<< "$status_failure")" "unavailable status returns error JSON"

if main apply >/dev/null 2>&1; then
	fail "incomplete apply command succeeded"
else
	assert_eq 2 "$?" "rejects an incomplete apply command"
fi

printf '1..%d\n' "$pass_count"
