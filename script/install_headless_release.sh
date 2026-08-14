#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
REPOSITORY="${TARTELET_RELEASE_REPOSITORY:-mzkmnk/tartelet}"
APP_NAME="TarteletHeadless"
BUNDLE_ID="com.mzkmnk.TarteletHeadless"
EXPECTED_TEAM_ID="${TARTELET_DEVELOPER_ID_TEAM_ID:-RRSM3L23N3}"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LAUNCH_AGENT_TARGET="gui/$(id -u)/$BUNDLE_ID"
VM_NAME="${TARTELET_CANARY_VM_NAME:-}"
RUNNER_IDLE_COMMAND='pgrep -x Runner.Worker >/dev/null && exit 1; exit 0'
INSTALL_TRANSITION_STARTED=false
INSTALL_SUCCEEDED=false
PREVIOUS_APP_MOVED=false
# shellcheck disable=SC2016
# HOME must expand inside the guest, not on the host.
RUNNER_READY_COMMAND='test -f "$HOME/actions-runner/.runner" && pgrep -x Runner.Listener >/dev/null'

tart_run_matches_vm() {
    local require_no_graphics="$1"
    local process_id
    local command
    while IFS= read -r process_id; do
        command="$(ps -p "$process_id" -o command=)"
        if [[ "$command" == *"tart run"* && "$command" == *" $VM_NAME" ]]; then
            if [[ "$require_no_graphics" == false || "$command" == *"--no-graphics"* ]]; then
                return 0
            fi
        fi
    done < <(pgrep -x tart || true)
    return 1
}

tart_run_count() {
    local process_id
    local command
    local count=0
    while IFS= read -r process_id; do
        command="$(ps -p "$process_id" -o command=)"
        if [[ "$command" == *"tart run"* ]]; then
            count=$((count + 1))
        fi
    done < <(pgrep -x tart || true)
    echo "$count"
}

detect_single_running_vm() {
    tart list --format json \
        | jq -er \
            '[.[] | select(.Running == true) | .Name] | if length == 1 then .[0] else error("expected one running VM") end'
}

vm_exists() {
    local inventory
    local jq_status

    inventory="$(tart list --format json)" || return 2
    if jq -e --arg vm "$VM_NAME" 'any(.[]; .Name == $vm)' \
        <<< "$inventory" >/dev/null; then
        return 0
    else
        jq_status=$?
    fi
    if [[ "$jq_status" -eq 1 ]]; then
        return 1
    fi
    return 2
}

