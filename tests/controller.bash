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
export PROJECTORCTL_AUDIO_AUTO_SWITCH=false
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

monitors_builtin='[
	{"id":0,"name":"eDP-1","disabled":false,"dpmsStatus":true,"width":1920,"height":1080,"scale":1,"transform":0,"x":0,"y":0,"mirrorOf":-1},
	{"id":1,"name":"HDMI-A-1","disabled":true,"dpmsStatus":false,"width":1920,"height":1080,"scale":1,"transform":0,"x":0,"y":0,"mirrorOf":-1}
]'
monitors_duplicate="$(jq -c '.[0:2]' <<< "$monitors_three")"
monitors_extend_right="$(jq -c '.[0:2] | .[1].mirrorOf = -1' <<< "$monitors_three")"
monitors_extend_left="$(jq -c '.[0:2] | .[0].x = 1920 | .[1].x = 0 | .[1].mirrorOf = -1' <<< "$monitors_three")"
monitors_legacy_external="$(jq -c '.[0:2] | .[0].dpmsStatus = false | .[1].mirrorOf = -1' <<< "$monitors_three")"
monitors_external_only="$(jq -c '.[0:2]
	| .[0].disabled = true | .[0].dpmsStatus = false
	| .[1].x = 0 | .[1].mirrorOf = -1' <<< "$monitors_three")"

monitor_snapshot_is_valid "$monitors_builtin" || fail "valid monitor snapshot was rejected"
if monitor_snapshot_is_valid '[{"name":"eDP-1"}]'; then
	fail "partial monitor snapshot was accepted"
fi
pass "partial monitor snapshots are rejected instead of assumed active"
if select_outputs '[{}]' >/dev/null 2>&1; then
	fail "malformed monitor entry was accepted"
fi
pass "malformed monitor entries fail without raw jq output"
valid_positive_integer 60 || fail "integer guard interval was rejected"
if valid_positive_integer 0.5 || ! valid_positive_number 0.5; then
	fail "guard interval validators accepted incompatible units"
fi
pass "guard scheduling only accepts values its arithmetic can consume"
assert_eq mirror "$(mode_topology duplicate)" "mode registry describes Present as a mirror"
assert_eq right "$(mode_direction extend-right)" "mode registry describes Extend right direction"
if mode_is_action external; then
	fail "mode registry still exposes legacy projector-only as an action"
fi
pass "mode registry keeps legacy projector-only diagnostic-only"

write_state builtin eDP-1 DP-2 "" info
select_outputs "$monitors_three"
assert_eq eDP-1 "$BUILTIN_OUTPUT" "finds the laptop panel"
assert_eq DP-2 "$EXTERNAL_OUTPUT" "keeps the remembered external display"

rm -f "$state_file"
select_outputs "$monitors_three"
assert_eq HDMI-A-1 "$EXTERNAL_OUTPUT" "prefers HDMI without a remembered display"
output_is_mirroring "$(jq -c '.[0:2]' <<< "$monitors_three")" HDMI-A-1 eDP-1 || fail "did not recognize mirror id"
pass "recognizes Hyprland's numeric mirror id"

stale_preference="$(jq -c '.[0:1] + [{"id":2,"name":"DP-2","disabled":true,"dpmsStatus":false,"x":1920,"y":0,"scale":1,"transform":0,"mirrorOf":-1}] + [.[1]]' <<< "$monitors_three")"
write_state builtin eDP-1 DP-2 "Private" info
select_outputs "$stale_preference"
assert_eq HDMI-A-1 "$EXTERNAL_OUTPUT" "active HDMI beats a disabled remembered connector"

multiple_internal='[
	{"id":0,"name":"eDP-1","disabled":false,"dpmsStatus":false,"x":0,"y":0},
	{"id":1,"name":"DSI-1","disabled":false,"dpmsStatus":true,"x":0,"y":0},
	{"id":2,"name":"HDMI-A-1","disabled":false,"dpmsStatus":true,"x":1920,"y":0}
]'
select_outputs "$multiple_internal"
assert_eq DSI-1 "$BUILTIN_OUTPUT" "an active internal panel beats a sleeping one"

