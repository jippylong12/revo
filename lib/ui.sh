#!/usr/bin/env bash
# Revo CLI - UI Components (Clack-style)
# Provides terminal UI primitives with Unicode/ASCII fallback

# Detect color support
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    UI_COLOR=1
else
    UI_COLOR=0
fi

# Detect Unicode support
if [[ "${LANG:-}" == *UTF-8* ]] || [[ "${LC_ALL:-}" == *UTF-8* ]]; then
    UI_UNICODE=1
else
    UI_UNICODE=0
fi

# --- Symbols ---
if [[ "$UI_UNICODE" -eq 1 ]]; then
    S_STEP_ACTIVE="◆"
    S_STEP_DONE="◇"
    S_STEP_ERROR="▲"
    S_BAR="│"
    S_BAR_START="┌"
    S_BAR_END="└"
    S_SPINNER_FRAMES=("◒" "◐" "◓" "◑")
    S_TABLE_RULE="─"
else
    S_STEP_ACTIVE="*"
    S_STEP_DONE="+"
    S_STEP_ERROR="!"
    S_BAR="|"
    S_BAR_START="/"
    S_BAR_END="\\"
    S_SPINNER_FRAMES=("-" "\\" "|" "/")
    S_TABLE_RULE="-"
fi

# --- Colors ---
ui_cyan() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[36m%s\033[0m' "$1" || printf '%s' "$1"
}

ui_green() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"
}

ui_yellow() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[33m%s\033[0m' "$1" || printf '%s' "$1"
}

ui_red() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"
}

ui_dim() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"
}

