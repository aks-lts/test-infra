#!/usr/bin/env bash

# Library: TOC utilities for CHANGELOG files preserving MUNGE markers.
# Provides function update_changelog_toc <markdown_file>

update_changelog_toc() {
    local mdFile="$1"
    if [[ -z "$mdFile" ]]; then
        echo "TOC: missing file argument" >&2; return 1
    fi
    if [[ ! -f "$mdFile" ]]; then
        echo "TOC: file not found: $mdFile" >&2; return 1
    fi

    # Ensure mdtoc installed (lightweight idempotent installer into ~/.local/bin if writable, else /tmp)
    if ! command -v mdtoc >/dev/null 2>&1; then
        echo "TOC: installing mdtoc v1.4.0" >&2
        local inst_dir
        if [[ -w "$HOME/.local/bin" ]]; then
            inst_dir="$HOME/.local/bin"
        elif [[ -w /usr/local/bin ]]; then
            inst_dir="/usr/local/bin"
        else
            inst_dir="$HOME/.local/bin"; mkdir -p "$HOME/.local/bin"
        fi
        mkdir -p /tmp/mdtoc.$$ && pushd /tmp/mdtoc.$$ >/dev/null 2>&1 || return 1
        wget -q https://github.com/kubernetes-sigs/mdtoc/releases/download/v1.4.0/mdtoc-amd64-linux -O mdtoc || { popd; return 1; }
        chmod +x mdtoc && mv mdtoc "$inst_dir/" || { popd; return 1; }
        popd >/dev/null 2>&1
        rm -rf /tmp/mdtoc.$$
        # Add to PATH for current shell if needed
        case ":$PATH:" in
            *":$inst_dir:"*) ;; 
            *) export PATH="$inst_dir:$PATH";;
        esac
    fi

    if ! command -v mdtoc >/dev/null 2>&1; then
        echo "TOC: mdtoc not available after install attempt" >&2
        return 1
    fi

    # Temporary replace markers for mdtoc tool
    sed -i 's/<!-- BEGIN MUNGE: GENERATED_TOC -->/<!-- toc -->/g' "$mdFile"
    sed -i 's|<!-- END MUNGE: GENERATED_TOC -->|<!-- /toc -->|g' "$mdFile"

    mdtoc --inplace "$mdFile" || { echo "TOC: mdtoc failed" >&2; return 1; }

    # Revert markers
    sed -i 's/<!-- toc -->/<!-- BEGIN MUNGE: GENERATED_TOC -->/g' "$mdFile"
    sed -i 's|<!-- /toc -->|<!-- END MUNGE: GENERATED_TOC -->|g' "$mdFile"
    echo "TOC: updated $mdFile" >&2
}

# If executed directly (not sourced) behave like the old CLI
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    update_changelog_toc "$@"
fi