layout_log="$test_root/layouts.log"
run_layout() { printf '%s\n' "$1" > "$layout_log"; }
wait_for_layout() { return 0; }
TEST_MONITORS="$monitors_three"
# shellcheck disable=SC2329
monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
BUILTIN_OUTPUT=eDP-1
EXTERNAL_OUTPUT=HDMI-A-1
caelestia_refresh_count=0
refresh_caelestia_screens() { ((++caelestia_refresh_count)); }

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
(( caelestia_refresh_count >= 3 )) || fail "verified layout transitions refresh Caelestia screens"
pass "verified layout transitions refresh Caelestia screens"

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
assert_contains "$controller_text" 'hl.dsp.dpms' "controller can wake a legacy projector-only laptop panel"
assert_not_contains "$controller_text" 'lua_quote disable' "controller never hides the laptop with DPMS"

TEST_MONITORS="$(jq -c '.[0:2]' <<< "$monitors_three")"
monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
write_state duplicate eDP-1 HDMI-A-1 "Presenting" info
status="$(status_json)"
assert_eq duplicate "$(jq -r .mode <<< "$status")" "reports Present as a mirror"
assert_eq 'Present / mirror' "$(jq -r .modeLabel <<< "$status")" "uses the presentation label"

external_only_status=""
write_state external eDP-1 HDMI-A-1 "Projector only" info
if external_only_status="$(status_json "$monitors_external_only")"; then
	fail "unsupported projector-only topology was reported as healthy"
fi
assert_eq unknown "$(jq -r .mode <<< "$external_only_status")" "projector-only is never misreported as Extend right"
assert_eq error "$(jq -r .health <<< "$external_only_status")" "projector-only status demands recovery"

woken_projector_only_status=""
if woken_projector_only_status="$(status_json "$monitors_extend_right")"; then
	fail "woken projector-only state was reported as healthy Extend right"
fi
assert_eq unknown "$(jq -r .mode <<< "$woken_projector_only_status")" "woken projector-only cannot select Extend right"
assert_eq extend-right "$(jq -r .observedMode <<< "$woken_projector_only_status")" "status retains the observed topology for diagnosis"
assert_contains "$(jq -r .message <<< "$woken_projector_only_status")" "Legacy projector-only" "status explains the projector-only contradiction"

declare -A status_topologies=(
	[builtin]="$monitors_builtin"
	[duplicate]="$monitors_duplicate"
	[extend-right]="$monitors_extend_right"
	[extend-left]="$monitors_extend_left"
)
for requested_mode in builtin duplicate extend-right extend-left; do
	for observed_mode in builtin duplicate extend-right extend-left; do
		write_state "$requested_mode" eDP-1 HDMI-A-1 "Matrix status" info
		matrix_status=""
		if [[ "$requested_mode" == "$observed_mode" ]]; then
			matrix_status="$(status_json "${status_topologies[$observed_mode]}")" || \
				fail "matching $requested_mode status was rejected"
			[[ "$(jq -r .mode <<< "$matrix_status")" == "$observed_mode" ]] || \
				fail "matching $requested_mode status was misclassified"
		else
			if matrix_status="$(status_json "${status_topologies[$observed_mode]}")"; then
				fail "recorded $requested_mode accepted observed $observed_mode"
			fi
			[[ "$(jq -r .mode <<< "$matrix_status")" == unknown ]] || \
				fail "recorded $requested_mode highlighted observed $observed_mode"
			[[ "$(jq -r .observedMode <<< "$matrix_status")" == "$observed_mode" ]] || \
				fail "recorded $requested_mode lost observed $observed_mode diagnostics"
		fi
	done
done
pass "status rejects every recorded/live topology mismatch"

layout_matches "$monitors_duplicate" duplicate eDP-1 HDMI-A-1 || fail "valid mirror topology was rejected"
if layout_matches "$monitors_extend_right" duplicate eDP-1 HDMI-A-1; then
	fail "broken mirror topology was accepted"
fi
pass "mirror validation rejects an unmirrored projector"
layout_matches "$monitors_extend_right" extend-right eDP-1 HDMI-A-1 || fail "valid extended topology was rejected"
if layout_matches "$monitors_extend_right" extend-left eDP-1 HDMI-A-1; then
	fail "wrong extended direction was accepted"
