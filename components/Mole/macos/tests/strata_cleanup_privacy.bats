#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_home strata-privacy
    mkdir -p "$HOME/.config/mole"
}

teardown() {
    mole_test_teardown_home
}

@test "Strata omits protected project roots before discovery and prunes nested Photos libraries" {
    mkdir -p "$HOME/Projects/app/__pycache__" "$HOME/Desktop/private" \
        "$HOME/Downloads/from-web" "$HOME/Documents/work" "$HOME/Pictures" \
        "$HOME/Other/Family.photoslibrary/album/__pycache__" "$HOME/Projects/Trip.PhotoLibrary/item/__pycache__"
    touch "$HOME/Desktop/private/Makefile" "$HOME/Documents/work/Makefile" "$HOME/Downloads/from-web/Makefile" \
        "$HOME/Other/Family.photoslibrary/album/Makefile" "$HOME/Projects/app/Makefile"
    touch "$HOME/Projects/app/__pycache__/mod.pyc" "$HOME/Projects/Trip.PhotoLibrary/item/__pycache__/mod.pyc"
    ln -s "$HOME/Documents" "$HOME/RepoAlias"
    printf '%s\n' "$HOME/Desktop/private" "$HOME/Documents/work" "$HOME/RepoAlias/work" "$HOME" \
        "/System/Volumes/Data$HOME/Desktop" "$HOME/Pictures" "$HOME/../outside" > "$HOME/.config/mole/purge_paths"

    run env _MOLE_STRATA_GUI=1 /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
roots=$(discover_project_cache_roots)
[[ "$roots" == "$HOME/Projects" ]] || { printf 'unexpected roots: %s\n' "$roots"; exit 1; }
project_cache_has_indicators "$HOME/Other" 5 && exit 1
unset _MOLE_STRATA_GUI
project_cache_has_indicators "$HOME/Other" 5 || exit 1
export _MOLE_STRATA_GUI=1
scan_project_cache_root "$HOME/Projects" "$HOME/result"
cat "$HOME/result"
RUN
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/Projects/app/__pycache__"* ]] || return 1
    [[ "$output" != *"Trip.PhotoLibrary"* ]] || return 1
}

@test "Strata avoids unselected download and home sweeps while terminal cleanup still reaches their probes" {
    mkdir -p "$HOME/Downloads" "$HOME/Desktop" "$HOME/.codex/worktrees"
    touch "$HOME/Downloads/fixture.part"
    run /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
source "$PROJECT_ROOT/lib/clean/hints.sh"
PROTECT_FINDER_METADATA=false
clean_ds_store_tree() { echo "finder $1"; }
_mole_paths_have_open_handle() { echo "download $1"; return 0; }
note_activity() { :; }
for client in 1 0; do
    export _MOLE_STRATA_GUI="$client"
    printf 'client %s\n' "$client"
    clean_finder_metadata
    _clean_incomplete_downloads
    agent_worktree_containers | tr '\0' '\n'
done
RUN
    [ "$status" -eq 0 ]
    [[ "$output" == "client 1"$'\n'"client 0"$'\n'* ]] || return 1
    [[ "$output" == *"finder $HOME"* && "$output" == *"download $HOME/Downloads/fixture.part"* && "$output" == *"$HOME/.codex/worktrees"* ]] || return 1
}

