#!/bin/bash
# Clean Homebrew caches and report orphaned dependencies
# Env: DRY_RUN
# Skips if run within 7 days, runs cleanup with package-manager timeouts
BREW_ACTIVE_LINK_PATHS=()
BREW_ACTIVE_LINK_TARGETS=()
BREW_ACTIVE_RESOLVED_TARGETS=()
BREW_ACTIVE_PREFIX=""
BREW_ACTIVE_CELLAR=""

brew_autoremove_preview_has_items() {
    local preview_file="$1"
    [[ -s "$preview_file" ]] || return 1
    grep -Eq '^(==> )?Would autoremove [0-9]+ unneeded formula' "$preview_file"
}

# Autoremove stays a review line: brew only sees its own dependency graph, so
# a formula a venv, pyenv build or cargo crate links against can still look
# unneeded (#1093). Name up to three candidates and count the rest.
show_brew_autoremove_preview() {
    local preview_file="$1"
    local -a names=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$(mole_terminal_safe_text "$name")")
    done < <(awk 'found && NF && $0 !~ /^==>/ { print $1 } /Would autoremove [0-9]+ unneeded formula/ { found = 1 }' "$preview_file")
    [[ ${#names[@]} -gt 0 ]] || return 0

    local subject=""
    if [[ ${#names[@]} -le 3 ]]; then
        subject="${names[0]}"
        local i
        for ((i = 1; i < ${#names[@]}; i++)); do
            subject+=", ${names[i]}"
        done
    else
        subject="${#names[@]} formulae"
    fi
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Homebrew unused dependencies · ${subject} · remove with ${GRAY}brew autoremove${NC}"
}

# `brew cleanup --dry-run` shares the real run's arguments, so the preview
# lists what that run would remove rather than a generic promise.
run_brew_cleanup_preview() {
    local timeout_seconds="$1"
    local preview_file="$2"

    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_COLOR=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout_seconds" brew cleanup --prune=30 --dry-run > "$preview_file" 2>&1
}

# Print a `brew cleanup --dry-run` result as one total row plus one row per
# item. An old Cellar version reads as "<formula> <version>"; any other path
# keeps its location. Empty directories, 0B entries and "Skipping" warnings
# free nothing and stay out of the list. Returns 1 when the preview names
# nothing.
show_brew_cleanup_preview() {
    local preview_file="$1"
    [[ -s "$preview_file" ]] || return 1

    local -a rows=()
    local line rest path detail size label
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "Would remove: "* ]] || continue
        rest="${line#Would remove: }"
        path="$rest"
        size=""
        if [[ "$rest" == *" ("*")" ]]; then
            path="${rest% (*}"
            detail="${rest##* (}"
            detail="${detail%)}"
            size="${detail##*, }"
        fi
        [[ "$size" == "0B" ]] && continue
        if [[ "$path" =~ /Cellar/([^/]+)/([^/]+)$ ]]; then
            label="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        else
            label="${path/#$HOME/~}"
        fi
        label=$(mole_terminal_safe_text "$label")
        [[ -n "$size" ]] && label+=" · $(mole_terminal_safe_text "$size")"
        rows+=("$label")
    done < "$preview_file"
    [[ ${#rows[@]} -gt 0 ]] || return 1

    local freed=""
    freed=$(sed -n 's/^==> This operation would free approximately \(.*\) of disk space\.$/\1/p' "$preview_file" | tail -1)
    freed=$(mole_terminal_safe_text "$freed")
    if [[ -n "$freed" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew cleanup · would free ${freed}"
    else
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew cleanup · $(mole_count_label "${#rows[@]}" item)"
    fi
    printf '    %s\n' "${rows[@]}"
}

# Homebrew formats its cleanup total with Formatter.disk_usage_readable: at
# most one decimal and B, KB, MB or GB, in decimal units since Homebrew 5.0
# (1KB = 1000 bytes). Older releases used 1024 with the same labels, which
# reads a few percent low here. Print that size in KB for the run total, or
# nothing when the text is not such a size.
brew_cleanup_size_kb() {
    [[ "${1:-}" =~ ^([0-9]+)(\.([0-9]))?(B|KB|MB|GB)$ ]] || return 0
    local tenths=$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[3]:-0}))
    local multiplier=1
    case "${BASH_REMATCH[4]}" in
        KB) multiplier=1000 ;;
        MB) multiplier=1000000 ;;
        GB) multiplier=1000000000 ;;
    esac
    echo "$(((tenths * multiplier + 10239) / 10240))"
}

# The window only counts a finished cleanup, which is the only one stamped.
# Dry-run asks the same question so it never previews a run that would skip.
brew_cleanup_ran_recently() {
    local brew_cache_file="$1"
    local cache_valid_days=7
    [[ -f "$brew_cache_file" ]] || return 1
    local last_cleanup
    last_cleanup=$(cat "$brew_cache_file" 2> /dev/null || echo "0")
    local current_time
    current_time=$(get_epoch_seconds)
    local time_diff=$((current_time - last_cleanup))
    local days_diff=$((time_diff / 86400))
    # A stamp from the future (clock set back) is expired, not recent.
    [[ $time_diff -ge 0 && $days_diff -lt $cache_valid_days ]] || return 1
    local cleaned_when="cleaned ${days_diff}d ago"
    [[ $days_diff -eq 0 ]] && cleaned_when="cleaned today"
    debug_log "Homebrew cleanup skipped: ${cleaned_when}"
    return 0
}

run_brew_autoremove_preview() {
    local timeout_seconds="$1"
    local preview_file="$2"

    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_COLOR=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout_seconds" brew autoremove --dry-run > "$preview_file" 2>&1
}

# Resolve an existing path through any symlink chain without requiring GNU
# readlink -f (unavailable on the macOS versions Mole supports).
brew_cleanup_resolve_existing_path() {
    local path="$1"
    local target=""
    local hops=0

    [[ "$path" == /* ]] || return 1
    while [[ -L "$path" ]]; do
        target=$(readlink "$path" 2> /dev/null) || return 1
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="${path%/*}/$target"
        fi
        hops=$((hops + 1))
        [[ $hops -le 32 ]] || return 1
    done

    [[ -e "$path" ]] || return 1
    local parent
    parent=$(cd "${path%/*}" 2> /dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$parent" "${path##*/}"
}

run_homebrew_link_restore_as_invoking_user() {
    /usr/bin/sudo -u "$SUDO_USER" -- "$@"
}

restore_homebrew_link() {
    local link_target="$1"
    local link_path="$2"

    if is_root_user; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] || return 1
        # Homebrew's bin directories belong to the invoking user. Dropping
        # privileges for the actual write closes the parent-directory TOCTOU:
        # even if that user swaps bin after validation, root never follows it.
        run_homebrew_link_restore_as_invoking_user /bin/ln -s "$link_target" "$link_path"
        return $?
    fi

    /bin/ln -s "$link_target" "$link_path"
}

# Record active Homebrew executable links in memory before delegating to
# `brew cleanup`. A file in the invoking user's temp tree cannot safely
# authorize later link creation when the whole command is running as root.
snapshot_homebrew_active_links() {
    BREW_ACTIVE_LINK_PATHS=()
    BREW_ACTIVE_LINK_TARGETS=()
    BREW_ACTIVE_RESOLVED_TARGETS=()
    BREW_ACTIVE_PREFIX=""
    BREW_ACTIVE_CELLAR=""

    local prefix cellar
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || return 0
    cellar=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --cellar 2> /dev/null) || return 0
    [[ "$prefix" == /* && "$cellar" == /* && -d "$prefix" && -d "$cellar" ]] || return 0
    prefix=$(cd "$prefix" 2> /dev/null && pwd -P) || return 0
    cellar=$(cd "$cellar" 2> /dev/null && pwd -P) || return 0
    BREW_ACTIVE_PREFIX="$prefix"
    BREW_ACTIVE_CELLAR="$cellar"

    local link_dir link_path link_target resolved_target
    for link_dir in "$prefix/bin" "$prefix/sbin"; do
        [[ -d "$link_dir" ]] || continue
        while IFS= read -r -d '' link_path; do
            link_target=$(readlink "$link_path" 2> /dev/null) || continue
            case "$link_target" in
                "$cellar"/*)
                    [[ "$link_target" != *"/../"* && "$link_target" != */.. ]] || continue
                    resolved_target="$link_target"
                    ;;
                ../Cellar/*)
                    [[ "$cellar" == "$prefix/Cellar" ]] || continue
                    local cellar_relative="${link_target#../Cellar/}"
                    [[ -n "$cellar_relative" && "$cellar_relative" != ../* && "$cellar_relative" != *"/../"* && "$cellar_relative" != */.. ]] || continue
                    resolved_target="$cellar/$cellar_relative"
                    ;;
                *) continue ;;
            esac
            [[ -e "$resolved_target" ]] || continue
            case "$resolved_target" in
                "$cellar"/*)
                    BREW_ACTIVE_LINK_PATHS+=("$link_path")
                    BREW_ACTIVE_LINK_TARGETS+=("$link_target")
                    BREW_ACTIVE_RESOLVED_TARGETS+=("$resolved_target")
                    ;;
            esac
        done < <(command find "$link_dir" -mindepth 1 -maxdepth 1 -type l -print0 2> /dev/null)
    done
}

# Restore only links that disappeared while their exact pre-cleanup Cellar
# target still exists. Never overwrite a replacement or revive a removed keg.
restore_homebrew_active_links() {
    [[ ${#BREW_ACTIVE_LINK_PATHS[@]} -gt 0 ]] || return 0

    local prefix cellar
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || return 0
    cellar=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --cellar 2> /dev/null) || return 0
    [[ "$prefix" == /* && "$cellar" == /* && -d "$prefix" && -d "$cellar" ]] || return 0
    prefix=$(cd "$prefix" 2> /dev/null && pwd -P) || return 0
    cellar=$(cd "$cellar" 2> /dev/null && pwd -P) || return 0
    [[ "$prefix" == "$BREW_ACTIVE_PREFIX" && "$cellar" == "$BREW_ACTIVE_CELLAR" ]] || return 0

    local restored=0
    local failed=0
    local link_path link_target resolved_target expected_target relative_path
    local current_target current_parent
    local index
    for ((index = 0; index < ${#BREW_ACTIVE_LINK_PATHS[@]}; index++)); do
        link_path="${BREW_ACTIVE_LINK_PATHS[$index]}"
        link_target="${BREW_ACTIVE_LINK_TARGETS[$index]}"
        resolved_target="${BREW_ACTIVE_RESOLVED_TARGETS[$index]}"

        # Restore only direct children of the real Homebrew bin/sbin roots.
        case "$link_path" in
            "$prefix/bin/"*) relative_path="${link_path#"$prefix/bin/"}" ;;
            "$prefix/sbin/"*) relative_path="${link_path#"$prefix/sbin/"}" ;;
            *) continue ;;
        esac
        [[ -n "$relative_path" && "$relative_path" != */* ]] || continue
        [[ ! -e "$link_path" && ! -L "$link_path" ]] || continue

        case "$link_target" in
            "$cellar"/*)
                [[ "$link_target" != *"/../"* && "$link_target" != */.. ]] || continue
                expected_target="$link_target"
                ;;
            ../Cellar/*)
                [[ "$cellar" == "$prefix/Cellar" ]] || continue
                relative_path="${link_target#../Cellar/}"
                [[ -n "$relative_path" && "$relative_path" != ../* && "$relative_path" != *"/../"* && "$relative_path" != */.. ]] || continue
                expected_target="$cellar/$relative_path"
                ;;
            *) continue ;;
        esac
        [[ "$resolved_target" == "$expected_target" ]] || continue

        current_target=$(brew_cleanup_resolve_existing_path "$resolved_target") || continue
        case "$current_target" in
            "$cellar"/*) ;;
            *) continue ;;
        esac

        current_parent=$(cd "${link_path%/*}" 2> /dev/null && pwd -P) || continue
        [[ "$current_parent" == "${link_path%/*}" ]] || continue
        if restore_homebrew_link "$link_target" "$link_path" 2> /dev/null; then
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done

    if [[ $restored -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew links · restored ${restored} active executable(s)"
        note_activity
    fi
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew links · ${failed} could not be restored, run ${GRAY}brew link <formula>${NC}"
        note_activity
    fi
}

# Ask the same Homebrew installation for its configured roots, including
# relocated logs, temporary staging, and the Ruby installation it prunes.
# Resolve existing ancestors so an absent or symlinked root is checked using
# both spellings. An unsupported Homebrew or an incomplete answer keeps all.
brew_cleanup_roots() {
    HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew ruby -e '
            require "keg"
            roots = [HOMEBREW_PREFIX, HOMEBREW_CELLAR, HOMEBREW_REPOSITORY,
                     HOMEBREW_CACHE, HOMEBREW_LOGS, HOMEBREW_LOCKS,
                     HOMEBREW_TEMP_CELLAR, HOMEBREW_TEMP_CASKROOM,
                     HOMEBREW_PREFIX/"Caskroom", HOMEBREW_LIBRARY/"Homebrew/vendor",
                     *Keg.prefix_subdirectories]
            roots.concat(%w[downloads Cask api-source api/cask api/formula
                            gh-actions-artifact bootsnap].map { |d| HOMEBREW_CACHE/d })
            roots.concat(HOMEBREW_PREFIX.glob("lib/python*/site-packages"))
            paths = roots.flat_map do |root|
              root = Pathname(root)
              raise unless root.absolute? && root.cleanpath == root
              ancestor = root.ascend.find { |p| p.exist? || p.symlink? }
              [root, (ancestor.realpath/root.relative_path_from(ancestor)).cleanpath]
            end.uniq
            raise if paths.any? { |p| p.root? || p.to_s.match?(/[[:cntrl:]]/) }
            puts paths
            puts "complete"
        ' 2> /dev/null
}