fi
pass "extended validation checks the requested side"
extra_internal="$(jq -c '. + [{"id":3,"name":"DSI-1","disabled":false,"dpmsStatus":true,"x":0,"y":0,"mirrorOf":-1}]' <<< "$monitors_duplicate")"
if layout_matches "$extra_internal" duplicate eDP-1 HDMI-A-1; then
	fail "mirror topology with an extra active output was accepted"
fi
pass "layout validation rejects extra active outputs"

TEST_MONITORS='[
	{"id":0,"name":"eDP-1","disabled":false,"dpmsStatus":true,"width":1920,"height":1080,"x":0,"y":0,"mirrorOf":-1},
	{"id":1,"name":"HDMI-A-1","disabled":true,"dpmsStatus":false,"width":1920,"height":1080,"x":0,"y":0,"mirrorOf":-1}
]'
write_state builtin eDP-1 HDMI-A-1 "Private" info
status="$(status_json)"
assert_eq builtin "$(jq -r .mode <<< "$status")" "reports the fail-closed Private layout"
assert_contains "$(jq -r .message <<< "$status")" "external outputs are disabled" "status explains the privacy boundary"

probe_log="$test_root/probes.log"
# Restore the real verifier after the layout-construction harness above.
# shellcheck source=/dev/null
source "$controller_lib_dir/hyprland.sh"
(
	trap - EXIT
	export verification_timeout=1 verification_retry_interval=0.1 monitor_probe_timeout=0.2
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$1" >> "$probe_log"; return 1; }
	wait_for_layout builtin eDP-1 || true
)
[[ "$(wc -l < "$probe_log")" -ge 3 ]] || fail "layout verification did not retry until its deadline"
assert_eq 0.2 "$(sed -n '1p' "$probe_log")" "layout verification uses short bounded probes"

delayed_snapshot="$test_root/delayed-snapshot.json"
delayed_attempts="$test_root/delayed-attempts"
(
	trap - EXIT
	verification_timeout=1
	verification_retry_interval=0.01
	monitor_probe_timeout=0.01
	printf '0\n' > "$delayed_attempts"
	# shellcheck disable=SC2329
	monitor_json() {
		local attempt=0
		read -r attempt < "$delayed_attempts"
		attempt=$((attempt + 1))
		printf '%s\n' "$attempt" > "$delayed_attempts"
		if ((attempt < 3)); then
			printf '%s\n' "$monitors_builtin"
		else
			printf '%s\n' "$monitors_extend_right"
		fi
	}
	wait_for_layout extend-right eDP-1 HDMI-A-1 || exit 1
	printf '%s\n' "$VERIFIED_MONITORS" > "$delayed_snapshot"
)
assert_eq "$monitors_extend_right" "$(<"$delayed_snapshot")" "verification accepts a layout that settles after initial probes"

verification_record="$PROJECTORCTL_RUNTIME_DIR/last-verification.json"
# The helper reads this global; keep the assignment explicit for the
# serialization test even though ShellCheck cannot see through the call.
# shellcheck disable=SC2034
LAST_MONITOR_SNAPSHOT="$monitors_extend_right"
write_verification_snapshot extend-right eDP-1 HDMI-A-1
assert_eq extend-right "$(jq -r .requestedMode < "$verification_record")" "failed verification records the requested layout"
assert_eq HDMI-A-1 "$(jq -r .external < "$verification_record")" "failed verification records the selected output"
jq -e --argjson expected "$monitors_extend_right" '.monitors == $expected' "$verification_record" >/dev/null || \
	fail "failed verification did not record the final monitor snapshot"
pass "failed verification records the final monitor snapshot"

legacy_mirror_result="$test_root/legacy-to-mirror.json"
(
	trap - EXIT
	TEST_MONITORS="$monitors_external_only"
	write_state external eDP-1 HDMI-A-1 "Projector only" info
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	run_layout() { TEST_MONITORS="$monitors_duplicate"; }
	apply_mode_locked duplicate > "$legacy_mirror_result"
)
assert_eq duplicate "$(jq -r .mode < "$legacy_mirror_result")" "mirror succeeds from a fully disabled laptop state"
assert_eq true "$(jq -r .ok < "$legacy_mirror_result")" "legacy projector-only transition is exactly verified"

