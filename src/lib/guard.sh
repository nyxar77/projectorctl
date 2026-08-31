guard_mode_is_armed() {
	case "$1" in
		duplicate|extend-right|extend-left) return 0 ;;
		*) return 1 ;;
	esac
}

queue_guard_check() {
	local removed_output="${1:-*}" existing="" temporary="$pending_guard_file.tmp.${BASHPID}"
	if [[ -r "$pending_guard_file" ]] && read -r existing < "$pending_guard_file"; then
		[[ -n "$existing" && "$existing" != "*" ]] && return 0
	fi
	printf '%s\n' "$removed_output" > "$temporary" || return 1
	mv -f "$temporary" "$pending_guard_file" || {
		rm -f "$temporary"
		return 1
	}
}

take_pending_guard() {
	local processing="$pending_guard_file.processing.${BASHPID}" removed_output=""
	[[ -e "$pending_guard_file" ]] || return 1
	mv "$pending_guard_file" "$processing" 2>/dev/null || return 1
	read -r removed_output < "$processing" || removed_output="*"
	rm -f "$processing"
	[[ "$removed_output" == "*" ]] && removed_output=""
	printf '%s\n' "$removed_output"
}

recover_with_notice() {
	local reason="$1"
	recover_private "$reason" || return 1
	RECOVERY_NOTICE="$reason"
}

recover_if_needed_locked() {
	local removed_output="${1:-}" state="" requested="" phase="" guarded="" remembered_builtin="" monitors=""
	state="$(read_state)"
	if ! state_is_current "$state"; then
		# A new graphical session has no runtime state or session overlay. The
		# persistent Private rules already own that case, so the guard stays
		# disarmed instead of reloading Hyprland during startup.
		if [[ -e "$state_file" || -e "$layout_file" ]]; then
			recover_with_notice "Display state was incompatible; Private mode was restored"
		fi
		return
	fi
	requested="$(jq -r '.requestedMode' <<< "$state")"
	phase="$(jq -r '.phase' <<< "$state")"
	guarded="$(jq -r '.guardExternal // .external' <<< "$state")"
	remembered_builtin="$(jq -r '.builtin' <<< "$state")"
	if [[ "$phase" != committed ]]; then
		recover_with_notice "An interrupted display change was reset to Private mode"
		return
	fi
	# `external` is a legacy projector-only mode. It is never preserved after an upgrade.
	if [[ "$requested" == external ]]; then
		recover_with_notice "Legacy projector-only state was reset to Private mode"
		return
	fi
	guard_mode_is_armed "$requested" || return 0
	if [[ -n "$removed_output" && "$removed_output" == "$guarded" ]] || drm_connector_is_disconnected "$guarded"; then
		recover_with_notice "Projector disconnected; Private mode was restored"
		return
	fi
	monitors="$(monitor_json)" || return 1
	select_outputs "$monitors" || return 1
	if output_exists "$monitors" "$remembered_builtin"; then
		BUILTIN_OUTPUT="$remembered_builtin"
	fi
	if ! layout_configuration_matches "$monitors" "$requested" "$BUILTIN_OUTPUT" "$guarded"; then
		recover_with_notice "A presentation output failed or changed; Private mode was restored"
	fi
}

guard_check() {
	local removed_output="${1:-}" pending_output="" result=0
	(
		exec 9> "$operation_lock"
		if ! flock -w 3 9; then
			queue_guard_check "$removed_output"
			exit 1
		fi
		if pending_output="$(take_pending_guard)"; then
			[[ -n "$pending_output" ]] && removed_output="$pending_output"
		fi
		RECOVERY_NOTICE=""
		recover_if_needed_locked "$removed_output" || result=$?
		if ((result != 0)); then
			queue_guard_check "$removed_output"
		fi
		flock -u 9
		exec 9>&-
		if [[ -n "$RECOVERY_NOTICE" ]]; then
			refresh_wallpaper >/dev/null 2>&1 &
			notify_recovery "$RECOVERY_NOTICE" >/dev/null 2>&1 &
		fi
		exit "$result"
	)
}

removed_output_from_event() {
	local event="$1" payload="${1#*>>}"
	if [[ "$event" == monitorremovedv2* ]]; then
		payload="${payload#*,}"
		payload="${payload%%,*}"
	fi
	printf '%s\n' "$payload"
}

emit_guard_event() {
	printf '%s\n' "$1" > "$guard_event_fifo"
}

watch_events() {
	local socket="" event="" removed_output=""
	while true; do
		if ! resolve_instance; then sleep 1; continue; fi
		socket="$hypr_root/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
		if [[ ! -S "$socket" ]]; then sleep 1; continue; fi
		while IFS= read -r event; do
			case "$event" in
				monitorremoved*) removed_output="$(removed_output_from_event "$event")"; emit_guard_event "removed:$removed_output" ;;
				monitoradded*|configreloaded*) emit_guard_event check ;;
			esac
		done < <(socat -U - "UNIX-CONNECT:$socket" 2>/dev/null || true)
		sleep 0.5
	done
}

watch_drm_events() {
	local event=""
	while true; do
		while IFS= read -r event; do
			[[ "$event" == KERNEL* ]] && emit_guard_event check
		done < <("$udevadm_bin" monitor --kernel --subsystem-match=drm 2>/dev/null || true)
		sleep 1
	done
}

watch_guard() {
	local hypr_event_pid="" drm_event_pid="" event="" removed_output="" next_poll=0 read_timeout="$watcher_health_interval"
	exec 8> "$guard_lock"
	flock -n 8 || return 0
	if [[ -e "$guard_event_fifo" && ! -p "$guard_event_fifo" ]]; then
		printf 'projectorctl: guard event path is not a FIFO\n' >&2
		return 1
	fi
	[[ -p "$guard_event_fifo" ]] || mkfifo -m 600 "$guard_event_fifo"
	exec 7<> "$guard_event_fifo"

	watch_events 8>&- & hypr_event_pid=$!
	watch_drm_events 8>&- & drm_event_pid=$!
	trap 'kill "${hypr_event_pid:-}" "${drm_event_pid:-}" 2>/dev/null || true; wait "${hypr_event_pid:-}" "${drm_event_pid:-}" 2>/dev/null || true' EXIT
	trap 'exit 0' INT TERM
	if guard_check; then
		next_poll=$((SECONDS + guard_poll_interval))
	else
		queue_guard_check
		next_poll=$((SECONDS + guard_retry_interval))
	fi
	while true; do
		event=""; removed_output=""; read_timeout="$watcher_health_interval"
		[[ -e "$pending_guard_file" ]] && read_timeout="$guard_retry_interval"
		IFS= read -r -t "$read_timeout" event <&7 || true
		[[ "$event" == removed:* ]] && removed_output="${event#removed:}"
		if [[ -n "$event" || -e "$pending_guard_file" || $SECONDS -ge $next_poll ]]; then
			if guard_check "$removed_output"; then
				next_poll=$((SECONDS + guard_poll_interval))
			else
				next_poll=$((SECONDS + guard_retry_interval))
			fi
		fi
		if ! kill -0 "$hypr_event_pid" 2>/dev/null; then wait "$hypr_event_pid" 2>/dev/null || true; watch_events 8>&- & hypr_event_pid=$!; fi
		if ! kill -0 "$drm_event_pid" 2>/dev/null; then wait "$drm_event_pid" 2>/dev/null || true; watch_drm_events 8>&- & drm_event_pid=$!; fi
	done
}
