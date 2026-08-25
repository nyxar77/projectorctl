#!/usr/bin/env bash
set -Eeuo pipefail

projectorctl_source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
projectorctl_default_lib_dir="$projectorctl_source_dir/lib"
if [[ ! -d "$projectorctl_default_lib_dir" ]]; then
	projectorctl_default_lib_dir="${XDG_DATA_HOME:-$HOME/.local/share}/projectorctl/lib"
fi
projectorctl_lib_dir="${PROJECTORCTL_LIB_DIR:-$projectorctl_default_lib_dir}"

for projectorctl_module in \
	config.sh \
	runtime.sh \
	state.sh \
	hyprland.sh \
	layouts.sh \
	status.sh \
	guard.sh; do
	# shellcheck source=/dev/null
	source "$projectorctl_lib_dir/$projectorctl_module"
done
unset projectorctl_module

usage() {
	printf 'usage: projectorctl status | apply MODE | recover | check | watch\n' >&2
}

main() {
	local command="${1:-status}"

	case "$command" in
		status)
			status_json
			;;
		apply)
			[[ $# -eq 2 ]] || {
				usage
				return 2
			}
			apply_mode "$2"
			;;
		recover)
			manual_recover
			;;
		check)
			guard_check
			;;
		watch)
			watch_guard
			;;
		*)
			usage
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