legacy_unplug_active='[{"id":0,"name":"eDP-1","disabled":false,"dpmsStatus":true,"x":0,"y":0,"mirrorOf":-1}]'
(
	trap - EXIT
	TEST_MONITORS='[{"id":0,"name":"eDP-1","disabled":true,"dpmsStatus":false,"x":0,"y":0,"mirrorOf":-1}]'
	write_state external eDP-1 HDMI-A-1 "Projector only" info
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	run_layout() { TEST_MONITORS="$legacy_unplug_active"; }
	recover_if_needed_locked HDMI-A-1
)
assert_eq builtin "$(state_field requestedMode)" "unplugging projector-only restores a disabled laptop"

declare -A transition_topologies=(
	[builtin]="$monitors_builtin"
	[duplicate]="$monitors_duplicate"
	[extend-right]="$monitors_extend_right"
	[extend-left]="$monitors_extend_left"
	[external]="$monitors_external_only"
)
transition_result="$test_root/transition-matrix.json"
for previous_mode in builtin duplicate extend-right extend-left external; do
	for target_mode in builtin duplicate extend-right extend-left; do
		previous_snapshot="${transition_topologies[$previous_mode]}"
		target_snapshot="${transition_topologies[$target_mode]}"
		if ! (
			trap - EXIT
			TEST_MONITORS="$previous_snapshot"
			TARGET_MONITORS="$target_snapshot"
			write_state "$previous_mode" eDP-1 HDMI-A-1 "Matrix transition" info
			# shellcheck disable=SC2329
			monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
			# shellcheck disable=SC2329
			run_layout() { TEST_MONITORS="$TARGET_MONITORS"; }
			apply_mode_locked "$target_mode" > "$transition_result"
		); then
			fail "$previous_mode to $target_mode transition failed"
		fi
		[[ "$(jq -r .mode < "$transition_result")" == "$target_mode" ]] || \
			fail "$previous_mode to $target_mode returned the wrong mode"
		[[ "$(jq -r .ok < "$transition_result")" == true ]] || \
			fail "$previous_mode to $target_mode returned unhealthy status"
	done
done
pass "every supported action succeeds from every previous layout"

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

legacy_recovery_log="$test_root/legacy-recovery.log"
(
	trap - EXIT
	write_state external eDP-1 HDMI-A-1 "Projector only" info
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$legacy_recovery_log"; }
	recover_if_needed_locked
)
assert_contains "$(<"$legacy_recovery_log")" "Legacy projector-only" "legacy projector-only state is recovered"

broken_mirror_log="$test_root/broken-mirror.log"
(
	trap - EXIT
	write_state duplicate eDP-1 HDMI-A-1 "Presenting" info
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$monitors_extend_right"; }
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$broken_mirror_log"; }
	recover_if_needed_locked
)
assert_contains "$(<"$broken_mirror_log")" "presentation output failed or changed" "guard repairs a broken mirror topology"

corrupt_recovery_log="$test_root/corrupt-recovery.log"
(
	trap - EXIT
	printf '{not-json\n' > "$state_file"
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$corrupt_recovery_log"; }
	recover_if_needed_locked
)
assert_contains "$(<"$corrupt_recovery_log")" "state was missing or incompatible" "corrupt state fails closed"

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
	if recover_if_needed_locked; then
		exit 1
	fi
)
[[ -e "$idle_log" ]] || fail "Private guard did not validate the topology"
pass "the guard fails closed when Private topology cannot be validated"

rm -f "$pending_guard_file"
(
	trap - EXIT
	# shellcheck disable=SC2329
	recover_if_needed_locked() { return 1; }
	guard_check 2>/dev/null || true
)
[[ -e "$pending_guard_file" ]] || fail "failed guard check was not queued"
pass "a failed guard check is queued for retry"

rm -f "$pending_guard_file"
queue_guard_check HDMI-A-1
assert_eq HDMI-A-1 "$(take_pending_guard)" "queued unplug keeps its connector identity"

