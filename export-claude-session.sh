#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# REQUIRED CONFIGURATION
# Set this to the specific Claude Code project directory containing
# the session .jsonl files you want to export.
#
# Example:
# PROJECT_DIR="$HOME/.claude/projects/-Users-jake-src-my-project"
# -------------------------------------------------------------------
PROJECT_DIR="$HOME/.claude/projects/REPLACE_WITH_SPECIFIC_PROJECT_DIR"

# Local export storage path.
EXPORT_DIR="$HOME/claude_exports"

mkdir -p "$EXPORT_DIR"

# Resolve PROJECT_DIR physically and fail if it does not exist.
if [ ! -d "$PROJECT_DIR" ]; then
    printf 'Error: PROJECT_DIR does not exist or is not a directory:\n%s\n' "$PROJECT_DIR" >&2
    exit 1
fi

PROJECT_DIR_REAL=$(
    cd "$PROJECT_DIR"
    pwd -P
)

# Validate that a candidate file is a direct .jsonl child of PROJECT_DIR.
# This prevents reading files outside PROJECT_DIR and prevents reading files
# from subdirectories inside PROJECT_DIR.
validate_session_file() {
    local candidate="$1"
    local candidate_dir
    local candidate_base
    local candidate_real_dir

    candidate_dir=$(dirname "$candidate")
    candidate_base=$(basename "$candidate")

    if [ ! -d "$candidate_dir" ]; then
        return 1
    fi

    candidate_real_dir=$(
        cd "$candidate_dir" 2>/dev/null
        pwd -P
    ) || return 1

    # Must be directly inside the exact configured PROJECT_DIR.
    if [ "$candidate_real_dir" != "$PROJECT_DIR_REAL" ]; then
        return 1
    fi

    # Must be a regular .jsonl file.
    case "$candidate_base" in
        *.jsonl) ;;
        *) return 1 ;;
    esac

    [ -f "$PROJECT_DIR_REAL/$candidate_base" ]
}

# Return a validated absolute path to a direct child file in PROJECT_DIR.
resolve_session_file() {
    local session_param="${1:-}"
    local candidate
    local match_count
    local matched_file

    if [ -n "$session_param" ]; then
        # Full or relative path, but still constrained to direct child of PROJECT_DIR.
        if validate_session_file "$session_param"; then
            printf '%s/%s\n' "$PROJECT_DIR_REAL" "$(basename "$session_param")"
            return 0
        fi

        # Exact filename inside PROJECT_DIR.
        candidate="$PROJECT_DIR_REAL/$session_param"
        if validate_session_file "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi

        # Exact session id without .jsonl.
        candidate="$PROJECT_DIR_REAL/${session_param}.jsonl"
        if validate_session_file "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi

        # Partial match, direct children only, deterministic, fail if ambiguous.
        # No recursion. No subdirectories.
        match_count=$(
            find "$PROJECT_DIR_REAL" \
                -maxdepth 1 \
                -type f \
                -name "*${session_param}*.jsonl" \
                -print \
            | sort \
            | wc -l \
            | tr -d ' '
        )

        if [ "$match_count" = "1" ]; then
            matched_file=$(
                find "$PROJECT_DIR_REAL" \
                    -maxdepth 1 \
                    -type f \
                    -name "*${session_param}*.jsonl" \
                    -print \
                | sort \
                | head -n 1
            )

            if validate_session_file "$matched_file"; then
                printf '%s\n' "$matched_file"
                return 0
            fi
        elif [ "$match_count" -gt 1 ]; then
            printf "Error: Session parameter is ambiguous: %s\n" "$session_param" >&2
            printf "Matching sessions:\n" >&2
            find "$PROJECT_DIR_REAL" \
                -maxdepth 1 \
                -type f \
                -name "*${session_param}*.jsonl" \
                -print \
            | sort \
            | xargs -n 1 basename >&2
            return 1
        fi

        printf "Error: Could not find a session log matching '%s' in:\n%s\n" "$session_param" "$PROJECT_DIR_REAL" >&2
        printf "Available sessions:\n" >&2
        find "$PROJECT_DIR_REAL" \
            -maxdepth 1 \
            -type f \
            -name "*.jsonl" \
            -print \
        | sort \
        | xargs -n 1 basename 2>/dev/null >&2 || true
        return 1
    fi

    # No parameter: newest direct child .jsonl file only.
    matched_file=$(
        find "$PROJECT_DIR_REAL" \
            -maxdepth 1 \
            -type f \
            -name "*.jsonl" \
            -print0 \
        | xargs -0 ls -t 2>/dev/null \
        | head -n 1
    )

    if [ -n "${matched_file:-}" ] && validate_session_file "$matched_file"; then
        printf '%s\n' "$matched_file"
        return 0
    fi

    printf "Error: No direct .jsonl session files found in:\n%s\n" "$PROJECT_DIR_REAL" >&2
    return 1
}