@test "Strata checks LaunchAgent program paths before following aliases or probing a private directory" {
    mkdir -p "$HOME/Desktop" "$HOME/Work" "$HOME/Library/LaunchAgents"
    touch "$HOME/Library/LaunchAgents/check.plist"
    ln -s "$HOME/Desktop" "$HOME/Work/alias"
    run env _MOLE_STRATA_GUI=1 /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
for target in "$HOME/Work/alias/tool" "$HOME/Pictures/album" "$HOME/Work/X.PhotosLibrary/tool" \
    "$HOME/DoCuMeNtS/tool" "/System/Volumes/Data$HOME/Downloads/tool" "$HOME/Work/../Desktop/tool"; do
    if mole_strata_allows_probe "$target" program; then echo "$target"; exit 1; fi
done
mole_strata_allows_probe "$HOME/Work/tool" program || exit 1
mole_strata_allows_probe "/usr/bin/true" program || exit 1
source "$PROJECT_ROOT/lib/clean/apps.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
MOLE_OPTIMIZE_TASK_ACTIVE=1
run_with_timeout() { printf '%s\n' "$HOME/Work/A.PHOTOSLIBRARY/bin/tool"; }
if _mole_launch_agent_path_provably_missing "$HOME/Work/A.PHOTOSLIBRARY/bin/tool"; then exit 1; fi
opt_launch_agents_cleanup
[[ "$MOLE_OPTIMIZE_TASK_OUTCOME" == "$MOLE_OPTIMIZE_OUTCOME_SKIPPED" ]] || exit 1
echo "safe program probes retained"
RUN
    [ "$status" -eq 0 ]
    [[ "$output" == *"safe program probes retained"* ]] || return 1
}

@test "Strata clean preview and execution skip cached sudo before system work" {
    run /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
export _MOLE_STRATA_GUI=1
adopt_sudo_session() { echo adopted >> "$HOME/admin"; return 0; }
for DRY_RUN in true false; do
    SYSTEM_CLEAN=true
    start_cleanup
    [[ "$SYSTEM_CLEAN" == false ]] || exit 1
done
[[ ! -e "$HOME/admin" ]] || exit 1
unset _MOLE_STRATA_GUI
DRY_RUN=false
start_cleanup
[[ "$SYSTEM_CLEAN" == true && -s "$HOME/admin" ]] || exit 1
echo "terminal adopted mock sudo"
RUN
    [ "$status" -eq 0 ]
    [[ "$output" == *"terminal adopted mock sudo"* ]] || return 1
}

@test "Strata preview binds its exported paths to the current candidate digest" {
    run env _MOLE_STRATA_GUI=1 /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=true
export MOLE_DRY_RUN=1
# Use a single isolated section to exercise the real ledger and summary.
EXTERNAL_VOLUME_TARGET="$HOME/fixture"
mkdir -p "$EXTERNAL_VOLUME_TARGET"
touch "$EXTERNAL_VOLUME_TARGET/sample"
clean_external_volume_target() { append_dry_run_cleanup_target "$1/sample" 100 1 true; }
start_cleanup
perform_cleanup
RUN
    [ "$status" -eq 0 ]
    local preview="$HOME/.config/mole/clean-list.txt"
    grep -F "$HOME/fixture/sample  #" "$preview"
    local digest
    digest=$(sed -n 's/^# Candidate digest: //p' "$preview")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$output" == *"Candidate digest: $digest"* ]] || return 1
}

@test "Strata candidate digest ignores record order and retains path identities" {
    run /bin/bash --noprofile --norc <<'RUN'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
CLEAN_PREVIEW_LEDGER_FILE="$HOME/ledger"
record() { printf '%s\0%s\0%s\0%s\0%s\0%s\0' "$1" 4 1 true Section "$2"; }
{ record inode:42 /first; record inode:43 /second; } > "$CLEAN_PREVIEW_LEDGER_FILE"
original=$(strata_candidate_digest)
[[ "$original" =~ ^[0-9a-f]{64}$ ]] || exit 1
{ record inode:43 /second; record inode:42 /first; } > "$CLEAN_PREVIEW_LEDGER_FILE"
[[ "$(strata_candidate_digest)" == "$original" ]] || exit 1
{ record inode:43 /second; record inode:44 /first; } > "$CLEAN_PREVIEW_LEDGER_FILE"
[[ "$(strata_candidate_digest)" != "$original" ]] || exit 1
printf 'truncated' >> "$CLEAN_PREVIEW_LEDGER_FILE"
if strata_candidate_digest; then exit 1; fi
echo "candidate comparisons passed"
RUN
    [ "$status" -eq 0 ]
    [[ "$output" == *"candidate comparisons passed"* ]] || return 1
}