mkdir -p "$PROJECTORCTL_DRM_ROOT/card0-HDMI-A-1" "$PROJECTORCTL_DRM_ROOT/card1-HDMI-A-1"
printf 'disconnected\n' > "$PROJECTORCTL_DRM_ROOT/card0-HDMI-A-1/status"
printf 'connected\n' > "$PROJECTORCTL_DRM_ROOT/card1-HDMI-A-1/status"
assert_eq connected "$(drm_connector_status HDMI-A-1)" "a connected GPU wins over a stale disconnected connector"

dpms_log="$test_root/dpms.log"
(
	trap - EXIT
	# shellcheck disable=SC2329
	run_lua() { printf '%s\n' "$1" > "$dpms_log"; }
	wake_configured_output "$monitors_legacy_external" eDP-1
)
assert_contains "$(<"$dpms_log")" '"enable"' "legacy projector-only recovery wakes the laptop panel"

failed_layout="$test_root/failed-layout.lua"
failed_apply="$test_root/failed-apply.json"
(
	trap - EXIT
	PROJECTORCTL_LAYOUT_FILE="$failed_layout"
	layout_file="$failed_layout"
	write_state builtin eDP-1 HDMI-A-1 "Private" info
	TEST_MONITORS="$monitors_duplicate"
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	run_layout() { printf 'return { mirror = "eDP-1" }\n' > "$layout_file"; return 1; }
	# shellcheck disable=SC2329
	recover_private() { return 1; }
	if apply_mode_locked duplicate > "$failed_apply"; then
		exit 1
	fi
)
assert_not_contains "$(<"$failed_layout")" 'mirror = "eDP-1"' "failed apply replaces a staged presentation file with Private layout"

final_mismatch_recovery="$test_root/final-mismatch-recovery.log"
(
	trap - EXIT
	TEST_MONITORS="$monitors_duplicate"
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$TEST_MONITORS"; }
	# shellcheck disable=SC2329
	apply_layout_mode() {
		# shellcheck disable=SC2034
		VERIFIED_MONITORS="$monitors_builtin"
		return 0
	}
	# shellcheck disable=SC2329
	recover_private() { printf '%s\n' "$1" > "$final_mismatch_recovery"; }
	if apply_mode_locked duplicate > /dev/null; then
		exit 1
	fi
)
assert_contains "$(<"$final_mismatch_recovery")" "private laptop display was restored" "unsafe final status triggers recovery instead of success"

write_state builtin eDP-1 HDMI-A-1 "Private" info
state_before="$(<"$state_file")"
(
	trap - EXIT
	# shellcheck disable=SC2329
	jq() { return 1; }
	if write_state duplicate eDP-1 HDMI-A-1 "Presenting" info; then
		exit 1
	fi
)
assert_eq "$state_before" "$(<"$state_file")" "failed state serialization does not replace valid state"

(
	trap - EXIT
	# shellcheck disable=SC2034
	command_kill_after=0.1
	if run_bounded 0.1 bash -c 'trap "" TERM; while :; do :; done'; then
		exit 1
	fi
)
pass "external command deadlines escalate to SIGKILL"

interrupt_log="$test_root/interrupt-recovery.log"
interrupt_result=0
(
	# shellcheck disable=SC2034
	ACTIVE_PRIVATE_RULES='private rules'
	BUILTIN_OUTPUT=eDP-1
	EXTERNAL_OUTPUT=HDMI-A-1
	# shellcheck disable=SC2329
	stage_private_layout() { :; }
	# shellcheck disable=SC2329
	run_layout() { printf 'reload\n' >> "$interrupt_log"; }
	# shellcheck disable=SC2329
	monitor_json() { printf '%s\n' "$monitors_builtin"; }
	# shellcheck disable=SC2329
	wake_output() { :; }
	# shellcheck disable=SC2329
	wait_for_layout() { :; }
	# shellcheck disable=SC2329
	write_state() { printf 'committed\n' >> "$interrupt_log"; }
	abort_active_transition TERM
) 2>/dev/null || interrupt_result=$?
assert_eq 143 "$interrupt_result" "an interrupted apply returns the signal exit code"
assert_contains "$(<"$interrupt_log")" committed "an interrupted apply actively restores Private mode"

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
