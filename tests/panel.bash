#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
panel_source="${PROJECTORCTL_PANEL_SOURCE:-$repo_root/src/projector-panel.sh}"
fake_source="${PROJECTORCTL_FAKE_QUICKSHELL:-$repo_root/tests/fake-quickshell}"
test_root="$(mktemp -d)"
runtime_dir="$test_root/run"
fake_quickshell="$test_root/quickshell"
fake_qml="$test_root/Projector.qml"
launcher_pid=""
unrelated_pid=""
panel_pid=""

cleanup() {
	[[ -n "$launcher_pid" ]] && kill "$launcher_pid" 2>/dev/null || true
	[[ -n "$panel_pid" ]] && kill "$panel_pid" 2>/dev/null || true
	[[ -n "$unrelated_pid" ]] && kill "$unrelated_pid" 2>/dev/null || true
	rm -rf "$test_root"
}
trap cleanup EXIT

cp "$fake_source" "$fake_qml"
ln -s "$(command -v bash)" "$fake_quickshell"
mkdir -p "$runtime_dir"

sleep 30 &
unrelated_pid="$!"
printf '%s\n' "$unrelated_pid" > "$runtime_dir/panel.pid"

PROJECTORCTL_PANEL_QML="$fake_qml" \
PROJECTORCTL_PANEL_RUNTIME_DIR="$runtime_dir" \
PROJECTORCTL_QUICKSHELL="$fake_quickshell" \
	bash "$panel_source" &
launcher_pid="$!"

for _ in {1..50}; do
	if [[ -r "$runtime_dir/panel.pid" ]]; then
		read -r panel_pid < "$runtime_dir/panel.pid" || true
	fi
	if [[ -n "$panel_pid" && "$panel_pid" != "$unrelated_pid" ]]; then
		break
	fi
	sleep 0.02
done

[[ "$panel_pid" =~ ^[0-9]+$ && "$panel_pid" != "$unrelated_pid" ]] || {
	printf 'panel did not start\n' >&2
	exit 1
}
kill -0 "$unrelated_pid" 2>/dev/null || {
	printf 'stale pid handling killed an unrelated process\n' >&2
	exit 1
}

PROJECTORCTL_PANEL_QML="$fake_qml" \
PROJECTORCTL_PANEL_RUNTIME_DIR="$runtime_dir" \
PROJECTORCTL_QUICKSHELL="$fake_quickshell" \
	bash "$panel_source"

wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
kill -0 "$panel_pid" 2>/dev/null && {
	printf 'second launch did not close the panel\n' >&2
	exit 1
}
[[ ! -e "$runtime_dir/panel.pid" ]] || {
	printf 'panel left a stale pid behind\n' >&2
	exit 1
}

PROJECTORCTL_PANEL_QML="$fake_qml" \
PROJECTORCTL_PANEL_RUNTIME_DIR="$runtime_dir" \
PROJECTORCTL_QUICKSHELL="$fake_quickshell" \
	bash "$panel_source" &
launcher_pid="$!"

panel_pid=""
for _ in {1..50}; do
	if [[ -r "$runtime_dir/panel.pid" ]]; then
		read -r panel_pid < "$runtime_dir/panel.pid" || true
	fi
	[[ "$panel_pid" =~ ^[0-9]+$ ]] && break
	sleep 0.02
done

[[ "$panel_pid" =~ ^[0-9]+$ ]] || {
	printf 'panel did not restart for signal test\n' >&2
	exit 1
}
kill "$launcher_pid"
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
kill -0 "$panel_pid" 2>/dev/null && {
	printf 'stopping the launcher left the panel running\n' >&2
	exit 1
}
panel_pid=""
[[ ! -e "$runtime_dir/panel.pid" ]] || {
	printf 'stopping the launcher left a stale pid behind\n' >&2
	exit 1
}

printf 'ok - ignores stale pids, toggles, and cleans up on exit\n'
