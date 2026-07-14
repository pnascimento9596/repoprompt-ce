#!/usr/bin/env bash
set -euo pipefail

APP_PROCESS_NAME="${1:-RepoPrompt}"
WAIT_SECONDS="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT:-3}"
OPEN_CLOSE_CYCLES="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES:-3}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$WAIT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "Wait must be a non-negative number: $WAIT_SECONDS"
[[ "$OPEN_CLOSE_CYCLES" =~ ^[1-9][0-9]*$ ]] || fail "Cycle count must be a positive integer: $OPEN_CLOSE_CYCLES"

osascript - "$APP_PROCESS_NAME" "$WAIT_SECONDS" "$OPEN_CLOSE_CYCLES" <<'APPLESCRIPT'
on firstElementWithIdentifier(containerRef, targetIdentifier)
    tell application "System Events"
        try
            set candidateIdentifier to value of attribute "AXIdentifier" of containerRef
            if candidateIdentifier is not missing value and candidateIdentifier as text is targetIdentifier then return containerRef
        end try
        try
            repeat with childRef in UI elements of containerRef
                set foundRef to my firstElementWithIdentifier(childRef, targetIdentifier)
                if foundRef is not missing value then return foundRef
            end repeat
        end try
    end tell
    return missing value
end firstElementWithIdentifier

on waitForElement(processRef, targetIdentifier, shouldExist)
    repeat 40 times
        set foundRef to my firstElementWithIdentifier(processRef, targetIdentifier)
        if shouldExist and foundRef is not missing value then return foundRef
        if not shouldExist and foundRef is missing value then return missing value
        delay 0.1
    end repeat
    if shouldExist then error "Could not find accessibility element " & targetIdentifier
    error "Accessibility element remained visible after popover close: " & targetIdentifier
end waitForElement

on assertHostSurvived(appProcessName, originalPID, originalWindow)
    tell application "System Events"
        if not (exists process appProcessName) then error appProcessName & " process exited during execution-location UI smoke"
        tell process appProcessName
            if unix id is not originalPID then error appProcessName & " restarted during execution-location UI smoke"
            if not (exists originalWindow) then error appProcessName & " lost the original host window during execution-location UI smoke"
        end tell
    end tell
end assertHostSurvived

on run argv
    set appProcessName to item 1 of argv
    set waitSeconds to item 2 of argv as number
    set openCloseCycles to item 3 of argv as integer

    tell application "System Events"
        if not (exists process appProcessName) then error appProcessName & " process is not running"
        tell process appProcessName
            set frontmost to true
            repeat 30 times
                if exists window 1 then exit repeat
                delay 0.2
            end repeat
            if not (exists window 1) then error appProcessName & " has no front window"
            set originalPID to unix id
            set originalWindow to window 1
        end tell
    end tell

    repeat with cycleIndex from 1 to openCloseCycles
        tell application "System Events"
            set processRef to process appProcessName
            set pillButton to my waitForElement(processRef, "agent-execution-location-pill", true)
            click pillButton

            -- Requiring both built-in options makes the smoke fail rather than pass vacuously
            -- when the pill click did not actually open its popover.
            my waitForElement(processRef, "agent-execution-location-option-local", true)
            my waitForElement(processRef, "agent-execution-location-option-new-worktree", true)
        end tell

        -- Leave the popover open while the async existing-worktree load replaces loading content.
        delay waitSeconds
        my assertHostSurvived(appProcessName, originalPID, originalWindow)

        tell application "System Events"
            set processRef to process appProcessName
            my waitForElement(processRef, "agent-execution-location-option-local", true)
            my waitForElement(processRef, "agent-execution-location-option-new-worktree", true)
            key code 53
            my waitForElement(processRef, "agent-execution-location-option-local", false)
            my waitForElement(processRef, "agent-execution-location-option-new-worktree", false)
        end tell

        my assertHostSurvived(appProcessName, originalPID, originalWindow)
    end repeat
end run
APPLESCRIPT

printf 'OK: Agent execution-location popover survived %s open/close cycles for process %s.\n' "$OPEN_CLOSE_CYCLES" "$APP_PROCESS_NAME"
