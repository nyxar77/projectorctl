instance_is_live() {
	local signature="$1" instance_dir="$hypr_root/$1" pid="" command_name="" command_line=""

	[[ -n "$signature" && -S "$instance_dir/.socket.sock" && -r "$instance_dir/hyprland.lock" ]] || return 1
	read -r pid _ < "$instance_dir/hyprland.lock" || return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	command_name="$(</proc/"$pid"/comm)" 2>/dev/null || return 1
	command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
	[[ "${command_name,,} ${command_line,,}" == *hyprland* ]]
}

use_instance() {
	local signature="$1" pid="" display=""
	read -r pid display < "$hypr_root/$signature/hyprland.lock" || true
	export HYPRLAND_INSTANCE_SIGNATURE="$signature"
	[[ -z "$display" ]] || export WAYLAND_DISPLAY="$display"
}

resolve_instance() {
	local current="${HYPRLAND_INSTANCE_SIGNATURE:-}" wanted_display="${WAYLAND_DISPLAY:-}"
	local instance_dir="" signature="" display="" candidate="" candidate_mtime=-1 lock_mtime=0
	local -a instance_dirs=()

	if instance_is_live "$current"; then
		use_instance "$current"
		return 0
	fi
	shopt -s nullglob
	instance_dirs=("$hypr_root"/*)
	shopt -u nullglob
	for instance_dir in "${instance_dirs[@]}"; do
		signature="${instance_dir##*/}"
		instance_is_live "$signature" || continue
		read -r _ display < "$instance_dir/hyprland.lock" || display=""
		if [[ -n "$wanted_display" && "$display" == "$wanted_display" ]]; then
			use_instance "$signature"
			return 0
		fi
		lock_mtime="$(stat -c %Y "$instance_dir/hyprland.lock" 2>/dev/null || printf '0')"
		if ((lock_mtime > candidate_mtime)); then
			candidate="$signature"
			candidate_mtime="$lock_mtime"
		fi
	done
	[[ -n "$candidate" ]] || return 1
	use_instance "$candidate"
}

monitor_json() {
	local query_timeout="${1:-$monitor_timeout}" monitors=""
	resolve_instance || return 1
	monitors="$(run_bounded "$query_timeout" "$hyprctl_bin" -j monitors all 2>/dev/null)" || return 1
	monitor_snapshot_is_valid "$monitors" || return 1
	printf '%s\n' "$monitors"
}

active_monitor_json() {
	local query_timeout="${1:-$monitor_timeout}" monitors=""
	resolve_instance || return 1
	monitors="$(run_bounded "$query_timeout" "$hyprctl_bin" -j monitors 2>/dev/null)" || return 1
	monitor_snapshot_is_valid "$monitors" || return 1
	printf '%s\n' "$monitors"
}

monitor_snapshot_is_valid() {
	jq -e '
		type == "array"
		and (([.[].name] | length) == ([.[].name] | unique | length))
		and all(.[]; type == "object"
			and (.name | type == "string" and length > 0)
			and (.id | type == "number")
			and (.disabled | type == "boolean")
			and (.dpmsStatus | type == "boolean")
			and (.x | type == "number")
			and (.y | type == "number"))
	' <<< "$1" >/dev/null 2>&1
}

select_outputs() {
	local monitors="$1" remembered_external=""
	monitor_snapshot_is_valid "$monitors" || return 1
	BUILTIN_OUTPUT="$(jq -r --arg pattern "$internal_pattern" '
		[.[] | select(.name | test($pattern; "i"))]
		| sort_by([if (.disabled == false and .dpmsStatus == true) then 0 else 1 end, .name])
		| .[0].name // empty
	' <<< "$monitors")"
	remembered_external="$(state_field external)"
	if [[ -n "$remembered_external" ]] && output_is_active "$monitors" "$remembered_external"; then
		EXTERNAL_OUTPUT="$remembered_external"
	else
		EXTERNAL_OUTPUT="$(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '
			[.[] | select(((.name | test($internal; "i")) | not)
				and ((.name | test($ignored; "i")) | not) and .disabled == false and .dpmsStatus == true)]
			| sort_by([if (.name | test("^HDMI"; "i")) then 0 else 1 end, .name])
			| .[0].name // empty
		' <<< "$monitors")"
	fi
	if [[ -z "$EXTERNAL_OUTPUT" && -n "$remembered_external" ]] && jq -e --arg output "$remembered_external" \
		--arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '
			any(.[]; .name == $output
				and ((.name | test($internal; "i")) | not)
				and ((.name | test($ignored; "i")) | not))
		' <<< "$monitors" >/dev/null; then
		EXTERNAL_OUTPUT="$remembered_external"
	elif [[ -z "$EXTERNAL_OUTPUT" ]]; then
		EXTERNAL_OUTPUT="$(jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '
			[.[] | select(((.name | test($internal; "i")) | not)
				and ((.name | test($ignored; "i")) | not))]
			| sort_by([if (.disabled // false) then 1 else 0 end,
				if (.name | test("^HDMI"; "i")) then 0 else 1 end, .name])
			| .[0].name // empty
		' <<< "$monitors")"
	fi
}

output_exists() {
	[[ -n "$2" ]] && jq -e --arg output "$2" 'any(.[]; .name == $output)' <<< "$1" >/dev/null
}

output_is_active() {
	[[ -n "$2" ]] && jq -e --arg output "$2" '
		any(.[]; .name == $output and .disabled == false and .dpmsStatus == true)
	' <<< "$1" >/dev/null
}

output_is_configured() {
	[[ -n "$2" ]] && jq -e --arg output "$2" '
		any(.[]; .name == $output and .disabled == false)
	' <<< "$1" >/dev/null
}

active_output_count() {
	jq -r --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($ignored; "i")) | not)
		and .disabled == false and .dpmsStatus == true)] | length' <<< "$1"
}

