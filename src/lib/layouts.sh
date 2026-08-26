private_layout_rules() {
	local monitors="$1" builtin="$2"
	compose_layout "$monitors" "$(enable_rule "$monitors" "$builtin" 0x0)"
}

emergency_private_rules() {
	local builtin="$1"
	[[ -n "$builtin" ]] || return 1
	printf '%s\n' "$(deny_unknown_rule)" \
		"{ output = $(lua_quote "$builtin"), mode = \"preferred\", position = \"0x0\", scale = 1, transform = 0, disabled = false, mirror = \"\" }"
}

stage_private_layout() {
	local rules="$1"
	write_private_baseline "$rules" || return 1
	write_layout_file "$layout_file" "$rules" || return 1
	ACTIVE_PRIVATE_RULES="$rules"
}

stage_emergency_private_layout() {
	local builtin="$1" rules=""
	rules="$(emergency_private_rules "$builtin")" || return 1
	stage_private_layout "$rules"
}

layout_rules_for_mode() {
	local monitors="$1" mode="$2" topology="" direction=""
	local builtin_position=0x0 external_position=auto-right
	topology="$(mode_topology "$mode")"
	direction="$(mode_direction "$mode")"
	case "$topology" in
		builtin)
			private_layout_rules "$monitors" "$BUILTIN_OUTPUT"
			;;
		mirror)
			compose_layout "$monitors" \
				"$(enable_rule "$monitors" "$BUILTIN_OUTPUT" 0x0)" "$EXTERNAL_OUTPUT" \
				"$(mirror_rule "$monitors" "$EXTERNAL_OUTPUT" "$BUILTIN_OUTPUT")"
			;;
		extend)
		if [[ "$direction" == left ]]; then
			builtin_position=auto-right
			external_position=0x0
		fi
		compose_layout "$monitors" \
			"$(enable_rule "$monitors" "$BUILTIN_OUTPUT" "$builtin_position")" "$EXTERNAL_OUTPUT" \
			"$(enable_rule "$monitors" "$EXTERNAL_OUTPUT" "$external_position")"
		;;
		*) return 1 ;;
	esac
}

# All supported modes use this transaction. Only their declarative rules,
# verification mode, and state metadata vary.
apply_layout_mode() {
	local mode="$1" monitors="$2" event="${3:-}" level="${4:-info}" rules="" current=""
	rules="$(layout_rules_for_mode "$monitors" "$mode")" || return 1
	[[ "$mode" == builtin ]] && {
		ACTIVE_PRIVATE_RULES="$rules"
		write_private_baseline "$rules" || return 1
	}
	wake_configured_output "$monitors" "$BUILTIN_OUTPUT"
	run_layout "$rules" || return 1
	current="$(monitor_json)" || {
		LAST_ERROR="Hyprland did not report the $(mode_label "$mode") layout"
		return 1
	}
	wake_output "$current" "$BUILTIN_OUTPUT" || return 1
	wait_for_layout "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" || return 1
	refresh_caelestia_screens
	[[ -n "$event" ]] || event="$(mode_event "$mode")" || return 1
	write_state "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "$event" "$level"
}

# Compatibility names intentionally contain no mode-specific behavior.
apply_builtin_only() { apply_layout_mode builtin "$1"; }
apply_duplicate() { apply_layout_mode duplicate "$1"; }
apply_extended() { apply_layout_mode "extend-$2" "$1"; }

recover_private() {
	local reason="$1" monitors="" remembered_builtin="" rules=""
	remembered_builtin="$(state_field builtin)"
	if ! monitors="$(monitor_json)"; then
		[[ -n "$remembered_builtin" ]] && stage_emergency_private_layout "$remembered_builtin" || true
		LAST_ERROR="Hyprland is not reachable during recovery"
		return 1
	fi
	select_outputs "$monitors" || {
		LAST_ERROR="Hyprland reported invalid monitor data during recovery"
		return 1
	}
	if output_exists "$monitors" "$remembered_builtin"; then
		BUILTIN_OUTPUT="$remembered_builtin"
	fi
	[[ -n "$BUILTIN_OUTPUT" ]] || {
		LAST_ERROR="No laptop display was detected"
		return 1
	}
	rules="$(private_layout_rules "$monitors" "$BUILTIN_OUTPUT")" || return 1
	stage_private_layout "$rules" || {
		LAST_ERROR="Could not stage the Private layout"
		return 1
	}
	apply_builtin_only "$monitors" || return 1
	write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "$reason" warning
}

emit_apply_error() {
	jq -cn --arg action "$1" --arg error "$2" --argjson recovered "$3" \
		'{ok: false, result: "error", action: $action, error: $error, recovered: $recovered}'
}

write_verification_snapshot() {
	local mode="$1" builtin="$2" external="$3" temporary="${runtime_root}/last-verification.json.tmp.${BASHPID}"
	[[ -n "$LAST_MONITOR_SNAPSHOT" ]] || return 0
	jq -cn \
		--arg mode "$mode" \
		--arg builtin "$builtin" \
		--arg external "$external" \
		--argjson monitors "$LAST_MONITOR_SNAPSHOT" \
		'{requestedMode: $mode, builtin: $builtin, external: $external, monitors: $monitors}' \
		> "$temporary" || return 1
	mv -f "$temporary" "${runtime_root}/last-verification.json" || return 1
}

