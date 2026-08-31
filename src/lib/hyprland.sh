lua_quote() {
	jq -Rn --arg value "$1" '$value'
}

monitor_scale() {
	jq -r --arg output "$2" '([.[] | select(.name == $output)][0].scale // 1) as $value |
		if ($value | type) == "number" and $value > 0 then $value else 1 end' <<< "$1"
}

monitor_transform() {
	jq -r --arg output "$2" '([.[] | select(.name == $output)][0].transform // 0) as $value |
		if ($value | type) == "number" then $value else 0 end' <<< "$1"
}

enable_rule() {
	local monitors="$1" output="$2" position="$3"
	printf '{ output = %s, mode = "preferred", position = %s, scale = %s, transform = %s, disabled = false, mirror = "" }' \
		"$(lua_quote "$output")" "$(lua_quote "$position")" \
		"$(monitor_scale "$monitors" "$output")" "$(monitor_transform "$monitors" "$output")"
}

mirror_rule() {
	local monitors="$1" output="$2" source="$3"
	printf '{ output = %s, mode = "preferred", scale = %s, transform = %s, disabled = false, mirror = %s }' \
		"$(lua_quote "$output")" "$(monitor_scale "$monitors" "$output")" \
		"$(monitor_transform "$monitors" "$output")" "$(lua_quote "$source")"
}

disable_rule() {
	printf '{ output = %s, disabled = true }' "$(lua_quote "$1")"
}

deny_unknown_rule() {
	printf '{ output = "", disabled = true }'
}

compose_layout() {
	local monitors="$1" builtin_rule="$2" selected_external="${3:-}" selected_rule="${4:-}"
	local output=""
	printf '%s\n' "$(deny_unknown_rule)" "$builtin_rule"
	[[ -z "$selected_rule" ]] || printf '%s\n' "$selected_rule"
	while IFS= read -r output; do
		[[ "$output" == "$BUILTIN_OUTPUT" || "$output" == "$selected_external" ]] && continue
		printf '%s\n' "$(disable_rule "$output")"
	done < <(jq -r '.[].name' <<< "$monitors")
}

write_layout_file() {
	local target="$1" rules="${2//$'\n'/, }" layout_dir="${1%/*}" temporary="${1}.tmp.${BASHPID}"
	[[ -n "$rules" && -n "$layout_dir" ]] || return 1
	mkdir -p "$layout_dir" || return 1
	printf 'return { %s }\n' "$rules" > "$temporary" || {
		rm -f "$temporary"
		return 1
	}
	mv -f "$temporary" "$target" || {
		rm -f "$temporary"
		return 1
	}
}

write_private_baseline() {
	write_layout_file "$private_layout_file" "$1"
}

run_layout() {
	write_layout_file "$layout_file" "$1"
	resolve_instance || {
		LAST_ERROR="Hyprland is not reachable"
		return 1
	}
	if ! run_bounded 4 "$hyprctl_bin" reload >/dev/null 2>&1; then
		LAST_ERROR="Hyprland could not reload the display layout"
		return 1
	fi
}

run_lua() {
	local script="$1" output=""
	resolve_instance || {
		LAST_ERROR="Hyprland is not reachable"
		return 1
	}
	if ! output="$(run_bounded 2 "$hyprctl_bin" eval "$script" 2>&1)"; then
		LAST_ERROR="${output//$'\n'/ }"
		[[ -n "$LAST_ERROR" ]] || LAST_ERROR="Hyprland rejected the display command"
		return 1
	fi
	if [[ "$output" == error:* ]]; then
		LAST_ERROR="${output//$'\n'/ }"
		return 1
	fi
}

wake_output() {
	local monitors="$1" output="$2" script=""
	output_exists "$monitors" "$output" || {
		LAST_ERROR="$output is no longer available"
		return 1
	}
	output_is_active "$monitors" "$output" && return 0
	printf -v script 'hl.dispatch(hl.dsp.dpms({ action = %s, monitor = %s }))' \
		"$(lua_quote enable)" "$(lua_quote "$output")"
	run_lua "$script"
}

wake_configured_output() {
	local monitors="$1" output="$2"
	jq -e --arg output "$output" 'any(.[]; .name == $output and .disabled == false and .dpmsStatus == false)' \
		<<< "$monitors" >/dev/null || return 0
	wake_output "$monitors" "$output" || true
}

