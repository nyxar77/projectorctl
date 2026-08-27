audio_sink_lines() {
	local line="" in_sinks=false
	"$wpctl_bin" status -n 2>/dev/null | while IFS= read -r line; do
		[[ "$line" == *Sinks:* ]] && { in_sinks=true; continue; }
		[[ "$line" == *Sources:* ]] && break
		[[ "$in_sinks" == true && "$line" =~ ([0-9]+)\.[[:space:]]+(alsa_output\.[^[:space:]]+) ]] || continue
		printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	done
}

hdmi_sink_is_connected() {
	local sink_id="$1" details="" card="" profile="" slot="" eld=""
	details="$("$wpctl_bin" inspect "$sink_id" 2>/dev/null)" || return 1
	[[ "$details" =~ alsa.card[[:space:]]*=[[:space:]]*\"([0-9]+)\" ]] || return 1
	card="${BASH_REMATCH[1]}"
	[[ "$details" =~ device.profile.name[[:space:]]*=[[:space:]]*\"HiFi:[[:space:]]*HDMI([0-9]+):[[:space:]]*sink\" ]] || return 1
	profile="${BASH_REMATCH[1]}"
	slot="$((profile - 1))"
	shopt -s nullglob
	for eld in /proc/asound/card"$card"/eld#*."$slot"; do
		[[ "$(<"$eld")" == *$'monitor_present\t\t1'* ]] && { shopt -u nullglob; return 0; }
	done
	shopt -u nullglob
	return 1
}

switch_audio_for_mode() {
	local mode="$1" sink_id="" sink_name="" selected="" attempt=0
	[[ "$audio_auto_switch" == true ]] || return 0
	command -v "$wpctl_bin" >/dev/null 2>&1 || return 0
	while ((attempt++ < 15)); do
		while read -r sink_id sink_name; do
			if [[ "$mode" == builtin ]]; then
				[[ "$sink_name" =~ HDMI|DP|DISPLAYPORT ]] || { selected="$sink_id"; break; }
			elif [[ "$sink_name" =~ HDMI|DP|DISPLAYPORT ]] && hdmi_sink_is_connected "$sink_id"; then
				selected="$sink_id"; break
			fi
		done < <(audio_sink_lines)
		[[ -n "$selected" ]] && "$wpctl_bin" set-default "$selected" >/dev/null 2>&1 && return 0
		sleep 0.2
	done
	return 1
}
