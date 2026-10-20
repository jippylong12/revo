#!/usr/bin/env bash
# Revo CLI - detect command
# Bootstraps a workspace around git repos that already exist in the current
# directory (and under repos/) without prompting: the workspace is named after
# the directory, repos are registered with the same auto-detection `revo init`
# uses, and the agent files are generated immediately.

cmd_detect() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                printf 'Usage: revo detect\n\n'
                printf 'Auto-detect git repositories in the current directory and\n'
                printf 'bootstrap a revo workspace around them without prompts.\n'
                printf 'Generates revo.yaml and the configured agent files.\n'
                return 0
                ;;
            *)
                ui_step_error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -f "revo.yaml" ]] || [[ -f "mars.yaml" ]]; then
        ui_step_error "Workspace already initialized — run 'revo context' to regenerate agent files"
        return 1
    fi

    ui_intro "Revo - Detect Existing Repositories"

    # Initialize the workspace using the cwd basename. This sets
    # REVO_WORKSPACE_ROOT/REVO_CONFIG_FILE/REVO_REPOS_DIR and writes an empty
    # revo.yaml + .gitignore.
    local default_name
    default_name=$(basename "$PWD")
    if ! config_init "$default_name"; then
        ui_step_error "Failed to initialize workspace"
        return 1
    fi

    _init_detect_repos

    if [[ $_INIT_DETECTED_COUNT -eq 0 ]]; then
        rm -f "$REVO_CONFIG_FILE"
        ui_step_error "No git repos with a remote found here. Use 'revo init' instead."
        ui_outro_cancel "Nothing to detect"
        return 1
    fi

    config_save
    ui_step_done "Detected:" "$_INIT_DETECTED_COUNT repository(ies)"
    ui_info "$(ui_dim "Edit revo.yaml to adjust tags or add depends_on relationships")"
    ui_bar_line

    cmd_context --auto
}
