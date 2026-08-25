mode_label() {
	case "$1" in
		builtin) printf 'Private / laptop only' ;;
		duplicate) printf 'Present / mirror' ;;
		extend-right) printf 'Extend right' ;;
		extend-left) printf 'Extend left' ;;
		extended) printf 'Extended desktop' ;;
		none) printf 'No active display' ;;
		*) printf 'Unknown layout' ;;
	esac
}

apply_builtin_only() {
	local monitors="$1" rules=""
	rules="$(compose_layout "$monitors" "$(enable_rule "$monitors" "$BUILTIN_OUTPUT" 0x0)")"
	# This persistent baseline is loaded before the session-only layout. A stale
	# presentation can therefore never resume after a reboot or new login.
	write_private_baseline "$rules" || return 1
	run_layout "$rules" || return 1
	wait_for_layout builtin "$BUILTIN_OUTPUT" || return 1
	write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "External outputs are private and disabled" info
}

apply_duplicate() {
	local monitors="$1" rules=""
	rules="$(compose_layout "$monitors" \
		"$(enable_rule "$monitors" "$BUILTIN_OUTPUT" 0x0)" "$EXTERNAL_OUTPUT" \
		"$(mirror_rule "$monitors" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT")")"
	run_layout "$rules" || return 1
	wait_for_layout duplicate "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" || return 1
	write_state duplicate "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Presenting on $EXTERNAL_OUTPUT" info
}

apply_extended() {
	local monitors="$1" direction="$2" mode="extend-$2" builtin_position=0x0 external_position=auto-right rules=""
	if [[ "$direction" == left ]]; then
		builtin_position=auto-right
		external_position=0x0
	fi
	rules="$(compose_layout "$monitors" \
		"$(enable_rule "$monitors" "$BUILTIN_OUTPUT" "$builtin_position")" "$EXTERNAL_OUTPUT" \
		"$(enable_rule "$monitors" "$EXTERNAL_OUTPUT" "$external_position")")"
	run_layout "$rules" || return 1
	wait_for_layout "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" || return 1
	write_state "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Projector is on the $direction" info
}

recover_private() {
	local reason="$1" monitors="" remembered_builtin=""
	monitors="$(monitor_json)" || {
		LAST_ERROR="Hyprland is not reachable during recovery"
		return 1
	}
	remembered_builtin="$(state_field builtin)"
	select_outputs "$monitors"
	if output_exists "$monitors" "$remembered_builtin"; then
		BUILTIN_OUTPUT="$remembered_builtin"
	fi
	[[ -n "$BUILTIN_OUTPUT" ]] || {
		LAST_ERROR="No laptop display was detected"
		return 1
	}
	apply_builtin_only "$monitors" || return 1
	write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "$reason" warning
}

emit_apply_error() {
	jq -cn --arg action "$1" --arg error "$2" --argjson recovered "$3" \
		'{ok: false, result: "error", action: $action, error: $error, recovered: $recovered}'
}

emit_apply_success() {
	local action="$1" result=""
	if result="$(status_json)"; then
		jq -c --arg action "$action" '. + {result: "success", action: $action}' <<< "$result"
	else
		jq -cn --arg action "$action" --arg modeLabel "$(mode_label "$action")" \
			'{ok: true, result: "success", action: $action, mode: $action, modeLabel: $modeLabel,
				health: "warning", message: "Layout applied; final status was unavailable", outputs: []}'
	fi
}

apply_mode_locked() {
	local mode="$1" monitors="" failure="" recovered=false
	case "$mode" in
		builtin|duplicate|extend-right|extend-left) ;;
		external)
			emit_apply_error "$mode" "Projector-only was removed because it relocates workspaces; use Present / mirror" false
			return 2
			;;
		*)
			emit_apply_error "$mode" "Unknown projector mode" false
			return 2
			;;
	esac
	monitors="$(monitor_json)" || {
		emit_apply_error "$mode" "Hyprland is not reachable" false
		return 1
	}
	select_outputs "$monitors"
	[[ -n "$BUILTIN_OUTPUT" ]] || {
		emit_apply_error "$mode" "No laptop display was detected" false
		return 1
	}
	if [[ "$mode" != builtin && -z "$EXTERNAL_OUTPUT" ]]; then
		emit_apply_error "$mode" "No projector or external display is connected" false
		return 1
	fi
	write_transition "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Switching to $(mode_label "$mode")" || {
		emit_apply_error "$mode" "Could not record the display transaction" false
		return 1
	}
	LAST_ERROR=""
	case "$mode" in
		builtin) apply_builtin_only "$monitors" ;;
		duplicate) apply_duplicate "$monitors" ;;
		extend-right) apply_extended "$monitors" right ;;
		extend-left) apply_extended "$monitors" left ;;
	esac && {
		emit_apply_success "$mode"
		return 0
	}
	failure="${LAST_ERROR:-The display layout did not pass verification}"
	if recover_private "Layout failed; private laptop display was restored"; then
		recovered=true
	fi
	emit_apply_error "$mode" "$failure" "$recovered"
	return 1
}

apply_mode() {
	local mode="$1" result=0
	exec 9> "$operation_lock"
	if ! flock -w 8 9; then
		emit_apply_error "$mode" "Another display change is still running" false
		return 1
	fi
	apply_mode_locked "$mode" || result=$?
	flock -u 9
	((result != 0)) || refresh_wallpaper || true
	return "$result"
}

manual_recover() {
	local result=0 response="" reason="Private laptop display restored manually"
	exec 9> "$operation_lock"
	if ! flock -w 8 9; then
		emit_apply_error recover "Another display change is still running" false
		return 1
	fi
	if recover_private "$reason"; then
		response="$(status_json)" || response="$(jq -cn '{ok:true, mode:"builtin", modeLabel:"Private / laptop only",
			health:"warning", message:"Private recovery completed; final status unavailable", outputs:[]}')"
	else
		response="$(emit_apply_error recover "${LAST_ERROR:-Could not restore the laptop display}" false)"
		result=1
	fi
	flock -u 9
	if ((result == 0)); then
		refresh_wallpaper || true
		notify_recovery "$reason"
	fi
	printf '%s\n' "$response"
	return "$result"
}
