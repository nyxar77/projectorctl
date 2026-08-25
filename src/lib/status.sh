status_json() {
	local monitors="" state="" event="" event_level="" requested="" mode=unknown health=ok message="Display layout is ready"
	local builtin_active=false external_active=false mirror_active=false active_count=0 external_count=0 builtin_x=0 external_x=0 outputs='[]'
	if ! monitors="$(monitor_json)"; then
		jq -cn '{ok:false, mode:"unavailable", modeLabel:"Display service unavailable", health:"error",
			message:"Hyprland is not reachable", externalAvailable:false, activeCount:0, outputs:[]}'
		return 1
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
		mode=none
	elif [[ "$builtin_active" == true && "$external_active" == true && "$mirror_active" == true && "$external_count" -eq 1 ]]; then
		mode=duplicate
	elif [[ "$builtin_active" == true && "$external_count" -eq 0 ]]; then
		mode=builtin
	elif [[ "$builtin_active" == true && "$external_active" == true && "$external_count" -eq 1 ]]; then
		builtin_x="$(jq -r --arg output "$BUILTIN_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		external_x="$(jq -r --arg output "$EXTERNAL_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		if ((external_x > builtin_x)); then mode=extend-right
		elif ((external_x < builtin_x)); then mode=extend-left
		else mode=extended
		fi
	else
		mode=unknown
	fi
	if [[ "$mode" == none || "$mode" == unknown ]]; then
		health=error
		message="Display state is unsafe; restore Private mode"
	elif [[ -n "$event" && "$requested" == "$mode" && "$event_level" == warning ]]; then
		health=warning
		message="$event"
	elif [[ -z "$EXTERNAL_OUTPUT" ]]; then
		health=idle
		message="Private mode; connect a projector to present"
	elif [[ "$mode" == builtin ]]; then
		message="Private mode; external outputs are disabled"
	elif [[ "$mode" == duplicate ]]; then
		message="Presenting on $EXTERNAL_OUTPUT"
	elif [[ -n "$event" ]]; then
		message="$event"
	fi
	outputs="$(jq -c --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | {
		name, description:(.description // .name),
		active:((.disabled // false) == false and (.dpmsStatus // true) == true),
		configured:((.disabled // false) == false), dpmsOn:(.dpmsStatus // true),
		width:(.width // 0), height:(.height // 0), refreshRate:(.refreshRate // 0),
		scale:(.scale // 1), x:(.x // 0), y:(.y // 0), internal:(.name | test($internal; "i")),
		projector:(((.name | test($internal; "i")) | not) and ((.name | test($ignored; "i")) | not))}]' <<< "$monitors")"
	jq -cn --arg mode "$mode" --arg modeLabel "$(mode_label "$mode")" --arg health "$health" --arg message "$message" \
		--arg builtin "$BUILTIN_OUTPUT" --arg external "$EXTERNAL_OUTPUT" \
		--argjson externalAvailable "$([[ -n "$EXTERNAL_OUTPUT" ]] && printf true || printf false)" \
		--argjson mirrorActive "$mirror_active" --argjson activeCount "$active_count" \
		--argjson externalCount "$external_count" --argjson outputs "$outputs" \
		'{ok:true, mode:$mode, modeLabel:$modeLabel, health:$health, message:$message,
			builtin:$builtin, external:$external, externalAvailable:$externalAvailable,
			mirrorActive:$mirrorActive, activeCount:$activeCount, externalCount:$externalCount, outputs:$outputs}'
}