brew_cleanup_scope_allowed() {
    local roots="" root rc=0 pattern parent_pattern
    roots=$(brew_cleanup_roots) || rc=$?
    mole_rc_signal "$rc" && return "$rc"
    if [[ $rc -ne 0 || "$roots" != /*$'\n'complete ]]; then
        debug_log "Homebrew cleanup: configured roots unavailable"
        return 1
    fi
    while IFS= read -r root; do
        [[ "$root" == /* && "$root" != / && "$root" != *[[:cntrl:]]* ]] || return 1
        if is_path_whitelisted "$root"; then
            return 2
        fi
        _brew_cleanup_roots+=("$root")
        # A glob may start above the root, e.g. /opt/*/Cellar/tool.
        for pattern in "${WHITELIST_PATTERNS[@]+"${WHITELIST_PATTERNS[@]}"}"; do
            [[ "$pattern" == *[\*\?\[]* ]] || continue
            local double="//" single="/"
            while [[ "$pattern" == *"$double"* ]]; do pattern=${pattern//"$double"/"$single"}; done
            parent_pattern=${pattern%/*}
            while [[ "$parent_pattern" == /* ]]; do
                # shellcheck disable=SC2053 # whitelist entries intentionally support globs
                [[ "$root" == $parent_pattern ]] && return 2
                parent_pattern=${parent_pattern%/*}
            done
        done
    done <<< "${roots%$'\n'complete}"
    return 0
}

# Homebrew walks some directories through symlinks. Constrain even a link
# created after the probe to the write roots that passed the whitelist.
# Paths are sandbox parameters, never interpolated into the policy source.
run_scoped_brew_cleanup() {
    local timeout="$1" profile="(version 1)(allow default)(deny file-write*)"
    local -a params=()
    local root key
    for root in "${_brew_cleanup_roots[@]}"; do
        key="BREW_ROOT_${#params[@]}"
        params+=("-D" "$key=$root")
        profile+="(allow file-write* (subpath (param \"$key\")))"
    done
    local scratch
    scratch=$(create_temp_dir) || return 1
    scratch=$(cd -P "$scratch" && pwd -P) || return 1
    params+=("-D" "BREW_TMP=$scratch")
    profile+='(allow file-write* (literal "/dev/null") (subpath (param "BREW_TMP")))'
    TMPDIR="$scratch" run_with_timeout "$timeout" /usr/bin/sandbox-exec "${params[@]}" -p "$profile" brew cleanup --prune=30
}

clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0
    local cleanup_timeout="${MOLE_TIMEOUT_PKG_CLEANUP_SEC:-20}"
    local autoremove_preview_timeout="${MOLE_TIMEOUT_PKG_LIST_SEC:-10}"
    local brew_cache_file="${HOME}/.cache/mole/brew_last_cleanup"
    brew_cleanup_ran_recently "$brew_cache_file" && return 0
    if [[ "${DRY_RUN:-false}" != true ]]; then
        snapshot_homebrew_active_links || true
    fi
    local -a _brew_cleanup_roots=()
    local scope_rc=0
    brew_cleanup_scope_allowed || scope_rc=$?
    if mole_rc_signal "$scope_rc"; then
        _mole_record_clean_cancellation "$scope_rc" "Homebrew cleanup"
        return "$scope_rc"
    fi
    if [[ $scope_rc -ne 0 ]]; then
        if [[ $scope_rc -eq 2 ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · skipped (whitelist)"
            note_activity
        fi
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local dry_run_cleanup_file
        dry_run_cleanup_file=$(create_temp_file)
        local dry_run_cleanup_exit=0
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup..."; fi
        run_brew_cleanup_preview "$cleanup_timeout" "$dry_run_cleanup_file" || dry_run_cleanup_exit=$?
        if [[ -t 1 ]]; then stop_inline_spinner; fi
        if mole_rc_signal "$dry_run_cleanup_exit"; then
            _mole_record_clean_cancellation "$dry_run_cleanup_exit" "Homebrew cleanup"
            return "$dry_run_cleanup_exit"
        fi
        if [[ $dry_run_cleanup_exit -eq 0 ]]; then
            show_brew_cleanup_preview "$dry_run_cleanup_file" && note_activity
        elif mole_rc_timeout "$dry_run_cleanup_exit"; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew cleanup preview timed out · run ${GRAY}brew cleanup --dry-run${NC} manually"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew · would cleanup"
            note_activity
        fi
        # Autoremove sits after the window check in the real run too.
        local dry_run_autoremove_file
        dry_run_autoremove_file=$(create_temp_file)
        local dry_run_autoremove_exit=0
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Homebrew dependencies..."; fi
        run_brew_autoremove_preview "$autoremove_preview_timeout" "$dry_run_autoremove_file" || dry_run_autoremove_exit=$?
        if [[ -t 1 ]]; then stop_inline_spinner; fi
        if mole_rc_signal "$dry_run_autoremove_exit"; then
            _mole_record_clean_cancellation "$dry_run_autoremove_exit" "Homebrew cleanup"
            return "$dry_run_autoremove_exit"
        fi
        if [[ $dry_run_autoremove_exit -eq 0 ]] && brew_autoremove_preview_has_items "$dry_run_autoremove_file"; then
            show_brew_autoremove_preview "$dry_run_autoremove_file"
        elif mole_rc_timeout "$dry_run_autoremove_exit"; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview timed out · run ${GRAY}brew autoremove --dry-run${NC} manually"
        fi
        return 0
    fi
    # No size gate on ~/Library/Caches/Homebrew: most of what `brew cleanup`
    # frees is old formula versions in the Cellar, which that cache does not
    # hold. A cache someone already emptied (Mole's Mac app clears downloads)
    # kept this under the old 50MB gate forever while old versions piled up.
    # The 7-day window above bounds how often this runs.
    local brew_tmp_file
    local brew_exit=0
    brew_tmp_file=$(create_temp_file)
    if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup..."; fi
    # No color, as in the preview: HOMEBREW_COLOR colors even redirected
    # output, and the summary line is read back from this file.
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_COLOR=1 NONINTERACTIVE=1 \
        run_scoped_brew_cleanup "$cleanup_timeout" > "$brew_tmp_file" 2>&1 || brew_exit=$?
    if [[ -t 1 ]]; then stop_inline_spinner; fi
    restore_homebrew_active_links
    if mole_rc_signal "$brew_exit"; then
        # Ctrl-C while brew holds the terminal reaches only the child.
        debug_log "Homebrew cleanup: owner command interrupted (exit $brew_exit)"
        _mole_record_clean_cancellation "$brew_exit" "Homebrew cleanup"
        return "$brew_exit"
    fi

    local brew_success=false
    if [[ $brew_exit -eq 0 ]]; then
        brew_success=true
    fi

    # Process cleanup output and extract metrics
    # Summarize cleanup results.
    if [[ "$brew_success" == "true" && -f "$brew_tmp_file" ]]; then
        local brew_output
        brew_output=$(cat "$brew_tmp_file" 2> /dev/null || echo "")
        local removed_count freed_space freed_kb
        removed_count=$(printf '%s\n' "$brew_output" | grep -c "Removing:" 2> /dev/null || true)
        # The real run's twin of the line show_brew_cleanup_preview reads.
        freed_space=$(printf '%s\n' "$brew_output" |
            sed -n 's/^==> This operation has freed approximately \(.*\) of disk space\.$/\1/p' | tail -1 || true)
        freed_kb=$(brew_cleanup_size_kb "$freed_space")
        [[ -n "$freed_kb" ]] || freed_space=""
        if [[ $removed_count -gt 0 ]] || [[ -n "$freed_space" ]]; then
            if [[ -n "$freed_space" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup${NC} · ${GREEN}$freed_space${NC}"
                mole_add_cleaned_row "$removed_count" "$freed_kb"
                note_activity
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup · $(mole_count_label "${removed_count}" item)"
                note_activity
            fi
        fi
    elif mole_rc_timeout "$brew_exit"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew cleanup timed out · run ${GRAY}brew cleanup${NC} manually"
        note_activity
    fi
    local autoremove_preview_file
    autoremove_preview_file=$(create_temp_file)
    local autoremove_preview_exit=0
    if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Checking Homebrew dependencies..."; fi
    run_brew_autoremove_preview "$autoremove_preview_timeout" "$autoremove_preview_file" || autoremove_preview_exit=$?
    if [[ -t 1 ]]; then stop_inline_spinner; fi
    if mole_rc_signal "$autoremove_preview_exit"; then
        _mole_record_clean_cancellation "$autoremove_preview_exit" "Homebrew cleanup"
        return "$autoremove_preview_exit"
    fi
    if mole_rc_timeout "$autoremove_preview_exit"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview timed out · run ${GRAY}brew autoremove --dry-run${NC} manually"
        # Keep the manual-action guidance visible past the idle-section erase.
        note_activity
    elif [[ $autoremove_preview_exit -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview failed · run ${GRAY}brew autoremove --dry-run${NC} manually"
        note_activity
    elif brew_autoremove_preview_has_items "$autoremove_preview_file"; then
        show_brew_autoremove_preview "$autoremove_preview_file"
        note_activity
    fi
    # Stamp only a finished cleanup; a timed-out one resumes on the next run.
    if [[ "$brew_success" == "true" ]]; then
        ensure_user_file "$brew_cache_file"
        get_epoch_seconds > "$brew_cache_file"
    fi
}

# Homebrew service logs. `brew services` points nginx, php-fpm, redis,
# postgresql and friends at <prefix>/var/log, `brew cleanup` never touches
# that tree, and a user with several services can carry tens of MB there
# untouched for months. Only <prefix>/var/log is scanned; its siblings
# (var/mysql, var/postgresql@*, var/redis, var/lib, var/run) are databases
# and runtime state, and nothing below reaches them.
#
# A candidate is a log-shaped regular file (*.log, *.log.N, *.log.gz,
# *.log.N.gz) at most one directory below the root, with one link, owned by
# the invoking user, and older than MOLE_LOG_AGE_DAYS. A file any process
# holds open is kept: deleting a log a running service writes frees nothing
# and leaves the service writing to an unlinked inode. An open state that
# cannot be proven (no complete process view, timeout, lsof diagnostics) keeps
# every candidate.
_BREW_SERVICE_LOG_ROOT=""
_BREW_SERVICE_LOG_UID=""

brew_service_log_name_is_log() {
    local name="$1"
    case "$name" in
        *.log | *.log.gz) return 0 ;;
    esac
    [[ "$name" =~ \.log\.[0-9]+(\.gz)?$ ]]
}

# Print the physical <prefix>/var/log root. Returns 1 when Homebrew or the
# root is absent, symlinked, or the prefix lookup fails; a signal passes up.
brew_service_log_root() {
    local prefix=""
    local prefix_rc=0
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || prefix_rc=$?
    if mole_rc_signal "$prefix_rc"; then
        return "$prefix_rc"
    fi
    [[ $prefix_rc -eq 0 && "$prefix" == /* && -d "$prefix" ]] || return 1
    local physical_prefix=""
    physical_prefix=$(cd -P "$prefix" 2> /dev/null && pwd -P) || return 1
    local root="$physical_prefix/var/log"
    [[ -d "$root" && ! -L "$root" && ! -L "$physical_prefix/var" ]] || return 1
    local physical_root=""
    physical_root=$(cd -P "$root" 2> /dev/null && pwd -P) || return 1
    [[ "$physical_root" == "$root" ]] || return 1
    printf '%s\n' "$root"
}

# Re-read one candidate's metadata. Used for the plan and again at the sink,
# so a log a service reopened or rewrote since the scan is never removed.
brew_service_log_is_eligible() {
    local path="$1"
    local root="$_BREW_SERVICE_LOG_ROOT"
    [[ -n "$root" && -n "$_BREW_SERVICE_LOG_UID" ]] || return 1
    [[ "$path" == "$root"/* ]] || return 1
    local relative="${path#"$root"/}"
    [[ -n "$relative" && "$relative" != */*/* && "$relative" != *"/../"* &&
        "$relative" != ../* && "$relative" != */.. ]] || return 1
    # lsof -F reports one name per line, so a control character in a name
    # could split it into a record that matches another candidate.
    [[ "$relative" != *[[:cntrl:]]* ]] || return 1
    brew_service_log_name_is_log "${path##*/}" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    if [[ "$relative" == */* ]]; then
        local parent="${path%/*}"
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
    fi

    local meta=""
    meta=$("$STAT_BSD" -f '%u %l %m' "$path" 2> /dev/null) || return 1
    local owner links mtime
    read -r owner links mtime <<< "$meta"
    [[ "$owner" == "$_BREW_SERVICE_LOG_UID" && "$links" == "1" ]] || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    local now
    now=$(get_epoch_seconds)
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    # BSD `find -mtime +N`, which builds the plan, rounds up to whole days,
    # so it means strictly older than N days.
    [[ $((now - mtime)) -gt $((MOLE_LOG_AGE_DAYS * 86400)) ]]
}

# Print every candidate some process holds open. 0 = complete answer,
# 2 = unknown, any signal status passes up. Output is meaningful only on 0.
brew_service_logs_open_paths() {
    [[ $# -gt 0 ]] || return 0
    local visibility_rc=0
    _mole_complete_lsof_mode || visibility_rc=$?
    if mole_rc_signal "$visibility_rc"; then
        return "$visibility_rc"
    fi
    [[ $visibility_rc -eq 0 ]] || return 2

    local records=""
    local lsof_rc=0
    # MO_DEBUG=0: the captured stream is evidence, see _mole_paths_have_open_handle.
    records=$(MO_DEBUG=0 _mole_run_complete_lsof "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -F n -- "$@" 2>&1) || lsof_rc=$?
    if mole_rc_timeout "$lsof_rc"; then
        return 2
    fi
    if mole_rc_signal "$lsof_rc"; then
        return "$lsof_rc"
    fi
    # 1 with no records is "none open"; 1 with records is "some open".
    [[ $lsof_rc -eq 0 || $lsof_rc -eq 1 ]] || return 2
    [[ $lsof_rc -eq 1 || -n "$records" ]] || return 2

    local -a open_paths=()
    local line candidate matched
    while IFS= read -r line; do
        case "$line" in
            "") continue ;;
            p* | f*) continue ;;
            n*)
                # A name that is not exactly one candidate means lsof saw the
                # file through another spelling; nothing can be matched then.
                matched=false
                for candidate in "$@"; do
                    if [[ "${line#n}" == "$candidate" ]]; then
                        matched=true
                        break
                    fi
                done
                [[ "$matched" == "true" ]] || return 2
                open_paths+=("${line#n}")
                ;;
            *) return 2 ;;
        esac
    done <<< "$records"
    [[ ${#open_paths[@]} -gt 0 ]] && printf '%s\n' "${open_paths[@]}"
    return 0
}

# safe_clean_guarded callback: recheck metadata and, before a real removal,
# the open state, then bind the approved object for safe_remove's final
# identity check. A refusal skips only this file.
_brew_service_log_delete_guard() {
    local path="$1"
    _MOLE_SAFE_CLEAN_SKIP_PATH="$path"
    brew_service_log_is_eligible "$path" || return 1
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _MOLE_SAFE_CLEAN_SKIP_PATH=""
        return 0
    fi

    _mole_snapshot_path_identity "$path" || return 1
    # The root is physical, so a parent that resolves elsewhere was swapped
    # for a link after the eligibility check; never bind that object.
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "${path%/*}" ]] || return 1
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    local open_rc=0
    _mole_paths_have_open_handle "$path" || open_rc=$?
    if mole_rc_signal "$open_rc"; then
        return "$open_rc"
    fi
    [[ $open_rc -eq 1 ]] || return 1
    _mole_path_matches_identity "$path" "$expected_parent" \
        "$expected_parent_id" "$expected_target_id" || return 1

    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$expected_parent"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$expected_parent_id"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$expected_target_id"
    _MOLE_SAFE_CLEAN_SKIP_PATH=""
    return 0
}

clean_homebrew_service_logs() {
    command -v brew > /dev/null 2>&1 || return 0
    # User-owned files only, never a privileged removal.
    is_root_user && return 0

    local root=""
    local root_rc=0
    root=$(brew_service_log_root) || root_rc=$?
    if mole_rc_signal "$root_rc"; then
        return "$root_rc"
    fi
    [[ $root_rc -eq 0 && -n "$root" ]] || return 0
    _BREW_SERVICE_LOG_ROOT="$root"
    _BREW_SERVICE_LOG_UID=$(id -u)

    local scan_file=""
    scan_file=$(create_temp_file) || return 0
    local scan_rc=0
    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" find "$root" \
        -mindepth 1 -maxdepth 2 -type f -links 1 -user "$_BREW_SERVICE_LOG_UID" \
        \( -name '*.log' -o -name '*.log.*' \) -mtime +"$MOLE_LOG_AGE_DAYS" \
        -print0 < /dev/null > "$scan_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        if mole_rc_signal "$scan_rc"; then
            return "$scan_rc"
        fi
        debug_log "Homebrew service logs: scan incomplete (status $scan_rc), keep all"
        return 0
    fi

    local -a candidates=()
    local path
    while IFS= read -r -d '' path; do
        brew_service_log_is_eligible "$path" && candidates+=("$path")
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    [[ ${#candidates[@]} -gt 0 ]] || return 0

    local open_list=""
    local open_rc=0
    open_list=$(brew_service_logs_open_paths "${candidates[@]}") || open_rc=$?
    if mole_rc_signal "$open_rc"; then
        return "$open_rc"
    fi
    if [[ $open_rc -ne 0 ]]; then
        debug_log "Homebrew service logs: open state unknown, keep ${#candidates[@]} files"
        return 0
    fi

    local -a idle=()
    local padded_open=$'\n'"$open_list"$'\n'
    for path in "${candidates[@]}"; do
        if [[ "$padded_open" == *$'\n'"$path"$'\n'* ]]; then
            debug_log "Homebrew service log in use, keep: $path"
            continue
        fi
        idle+=("$path")
    done
    [[ ${#idle[@]} -gt 0 ]] || return 0

    local guarded_rc=0
    safe_clean_guarded _brew_service_log_delete_guard \
        "${idle[@]}" "Homebrew service logs" || guarded_rc=$?
    # 75 means the guard stopped the batch; every refusal above is per file.
    [[ $guarded_rc -eq 75 ]] && return 0
    return "$guarded_rc"
}
