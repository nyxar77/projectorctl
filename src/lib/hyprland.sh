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
	local target="$1" rules="${2//$'\n'/, }" layout_dir="${1%/*}" temporary="${1}.tmp.$$"
	mkdir -p "$layout_dir"
	printf 'return { %s }\n' "$rules" > "$temporary"
	mv -f "$temporary" "$target"
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
	if ! timeout 8 "$hyprctl_bin" reload >/dev/null 2>&1; then
		LAST_ERROR="Hyprland could not reload the display layout"
		return 1
	fi
}

wait_for_layout() {
	local mode="$1" builtin="$2" external="${3:-}" current="" attempt=0 builtin_x=0 external_x=0
	for ((attempt = 0; attempt < verification_attempts; attempt++)); do
		if current="$(monitor_json "$monitor_probe_timeout")" && output_is_active "$current" "$builtin"; then
			case "$mode" in
				builtin)
					(( $(active_external_count "$current") == 0 )) && return 0
					;;
				duplicate)
					output_is_mirroring "$current" "$external" "$builtin" && \
						(( $(active_external_count "$current") == 1 )) && return 0
					;;
				extend-right|extend-left)
					if output_is_active "$current" "$external" && (( $(active_external_count "$current") == 1 )); then
						builtin_x="$(jq -r --arg output "$builtin" '[.[] | select(.name == $output)][0].x // 0' <<< "$current")"
						external_x="$(jq -r --arg output "$external" '[.[] | select(.name == $output)][0].x // 0' <<< "$current")"
						[[ "$mode" == extend-right && "$external_x" -gt "$builtin_x" ]] && return 0
						[[ "$mode" == extend-left && "$external_x" -lt "$builtin_x" ]] && return 0
					fi
					;;
			esac
		fi
		sleep 0.1
	done
	LAST_ERROR="Hyprland did not apply the requested layout"
	return 1
}
