guard_mode_is_armed() {
	case "$1" in duplicate|extend-right|extend-left) return 0 ;; *) return 1 ;; esac
}

recover_if_needed_locked() {
	local removed_output="${1:-}" state="" requested="" phase="" guarded="" monitors="" active_monitors=""
	state="$(read_state)"
	requested="$(jq -r '.requestedMode // empty' <<< "$state")"
	phase="$(jq -r '.phase // "committed"' <<< "$state")"
	if [[ "$phase" != committed ]]; then
		recover_private "An interrupted display change was reset to Private mode" || return 1
		RECOVERY_NOTICE="An interrupted display change was reset to Private mode"
		return 0
	fi
	guard_mode_is_armed "$requested" || return 0
	guarded="$(jq -r '.guardExternal // .external // empty' <<< "$state")"
	if [[ -n "$removed_output" && "$removed_output" == "$guarded" ]] || drm_connector_is_disconnected "$guarded"; then
		recover_private "Projector disconnected; Private mode was restored" || return 1
		RECOVERY_NOTICE="Projector disconnected; Private mode was restored"
		return 0
	fi
	monitors="$(monitor_json)" || return 1
	active_monitors="$(active_monitor_json)" || active_monitors="$monitors"
	if ! output_is_active "$active_monitors" "$guarded" || ! output_is_active "$active_monitors" "$(jq -r '.builtin // empty' <<< "$state")"; then
		recover_private "A presentation output failed; Private mode was restored" || return 1
		RECOVERY_NOTICE="A presentation output failed; Private mode was restored"
	fi
}

queue_guard_check() {
	local removed_output="${1:-*}" temporary="$pending_guard_file.tmp.$BASHPID"
	printf '%s\n' "$removed_output" > "$temporary"
	mv -f "$temporary" "$pending_guard_file"
}

guard_check() {
	local removed_output="${1:-}" result=0
	(
		exec 9> "$operation_lock"
		if ! flock -w 5 9; then
			queue_guard_check "$removed_output"
			exit 1
		fi
		RECOVERY_NOTICE=""
		recover_if_needed_locked "$removed_output" || result=$?
		if ((result == 0)); then rm -f "$pending_guard_file"
		else queue_guard_check "$removed_output"
		fi
		flock -u 9
		if [[ -n "$RECOVERY_NOTICE" ]]; then
			refresh_wallpaper || true
			notify_recovery "$RECOVERY_NOTICE"
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
				monitoradded*) emit_guard_event check ;;
				configreloaded*) emit_guard_event check ;;
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

	# A service restart never resumes presentation. It establishes the private baseline first.
	manual_recover >/dev/null || printf 'projectorctl: could not establish Private mode on startup\n' >&2
	watch_events 8>&- & hypr_event_pid=$!
	watch_drm_events 8>&- & drm_event_pid=$!
	trap 'kill "${hypr_event_pid:-}" "${drm_event_pid:-}" 2>/dev/null || true' EXIT
	trap 'exit 0' INT TERM
	next_poll=$((SECONDS + guard_poll_interval))
	while true; do
		event=""; removed_output=""; read_timeout="$watcher_health_interval"
		[[ -e "$pending_guard_file" ]] && read_timeout="$guard_retry_interval"
		IFS= read -r -t "$read_timeout" event <&7 || true
		[[ "$event" == removed:* ]] && removed_output="${event#removed:}"
		if [[ -n "$event" || -e "$pending_guard_file" || $SECONDS -ge $next_poll ]]; then
			guard_check "$removed_output" || true
			next_poll=$((SECONDS + guard_poll_interval))
		fi
		if ! kill -0 "$hypr_event_pid" 2>/dev/null; then wait "$hypr_event_pid" 2>/dev/null || true; watch_events 8>&- & hypr_event_pid=$!; fi
		if ! kill -0 "$drm_event_pid" 2>/dev/null; then wait "$drm_event_pid" 2>/dev/null || true; watch_drm_events 8>&- & drm_event_pid=$!; fi
	done
}
