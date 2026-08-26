#!/usr/bin/env bash
set -Eeuo pipefail

: "${PROJECTORCTL_PANEL_QML:?PROJECTORCTL_PANEL_QML is not set}"

quickshell_bin="${PROJECTORCTL_QUICKSHELL:-quickshell}"
if [[ -n "${PROJECTORCTL_PANEL_RUNTIME_DIR:-}" ]]; then
	runtime_dir="$PROJECTORCTL_PANEL_RUNTIME_DIR"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
	runtime_dir="$XDG_RUNTIME_DIR/projectorctl"
else
	runtime_dir="/tmp/projectorctl-$UID"
fi
pid_file="$runtime_dir/panel.pid"
lock_file="$runtime_dir/panel.lock"

umask 077
if [[ -L "$runtime_dir" || ( -e "$runtime_dir" && ! -d "$runtime_dir" ) ]]; then
	printf 'projector-panel: unsafe runtime path: %s\n' "$runtime_dir" >&2
	exit 1
fi
mkdir -p "$runtime_dir"
[[ -O "$runtime_dir" ]] || {
	printf 'projector-panel: runtime directory is not owned by this user: %s\n' "$runtime_dir" >&2
	exit 1
}
chmod 700 "$runtime_dir"

panel_is_live() {
	local pid="$1"
	local command_line=""

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
	[[ "${command_line,,}" == *quickshell* && "${command_line,,}" == *projector.qml* ]]
}

remove_own_pid() {
	local current_pid=""

	if [[ -r "$pid_file" ]] && read -r current_pid < "$pid_file" && [[ "$current_pid" == "${panel_pid:-}" ]]; then
		rm -f "$pid_file"
	fi
}

cleanup_own_panel() {
	local result="$?"
	trap - EXIT INT TERM HUP
	if [[ -n "${panel_pid:-}" ]] && kill -0 "$panel_pid" 2>/dev/null; then
		kill "$panel_pid" 2>/dev/null || true
		for _ in {1..20}; do
			kill -0 "$panel_pid" 2>/dev/null || break
			sleep 0.05
		done
		if kill -0 "$panel_pid" 2>/dev/null; then
			kill -KILL "$panel_pid" 2>/dev/null || true
		fi
		wait "$panel_pid" 2>/dev/null || true
	fi
	remove_own_pid
	exit "$result"
}

exec 9> "$lock_file"
flock -w 2 9 || {
	printf 'projector-panel: another panel action is still running\n' >&2
	exit 1
}

old_pid=""
if [[ -r "$pid_file" ]] && read -r old_pid < "$pid_file" && panel_is_live "$old_pid"; then
	kill "$old_pid" 2>/dev/null || true
	for _ in {1..20}; do
		kill -0 "$old_pid" 2>/dev/null || break
		sleep 0.05
	done
	if kill -0 "$old_pid" 2>/dev/null; then
		printf 'projector-panel: the existing panel did not close\n' >&2
		exit 1
	fi
	rm -f "$pid_file"
	exit 0
fi

rm -f "$pid_file"
panel_pid=""
trap cleanup_own_panel EXIT
trap 'exit 0' INT TERM HUP
"$quickshell_bin" -p "$PROJECTORCTL_PANEL_QML" "$@" 9>&- &
panel_pid="$!"
printf '%s\n' "$panel_pid" > "$pid_file"
flock -u 9

wait "$panel_pid"
