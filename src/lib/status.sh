status_json() {
	local monitors="" state="" event="" event_level="" requested="" phase="" mode=unknown observed_mode=unknown
	local health=ok message="Display layout is ready" state_current=false state_mismatch=false
	local builtin_active=false external_active=false mirror_active=false active_count=0 external_count=0 builtin_x=0 external_x=0 outputs='[]'
	if [[ -n "${1:-}" ]]; then
		monitors="$1"
		monitor_snapshot_is_valid "$monitors" || {
			jq -cn '{ok:false, mode:"unavailable", modeLabel:"Display service unavailable", health:"error", message:"Hyprland returned invalid monitor data", externalAvailable:false, activeCount:0, outputs:[]}'
			return 1
		}
	elif ! monitors="$(monitor_json)"; then
		jq -cn '{ok:false, mode:"unavailable", modeLabel:"Display service unavailable", health:"error",
			message:"Hyprland is not reachable", externalAvailable:false, activeCount:0, outputs:[]}'
		return 1
	fi
	select_outputs "$monitors" || {
		jq -cn '{ok:false, mode:"unavailable", modeLabel:"Display service unavailable", health:"error", message:"Hyprland returned invalid monitor data", externalAvailable:false, activeCount:0, outputs:[]}'
		return 1
	}
	state="$(read_state)"
	requested="$(jq -r '.requestedMode // empty' <<< "$state")"
	phase="$(jq -r '.phase // empty' <<< "$state")"
	event="$(jq -r '.lastEvent // empty' <<< "$state")"
	event_level="$(jq -r '.eventLevel // empty' <<< "$state")"
	state_is_current "$state" && state_current=true
	output_is_active "$monitors" "$BUILTIN_OUTPUT" && builtin_active=true
	output_is_active "$monitors" "$EXTERNAL_OUTPUT" && external_active=true
	output_is_mirroring "$monitors" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT" && mirror_active=true
	active_count="$(active_output_count "$monitors")"
	external_count="$(active_external_count "$monitors")"
	if ((active_count == 0)); then
		mode=none
	elif [[ "$builtin_active" == true && "$external_active" == true && "$mirror_active" == true && \
		"$active_count" -eq 2 && "$external_count" -eq 1 ]]; then
		mode=duplicate
	elif [[ "$builtin_active" == true && "$active_count" -eq 1 && "$external_count" -eq 0 ]]; then
		mode=builtin
	elif [[ "$builtin_active" == true && "$external_active" == true && \
		"$active_count" -eq 2 && "$external_count" -eq 1 ]]; then
		builtin_x="$(jq -r --arg output "$BUILTIN_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		external_x="$(jq -r --arg output "$EXTERNAL_OUTPUT" '[.[] | select(.name == $output)][0].x // 0' <<< "$monitors")"
		if ((external_x > builtin_x)); then mode=extend-right
		elif ((external_x < builtin_x)); then mode=extend-left
		else mode=extended
		fi
	else
		mode=unknown
	fi
	observed_mode="$mode"
	if [[ "$requested" == external ]]; then
		mode=unknown
		health=error
		message="Legacy projector-only state is unsafe; restore Private mode"
	elif [[ "$state_current" == true && "$phase" != committed ]]; then
		mode=unknown
		health=error
		message="A display change was interrupted; restore Private mode"
	elif [[ "$state_current" == true ]]; then
		mode_is_action "$requested" || state_mismatch=true
		[[ "$requested" == "$observed_mode" ]] || state_mismatch=true
		if [[ "$state_mismatch" == true ]]; then
			mode=unknown
			health=error
			message="Recorded $(mode_label "$requested") but observed $(mode_label "$observed_mode"); restore Private mode"
		fi
	fi
	if [[ "$health" != error ]]; then
		if [[ "$observed_mode" == none || "$observed_mode" == unknown ]]; then
			health=error
			message="Display state is unsafe; restore Private mode"
		elif [[ "$state_current" != true ]]; then
			if [[ "$observed_mode" == builtin ]]; then
				health=idle
				message="Private mode; presentation guard is disarmed"
			else
				mode=unknown
				health=error
				message="Untracked display layout; restore Private mode"
			fi
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
	fi
	outputs="$(jq -c --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | {
		name, description:(.description // .name),
		active:((.disabled // false) == false and (.dpmsStatus // true) == true),
		configured:((.disabled // false) == false), dpmsOn:(.dpmsStatus // true),
		width:(.width // 0), height:(.height // 0), refreshRate:(.refreshRate // 0),
		scale:(.scale // 1), x:(.x // 0), y:(.y // 0), internal:(.name | test($internal; "i")),
		projector:(((.name | test($internal; "i")) | not) and ((.name | test($ignored; "i")) | not))}]' <<< "$monitors")"
	jq -cn --arg mode "$mode" --arg modeLabel "$(mode_label "$mode")" --arg observedMode "$observed_mode" \
		--arg health "$health" --arg message "$message" \
		--arg builtin "$BUILTIN_OUTPUT" --arg external "$EXTERNAL_OUTPUT" \
		--argjson externalAvailable "$([[ -n "$EXTERNAL_OUTPUT" ]] && printf true || printf false)" \
		--argjson mirrorActive "$mirror_active" --argjson activeCount "$active_count" \
		--argjson externalCount "$external_count" --argjson outputs "$outputs" \
		'{ok:($health != "error"), mode:$mode, modeLabel:$modeLabel, observedMode:$observedMode,
			health:$health, message:$message,
			builtin:$builtin, external:$external, externalAvailable:$externalAvailable,
			mirrorActive:$mirrorActive, activeCount:$activeCount, externalCount:$externalCount, outputs:$outputs}'
	[[ "$health" != error ]]
}