# Emit text as an indented Markdown code block.
# This is structurally robust against embedded ``` fences.
write_indented_block() {
    local text="$1"

    if [ -n "$text" ]; then
        printf '%s\n' "$text" | sed 's/^/    /'
    fi
}

SESSION_PARAM="${1:-}"
SELECTED_SESSION=$(resolve_session_file "$SESSION_PARAM")

SESSION_ID=$(basename "$SELECTED_SESSION" .jsonl)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Keep the output filename sane even if the session id contains unusual characters.
SAFE_SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')
OUTPUT_FILE="$EXPORT_DIR/export_${TIMESTAMP}_${SAFE_SESSION_ID}.md"

printf 'Processing session history log: %s\n' "$SESSION_ID"
printf 'Project directory: %s\n' "$PROJECT_DIR_REAL"
printf 'Target path: %s\n' "$SELECTED_SESSION"

{
    printf '%s\n' '---'
    printf 'title: %s\n' 'Claude Code Custom Transcript'
    printf 'date: %s\n' "$(date)"
    printf 'session_id: %s\n' "$SESSION_ID"
    printf 'source_file: %s\n' "$SELECTED_SESSION"
    printf '%s\n' '---'
    printf '\n'
} > "$OUTPUT_FILE"

# Stream and parse the JSONL.
#
# Supports both:
#   { "role": "...", "content": ... }
# and:
#   { "message": { "role": "...", "content": ... } }
#
# Content may be:
#   - string
#   - array of typed blocks
#
# Tool calls are intentionally omitted.
while IFS= read -r line; do
    # Skip blank lines defensively.
    [ -n "$line" ] || continue

    ROLE=$(
        jq -r '
            .message.role // .role // empty
        ' <<< "$line"
    )

    if [ "$ROLE" = "user" ]; then
        USER_TEXT=$(
            jq -r '
                (.message.content // .content // empty) as $c
                | if ($c | type) == "string" then
                    $c
                  elif ($c | type) == "array" then
                    $c[]?
                    | select(.type == "text")
                    | .text
                  else
                    empty
                  end
            ' <<< "$line"
        )

        if [ -n "$USER_TEXT" ]; then
            {
                printf '### 👤 User\n\n'
                printf '%s\n\n' "$USER_TEXT"
            } >> "$OUTPUT_FILE"
        fi

    elif [ "$ROLE" = "assistant" ]; then
        REASONING=$(
            jq -r '
                (.message.content // .content // empty) as $c
                | if ($c | type) == "array" then
                    $c[]?
                    | select(.type == "thinking" or .type == "reasoning")
                    | .text // .thinking // .content // empty
                  else
                    empty
                  end
            ' <<< "$line"
        )

        TEXT_RESPONSE=$(
            jq -r '
                (.message.content // .content // empty) as $c
                | if ($c | type) == "string" then
                    $c
                  elif ($c | type) == "array" then
                    $c[]?
                    | select(.type == "text")
                    | .text
                  else
                    empty
                  end
            ' <<< "$line"
        )

        {
            printf '### Claude\n\n'

            if [ -n "$REASONING" ]; then
                printf '#### Internal Reasoning Trace\n\n'
                write_indented_block "$REASONING"
                printf '\n\n'
            else
                # Do not silently omit reasoning. If an assistant message lacks
                # a reasoning block, make that absence explicit in the export.
                printf '#### Internal Reasoning Trace\n\n'
                printf '    [No reasoning block found in this assistant message.]\n\n'
            fi

            if [ -n "$TEXT_RESPONSE" ]; then
                printf '%s\n\n' "$TEXT_RESPONSE"
            fi
        } >> "$OUTPUT_FILE"
    fi
done < "$SELECTED_SESSION"

printf 'Export complete. Your transcript with reasoning traces is saved at:\n'
printf '%s\n' "$OUTPUT_FILE"
