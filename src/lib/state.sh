read_state() {
	if [[ -r "$state_file" ]] && jq -e 'type == "object"' "$state_file" >/dev/null 2>&1; then
		jq -c . "$state_file"
	else
		printf '{"version":0,"phase":"invalid"}\n'
	fi
}

state_is_current() {
	jq -e '
		.version == 2
		and (.phase == "committed" or .phase == "applying")
		and (.requestedMode | type == "string")
		and (.targetMode | type == "string")
		and (.builtin | type == "string")
		and (.external | type == "string")
		and (.guardExternal | type == "string")
	' <<< "$1" >/dev/null
}

state_field() {
	read_state | jq -r --arg field "$1" '.[$field] // empty'
}

write_json_atomically() {
	local target="$1" payload="$2" temporary="${1}.tmp.${BASHPID}"
	printf '%s\n' "$payload" > "$temporary" || {
		rm -f "$temporary"
		return 1
	}
	jq -e 'type == "object"' "$temporary" >/dev/null 2>&1 || {
		rm -f "$temporary"
		return 1
	}
	mv -f "$temporary" "$target" || {
		rm -f "$temporary"
		return 1
	}
}

write_state() {
	local mode="$1" builtin="$2" external="$3" event="${4:-}" level="${5:-info}" payload=""
	payload="$(jq -cn --arg mode "$mode" --arg builtin "$builtin" --arg external "$external" \
		--arg event "$event" --arg level "$level" --argjson updatedAt "$(date +%s)" '
		{
			version: 2,
			requestedMode: $mode, builtin: $builtin, external: $external,
			guardExternal: (if $mode == "duplicate" or ($mode | startswith("extend-")) then $external else "" end),
			phase: "committed", targetMode: "", lastEvent: $event, eventLevel: $level, updatedAt: $updatedAt
		}')" || return 1
	write_json_atomically "$state_file" "$payload"
}

write_transition() {
	local target_mode="$1" builtin="$2" external="$3" event="$4" payload=""
	payload="$(jq -cn --arg targetMode "$target_mode" --arg builtin "$builtin" --arg external "$external" \
		--arg event "$event" --argjson updatedAt "$(date +%s)" '
		{version: 2, requestedMode: $targetMode, builtin: $builtin, external: $external,
			guardExternal: $external, phase: "applying", targetMode: $targetMode,
			lastEvent: $event, eventLevel: "info", updatedAt: $updatedAt}
		')" || return 1
	write_json_atomically "$state_file" "$payload"
}