layout_matches() {
	local monitors="$1" mode="$2" topology="" direction=""
	local builtin="$3" external="${4:-}" builtin_x=0 external_x=0
	topology="$(mode_topology "$mode")"
	direction="$(mode_direction "$mode")"
	output_is_active "$monitors" "$builtin" || return 1
	case "$topology" in
		builtin)
			(( $(active_output_count "$monitors") == 1 )) && \
				(( $(active_external_count "$monitors") == 0 ))
			;;
		mirror)
			output_is_mirroring "$monitors" "$external" "$builtin" && \
				(( $(active_output_count "$monitors") == 2 )) && \
				(( $(active_external_count "$monitors") == 1 ))
			;;
		extend)
			output_is_active "$monitors" "$external" || return 1
			(( $(active_output_count "$monitors") == 2 )) || return 1
			(( $(active_external_count "$monitors") == 1 )) || return 1
			output_is_mirroring "$monitors" "$external" "$builtin" && return 1
			builtin_x="$(jq -r --arg output "$builtin" '[.[] | select(.name == $output)][0].x' <<< "$monitors")" || return 1
			external_x="$(jq -r --arg output "$external" '[.[] | select(.name == $output)][0].x' <<< "$monitors")" || return 1
			[[ "$direction" == right && "$external_x" -gt "$builtin_x" ]] || \
				[[ "$direction" == left && "$external_x" -lt "$builtin_x" ]]
			;;
		*) return 1 ;;
	esac
}

layout_configuration_matches() {
	local monitors="$1" mode="$2" topology="" direction=""
	local builtin="$3" external="${4:-}" builtin_x=0 external_x=0
	topology="$(mode_topology "$mode")"
	direction="$(mode_direction "$mode")"
	output_is_configured "$monitors" "$builtin" || return 1
	case "$topology" in
		builtin)
			(( $(configured_output_count "$monitors") == 1 )) && \
				(( $(configured_external_count "$monitors") == 0 ))
			;;
		mirror)
			output_is_configured_mirroring "$monitors" "$external" "$builtin" && \
				(( $(configured_output_count "$monitors") == 2 )) && \
				(( $(configured_external_count "$monitors") == 1 ))
			;;
		extend)
			output_is_configured "$monitors" "$external" || return 1
			(( $(configured_output_count "$monitors") == 2 )) || return 1
			(( $(configured_external_count "$monitors") == 1 )) || return 1
			output_is_configured_mirroring "$monitors" "$external" "$builtin" && return 1
			builtin_x="$(jq -r --arg output "$builtin" '[.[] | select(.name == $output)][0].x' <<< "$monitors")" || return 1
			external_x="$(jq -r --arg output "$external" '[.[] | select(.name == $output)][0].x' <<< "$monitors")" || return 1
			[[ "$direction" == right && "$external_x" -gt "$builtin_x" ]] || \
				[[ "$direction" == left && "$external_x" -lt "$builtin_x" ]]
			;;
		*) return 1 ;;
	esac
}

epoch_microseconds() {
	local value="${1:-$EPOCHREALTIME}"
	value="${value//[.,]/}"
	[[ "$value" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
}

wait_for_layout() {
	local mode="$1" builtin="$2" external="${3:-}" current="" deadline=0 now=0
	now="$(epoch_microseconds)" || {
		LAST_ERROR="Could not read the monotonic layout-verification clock"
		return 1
	}
	deadline=$((10#$now + verification_timeout * 1000000))
	LAST_MONITOR_SNAPSHOT=""
	while true; do
		now="$(epoch_microseconds)" || {
			LAST_ERROR="Could not read the monotonic layout-verification clock"
			return 1
		}
		((10#$now < deadline)) || break
		if current="$(monitor_json "$monitor_probe_timeout")"; then
			LAST_MONITOR_SNAPSHOT="$current"
		fi
		if [[ -n "$LAST_MONITOR_SNAPSHOT" ]] && layout_matches "$LAST_MONITOR_SNAPSHOT" "$mode" "$builtin" "$external"; then
			VERIFIED_MONITORS="$LAST_MONITOR_SNAPSHOT"
			return 0
		fi
		sleep "$verification_retry_interval"
	done
	LAST_ERROR="Hyprland did not apply the requested layout within ${verification_timeout}s"
	return 1
}
