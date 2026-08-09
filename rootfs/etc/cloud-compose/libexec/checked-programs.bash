# Shared trust boundary for jq, AWK, and sourced shell programs consumed by Cloud Compose.
# This file is sourced from checked runtime scripts; it is not an entrypoint.

cloud_compose_program_owner_path() {
    local owner_source="$1"

    readlink -f -- "$owner_source"
}

cloud_compose_validate_root_parent() {
    local current="$1" metadata owner group mode

    if [[ -L "$current" || ! -d "$current" ]]; then
        echo "Installed Cloud Compose program parent is missing or redirected: $current" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%g:%a' -- "$current")" || return 1
    IFS=: read -r owner group mode <<<"$metadata"
    if [[ "$owner" != 0 || "$group" != 0 || ! "$mode" =~ ^[0-7]{3,4}$ ||
        $((8#$mode & 0022)) -ne 0 ]]; then
        echo "Installed Cloud Compose program parent is not root-controlled: $current" >&2
        return 1
    fi
}

cloud_compose_installed_home() {
    local resolved_home alias_metadata alias_target
    local -a parents

    if [[ -L /home ]]; then
        alias_metadata="$(stat -c '%u:%g:%h' -- /home)" || return 1
        alias_target="$(readlink -- /home)" || return 1
        if [[ "$alias_metadata" != "0:0:1" ||
            ( "$alias_target" != "var/home" && "$alias_target" != "/var/home" ) ]]; then
            echo "Installed Cloud Compose home uses an unsafe operating-system alias" >&2
            return 1
        fi
    elif [[ ! -d /home ]]; then
        echo "Installed Cloud Compose home parent is missing" >&2
        return 1
    fi

    resolved_home="$(readlink -f -- /home)" || return 1
    case "$resolved_home" in
        /home) parents=(/ /home /home/cloud-compose) ;;
        /var/home) parents=(/ /var /var/home /var/home/cloud-compose) ;;
        *)
            echo "Installed Cloud Compose home resolves outside a supported root-controlled path" >&2
            return 1
            ;;
    esac
    for parent in "${parents[@]}"; do
        cloud_compose_validate_root_parent "$parent" || return 1
    done
    printf '%s/cloud-compose\n' "$resolved_home"
}

cloud_compose_owner_is_installed() {
    local owner_path="$1" candidate_home installed_home

    candidate_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
    if [[ "$candidate_home" == "/" ]]; then
        echo "Installed Cloud Compose home resolves to the filesystem root" >&2
        return 2
    fi
    if [[ -z "$candidate_home" ||
        "$owner_path" != "${candidate_home%/}/"* ]]; then
        return 1
    fi
    installed_home="$(cloud_compose_installed_home)" || return 2
    [[ "$candidate_home" == "$installed_home" ]] || return 2
}

cloud_compose_validate_installed_program() {
    local program="$1" program_dir="$2" program_name current metadata owner group mode links
    local -a parents

    case "$program_dir" in
        /etc/cloud-compose/jq | /etc/cloud-compose/awk) ;;
        *)
            echo "Unsupported installed Cloud Compose program directory: $program_dir" >&2
            return 1
            ;;
    esac
    program_name="${program##*/}"
    [[ "$program" == "$program_dir/$program_name" &&
        "$program_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(jq|awk)$ &&
        "$program" != *$'\n'* &&
        "$program" != *$'\r'* && ! "$program" =~ (^|/)\.\.?(/|$) ]] || {
        echo "Unsafe installed Cloud Compose program path: $program" >&2
        return 1
    }

    parents=(/ /etc /etc/cloud-compose "$program_dir")
    for current in "${parents[@]}"; do
        cloud_compose_validate_root_parent "$current" || return 1
    done

    if [[ -L "$program" || ! -f "$program" ]]; then
        echo "Installed Cloud Compose program is missing or redirected: $program" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%g:%a:%h' -- "$program")" || return 1
    IFS=: read -r owner group mode links <<<"$metadata"
    if [[ "$owner" != 0 || "$group" != 0 || "$links" != 1 ||
        ! "$mode" =~ ^[0-7]{3,4}$ ||
        $((8#$mode & 0022)) -ne 0 ]]; then
        echo "Installed Cloud Compose program is not a single-link, root-controlled regular file: $program" >&2
        return 1
    fi
}

cloud_compose_validate_installed_program_dir() (
    local program_dir="$1" program
    local -a programs

    shopt -s nullglob dotglob
    case "$program_dir" in
        /etc/cloud-compose/jq) programs=("$program_dir"/*.jq) ;;
        /etc/cloud-compose/awk) programs=("$program_dir"/*.awk) ;;
        *)
            echo "Unsupported installed Cloud Compose program directory: $program_dir" >&2
            return 1
            ;;
    esac
    ((${#programs[@]} > 0)) || {
        echo "Installed Cloud Compose program directory is empty: $program_dir" >&2
        return 1
    }
    for program in "${programs[@]}"; do
        cloud_compose_validate_installed_program "$program" "$program_dir" || return 1
    done
)

cloud_compose_validate_installed_source() {
    local program="$1" resolved_program installed_home metadata owner group mode links

    [[ "$program" =~ ^/home/cloud-compose/[A-Za-z0-9][A-Za-z0-9._-]*\.sh$ ]] || {
        echo "Unsafe installed Cloud Compose source program path: $program" >&2
        return 1
    }
    installed_home="$(cloud_compose_installed_home)" || return 1
    resolved_program="$(readlink -f -- "$program")" || return 1
    [[ "$resolved_program" == "$installed_home/${program##*/}" ]] || {
        echo "Installed Cloud Compose source program resolves outside its fixed home" >&2
        return 1
    }
    if [[ -L "$program" || ! -f "$program" ]]; then
        echo "Installed Cloud Compose source program is missing or redirected: $program" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%g:%a:%h' -- "$program")" || return 1
    IFS=: read -r owner group mode links <<<"$metadata"
    if [[ "$owner" != 0 || "$group" != 0 || "$links" != 1 ||
        ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
        echo "Installed Cloud Compose source program is not a single-link, root-controlled regular file: $program" >&2
        return 1
    fi
}

cloud_compose_bind_program_dir() {
    local owner_source="$1" variable_name="$2" installed_dir="$3" repository_dir="$4"
    shift 4
    local owner_path selected name program installed_status=0

    owner_path="$(cloud_compose_program_owner_path "$owner_source")" || return 1
    if cloud_compose_owner_is_installed "$owner_path"; then
        installed_status=0
    else
        installed_status=$?
    fi
    if ((installed_status > 1)); then
        return 1
    fi
    if ((installed_status == 0)); then
        if [[ -v $variable_name && "${!variable_name}" != "$installed_dir" ]]; then
            echo "$variable_name cannot override the installed Cloud Compose program directory" >&2
            return 1
        fi
        selected="$installed_dir"
        cloud_compose_validate_installed_program_dir "$selected" || return 1
        for name in "$@"; do
            [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.(jq|awk)$ ]] || {
                echo "Unsafe Cloud Compose program name: $name" >&2
                return 1
            }
            program="$selected/$name"
            cloud_compose_validate_installed_program "$program" "$selected" || return 1
        done
        if [[ ! -v $variable_name ]]; then
            printf -v "$variable_name" '%s' "$selected"
        fi
        readonly "$variable_name"
    else
        if [[ -v $variable_name && -n "${!variable_name}" ]]; then
            selected="${!variable_name}"
        else
            selected="$repository_dir"
        fi
        printf -v "$variable_name" '%s' "$selected"
    fi
}

cloud_compose_bind_program() {
    local owner_source="$1" variable_name="$2" installed_program="$3" repository_program="$4"
    local owner_path selected program_dir installed_status=0

    owner_path="$(cloud_compose_program_owner_path "$owner_source")" || return 1
    if cloud_compose_owner_is_installed "$owner_path"; then
        installed_status=0
    else
        installed_status=$?
    fi
    if ((installed_status > 1)); then
        return 1
    fi
    if ((installed_status == 0)); then
        if [[ -v $variable_name && "${!variable_name}" != "$installed_program" ]]; then
            echo "$variable_name cannot override the installed Cloud Compose program" >&2
            return 1
        fi
        selected="$installed_program"
        program_dir="${installed_program%/*}"
        cloud_compose_validate_installed_program "$selected" "$program_dir" || return 1
        if [[ ! -v $variable_name ]]; then
            printf -v "$variable_name" '%s' "$selected"
        fi
        readonly "$variable_name"
    else
        if [[ -v $variable_name && -n "${!variable_name}" ]]; then
            selected="${!variable_name}"
        else
            selected="$repository_program"
        fi
        printf -v "$variable_name" '%s' "$selected"
    fi
}

cloud_compose_bind_source_program() {
    local owner_source="$1" variable_name="$2" installed_program="$3" repository_program="$4"
    local owner_path selected installed_status=0

    owner_path="$(cloud_compose_program_owner_path "$owner_source")" || return 1
    if cloud_compose_owner_is_installed "$owner_path"; then
        installed_status=0
    else
        installed_status=$?
    fi
    if ((installed_status > 1)); then
        return 1
    fi
    if ((installed_status == 0)); then
        if [[ -v $variable_name && "${!variable_name}" != "$installed_program" ]]; then
            echo "$variable_name cannot override the installed Cloud Compose source program" >&2
            return 1
        fi
        selected="$installed_program"
        cloud_compose_validate_installed_source "$selected" || return 1
        if [[ ! -v $variable_name ]]; then
            printf -v "$variable_name" '%s' "$selected"
        fi
        readonly "$variable_name"
    else
        if [[ -v $variable_name && -n "${!variable_name}" ]]; then
            selected="${!variable_name}"
        else
            selected="$repository_program"
        fi
        printf -v "$variable_name" '%s' "$selected"
    fi
}
