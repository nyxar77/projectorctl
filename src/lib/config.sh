runtime_root="${PROJECTORCTL_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/projector-control-${UID}}"
hypr_root="${PROJECTORCTL_HYPR_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/hypr}"
drm_root="${PROJECTORCTL_DRM_ROOT:-/sys/class/drm}"
state_file="$runtime_root/state.json"
layout_file="${PROJECTORCTL_LAYOUT_FILE:-${XDG_RUNTIME_DIR:-$runtime_root}/projector-layout.lua}"
private_layout_file="${PROJECTORCTL_PRIVATE_LAYOUT_FILE:-${HOME}/.cache/hypr/projector-private-layout.lua}"
operation_lock="$runtime_root/operation.lock"
guard_lock="$runtime_root/guard.lock"
pending_guard_file="$runtime_root/recovery.pending"
guard_event_fifo="$runtime_root/guard.events"

hyprctl_bin="${PROJECTORCTL_HYPRCTL:-hyprctl}"
caelestia_bin="${PROJECTORCTL_CAELESTIA:-caelestia}"
systemctl_bin="${PROJECTORCTL_SYSTEMCTL:-systemctl}"
refresh_caelestia="${PROJECTORCTL_REFRESH_CAELESTIA:-true}"
notify_bin="${PROJECTORCTL_NOTIFY_SEND:-notify-send}"
udevadm_bin="${PROJECTORCTL_UDEVADM:-udevadm}"
guard_poll_interval="${PROJECTORCTL_GUARD_POLL_INTERVAL:-60}"
monitor_timeout="${PROJECTORCTL_MONITOR_TIMEOUT:-2}"
monitor_probe_timeout="${PROJECTORCTL_MONITOR_PROBE_TIMEOUT:-0.25}"
verification_timeout="${PROJECTORCTL_VERIFICATION_TIMEOUT:-${PROJECTORCTL_VERIFICATION_ATTEMPTS:-8}}"
verification_retry_interval="${PROJECTORCTL_VERIFICATION_RETRY_INTERVAL:-0.1}"
guard_retry_interval="${PROJECTORCTL_GUARD_RETRY_INTERVAL:-1}"
watcher_health_interval="${PROJECTORCTL_WATCHER_HEALTH_INTERVAL:-5}"
command_kill_after="${PROJECTORCTL_COMMAND_KILL_AFTER:-1}"

internal_pattern='^(eDP|LVDS|DSI)(-|$)'
ignored_output_pattern='^(HEADLESS|FALLBACK)(-|$)'
BUILTIN_OUTPUT=""
EXTERNAL_OUTPUT=""
LAST_ERROR=""
RECOVERY_NOTICE=""
VERIFIED_MONITORS=""
LAST_MONITOR_SNAPSHOT=""
ACTIVE_PRIVATE_RULES=""

# Declarative mode registry. Runtime code should consume these fields instead
# of branching on individual mode names.
declare -Ag MODE_ACTION MODE_DIRECTION MODE_EVENT MODE_LABEL MODE_REQUIRES_EXTERNAL MODE_TOPOLOGY

MODE_ACTION[builtin]=true
MODE_ACTION[duplicate]=true
MODE_ACTION["extend-right"]=true
MODE_ACTION["extend-left"]=true
MODE_ACTION[external]=false

MODE_DIRECTION[builtin]=none
MODE_DIRECTION[duplicate]=none
MODE_DIRECTION["extend-right"]=right
MODE_DIRECTION["extend-left"]=left
MODE_DIRECTION[external]=none

MODE_EVENT[builtin]='External outputs are private and disabled'
MODE_EVENT[duplicate]='Presenting on %s'
MODE_EVENT["extend-right"]='Projector is on the right'
MODE_EVENT["extend-left"]='Projector is on the left'
MODE_EVENT[external]='Legacy projector-only state is unsafe'

MODE_LABEL[builtin]='Private / laptop only'
MODE_LABEL[duplicate]='Present / mirror'
MODE_LABEL["extend-right"]='Extend right'
MODE_LABEL["extend-left"]='Extend left'
MODE_LABEL[external]='Unsafe legacy projector-only layout'
MODE_LABEL[extended]='Extended desktop'
MODE_LABEL[none]='No active display'
MODE_LABEL[unknown]='Unknown layout'

MODE_REQUIRES_EXTERNAL[builtin]=false
MODE_REQUIRES_EXTERNAL[duplicate]=true
MODE_REQUIRES_EXTERNAL["extend-right"]=true
MODE_REQUIRES_EXTERNAL["extend-left"]=true
MODE_REQUIRES_EXTERNAL[external]=true

MODE_TOPOLOGY[builtin]=builtin
MODE_TOPOLOGY[duplicate]=mirror
MODE_TOPOLOGY["extend-right"]=extend
MODE_TOPOLOGY["extend-left"]=extend
MODE_TOPOLOGY[external]=legacy
MODE_TOPOLOGY[extended]=extended
MODE_TOPOLOGY[none]=none
MODE_TOPOLOGY[unknown]=unknown

mode_is_action() {
	[[ "${MODE_ACTION["$1"]:-false}" == true ]]
}

mode_is_legacy() {
	[[ "${MODE_TOPOLOGY["$1"]:-}" == legacy ]]
}

mode_requires_external() {
	[[ "${MODE_REQUIRES_EXTERNAL["$1"]:-false}" == true ]]
}

mode_topology() {
	printf '%s\n' "${MODE_TOPOLOGY["$1"]:-unknown}"
}

mode_direction() {
	printf '%s\n' "${MODE_DIRECTION["$1"]:-none}"
}

mode_label() {
	printf '%s\n' "${MODE_LABEL["$1"]:-Unknown layout}"
}

mode_event() {
	local event="${MODE_EVENT["$1"]:-}"
	event="${event//%s/$EXTERNAL_OUTPUT}"
	printf '%s\n' "$event"
}

valid_positive_duration() {
	local value="$1" number=""
	[[ "$value" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)(s|m|h|d)?$ ]] || return 1
	number="${value%[smhd]}"
	[[ "$number" == *[1-9]* ]]
}

valid_positive_number() {
	[[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ && "$1" == *[1-9]* ]]
}

valid_positive_integer() {
	[[ "$1" =~ ^[1-9][0-9]*$ ]]
}

valid_positive_integer "$guard_poll_interval" || guard_poll_interval=60
valid_positive_duration "$monitor_timeout" || monitor_timeout=2
valid_positive_duration "$monitor_probe_timeout" || monitor_probe_timeout=0.25
valid_positive_integer "$verification_timeout" || verification_timeout=8
valid_positive_number "$verification_retry_interval" || verification_retry_interval=0.1
valid_positive_integer "$guard_retry_interval" || guard_retry_interval=1
valid_positive_number "$watcher_health_interval" || watcher_health_interval=5
valid_positive_duration "$command_kill_after" || command_kill_after=1
[[ "$refresh_caelestia" == true || "$refresh_caelestia" == false ]] || refresh_caelestia=true

run_bounded() {
	local deadline="$1"
	shift
	timeout --kill-after="$command_kill_after" "$deadline" "$@"
}

umask 077
if [[ -L "$runtime_root" || ( -e "$runtime_root" && ! -d "$runtime_root" ) ]]; then
	printf 'projectorctl: unsafe runtime path: %s\n' "$runtime_root" >&2
	return 1
fi
mkdir -p "$runtime_root"
[[ -O "$runtime_root" ]] || {
	printf 'projectorctl: runtime directory is not owned by this user: %s\n' "$runtime_root" >&2
	return 1
}
chmod 700 "$runtime_root"