wait_for_runner_processes_to_stop() {
    for _ in {1..450}; do
        if ! pgrep -x "$APP_NAME" >/dev/null \
            && ! tart_run_matches_vm false; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

delete_stale_vm() {
    local vm_status

    if vm_exists; then
        echo "Removing stale ephemeral VM $VM_NAME."
        tart delete "$VM_NAME"
    else
        vm_status=$?
        if [[ "$vm_status" -ne 1 ]]; then
            return 1
        fi
    fi
    if vm_exists; then
        return 1
    else
        vm_status=$?
        [[ "$vm_status" -eq 1 ]]
    fi
}

wait_for_headless_app() {
    for _ in {1..120}; do
        if [[ "$(tart_run_count)" -eq 1 ]] \
            && pgrep -x "$APP_NAME" >/dev/null \
            && tart_run_matches_vm true; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_runner_listener() {
    for _ in {1..120}; do
        if printf '%s\n' "$RUNNER_READY_COMMAND" \
            | tart exec -i "$VM_NAME" /bin/zsh 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restore_previous_runner() {
    local failed_app="$HOME/.Trash/$APP_NAME-failed-$VERSION-$TIMESTAMP.app"

    launchctl bootout "$LAUNCH_AGENT_TARGET" 2>/dev/null || true
    if ! wait_for_runner_processes_to_stop; then
        echo "Rollback could not stop the failed runner; previous app remains at $BACKUP_APP." >&2
        return 1
    fi
    if ! delete_stale_vm; then
        echo "Rollback could not remove the failed ephemeral VM; previous app remains at $BACKUP_APP." >&2
        return 1
    fi
    if [[ "$PREVIOUS_APP_MOVED" == true ]]; then
        if [[ -e "$INSTALLED_APP" ]]; then
            mv "$INSTALLED_APP" "$failed_app"
        elif [[ -e "$STAGED_APP" ]]; then
            mv "$STAGED_APP" "$failed_app"
        fi
        mv "$BACKUP_APP" "$INSTALLED_APP"
    elif [[ -e "$STAGED_APP" ]]; then
        mv "$STAGED_APP" "$failed_app"
    fi
    if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"; then
        echo "Rollback preserved the previous app but could not restart its LaunchAgent." >&2
        return 1
    fi
    if ! wait_for_headless_app || ! wait_for_runner_listener; then
        echo "Rollback preserved the previous app, but its runner canary failed." >&2
        return 1
    fi
    echo "Install failed; the previous app and runner were restored." >&2
}

recover_on_exit() {
    local exit_status=$?

    trap - EXIT
    if [[ "$exit_status" -ne 0 \
        && "$INSTALL_TRANSITION_STARTED" == true \
        && "$INSTALL_SUCCEEDED" == false ]]; then
        set +e
        restore_previous_runner
    fi
    exit "$exit_status"
}

trap recover_on_exit EXIT

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <release-version>" >&2
    exit 2
fi

ASSET_NAME="$APP_NAME-$VERSION-macos-arm64.zip"
CHECKSUM_NAME="$ASSET_NAME.sha256"
DOWNLOAD_DIR="$(mktemp -d "/tmp/tartelet-headless-install.$VERSION.XXXXXX")"
EXTRACT_DIR="$DOWNLOAD_DIR/extracted"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
INSTALLED_APP="/Applications/$APP_NAME.app"
STAGED_APP="/Applications/$APP_NAME.new-$TIMESTAMP.app"
BACKUP_APP="$HOME/.Trash/$APP_NAME-pre-$VERSION-$TIMESTAMP.app"
mkdir -p "$EXTRACT_DIR"

gh release download "$VERSION" \
    --repo "$REPOSITORY" \
    --dir "$DOWNLOAD_DIR" \
    --pattern "$ASSET_NAME" \
    --pattern "$CHECKSUM_NAME"
(
    cd "$DOWNLOAD_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME"
)
ditto -x -k "$DOWNLOAD_DIR/$ASSET_NAME" "$EXTRACT_DIR"

NEW_APP="$EXTRACT_DIR/$APP_NAME.app"
INFO_PLIST="$NEW_APP/Contents/Info.plist"
test -d "$NEW_APP"
test "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" = "$BUNDLE_ID"
test "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" = "$VERSION"
test "$(plutil -extract TarteletHeadlessBuild raw "$INFO_PLIST")" = true
test "$(plutil -extract LSMultipleInstancesProhibited raw "$INFO_PLIST")" = true
codesign --verify --deep --strict --verbose=2 "$NEW_APP"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$NEW_APP" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$SIGNATURE_DETAILS"
grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$SIGNATURE_DETAILS"
test "$(lipo -archs "$NEW_APP/Contents/MacOS/$APP_NAME")" = arm64
xcrun stapler validate "$NEW_APP"
spctl --assess --type execute --verbose=4 "$NEW_APP"

if [[ -z "$VM_NAME" ]]; then
    VM_NAME="$(detect_single_running_vm)"
fi
if ! printf '%s\n' "$RUNNER_IDLE_COMMAND" \
    | tart exec -i "$VM_NAME" /bin/zsh; then
    echo "The GitHub Actions runner is busy; refusing to replace the app." >&2
    exit 1
fi
if [[ "$(tart_run_count)" -ne 1 ]] || ! tart_run_matches_vm false; then
    echo "This installer requires exactly one running VM named $VM_NAME." >&2
    exit 1
fi

test -f "$LAUNCH_AGENT_PLIST"
test -d "$INSTALLED_APP"
test -d "$HOME/.Trash"
test ! -e "$STAGED_APP"
test ! -e "$BACKUP_APP"
if ! printf '%s\n' "$RUNNER_IDLE_COMMAND" \
    | tart exec -i "$VM_NAME" /bin/zsh; then
    echo "The GitHub Actions runner became busy; refusing to replace the app." >&2
    exit 1
fi
launchctl bootout "$LAUNCH_AGENT_TARGET"
INSTALL_TRANSITION_STARTED=true
if ! wait_for_runner_processes_to_stop; then
    echo "The existing runner did not stop cleanly within 45 seconds." >&2
    exit 1
fi
if ! delete_stale_vm; then
    echo "The existing ephemeral VM could not be removed." >&2
    exit 1
fi

/usr/bin/ditto "$NEW_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
mv "$INSTALLED_APP" "$BACKUP_APP"
PREVIOUS_APP_MOVED=true
mv "$STAGED_APP" "$INSTALLED_APP"

if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"; then
    echo "The new app's LaunchAgent could not be started." >&2
    exit 1
fi

if ! wait_for_headless_app; then
    echo "The new headless app did not start within 120 seconds." >&2
    exit 1
fi

if ! wait_for_runner_listener; then
    echo "The new runner listener did not become ready within 120 seconds." >&2
    exit 1
fi

INSTALL_SUCCEEDED=true
echo "Installed $APP_NAME $VERSION; runner listener is ready."
echo "Previous app backup: $BACKUP_APP"
echo "Downloaded files retained at $DOWNLOAD_DIR"