ui_bold() {
    [[ "$UI_COLOR" -eq 1 ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"
}

# --- Bar Components ---
ui_bar() {
    ui_dim "$S_BAR"
}

ui_bar_start() {
    ui_dim "$S_BAR_START"
}

ui_bar_end() {
    ui_dim "$S_BAR_END"
}

# --- Layout Components ---

# Intro: Start of a section
# Usage: ui_intro "Title"
ui_intro() {
    local title="$1"
    printf '%s  %s\n' "$(ui_bar_start)" "$(ui_cyan "$title")"
    printf '%s\n' "$(ui_bar)"
}

# Outro: End of a section
# Usage: ui_outro "Message"
ui_outro() {
    local message="$1"
    printf '%s\n' "$(ui_bar)"
    printf '%s  %s\n' "$(ui_bar_end)" "$(ui_green "$message")"
}

# Outro with cancel
ui_outro_cancel() {
    local message="$1"
    printf '%s\n' "$(ui_bar)"
    printf '%s  %s\n' "$(ui_bar_end)" "$(ui_red "$message")"
}

# Step: Active prompt
# Usage: ui_step "Label"
ui_step() {
    local label="$1"
    printf '%s  %s\n' "$(ui_cyan "$S_STEP_ACTIVE")" "$label"
}

# Step done: Completed step
# Usage: ui_step_done "Label" "value"
ui_step_done() {
    local label="$1"
    local value="${2:-}"
    if [[ -n "$value" ]]; then
        printf '%s  %s %s\n' "$(ui_green "$S_STEP_DONE")" "$label" "$(ui_dim "$value")"
    else
        printf '%s  %s\n' "$(ui_green "$S_STEP_DONE")" "$label"
    fi
}

# Step error
ui_step_error() {
    local message="$1"
    printf '%s  %s\n' "$(ui_yellow "$S_STEP_ERROR")" "$(ui_yellow "$message")"
}

# Info line (continuation)
ui_info() {
    local message="$1"
    printf '%s  %s\n' "$(ui_bar)" "$message"
}

# Empty bar line
ui_bar_line() {
    printf '%s\n' "$(ui_bar)"
}

# --- Spinner ---
# Usage:
#   ui_spinner_start "Loading..."
#   ... do work ...
#   ui_spinner_stop "Done!" # or ui_spinner_stop
_SPINNER_PID=""
_SPINNER_MSG=""

ui_spinner_start() {
    local message="$1"
    _SPINNER_MSG="$message"

    # Skip spinner animation when stdout is not a terminal (piped/redirected)
    if [[ ! -t 1 ]]; then
        return
    fi

    (
        local i=0
        local frame_count=${#S_SPINNER_FRAMES[@]}

        while true; do
            printf '\r%s  %s %s' "$(ui_bar)" "$(ui_cyan "${S_SPINNER_FRAMES[$i]}")" "$message"
            ((i = (i + 1) % frame_count))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
}

ui_spinner_stop() {
    local final_message="${1:-}"

    if [[ -n "$_SPINNER_PID" ]] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
    fi
    _SPINNER_PID=""

    # Clear spinner line only when connected to a terminal
    if [[ -t 1 ]]; then
        printf '\r\033[K'
    fi

    # Show final message if provided
    if [[ -n "$final_message" ]]; then
        ui_step_done "$final_message"
    fi
}

ui_spinner_error() {
    local message="$1"

    if [[ -n "$_SPINNER_PID" ]] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
    fi
    _SPINNER_PID=""

    if [[ -t 1 ]]; then
        printf '\r\033[K'
    fi
    ui_step_error "$message"
}

# --- Progress ---
# Usage: ui_progress "message" current total
ui_progress() {
    local message="$1"
    local current="$2"
    local total="$3"
    local percent=$((current * 100 / total))
    local bar_width=20
    local filled=$((percent * bar_width / 100))
    local empty=$((bar_width - filled))

    printf '\r%s  ' "$(ui_bar)"
    printf '%s [' "$message"
    printf '%*s' "$filled" '' | tr ' ' '='
    printf '%*s' "$empty" '' | tr ' ' ' '
    printf '] %d%%' "$percent"
}

# --- ANSI-aware padding ---

_ui_visible_len() {
    local str="$1"
    local stripped
    stripped=$(printf '%s' "$str" | sed $'s/\033\\[[0-9;]*m//g')
    printf '%d' "${#stripped}"
}

_ui_pad() {
    local str="$1"
    local target_width="$2"
    local visible_len
    visible_len=$(_ui_visible_len "$str")
    local pad=$((target_width - visible_len))
    [[ $pad -lt 0 ]] && pad=0
    printf '%s%*s' "$str" "$pad" ""
}

# --- Table ---
# Usage: ui_table_widths 24 20 12 14
#        ui_table_header "Col1" "Col2" "Col3" "Col4"
#        ui_table_row "val1" "val2" "val3" "val4"
_TABLE_COL_WIDTHS=()

ui_table_widths() {
    _TABLE_COL_WIDTHS=("$@")
}

ui_table_header() {
    local cols=("$@")
    local i=0

    printf '%s  ' "$(ui_bar)"
    for col in "${cols[@]}"; do
        local w="${_TABLE_COL_WIDTHS[$i]:-20}"
        local padded
        padded=$(printf "%-${w}s" "$col")
        printf '%s' "$(ui_bold "$padded")"
        i=$((i + 1))
    done
    printf '\n'

    # Separator
    printf '%s  ' "$(ui_bar)"
    i=0
    for _ in "${cols[@]}"; do
        local w="${_TABLE_COL_WIDTHS[$i]:-20}"
        local dashes=""
        local j=0
        while [[ $j -lt $w ]]; do
            dashes+="$S_TABLE_RULE"
            j=$((j + 1))
        done
        printf '%s' "$(ui_dim "$dashes")"
        i=$((i + 1))
    done
    printf '\n'
}

ui_table_row() {
    local vals=("$@")
    local i=0

    printf '%s  ' "$(ui_bar)"
    for val in "${vals[@]}"; do
        local w="${_TABLE_COL_WIDTHS[$i]:-20}"
        _ui_pad "$val" "$w"
        i=$((i + 1))
    done
    printf '\n'
}

# --- Exit cleanup ---

# Show cursor
ui_cursor_show() {
    [[ -t 1 ]] || return 0
    printf '\033[?25h'
}

# Kill a running spinner and restore the cursor when the script exits for
# any reason. One trap for both so neither registration clobbers the other.
_ui_exit_cleanup() {
    if [[ -n "${_SPINNER_PID:-}" ]] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
        [[ -t 1 ]] && printf '\r\033[K'
    fi
    ui_cursor_show
}
trap '_ui_exit_cleanup' EXIT
