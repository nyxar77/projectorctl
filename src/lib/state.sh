read_state() {
	if [[ -r "$state_file" ]] && jq -e 'type == "object"' "$state_file" >/dev/null 2>&1; then
		jq -c . "$state_file"
	else
		printf '{}\n'
	fi
}

state_field() {
	read_state | jq -r --arg field "$1" '.[$field] // empty'
}

write_state() {
	local mode="$1" builtin="$2" external="$3" event="${4:-}" level="${5:-info}"
	local temporary="$state_file.tmp.$$"
	jq -cn --arg mode "$mode" --arg builtin "$builtin" --arg external "$external" \
		--arg event "$event" --arg level "$level" --argjson updatedAt "$(date +%s)" '
		{
			requestedMode: $mode, builtin: $builtin, external: $external,
			guardExternal: (if $mode == "duplicate" or ($mode | startswith("extend-")) then $external else "" end),
			phase: "committed", targetMode: "", lastEvent: $event, eventLevel: $level, updatedAt: $updatedAt
		}' > "$temporary"
	mv -f "$temporary" "$state_file"
}

write_transition() {
	local target_mode="$1" builtin="$2" external="$3" event="$4"
	local temporary="$state_file.tmp.$$"
	read_state | jq -c --arg targetMode "$target_mode" --arg builtin "$builtin" --arg external "$external" \
		--arg event "$event" --argjson updatedAt "$(date +%s)" '
		. + {builtin: $builtin, external: $external, phase: "applying", targetMode: $targetMode,
			lastEvent: $event, eventLevel: "info", updatedAt: $updatedAt}
	' > "$temporary"
	mv -f "$temporary" "$state_file"
}
