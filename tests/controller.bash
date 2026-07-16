#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
controller_source="${PROJECTORCTL_SOURCE:-$repo_root/src/projectorctl.sh}"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export HOME="$test_root/home"
export PROJECTORCTL_RUNTIME_DIR="$test_root/run"
export PROJECTORCTL_LAYOUT_FILE="$test_root/layout.lua"
mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$controller_source"
state_file="$PROJECTORCTL_RUNTIME_DIR/state.json"

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

if main apply >/dev/null 2>&1; then
	fail "apply without a mode should fail"
else
	assert_eq 2 "$?" "rejects an incomplete apply command"
fi

printf '1..%d\n' "$pass_count"
