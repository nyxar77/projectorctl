#!/usr/bin/env bash
set -Eeuo pipefail

runtime_root="${PROJECTORCTL_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/projector-control-${UID}}"
hypr_root="${PROJECTORCTL_HYPR_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/hypr}"
state_file="$runtime_root/state.json"
layout_file="${PROJECTORCTL_LAYOUT_FILE:-${HOME}/.cache/hypr/projector-layout.lua}"
operation_lock="$runtime_root/operation.lock"
guard_lock="$runtime_root/guard.lock"

hyprctl_bin="${PROJECTORCTL_HYPRCTL:-hyprctl}"
caelestia_bin="${PROJECTORCTL_CAELESTIA:-caelestia}"
notify_bin="${PROJECTORCTL_NOTIFY_SEND:-notify-send}"

internal_pattern='^(eDP|LVDS|DSI)(-|$)'
ignored_output_pattern='^(HEADLESS|FALLBACK)(-|$)'
BUILTIN_OUTPUT=""
EXTERNAL_OUTPUT=""
LAST_ERROR=""

mkdir -p "$runtime_root"

instance_is_live() {
	local signature="$1"
	local instance_dir="$hypr_root/$signature"
	local pid=""
	local command_name=""
	local command_line=""

	[[ -n "$signature" && -S "$instance_dir/.socket.sock" && -r "$instance_dir/hyprland.lock" ]] || return 1
	read -r pid _ < "$instance_dir/hyprland.lock" || return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	command_name="$(</proc/"$pid"/comm)" 2>/dev/null || return 1
	command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
	[[ "${command_name,,} ${command_line,,}" == *hyprland* ]]
}

use_instance() {
	local signature="$1"
	local pid=""
	local display=""

	read -r pid display < "$hypr_root/$signature/hyprland.lock" || true
	export HYPRLAND_INSTANCE_SIGNATURE="$signature"
	if [[ -n "$display" ]]; then
		export WAYLAND_DISPLAY="$display"
	fi
}

resolve_instance() {
	local current="${HYPRLAND_INSTANCE_SIGNATURE:-}"
	local wanted_display="${WAYLAND_DISPLAY:-}"
	local instance_dir=""
	local signature=""
	local display=""
	local candidate=""
	local candidate_mtime=-1
	local lock_mtime=0
	local -a instance_dirs=()

	if instance_is_live "$current"; then
		use_instance "$current"
		return 0
	fi

	shopt -s nullglob
	instance_dirs=("$hypr_root"/*)
	shopt -u nullglob

	for instance_dir in "${instance_dirs[@]}"; do
		signature="${instance_dir##*/}"
		instance_is_live "$signature" || continue
		read -r _ display < "$instance_dir/hyprland.lock" || display=""
		if [[ -n "$wanted_display" && "$display" == "$wanted_display" ]]; then
			use_instance "$signature"
			return 0
		fi
		lock_mtime="$(stat -c %Y "$instance_dir/hyprland.lock" 2>/dev/null || printf '0')"
		if ((lock_mtime > candidate_mtime)); then
			candidate="$signature"
			candidate_mtime="$lock_mtime"
		fi
	done

	[[ -n "$candidate" ]] || return 1
	use_instance "$candidate"
}

monitor_json() {
	local monitors=""

	resolve_instance || return 1
	monitors="$(timeout 3 "$hyprctl_bin" -j monitors all 2>/dev/null)" || return 1
	jq -e 'type == "array"' <<< "$monitors" >/dev/null 2>&1 || return 1
	printf '%s\n' "$monitors"
}

read_state() {
	if [[ -r "$state_file" ]] && jq -e 'type == "object"' "$state_file" >/dev/null 2>&1; then
		jq -c . "$state_file"
	else
		printf '{}\n'
	fi
}

state_field() {
	local field="$1"
	read_state | jq -r --arg field "$field" '.[$field] // empty'
}

write_state() {
	local mode="$1"
	local builtin="$2"
	local external="$3"
	local event="${4:-}"
	local level="${5:-info}"
	local temporary="$state_file.tmp.$$"

	jq -cn \
		--arg mode "$mode" \
		--arg builtin "$builtin" \
		--arg external "$external" \
		--arg event "$event" \
		--arg level "$level" \
		--argjson updatedAt "$(date +%s)" \
		'{requestedMode: $mode, builtin: $builtin, external: $external, lastEvent: $event, eventLevel: $level, updatedAt: $updatedAt}' \
		> "$temporary"
	mv -f "$temporary" "$state_file"
}