emit_apply_success() {
	local action="$1" result=""
	if result="$(status_json "${VERIFIED_MONITORS:-}")" && \
		[[ "$(jq -r '.mode' <<< "$result")" == "$action" ]] && \
		[[ "$(jq -r '.health' <<< "$result")" != error ]]; then
		jq -c --arg action "$action" '. + {result: "success", action: $action}' <<< "$result"
		return 0
	fi
	emit_apply_error "$action" "The final display state did not match the requested layout" false
	return 1
}

abort_active_transition() {
	local signal="$1" exit_code=128 current=""
	trap - INT TERM HUP
	case "$signal" in
		HUP) exit_code=129 ;;
		INT) exit_code=130 ;;
		TERM) exit_code=143 ;;
	esac
	if [[ -n "$ACTIVE_PRIVATE_RULES" ]]; then
		stage_private_layout "$ACTIVE_PRIVATE_RULES" || true
		if run_layout "$ACTIVE_PRIVATE_RULES" && current="$(monitor_json)"; then
			wake_output "$current" "$BUILTIN_OUTPUT" || true
			if wait_for_layout builtin "$BUILTIN_OUTPUT"; then
				write_state builtin "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" \
					"Display transaction was interrupted; Private mode was restored" warning || true
			fi
		fi
	fi
	printf 'projectorctl: display transaction interrupted by %s; Private recovery attempted\n' "$signal" >&2
	exit "$exit_code"
}

apply_mode_locked() {
	local mode="$1" monitors="" failure="" recovered=false private_rules="" applied=false
	if mode_is_legacy "$mode"; then
			emit_apply_error "$mode" "Projector-only was removed because it relocates workspaces; use Present / mirror" false
			return 2
	fi
	if ! mode_is_action "$mode"; then
			emit_apply_error "$mode" "Unknown projector mode" false
			return 2
	fi
	monitors="$(monitor_json)" || {
		emit_apply_error "$mode" "Hyprland is not reachable or returned invalid monitor data" false
		return 1
	}
	select_outputs "$monitors" || {
		emit_apply_error "$mode" "Hyprland returned invalid monitor data" false
		return 1
	}
	[[ -n "$BUILTIN_OUTPUT" ]] || {
		emit_apply_error "$mode" "No laptop display was detected" false
		return 1
	}
	if mode_requires_external "$mode" && [[ -z "$EXTERNAL_OUTPUT" ]]; then
		emit_apply_error "$mode" "No projector or external display is connected" false
		return 1
	fi
	private_rules="$(private_layout_rules "$monitors" "$BUILTIN_OUTPUT")" || {
		emit_apply_error "$mode" "Could not build the Private fallback layout" false
		return 1
	}
	ACTIVE_PRIVATE_RULES="$private_rules"
	write_private_baseline "$private_rules" || {
		emit_apply_error "$mode" "Could not record the Private fallback layout" false
		return 1
	}
	# Keep the on-disk session overlay private until the target is actually sent
	# to Hyprland. A crash before that point cannot revive an old presentation on
	# a later compositor reload.
	write_layout_file "$layout_file" "$private_rules" || {
		emit_apply_error "$mode" "Could not stage the Private fallback layout" false
		return 1
	}
	write_transition "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" "Switching to $(mode_label "$mode")" || {
		emit_apply_error "$mode" "Could not record the display transaction" false
		return 1
	}
	LAST_ERROR=""
	VERIFIED_MONITORS=""
	apply_layout_mode "$mode" "$monitors" && applied=true
	if [[ "$applied" == true ]]; then
		if emit_apply_success "$mode"; then
			return 0
		fi
		LAST_ERROR="The final display state did not match the requested layout"
	fi
	failure="${LAST_ERROR:-The display layout did not pass verification}"
	write_verification_snapshot "$mode" "$BUILTIN_OUTPUT" "$EXTERNAL_OUTPUT" || true
	stage_private_layout "$private_rules" || true
	if recover_private "Layout failed; private laptop display was restored"; then
		recovered=true
	fi
	emit_apply_error "$mode" "$failure" "$recovered"
	return 1
}

apply_mode() {
	local mode="$1" result=0
	exec 9> "$operation_lock"
	if ! flock -w 3 9; then
		exec 9>&-
		emit_apply_error "$mode" "Another display change is still running" false
		return 1
	fi
	trap 'abort_active_transition INT' INT
	trap 'abort_active_transition TERM' TERM
	trap 'abort_active_transition HUP' HUP
	apply_mode_locked "$mode" || result=$?
	trap - INT TERM HUP
	flock -u 9
	exec 9>&-
	if ((result == 0)); then
		refresh_wallpaper >/dev/null 2>&1 &
	fi
	return "$result"
}

establish_private_baseline() {
	recover_private "Private baseline established"
}

manual_recover() {
	local result=0 response="" reason="Private laptop display restored manually"
	exec 9> "$operation_lock"
	if ! flock -w 3 9; then
		exec 9>&-
		emit_apply_error recover "Another display change is still running" false
		return 1
	fi
	if establish_private_baseline; then
		response="$(status_json "${VERIFIED_MONITORS:-}")" || response="$(jq -cn '{ok:true, mode:"builtin", modeLabel:"Private / laptop only", health:"warning", message:"Private recovery completed; final status unavailable", outputs:[]}')"
	else
		response="$(emit_apply_error recover "${LAST_ERROR:-Could not restore the laptop display}" false)"
		result=1
	fi
	flock -u 9
	exec 9>&-
	if ((result == 0)); then
		refresh_wallpaper >/dev/null 2>&1 &
		notify_recovery "$reason" >/dev/null 2>&1 &
	fi
	printf '%s\n' "$response"
	return "$result"
}