active_external_count() {
	jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($internal; "i")) | not) and ((.name | test($ignored; "i")) | not)
		and .disabled == false and .dpmsStatus == true)] | length' <<< "$1"
}

configured_output_count() {
	jq -r --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($ignored; "i")) | not) and .disabled == false)] | length' <<< "$1"
}

configured_external_count() {
	jq -r --arg internal "$internal_pattern" --arg ignored "$ignored_output_pattern" '[.[] | select(
		((.name | test($internal; "i")) | not) and ((.name | test($ignored; "i")) | not)
		and .disabled == false)] | length' <<< "$1"
}

output_is_mirroring() {
	local monitors="$1" mirror_output="$2" source_output="$3"
	[[ -n "$mirror_output" && -n "$source_output" ]] && jq -e --arg mirror "$mirror_output" --arg source "$source_output" '
		([.[] | select(.name == $source)][0].id | tostring) as $sourceId |
		any(.[]; .name == $mirror and .disabled == false and .dpmsStatus == true
			and (((.mirrorOf // "") | tostring) == $source or ((.mirrorOf // "") | tostring) == $sourceId))
	' <<< "$monitors" >/dev/null
}

output_is_configured_mirroring() {
	local monitors="$1" mirror_output="$2" source_output="$3"
	[[ -n "$mirror_output" && -n "$source_output" ]] && jq -e --arg mirror "$mirror_output" --arg source "$source_output" '
		([.[] | select(.name == $source)][0].id | tostring) as $sourceId |
		any(.[]; .name == $mirror and .disabled == false
			and (((.mirrorOf // "") | tostring) == $source or ((.mirrorOf // "") | tostring) == $sourceId))
	' <<< "$monitors" >/dev/null
}

drm_connector_status() {
	local output="$1" connector="" connector_state="" saw_unknown=false saw_disconnected=false
	local -a connectors=()
	[[ -n "$output" ]] || return 1
	shopt -s nullglob
	connectors=("$drm_root"/card*-"$output"/status)
	shopt -u nullglob
	for connector in "${connectors[@]}"; do
		[[ -r "$connector" ]] || continue
		read -r connector_state < "$connector" || continue
		[[ "$connector_state" == connected ]] && { printf 'connected\n'; return 0; }
		[[ "$connector_state" == unknown ]] && saw_unknown=true
		[[ "$connector_state" == disconnected ]] && saw_disconnected=true
	done
	[[ "$saw_unknown" == true ]] && { printf 'unknown\n'; return 0; }
	[[ "$saw_disconnected" == true ]] && { printf 'disconnected\n'; return 0; }
	return 1
}

drm_connector_is_disconnected() {
	[[ "$(drm_connector_status "$1" 2>/dev/null || true)" == disconnected ]]
}

refresh_wallpaper() {
	local wallpaper_file="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/wallpaper/path.txt" wallpaper=""
	command -v "$caelestia_bin" >/dev/null 2>&1 || return 1
	[[ -r "$wallpaper_file" ]] || return 1
	read -r wallpaper < "$wallpaper_file" || return 1
	[[ -n "$wallpaper" && -f "$wallpaper" ]] || return 1
	run_bounded 12 "$caelestia_bin" wallpaper -f "$wallpaper" >/dev/null 2>&1
}

notify_recovery() {
	command -v "$notify_bin" >/dev/null 2>&1 || return 0
	run_bounded 3 "$notify_bin" -u critical -a Projector "Private display restored" "$1" >/dev/null 2>&1 || true
}
