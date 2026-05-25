#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# REQUIRED CONFIGURATION
# Set this to the specific Claude Code project directory containing
# the session .jsonl files you want to export.
# -------------------------------------------------------------------
PROJECT_DIR="$HOME/.claude/projects/YOUR_PROJECT_DIR"

# Local export storage path.
EXPORT_DIR="$HOME/claude_exports"

mkdir -p "$EXPORT_DIR"

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

# List direct .jsonl children only.
list_session_files() {
    find "$PROJECT_DIR_REAL" \
        -maxdepth 1 \
        -type f \
        -name "*.jsonl" \
        -print \
    | sort
}

# Print direct .jsonl children whose basename contains a query literally.
# Uses grep -F for fixed-string matching rather than shell glob semantics.
find_sessions_by_filename_literal() {
    local query="$1"

    list_session_files \
    | while IFS= read -r file; do
        basename "$file" | grep -Fqi -- "$query" && printf '%s\n' "$file"
      done \
    | sort -u
}

# Print direct .jsonl children whose content appears to match the requested
# session title/name/query.
#
# This has two passes:
#   1. Structured jq search against likely title/name/summary fields.
#   2. Raw fixed-string grep fallback across the JSONL file.
#
# Both passes are confined to direct .jsonl children of PROJECT_DIR.
find_sessions_by_content_literal() {
    local query="$1"
    local file

    list_session_files \
    | while IFS= read -r file; do
        validate_session_file "$file" || continue

        # Structured title/name/summary search.
        #
        # This intentionally checks a broad set of likely fields because Claude
        # Code transcript event schemas can vary.
        if jq -e --arg q "$query" '
            def norm:
                tostring
                | ascii_downcase;

            def has_query:
                norm
                | contains($q | ascii_downcase);

            any(
                [
                    .title?,
                    .name?,
                    .summary?,
                    .sessionName?,
                    .session_name?,
                    .conversationTitle?,
                    .conversation_title?,
                    .message.title?,
                    .message.name?,
                    .message.summary?,
                    .message.sessionName?,
                    .message.session_name?,
                    .message.conversationTitle?,
                    .message.conversation_title?
                ][];
                . != null and has_query
            )
        ' "$file" >/dev/null 2>&1; then
            printf '%s\n' "$file"
            continue
        fi

        # Raw fixed-string fallback. This catches names/titles embedded in
        # schema variants not covered above.
        if grep -Fqi -- "$query" "$file"; then
            printf '%s\n' "$file"
        fi
      done \
    | sort -u
}

# Resolve a user's session argument to exactly one validated session file.
resolve_session_file() {
    local session_param="${1:-}"
    local candidate
    local matched_file
    local matches
    local match_count

    if [ -n "$session_param" ]; then
        # 1. Full or relative path. Still constrained to direct child of PROJECT_DIR.
        if validate_session_file "$session_param"; then
            printf '%s/%s\n' "$PROJECT_DIR_REAL" "$(basename "$session_param")"
            return 0
        fi

        # 2. Exact filename inside PROJECT_DIR.
        candidate="$PROJECT_DIR_REAL/$session_param"
        if validate_session_file "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi

        # 3. Exact session id without .jsonl.
        candidate="$PROJECT_DIR_REAL/${session_param}.jsonl"
        if validate_session_file "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi

        # 4. Literal partial filename match.
        matches=$(find_sessions_by_filename_literal "$session_param")
        match_count=$(
            printf '%s\n' "$matches" \
            | sed '/^$/d' \
            | wc -l \
            | tr -d ' '
        )

        if [ "$match_count" = "1" ]; then
            matched_file=$(printf '%s\n' "$matches" | sed '/^$/d' | head -n 1)

            if validate_session_file "$matched_file"; then
                printf '%s\n' "$matched_file"
                return 0
            fi
        elif [ "$match_count" -gt 1 ]; then
            printf "Error: Session parameter is ambiguous as a filename match: %s\n" "$session_param" >&2
            printf "Matching sessions:\n" >&2
            printf '%s\n' "$matches" \
                | sed '/^$/d' \
                | xargs -n 1 basename >&2
            return 1
        fi

        # 5. Literal content/title/name match.
        matches=$(find_sessions_by_content_literal "$session_param")
        match_count=$(
            printf '%s\n' "$matches" \
            | sed '/^$/d' \
            | wc -l \
            | tr -d ' '
        )

        if [ "$match_count" = "1" ]; then
            matched_file=$(printf '%s\n' "$matches" | sed '/^$/d' | head -n 1)

            if validate_session_file "$matched_file"; then
                printf '%s\n' "$matched_file"
                return 0
            fi
        elif [ "$match_count" -gt 1 ]; then
            printf "Error: Session parameter is ambiguous as a content/name/title match: %s\n" "$session_param" >&2
            printf "Matching sessions:\n" >&2
            printf '%s\n' "$matches" \
                | sed '/^$/d' \
                | xargs -n 1 basename >&2
            return 1
        fi

        printf "❌ Error: Could not find a session matching '%s' in:\n%s\n" "$session_param" "$PROJECT_DIR_REAL" >&2
        printf "Available direct .jsonl sessions:\n" >&2
        list_session_files | xargs -n 1 basename 2>/dev/null >&2 || true
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

# Use the provided session name/query in the export filename when supplied.
# Otherwise fall back to the actual session id.
if [ -n "${SESSION_PARAM:-}" ]; then
    OUTPUT_BASENAME="$SESSION_PARAM"
else
    OUTPUT_BASENAME="$SESSION_ID"
fi

# Keep the output filename sane even if the session name contains spaces,
# punctuation, slashes, or other unusual characters.
SAFE_OUTPUT_BASENAME=$(
    printf '%s' "$OUTPUT_BASENAME" \
    | tr '/[:space:]' '__' \
    | tr -c 'A-Za-z0-9._-' '_'
)

# Collapse repeated underscores and trim leading/trailing underscores.
SAFE_OUTPUT_BASENAME=$(
    printf '%s' "$SAFE_OUTPUT_BASENAME" \
    | sed -E 's/_+/_/g; s/^_+//; s/_+$//'
)

# Defensive fallback in case the provided name sanitizes to an empty string.
if [ -z "$SAFE_OUTPUT_BASENAME" ]; then
    SAFE_OUTPUT_BASENAME="$SESSION_ID"
fi

OUTPUT_FILE="$EXPORT_DIR/export_${TIMESTAMP}_${SAFE_OUTPUT_BASENAME}.md"

printf '%s\n' "Processing session history log: $SESSION_ID"
printf '%s\n' "Project directory: $PROJECT_DIR_REAL"
printf '%s\n' "Target path: $SELECTED_SESSION"

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
                printf '### User\n\n'
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
                printf '#### Reasoning\n\n'
                write_indented_block "$REASONING"
                printf '\n\n'
            else
                # Do not silently omit reasoning. If an assistant message lacks
                # a reasoning block, make that absence explicit in the export.
                printf '#### Reasoning\n\n'
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