select_outputs() {
	local monitors="$1"
	local remembered_external=""

	BUILTIN_OUTPUT="$(jq -r --arg pattern "$internal_pattern" '
		[.[] | select(.name | test($pattern; "i"))]
		| sort_by([if (.disabled // false) then 1 else 0 end, .name])
		| .[0].name // empty
	' <<< "$monitors")"

	remembered_external="$(state_field external)"
	if [[ -n "$remembered_external" ]] && jq -e \
		--arg output "$remembered_external" \
		--arg internal "$internal_pattern" \
		--arg ignored "$ignored_output_pattern" '
			any(.[];
				.name == $output
				and ((.name | test($internal; "i")) | not)
				and ((.name | test($ignored; "i")) | not)
			)
		' <<< "$monitors" >/dev/null; then
		EXTERNAL_OUTPUT="$remembered_external"
	else
		EXTERNAL_OUTPUT="$(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '
			[.[] | select(
				((.name | test($internal; "i")) | not)
				and ((.name | test($ignored; "i")) | not)
			)]
			| sort_by([
				if (.disabled // false) then 1 else 0 end,
				if (.name | test("^HDMI"; "i")) then 0 else 1 end,
				.name
			])
			| .[0].name // empty
		' <<< "$monitors")"
	fi
}

output_is_active() {
	local monitors="$1"
	local output="$2"
	[[ -n "$output" ]] && jq -e --arg output "$output" '
		any(.[]; .name == $output and (.disabled // false) == false and (.dpmsStatus // true) == true)
	' <<< "$monitors" >/dev/null
}

output_is_configured() {
	local monitors="$1"
	local output="$2"
	[[ -n "$output" ]] && jq -e --arg output "$output" 'any(.[]; .name == $output and (.disabled // false) == false)' <<< "$monitors" >/dev/null
}

output_exists() {
	local monitors="$1"
	local output="$2"
	[[ -n "$output" ]] && jq -e --arg output "$output" 'any(.[]; .name == $output)' <<< "$monitors" >/dev/null
}

active_output_count() {
	local monitors="$1"
	jq -r --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($ignored; "i")) | not)
		and (.disabled // false) == false
		and (.dpmsStatus // true) == true
	)] | length' <<< "$monitors"
}

active_external_count() {
	local monitors="$1"
	jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($internal; "i")) | not)
		and ((.name | test($ignored; "i")) | not)
		and (.disabled // false) == false
		and (.dpmsStatus // true) == true
	)] | length' <<< "$monitors"
}

other_external_is_active() {
	local monitors="$1"
	local selected="$2"
	jq -e --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" --arg selected "$selected" '
		any(.[];
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
			and .name != $selected
			and (.disabled // false) == false
			and (.dpmsStatus // true) == true
		)
	' <<< "$monitors" >/dev/null
}

output_is_mirroring() {
	local monitors="$1"
	local mirror_output="$2"
	local source_output="$3"
	[[ -n "$mirror_output" && -n "$source_output" ]] && jq -e \
		--arg mirror "$mirror_output" \
		--arg source "$source_output" '
			([.[] | select(.name == $source)][0].id | tostring) as $sourceId
			|
			any(.[];
				.name == $mirror
				and (.disabled // false) == false
				and (.dpmsStatus // true) == true
				and (((.mirrorOf // "") | tostring) == $source or ((.mirrorOf // "") | tostring) == $sourceId)
			)
		' <<< "$monitors" >/dev/null
}

lua_quote() {
	jq -Rn --arg value "$1" '$value'
}

monitor_scale() {
	local monitors="$1"
	local output="$2"
	jq -r --arg output "$output" '([.[] | select(.name == $output)][0].scale // 1) as $scale | if ($scale | type) == "number" and $scale > 0 then $scale else 1 end' <<< "$monitors"
}

monitor_transform() {
	local monitors="$1"
	local output="$2"
	jq -r --arg output "$output" '([.[] | select(.name == $output)][0].transform // 0) as $transform | if ($transform | type) == "number" then $transform else 0 end' <<< "$monitors"
}

enable_rule() {
	local monitors="$1"
	local output="$2"
	local position="$3"
	local scale=""
	local transform=""

	scale="$(monitor_scale "$monitors" "$output")"
	transform="$(monitor_transform "$monitors" "$output")"
	printf '{ output = %s, mode = "preferred", position = %s, scale = %s, transform = %s, disabled = false, mirror = "" }' \
		"$(lua_quote "$output")" "$(lua_quote "$position")" "$scale" "$transform"
}

mirror_rule() {
	local monitors="$1"
	local output="$2"
	local source="$3"
	local scale=""
	local transform=""

	scale="$(monitor_scale "$monitors" "$output")"
	transform="$(monitor_transform "$monitors" "$output")"
	printf '{ output = %s, mode = "preferred", scale = %s, transform = %s, disabled = false, mirror = %s }' \
		"$(lua_quote "$output")" "$scale" "$transform" "$(lua_quote "$source")"
}

disable_rule() {
	local output="$1"
	printf '{ output = %s, disabled = true }' "$(lua_quote "$output")"
}

run_lua() {
	local script="$1"
	local command_output=""

	resolve_instance || {
		LAST_ERROR="Hyprland is not reachable"
		return 1
	}

	if ! command_output="$(timeout 5 "$hyprctl_bin" eval "$script" 2>&1)"; then
		command_output="${command_output//$'\n'/ }"
		LAST_ERROR="${command_output:0:220}"
		[[ -n "$LAST_ERROR" ]] || LAST_ERROR="Hyprland rejected the display command"
		return 1
	fi
	if [[ "$command_output" == error:* ]]; then
		command_output="${command_output//$'\n'/ }"
		LAST_ERROR="${command_output:0:220}"
		return 1
	fi

	return 0
}

run_layout() {
	local rules="${1//$'\n'/, }"
	local layout_dir="${layout_file%/*}"
	local temporary="${layout_file}.tmp.$$"

	mkdir -p "$layout_dir"
	printf 'return { %s }\n' "$rules" > "$temporary"
	mv -f "$temporary" "$layout_file"
	resolve_instance || {
		LAST_ERROR="Hyprland is not reachable"
		return 1
	}
	if ! timeout 8 "$hyprctl_bin" reload >/dev/null 2>&1; then
		LAST_ERROR="Hyprland could not reload the display layout"
		return 1
	fi
}

set_output_dpms() {
	local output="$1"
	local action="$2"
	local script=""

	printf -v script 'hl.dispatch(hl.dsp.dpms({ action = %s, monitor = %s }))' \
		"$(lua_quote "$action")" "$(lua_quote "$output")"
	run_lua "$script"
}

focus_output() {
	local output="$1"
	local script=""

	printf -v script 'hl.dispatch(hl.dsp.focus({ monitor = %s }))' "$(lua_quote "$output")"
	run_lua "$script"
}

move_workspace_to_output() {
	local workspace="$1"
	local output="$2"
	local script=""

	printf -v script 'hl.dispatch(hl.dsp.workspace.move({ workspace = %s, monitor = %s }))' \
		"$workspace" "$(lua_quote "$output")"
	run_lua "$script"
}

wait_for_output() {
	local output="$1"
	local expected="$2"
	local current=""
	local attempt=0

	for ((attempt = 0; attempt < 30; attempt++)); do
		if current="$(monitor_json)"; then
			if [[ "$expected" == "active" ]] && output_is_active "$current" "$output"; then
				return 0
			fi
			if [[ "$expected" == "inactive" ]] && ! output_is_active "$current" "$output"; then
				return 0
			fi
			if [[ "$expected" == "configured" ]] && output_is_configured "$current" "$output"; then
				return 0
			fi
		fi
		sleep 0.1
	done

	LAST_ERROR="$output did not become $expected"
	return 1
}

wake_output() {
	local output="$1"
	local current=""

	current="$(monitor_json)" || {
		LAST_ERROR="Could not inspect $output before waking it"
		return 1
	}
	output_is_configured "$current" "$output" || {
		LAST_ERROR="$output is not configured"
		return 1
	}
	if output_is_active "$current" "$output"; then
		return 0
	fi

	set_output_dpms "$output" on || return 1
	wait_for_output "$output" active
}

sleep_output() {
	local output="$1"
	local current=""
	local visible_count=0

	current="$(monitor_json)" || {
		LAST_ERROR="Could not inspect $output before powering it down"
		return 1
	}
	visible_count="$(active_output_count "$current")"
	if ((visible_count < 2)); then
		LAST_ERROR="Refusing to power down $output without another visible display"
		return 1
	fi

	set_output_dpms "$output" off || return 1
	wait_for_output "$output" inactive || return 1
	current="$(monitor_json)" || return 1
	if (( $(active_output_count "$current") == 0 )); then
		set_output_dpms "$output" on || true
		wait_for_output "$output" active || true
		LAST_ERROR="The external display disappeared during the switch"
		return 1
	fi
}

wait_for_no_other_external() {
	local selected="$1"
	local current=""
	local attempt=0

	for ((attempt = 0; attempt < 30; attempt++)); do
		if current="$(monitor_json)" && ! other_external_is_active "$current" "$selected"; then
			return 0
		fi
		sleep 0.1
	done

	LAST_ERROR="Another external display stayed active"
	return 1
}

extended_layout_matches() {
	local monitors="$1"
	local direction="$2"
	local builtin_x=0
	local external_x=0

	output_is_active "$monitors" "$BUILTIN_OUTPUT" || return 1
	output_is_active "$monitors" "$EXTERNAL_OUTPUT" || return 1
	builtin_x="$(jq -r --arg output "$BUILTIN_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
	external_x="$(jq -r --arg output "$EXTERNAL_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"

	if [[ "$direction" == "right" ]]; then
		((external_x > builtin_x))
	else
		((external_x < builtin_x))
	fi
}

wait_for_extended_layout() {
	local direction="$1"
	local current=""
	local attempt=0

	for ((attempt = 0; attempt < 30; attempt++)); do
		if current="$(monitor_json)" && extended_layout_matches "$current" "$direction"; then
			return 0
		fi
		sleep 0.1
	done

	LAST_ERROR="Hyprland did not place the projector on the $direction"
	return 1
}

refresh_wallpaper() {
	local wallpaper_file="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/wallpaper/path.txt"
	local wallpaper=""

	command -v "$caelestia_bin" >/dev/null 2>&1 || return 1
	[[ -r "$wallpaper_file" ]] || return 1
	read -r wallpaper < "$wallpaper_file" || return 1
	[[ -n "$wallpaper" && -f "$wallpaper" ]] || return 1
	timeout 12 "$caelestia_bin" wallpaper -f "$wallpaper" >/dev/null 2>&1
}

notify_recovery() {
	local message="$1"
	if command -v "$notify_bin" >/dev/null 2>&1; then
		"$notify_bin" -u critical -a "Projector" "Laptop display restored" "$message" >/dev/null 2>&1 || true
	fi
}

move_workspaces_to_output() {
	local source="$1"
	local target="$2"
	local workspaces=""
	local workspace=""
	local -a workspace_ids=()

	resolve_instance || {
		LAST_ERROR="Hyprland is not reachable"
		return 1
	}
	if ! workspaces="$(timeout 5 "$hyprctl_bin" -j workspaces 2>/dev/null)"; then
		LAST_ERROR="Could not inspect workspaces before switching displays"
		return 1
	fi
	mapfile -t workspace_ids < <(jq -r --arg source "$source" '.[] | select(.monitor == $source and .id > 0) | .id' <<< "$workspaces")
	for workspace in "${workspace_ids[@]}"; do
		move_workspace_to_output "$workspace" "$target" || return 1
	done
	focus_output "$target"
}

prepare_both_outputs() {
	local monitors="$1"
	local current="$monitors"
	local position=""
	local rule=""

	if ! output_is_configured "$current" "$BUILTIN_OUTPUT"; then
		if output_is_active "$current" "$EXTERNAL_OUTPUT"; then
			position="auto-left"
		else
			position="0x0"
		fi
		rule="$(enable_rule "$current" "$BUILTIN_OUTPUT" "$position")"
		run_layout "$rule" || return 1
		wait_for_output "$BUILTIN_OUTPUT" configured || return 1
		current="$(monitor_json)" || {
			LAST_ERROR="Could not verify the laptop display"
			return 1
		}
	fi
	wake_output "$BUILTIN_OUTPUT" || return 1
	current="$(monitor_json)" || return 1

	if ! output_is_configured "$current" "$EXTERNAL_OUTPUT"; then
		rule="$(enable_rule "$current" "$EXTERNAL_OUTPUT" "auto-right")"
		run_layout "$rule" || return 1
		wait_for_output "$EXTERNAL_OUTPUT" configured || return 1
	fi
	wake_output "$EXTERNAL_OUTPUT"
}

emergency_recover() {
	local builtin="$1"
	local command_output=""

	resolve_instance || return 1
	if ! command_output="$(timeout 8 "$hyprctl_bin" reload 2>&1)"; then
		command_output="${command_output//$'\n'/ }"
		LAST_ERROR="${command_output:0:220}"
		[[ -n "$LAST_ERROR" ]] || LAST_ERROR="Hyprland configuration reload failed"
		return 1
	fi

	sleep 0.5
	set_output_dpms "$builtin" on || true
	wait_for_output "$builtin" active
}

safe_recover() {
	local reason="$1"
	local monitors=""
	local builtin="$BUILTIN_OUTPUT"
	local external=""
	local rule=""
	local script=""
	local -a rules=()

	monitors="$(monitor_json)" || return 1
	if [[ -z "$builtin" ]]; then
		builtin="$(state_field builtin)"
	fi
	if ! output_exists "$monitors" "$builtin"; then
		builtin=""
	fi
	select_outputs "$monitors"
	if [[ -z "$builtin" ]]; then
		builtin="$BUILTIN_OUTPUT"
	fi
	[[ -n "$builtin" ]] || return 1
	BUILTIN_OUTPUT="$builtin"

	# Restore visible laptop output first. Do not wait on a removed projector.
	if ! output_is_configured "$monitors" "$builtin"; then
		rule="$(enable_rule "$monitors" "$builtin" "0x0")"
		run_layout "$rule" || emergency_recover "$builtin" || return 1
		wait_for_output "$builtin" configured || emergency_recover "$builtin" || return 1
	fi
	if ! wake_output "$builtin"; then
		emergency_recover "$builtin" || return 1
	fi

	focus_output "$builtin" || true
	monitors="$(monitor_json)" || return 1
	select_outputs "$monitors"
	BUILTIN_OUTPUT="$builtin"
	external="$EXTERNAL_OUTPUT"
	if [[ -n "$external" ]] && output_is_active "$monitors" "$external"; then
		rules+=("$(enable_rule "$monitors" "$builtin" "0x0")")
		rules+=("$(enable_rule "$monitors" "$external" "auto-right")")
		printf -v script '%s\n' "${rules[@]}"
		run_layout "$script" || true
	fi
	monitors="$(monitor_json)" || return 1
	select_outputs "$monitors"
	BUILTIN_OUTPUT="$builtin"
	if (( $(active_external_count "$monitors") > 0 )); then
		write_state extend-right "$builtin" "$EXTERNAL_OUTPUT" "$reason" warning
	else
		write_state builtin "$builtin" "" "$reason" warning
	fi
	refresh_wallpaper || true
	notify_recovery "$reason"
}

apply_builtin_only() {
	local monitors="$1"
	local rule=""
	local script=""
	local output=""
	local -a rules=()
	local -a external_outputs=()

	write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Switching to laptop only" info
	rule="$(enable_rule "$monitors" "$BUILTIN_OUTPUT" "0x0")"
	run_layout "$rule" || return 1
	wait_for_output "$BUILTIN_OUTPUT" configured || return 1
	wake_output "$BUILTIN_OUTPUT" || return 1

	monitors="$(monitor_json)" || {
		LAST_ERROR="Could not verify connected displays"
		return 1
	}
	mapfile -t external_outputs < <(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '
		.[] | select(
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
		) | .name
	' <<< "$monitors")
	rules+=("$(enable_rule "$monitors" "$BUILTIN_OUTPUT" "0x0")")
	for output in "${external_outputs[@]}"; do
		rules+=("$(disable_rule "$output")")
	done
	if ((${#rules[@]} > 0)); then
		printf -v script '%s\n' "${rules[@]}"
		run_layout "$script" || return 1
	fi

	monitors="$(monitor_json)" || return 1
	if (( $(active_external_count "$monitors") != 0 )); then
		LAST_ERROR="An external display stayed active"
		return 1
	fi
	write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Laptop display is active" info
}

apply_external_only() {
	local monitors="$1"
	local current=""
	local script=""
	local output=""
	local -a rules=()
	local -a other_outputs=()

	prepare_both_outputs "$monitors" || return 1
	current="$(monitor_json)" || return 1
	rules+=("$(enable_rule "$current" "$EXTERNAL_OUTPUT" "0x0")")
	rules+=("$(enable_rule "$current" "$BUILTIN_OUTPUT" "auto-left")")
	mapfile -t other_outputs < <(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" --arg selected "$EXTERNAL_OUTPUT" '
		.[] | select(
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
			and .name != $selected
		) | .name
	' <<< "$current")
	for output in "${other_outputs[@]}"; do
		rules+=("$(disable_rule "$output")")
	done
	printf -v script '%s\n' "${rules[@]}"
	run_layout "$script" || return 1
	wait_for_output "$BUILTIN_OUTPUT" active || return 1
	wait_for_output "$EXTERNAL_OUTPUT" active || return 1
	wait_for_no_other_external "$EXTERNAL_OUTPUT" || return 1
	move_workspaces_to_output "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" || return 1
	write_state external "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Laptop fallback is armed" info
	sleep_output "$BUILTIN_OUTPUT" || return 1
	wait_for_output "$EXTERNAL_OUTPUT" active || return 1
	write_state external "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Projector only; laptop fallback is armed" info
}

apply_extended() {
	local monitors="$1"
	local direction="$2"
	local current=""
	local script=""
	local output=""
	local -a rules=()
	local -a other_outputs=()

	prepare_both_outputs "$monitors" || return 1
	current="$(monitor_json)" || return 1
	if [[ "$direction" == "right" ]]; then
		rules+=("$(enable_rule "$current" "$BUILTIN_OUTPUT" "0x0")")
		rules+=("$(enable_rule "$current" "$EXTERNAL_OUTPUT" "auto-right")")
	else
		rules+=("$(enable_rule "$current" "$EXTERNAL_OUTPUT" "0x0")")
		rules+=("$(enable_rule "$current" "$BUILTIN_OUTPUT" "auto-right")")
	fi
	mapfile -t other_outputs < <(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" --arg selected "$EXTERNAL_OUTPUT" '
		.[] | select(
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
			and .name != $selected
		) | .name
	' <<< "$current")
	for output in "${other_outputs[@]}"; do
		rules+=("$(disable_rule "$output")")
	done
	printf -v script '%s\n' "${rules[@]}"
	run_layout "$script" || return 1
	wait_for_output "$BUILTIN_OUTPUT" active || return 1
	wait_for_output "$EXTERNAL_OUTPUT" active || return 1
	wait_for_no_other_external "$EXTERNAL_OUTPUT" || return 1
	wait_for_extended_layout "$direction" || return 1
	write_state "extend-$direction" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Projector is on the $direction" info
}

apply_duplicate() {
	local monitors="$1"
	local current=""
	local script=""
	local output=""
	local -a rules=()
	local -a other_outputs=()

	prepare_both_outputs "$monitors" || return 1
	current="$(monitor_json)" || return 1
	rules+=("$(enable_rule "$current" "$BUILTIN_OUTPUT" "0x0")")
	rules+=("$(mirror_rule "$current" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT")")
	mapfile -t other_outputs < <(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" --arg selected "$EXTERNAL_OUTPUT" '
		.[] | select(
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
			and .name != $selected
		) | .name
	' <<< "$current")
	for output in "${other_outputs[@]}"; do
		rules+=("$(disable_rule "$output")")
	done
	printf -v script '%s\n' "${rules[@]}"
	run_layout "$script" || return 1
	wait_for_output "$BUILTIN_OUTPUT" active || return 1
	wait_for_output "$EXTERNAL_OUTPUT" active || return 1
	wait_for_no_other_external "$EXTERNAL_OUTPUT" || return 1
	current="$(monitor_json)" || return 1
	output_is_mirroring "$current" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT" || {
		LAST_ERROR="Hyprland did not create a shared duplicate layout"
		return 1
	}
	write_state duplicate "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Mirroring on $EXTERNAL_OUTPUT" info
}

mode_label() {
	case "$1" in
		builtin) printf 'Laptop only' ;;
		external) printf 'Projector only' ;;
		duplicate) printf 'Mirror' ;;
		extend-right) printf 'Extend right' ;;
		extend-left) printf 'Extend left' ;;
		extended) printf 'Extended desktop' ;;
		none) printf 'No active display' ;;
		*) printf 'Unknown layout' ;;
	esac
}

status_json() {
	local monitors=""
	local state=""
	local requested=""
	local event=""
	local event_level=""
	local mode="unknown"
	local label=""
	local health="ok"
	local message="Display layout is ready"
	local builtin_active=false
	local external_active=false
	local mirror_active=false
	local active_count=0
	local external_count=0
	local builtin_x=0
	local external_x=0
	local outputs='[]'

	if ! monitors="$(monitor_json)"; then
		jq -cn '{ok: false, mode: "unavailable", modeLabel: "Display service unavailable", health: "error", message: "Hyprland is not reachable", externalAvailable: false, activeCount: 0, outputs: []}'
		return 0
	fi

	select_outputs "$monitors"
	state="$(read_state)"
	requested="$(jq -r '.requestedMode // empty' <<< "$state")"
	event="$(jq -r '.lastEvent // empty' <<< "$state")"
	event_level="$(jq -r '.eventLevel // empty' <<< "$state")"
	output_is_active "$monitors" "$BUILTIN_OUTPUT" && builtin_active=true
	output_is_active "$monitors" "$EXTERNAL_OUTPUT" && external_active=true
	output_is_mirroring "$monitors" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT" && mirror_active=true
	active_count="$(active_output_count "$monitors")"
	external_count="$(active_external_count "$monitors")"

	if ((active_count == 0)); then
		mode="none"
	elif [[ "$builtin_active" == true && "$external_active" == true && "$mirror_active" == true && "$external_count" -eq 1 ]]; then
		mode="duplicate"
	elif [[ "$builtin_active" == true && "$external_count" -eq 0 ]]; then
		mode="builtin"
	elif [[ "$builtin_active" == false && "$external_count" -gt 0 ]]; then
		mode="external"
	elif [[ "$builtin_active" == true && "$external_active" == true && "$external_count" -eq 1 ]]; then
		builtin_x="$(jq -r --arg output "$BUILTIN_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		external_x="$(jq -r --arg output "$EXTERNAL_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		if ((external_x > builtin_x)); then
			mode="extend-right"
		elif ((external_x < builtin_x)); then
			mode="extend-left"
		else
			mode="extended"
		fi
	else
		mode="extended"
	fi

	label="$(mode_label "$mode")"
	if [[ "$mode" == "none" ]]; then
		health="error"
		message="No display is active; recovery is required"
	elif [[ -n "$event" && "$event_level" == "warning" && "$requested" == "$mode" ]]; then
		health="warning"
		message="$event"
	elif [[ -n "$event" && "$event_level" == "error" && "$requested" == "$mode" ]]; then
		health="error"
		message="$event"
	elif [[ -z "$EXTERNAL_OUTPUT" ]]; then
		health="idle"
		message="Connect a projector or external display"
	elif [[ "$mode" == "external" ]]; then
		message="Only $EXTERNAL_OUTPUT is on; laptop fallback is ready"
	elif [[ "$mode" == "duplicate" ]]; then
		message="Mirroring on $EXTERNAL_OUTPUT"
	elif [[ -n "$event" ]]; then
		message="$event"
	fi

	outputs="$(jq -c --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | {
		name,
		description: (.description // .name),
		active: ((.disabled // false) == false and (.dpmsStatus // true) == true),
		configured: ((.disabled // false) == false),
		dpmsOn: (.dpmsStatus // true),
		width: (.width // 0),
		height: (.height // 0),
		refreshRate: (.refreshRate // 0),
		scale: (.scale // 1),
		x: (.x // 0),
		y: (.y // 0),
		internal: (.name | test($internal; "i")),
		projector: (
			((.name | test($internal; "i")) | not)
			and ((.name | test($ignored; "i")) | not)
		)
	}]' <<< "$monitors")"

	jq -cn \
		--arg mode "$mode" \
		--arg modeLabel "$label" \
		--arg health "$health" \
		--arg message "$message" \
		--arg builtin "$BUILTIN_OUTPUT" \
		--arg external "$EXTERNAL_OUTPUT" \
		--argjson externalAvailable "$([[ -n "$EXTERNAL_OUTPUT" ]] && printf true || printf false)" \
		--argjson mirrorActive "$mirror_active" \
		--argjson activeCount "$active_count" \
		--argjson externalCount "$external_count" \
		--argjson outputs "$outputs" \
		'{
			ok: true,
			mode: $mode,
			modeLabel: $modeLabel,
			health: $health,
			message: $message,
			builtin: $builtin,
			external: $external,
			externalAvailable: $externalAvailable,
		mirrorActive: $mirrorActive,
		activeCount: $activeCount,
			externalCount: $externalCount,
			outputs: $outputs
		}'
}

emit_apply_error() {
	local action="$1"
	local message="$2"
	local recovered="$3"

	jq -cn \
		--arg action "$action" \
		--arg error "$message" \
		--argjson recovered "$recovered" \
		'{ok: false, result: "error", action: $action, error: $error, recovered: $recovered}'
}

emit_apply_success() {
	local action="$1"
	local result=""

	result="$(status_json)"
	jq -c --arg action "$action" '. + {result: "success", action: $action}' <<< "$result"
}

apply_mode_locked() {
	local mode="$1"
	local monitors=""
	local failure=""
	local applied=false
	local recovered=false

	if ! monitors="$(monitor_json)"; then
		emit_apply_error "$mode" "Hyprland is not reachable" false
		return 1
	fi
	select_outputs "$monitors"

	if [[ -z "$BUILTIN_OUTPUT" ]]; then
		emit_apply_error "$mode" "No laptop display was detected" false
		return 1
	fi
	if [[ "$mode" != "builtin" && -z "$EXTERNAL_OUTPUT" ]]; then
		emit_apply_error "$mode" "No projector or external display is connected" false
		return 1
	fi

	LAST_ERROR=""
	case "$mode" in
		builtin) apply_builtin_only "$monitors" && applied=true ;;
		external) apply_external_only "$monitors" && applied=true ;;
		duplicate) apply_duplicate "$monitors" && applied=true ;;
		extend-right) apply_extended "$monitors" right && applied=true ;;
		extend-left) apply_extended "$monitors" left && applied=true ;;
		*)
			emit_apply_error "$mode" "Unknown projector mode" false
			return 2
			;;
	esac

	if [[ "$applied" == false ]]; then
		failure="$LAST_ERROR"
		[[ -n "$failure" ]] || failure="The display layout did not pass verification"
		if safe_recover "Mode failed; laptop display was restored"; then
			recovered=true
		fi
		emit_apply_error "$mode" "$failure" "$recovered"
		return 1
	fi

	refresh_wallpaper || true
	emit_apply_success "$mode"
}

apply_mode() {
	local mode="$1"
	exec 9> "$operation_lock"
	if ! flock -w 8 9; then
		emit_apply_error "$mode" "Another display change is still running" false
		return 1
	fi
	apply_mode_locked "$mode"
}

recover_if_needed_locked() {
	local monitors=""
	local state=""
	local requested=""
	local remembered_builtin=""
	local remembered_external=""
	local active_count=0
	local builtin_active=false
	local target_active=false

	monitors="$(monitor_json)" || return 0
	select_outputs "$monitors"
	state="$(read_state)"
	requested="$(jq -r '.requestedMode // empty' <<< "$state")"
	remembered_builtin="$(jq -r '.builtin // empty' <<< "$state")"
	remembered_external="$(jq -r '.external // empty' <<< "$state")"
	if output_exists "$monitors" "$remembered_builtin"; then
		BUILTIN_OUTPUT="$remembered_builtin"
	fi
	active_count="$(active_output_count "$monitors")"
	output_is_active "$monitors" "$BUILTIN_OUTPUT" && builtin_active=true
	output_is_active "$monitors" "$remembered_external" && target_active=true

	if ((active_count == 0)); then
		safe_recover "All displays went offline; the laptop panel was restored" || true
		return 0
	fi

	if [[ "$requested" == "external" && "$target_active" == false ]]; then
		if [[ "$builtin_active" == false ]]; then
			safe_recover "Projector disconnected; the laptop panel was restored" || true
		else
			write_state builtin "$BUILTIN_OUTPUT" "" "Projector disconnected; laptop display stayed active" warning
			notify_recovery "Projector disconnected; laptop display stayed active"
		fi
		return 0
	fi

	if [[ "$requested" == "duplicate" ]]; then
		if [[ "$target_active" == false ]]; then
			write_state builtin "$BUILTIN_OUTPUT" "" "Projector disconnected; laptop display stayed active" warning
			refresh_wallpaper || true
			return 0
		fi
		if [[ "$builtin_active" == false ]]; then
			safe_recover "Duplicate source disappeared; the laptop panel was restored" || true
			return 0
		fi
		if ! output_is_mirroring "$monitors" "$remembered_external" "$BUILTIN_OUTPUT"; then
			if ! apply_duplicate "$monitors"; then
				safe_recover "Duplicate layout failed; the laptop panel was restored" || true
			fi
		fi
	fi
}

guard_check() {
	(
		exec 9> "$operation_lock"
		flock -n 9 || exit 0
		recover_if_needed_locked
	)
}

watch_events() {
	local socket=""
	local event=""

	while true; do
		if ! resolve_instance; then
			sleep 1
			continue
		fi
		socket="$hypr_root/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
		if [[ ! -S "$socket" ]]; then
			sleep 1
			continue
		fi

		while IFS= read -r event; do
			case "$event" in
				monitorremoved*|monitoradded*|configreloaded*)
					sleep 0.15
					guard_check
					[[ "$event" == monitoradded* ]] && refresh_wallpaper || true
					;;
			esac
		done < <(socat -U - "UNIX-CONNECT:$socket" 2>/dev/null || true)
		sleep 0.5
	done
}

watch_guard() {
	local event_pid=""

	exec 8> "$guard_lock"
	flock -n 8 || return 0

	watch_events 8>&- &
	event_pid="$!"
	trap '[[ -n ${event_pid:-} ]] && kill "$event_pid" 2>/dev/null || true' EXIT
	trap 'exit 0' INT TERM

	while true; do
		guard_check
		sleep 2
	done
}

usage() {
	printf 'usage: projectorctl status | apply MODE | recover | check | watch\n' >&2
}

main() {
	local command="${1:-status}"

	case "$command" in
		status)
			status_json
			;;
		apply)
			[[ $# -eq 2 ]] || {
				usage
				return 2
			}
			apply_mode "$2"
			;;
		recover)
			exec 9> "$operation_lock"
			flock -w 8 9 || return 1
			if safe_recover "Laptop display restored manually"; then
				status_json
			else
				emit_apply_error recover "Could not restore the laptop display" false
				return 1
			fi
			;;
		check)
			guard_check
			;;
		watch)
			watch_guard
			;;
		*)
			usage
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
