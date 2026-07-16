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
mkdir -p "$runtime_dir"

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
"$quickshell_bin" -p "$PROJECTORCTL_PANEL_QML" "$@" &
panel_pid="$!"
printf '%s\n' "$panel_pid" > "$pid_file"
flock -u 9

trap remove_own_pid EXIT
trap 'exit 0' INT TERM
wait "$panel_pid"
