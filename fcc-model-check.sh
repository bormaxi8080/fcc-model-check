#!/usr/bin/env bash

set -u

FCC_ENV="${FCC_ENV:-$HOME/.fcc/.env}"
FCC_URL="${FCC_URL:-http://127.0.0.1:8082}"
FCC_TOKEN="${FCC_TOKEN:-freecc}"

NVIDIA_URL="${NVIDIA_URL:-https://integrate.api.nvidia.com/v1/chat/completions}"

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"

DIRECT_MAX_TOKENS="${DIRECT_MAX_TOKENS:-64}"
FCC_MAX_TOKENS="${FCC_MAX_TOKENS:-256}"

DIRECT_CONNECT_TIMEOUT="${DIRECT_CONNECT_TIMEOUT:-15}"
DIRECT_MAX_TIME="${DIRECT_MAX_TIME:-180}"

FCC_CONNECT_TIMEOUT="${FCC_CONNECT_TIMEOUT:-5}"
FCC_MAX_TIME="${FCC_MAX_TIME:-180}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

if [[ ! -f "$FCC_ENV" ]]; then
    echo "ERROR: FCC env file not found: $FCC_ENV"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is not installed."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is not installed."
    exit 1
fi

get_env() {
    local key="$1"

    grep -E "^${key}=" "$FCC_ENV" 2>/dev/null \
        | tail -1 \
        | cut -d= -f2- \
        | sed 's/^["'\'']//; s/["'\'']$//'
}

NVIDIA_NIM_API_KEY="${NVIDIA_NIM_API_KEY:-$(get_env NVIDIA_NIM_API_KEY)}"

if [[ -z "${NVIDIA_NIM_API_KEY:-}" ]]; then
    echo "ERROR: NVIDIA_NIM_API_KEY is not set."
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

print_line() {
    printf '%*s\n' 110 '' | tr ' ' '-'
}

normalize_text() {
    printf '%s' "$1" \
        | tr -d '\r' \
        | sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//'
}

print_json_error_compact() {
    local body="$1"

    if [[ -s "$body" ]]; then
        jq -c '.' "$body" 2>/dev/null || cat "$body"
    else
        printf '(empty response body)'
    fi
}

print_fcc_error() {
    local body="$1"

    if [[ -s "$body" ]]; then
        jq -r '
            .error.message
            // .detail
            // .message
            // .
        ' "$body" 2>/dev/null || cat "$body"
    else
        printf '(empty response body)'
    fi
}

# Direct NVIDIA transient HTTP responses.
is_transient_nvidia_http() {
    case "$1" in
        500|502|503|504)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# FCC may map upstream temporary failures to HTTP 529.
is_transient_fcc_http() {
    case "$1" in
        500|502|503|504|529)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# curl exit codes that normally indicate a temporary transport/network problem.
#
# 7  = failed to connect
# 18 = partial file
# 28 = operation timeout
# 35 = TLS connect error
# 52 = empty reply
# 55 = send failure
# 56 = receive failure
curl_is_temporary() {
    case "$1" in
        7|18|28|35|52|55|56)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# FCC sometimes wraps the real upstream status in HTTP 529 or another
# compatibility-layer response. Inspect the message too.
fcc_body_is_temporary() {
    local body="$1"

    [[ -s "$body" ]] || return 1

    if grep -Eqi \
        'service[_ ]unavailable|temporarily overloaded|provider is currently overloaded|please retry|upstream.*503|code["'\'': ]+503' \
        "$body"; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Result codes
#
# 0 = PASS
# 1 = UNAVAILABLE / 404
# 2 = RATE LIMIT / 429
# 3 = ERROR
# 4 = SEMANTIC INCONCLUSIVE
# 5 = EOL / 410
# 6 = TEMPORARY UPSTREAM / TRANSPORT FAILURE
# -----------------------------------------------------------------------------

RC_PASS=0
RC_UNAVAILABLE=1
RC_RATE_LIMIT=2
RC_ERROR=3
RC_INCONCLUSIVE=4
RC_EOL=5
RC_TEMPORARY=6

# -----------------------------------------------------------------------------
# Counters
# -----------------------------------------------------------------------------

direct_ok=0
direct_inconclusive=0
direct_eol=0
direct_unavailable=0
direct_rate_limit=0
direct_temporary=0
direct_error=0

alias_ok=0
alias_inconclusive=0
alias_eol=0
alias_unavailable=0
alias_rate_limit=0
alias_temporary=0
alias_error=0

# -----------------------------------------------------------------------------
# Direct NVIDIA test
# -----------------------------------------------------------------------------

test_nvidia() {
    local tier="$1"
    local fcc_model="$2"

    local real_model="${fcc_model#nvidia_nim/}"
    local body="$tmp_dir/nvidia-${tier}.json"
    local expected="${tier}_DIRECT_OK"

    local payload
    local http_code=""
    local curl_exit=0
    local attempt

    payload="$(
        jq -nc \
            --arg model "$real_model" \
            --arg prompt "Reply exactly: ${expected}" \
            --argjson max_tokens "$DIRECT_MAX_TOKENS" \
            '{
                model: $model,
                messages: [
                    {
                        role: "user",
                        content: $prompt
                    }
                ],
                max_tokens: $max_tokens,
                temperature: 0,
                stream: false,
                chat_template_kwargs: {
                    enable_thinking: false
                }
            }'
    )"

    for ((attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++)); do
        : > "$body"

        http_code="$(
            curl -sS \
                --connect-timeout "$DIRECT_CONNECT_TIMEOUT" \
                --max-time "$DIRECT_MAX_TIME" \
                -o "$body" \
                -w "%{http_code}" \
                "$NVIDIA_URL" \
                -H "Authorization: Bearer $NVIDIA_NIM_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$payload"
        )"

        curl_exit=$?

        if [[ "$curl_exit" -ne 0 ]]; then
            if curl_is_temporary "$curl_exit"; then
                if [[ "$attempt" -lt "$RETRY_ATTEMPTS" ]]; then
                    printf "  DIRECT NVIDIA : 🟠 CURL ERROR %s — retry %d/%d\n" \
                        "$curl_exit" \
                        "$attempt" \
                        "$RETRY_ATTEMPTS"

                    sleep "$RETRY_DELAY"
                    continue
                fi

                printf "  DIRECT NVIDIA : 🟠 CURL ERROR %s after %d attempt(s)\n" \
                    "$curl_exit" \
                    "$attempt"
                printf "  Transport     : 🟠 TEMPORARY TRANSPORT FAILURE\n"
                printf "  NVIDIA model  : %s\n" "$real_model"

                return "$RC_TEMPORARY"
            fi

            printf "  DIRECT NVIDIA : 🔴 CURL ERROR %s\n" "$curl_exit"
            printf "  Transport     : ❌ FAILED\n"
            printf "  NVIDIA model  : %s\n" "$real_model"

            return "$RC_ERROR"
        fi

        if is_transient_nvidia_http "$http_code" &&
           [[ "$attempt" -lt "$RETRY_ATTEMPTS" ]]; then

            printf "  DIRECT NVIDIA : 🟠 HTTP %s — retry %d/%d\n" \
                "$http_code" \
                "$attempt" \
                "$RETRY_ATTEMPTS"

            sleep "$RETRY_DELAY"
            continue
        fi

        break
    done

    case "$http_code" in
        200)
            local response_model
            local response_text
            local normalized

            response_model="$(
                jq -r '.model // "?"' "$body" 2>/dev/null
            )"

            response_text="$(
                jq -r '
                    .choices[0].message.content
                    // .choices[0].text
                    // "?"
                ' "$body" 2>/dev/null
            )"

            normalized="$(normalize_text "$response_text")"

            printf "  DIRECT NVIDIA : ✅ HTTP 200\n"
            printf "  Transport     : ✅ HEALTHY\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Response model: %s\n" "$response_model"
            printf "  Expected      : %s\n" "$expected"
            printf "  Response      : %s\n" "$response_text"

            if [[ "$normalized" == "$expected" ]]; then
                printf "  Semantic      : ✅ PASS\n"
                return "$RC_PASS"
            fi

            printf "  Semantic      : 🟡 INCONCLUSIVE\n"
            printf "                  HTTP transport is healthy, but the exact semantic\n"
            printf "                  probe was not returned as requested.\n"

            return "$RC_INCONCLUSIVE"
            ;;

        404)
            printf "  DIRECT NVIDIA : ❌ HTTP 404 UNAVAILABLE\n"
            printf "  Transport     : ❌ FAILED\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Error         : "
            print_json_error_compact "$body"
            echo

            return "$RC_UNAVAILABLE"
            ;;

        410)
            printf "  DIRECT NVIDIA : ☠️  HTTP 410 EOL\n"
            printf "  Transport     : ❌ FAILED\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Error         : "
            print_json_error_compact "$body"
            echo

            return "$RC_EOL"
            ;;

        429)
            printf "  DIRECT NVIDIA : 🟡 HTTP 429 RATE LIMITED\n"
            printf "  Transport     : 🟡 TEMPORARILY LIMITED\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Error         : "
            print_json_error_compact "$body"
            echo

            return "$RC_RATE_LIMIT"
            ;;

        500|502|503|504)
            printf "  DIRECT NVIDIA : 🟠 HTTP %s after %d attempt(s)\n" \
                "$http_code" \
                "$attempt"
            printf "  Transport     : 🟠 TEMPORARY UPSTREAM FAILURE\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Error         : "
            print_json_error_compact "$body"
            echo

            return "$RC_TEMPORARY"
            ;;

        *)
            printf "  DIRECT NVIDIA : 🔴 HTTP %s ERROR\n" "$http_code"
            printf "  Transport     : ❌ FAILED\n"
            printf "  NVIDIA model  : %s\n" "$real_model"
            printf "  Error         : "
            print_json_error_compact "$body"
            echo

            return "$RC_ERROR"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# FCC alias test
# -----------------------------------------------------------------------------

test_fcc_alias() {
    local tier="$1"
    local alias="$2"
    local expected_model="$3"

    local body="$tmp_dir/fcc-${tier}.json"
    local expected="${tier}_ALIAS_OK"

    local payload
    local http_code=""
    local curl_exit=0
    local attempt

    payload="$(
        jq -nc \
            --arg model "$alias" \
            --arg prompt "Reply exactly: ${expected}" \
            --argjson max_tokens "$FCC_MAX_TOKENS" \
            '{
                model: $model,
                max_tokens: $max_tokens,
                messages: [
                    {
                        role: "user",
                        content: $prompt
                    }
                ]
            }'
    )"

    for ((attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++)); do
        : > "$body"

        http_code="$(
            curl -sS \
                --connect-timeout "$FCC_CONNECT_TIMEOUT" \
                --max-time "$FCC_MAX_TIME" \
                -o "$body" \
                -w "%{http_code}" \
                "$FCC_URL/v1/messages" \
                -H "Authorization: Bearer $FCC_TOKEN" \
                -H "Content-Type: application/json" \
                -H "anthropic-version: 2023-06-01" \
                -d "$payload"
        )"

        curl_exit=$?

        if [[ "$curl_exit" -ne 0 ]]; then
            if curl_is_temporary "$curl_exit"; then
                if [[ "$attempt" -lt "$RETRY_ATTEMPTS" ]]; then
                    printf "  FCC ALIAS     : 🟠 CURL ERROR %s — retry %d/%d\n" \
                        "$curl_exit" \
                        "$attempt" \
                        "$RETRY_ATTEMPTS"

                    sleep "$RETRY_DELAY"
                    continue
                fi

                printf "  FCC ALIAS     : 🟠 CURL ERROR %s after %d attempt(s)\n" \
                    "$curl_exit" \
                    "$attempt"
                printf "  Transport     : 🟠 TEMPORARY TRANSPORT FAILURE\n"
                printf "  Alias         : %s\n" "$alias"
                printf "  Expected route: %s\n" "$expected_model"

                return "$RC_TEMPORARY"
            fi

            printf "  FCC ALIAS     : 🔴 CURL ERROR %s\n" "$curl_exit"
            printf "  Transport     : ❌ FAILED\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"

            return "$RC_ERROR"
        fi

        if is_transient_fcc_http "$http_code" &&
           [[ "$attempt" -lt "$RETRY_ATTEMPTS" ]]; then

            printf "  FCC ALIAS     : 🟠 HTTP %s — retry %d/%d\n" \
                "$http_code" \
                "$attempt" \
                "$RETRY_ATTEMPTS"

            sleep "$RETRY_DELAY"
            continue
        fi

        break
    done

    case "$http_code" in
        200)
            local response_model
            local response_text
            local normalized

            response_model="$(
                jq -r '.model // "?"' "$body" 2>/dev/null
            )"

            response_text="$(
                jq -r '
                    if (.content | type) == "array" then
                        [
                            .content[]
                            | select(.type == "text")
                            | .text
                        ] | join("")
                    elif (.content | type) == "string" then
                        .content
                    elif .choices[0].message.content? then
                        .choices[0].message.content
                    elif .choices[0].text? then
                        .choices[0].text
                    else
                        "?"
                    end
                ' "$body" 2>/dev/null
            )"

            normalized="$(normalize_text "$response_text")"

            printf "  FCC ALIAS     : ✅ HTTP 200\n"
            printf "  Transport     : ✅ HEALTHY\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Response model: %s\n" "$response_model"
            printf "  Expected      : %s\n" "$expected"
            printf "  Response      : %s\n" "$response_text"

            if [[ "$normalized" == "$expected" ]]; then
                printf "  Semantic      : ✅ PASS\n"
                return "$RC_PASS"
            fi

            printf "  Semantic      : 🟡 INCONCLUSIVE\n"
            printf "                  FCC transport is healthy. The backend returned HTTP 200,\n"
            printf "                  but the exact validation token was not the whole response.\n"
            printf "                  This may be caused by reasoning/thinking output and is not\n"
            printf "                  treated as a broken FCC route.\n"

            return "$RC_INCONCLUSIVE"
            ;;

        404)
            printf "  FCC ALIAS     : ❌ HTTP 404 UNAVAILABLE\n"
            printf "  Transport     : ❌ FAILED\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Error         : "
            print_fcc_error "$body"
            echo

            return "$RC_UNAVAILABLE"
            ;;

        410)
            printf "  FCC ALIAS     : ☠️  HTTP 410 EOL\n"
            printf "  Transport     : ❌ FAILED\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Error         : "
            print_fcc_error "$body"
            echo

            return "$RC_EOL"
            ;;

        429)
            printf "  FCC ALIAS     : 🟡 HTTP 429 RATE LIMITED\n"
            printf "  Transport     : 🟡 TEMPORARILY LIMITED\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Error         : "
            print_fcc_error "$body"
            echo

            return "$RC_RATE_LIMIT"
            ;;

        500|502|503|504|529)
            printf "  FCC ALIAS     : 🟠 HTTP %s after %d attempt(s)\n" \
                "$http_code" \
                "$attempt"
            printf "  Transport     : 🟠 TEMPORARY UPSTREAM FAILURE\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Error         : "
            print_fcc_error "$body"
            echo

            return "$RC_TEMPORARY"
            ;;

        *)
            # Some FCC/provider combinations may use a non-standard HTTP status
            # while the body still clearly describes an upstream 503/overload.
            if fcc_body_is_temporary "$body"; then
                printf "  FCC ALIAS     : 🟠 HTTP %s TEMPORARY\n" "$http_code"
                printf "  Transport     : 🟠 TEMPORARY UPSTREAM FAILURE\n"
                printf "  Alias         : %s\n" "$alias"
                printf "  Expected route: %s\n" "$expected_model"
                printf "  Error         : "
                print_fcc_error "$body"
                echo

                return "$RC_TEMPORARY"
            fi

            printf "  FCC ALIAS     : 🔴 HTTP %s ERROR\n" "$http_code"
            printf "  Transport     : ❌ FAILED\n"
            printf "  Alias         : %s\n" "$alias"
            printf "  Expected route: %s\n" "$expected_model"
            printf "  Error         : "
            print_fcc_error "$body"
            echo

            return "$RC_ERROR"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Counter helpers
# -----------------------------------------------------------------------------

count_direct_result() {
    local result="$1"

    case "$result" in
        "$RC_PASS")
            direct_ok=$((direct_ok + 1))
            ;;
        "$RC_INCONCLUSIVE")
            direct_inconclusive=$((direct_inconclusive + 1))
            ;;
        "$RC_EOL")
            direct_eol=$((direct_eol + 1))
            ;;
        "$RC_UNAVAILABLE")
            direct_unavailable=$((direct_unavailable + 1))
            ;;
        "$RC_RATE_LIMIT")
            direct_rate_limit=$((direct_rate_limit + 1))
            ;;
        "$RC_TEMPORARY")
            direct_temporary=$((direct_temporary + 1))
            ;;
        *)
            direct_error=$((direct_error + 1))
            ;;
    esac
}

count_alias_result() {
    local result="$1"

    case "$result" in
        "$RC_PASS")
            alias_ok=$((alias_ok + 1))
            ;;
        "$RC_INCONCLUSIVE")
            alias_inconclusive=$((alias_inconclusive + 1))
            ;;
        "$RC_EOL")
            alias_eol=$((alias_eol + 1))
            ;;
        "$RC_UNAVAILABLE")
            alias_unavailable=$((alias_unavailable + 1))
            ;;
        "$RC_RATE_LIMIT")
            alias_rate_limit=$((alias_rate_limit + 1))
            ;;
        "$RC_TEMPORARY")
            alias_temporary=$((alias_temporary + 1))
            ;;
        *)
            alias_error=$((alias_error + 1))
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------

echo
echo "FCC / NVIDIA MODEL HEALTH CHECK"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "FCC : $FCC_URL"
echo "ENV : $FCC_ENV"
echo "Retries: $RETRY_ATTEMPTS attempt(s), ${RETRY_DELAY}s delay"
echo "Direct semantic probe: thinking disabled"
echo "FCC semantic probe   : informational / non-fatal"
echo

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

for tier in FABLE OPUS SONNET HAIKU
do
    case "$tier" in
        FABLE)
            model="$(get_env MODEL_FABLE)"
            alias="claude-fable-5"
            ;;
        OPUS)
            model="$(get_env MODEL_OPUS)"
            alias="claude-opus-5"
            ;;
        SONNET)
            model="$(get_env MODEL_SONNET)"
            alias="claude-sonnet-4-20250514"
            ;;
        HAIKU)
            model="$(get_env MODEL_HAIKU)"
            alias="claude-haiku-4-20250514"
            ;;
    esac

    print_line

    echo "[$tier]"
    printf "  Config        : %s\n" "${model:-NOT CONFIGURED}"
    printf "  Alias         : %s\n" "$alias"

    if [[ -z "${model:-}" ]]; then
        echo "  🔴 MODEL_${tier} is not configured."

        direct_error=$((direct_error + 1))
        alias_error=$((alias_error + 1))

        echo
        continue
    fi

    # -------------------------------------------------------------------------
    # Direct NVIDIA
    # -------------------------------------------------------------------------

    test_nvidia "$tier" "$model"
    direct_result=$?

    count_direct_result "$direct_result"

    echo

    # -------------------------------------------------------------------------
    # FCC alias
    # -------------------------------------------------------------------------

    test_fcc_alias "$tier" "$alias" "$model"
    alias_result=$?

    count_alias_result "$alias_result"

    echo
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_line

echo
echo "SUMMARY"
echo

printf "%-20s %5s %12s %5s %5s %10s %10s %6s\n" \
    "" \
    "PASS" \
    "INCONCLUSIVE" \
    "EOL" \
    "404" \
    "RATE-LIMIT" \
    "TEMPORARY" \
    "ERROR"

printf "%-20s %5d %12d %5d %5d %10d %10d %6d\n" \
    "Direct NVIDIA" \
    "$direct_ok" \
    "$direct_inconclusive" \
    "$direct_eol" \
    "$direct_unavailable" \
    "$direct_rate_limit" \
    "$direct_temporary" \
    "$direct_error"

printf "%-20s %5d %12d %5d %5d %10d %10d %6d\n" \
    "FCC aliases" \
    "$alias_ok" \
    "$alias_inconclusive" \
    "$alias_eol" \
    "$alias_unavailable" \
    "$alias_rate_limit" \
    "$alias_temporary" \
    "$alias_error"

echo
print_line

# -----------------------------------------------------------------------------
# Interpretation
# -----------------------------------------------------------------------------

hard_fail=0
temporary_problem=0
semantic_note=0

if [[ "$direct_eol" -gt 0 ]]; then
    echo "☠️  Direct NVIDIA 410 / EOL:"
    echo "   One or more configured models have reached end-of-life."
    echo "   Replace them in:"
    echo "   $FCC_ENV"
    echo

    hard_fail=1
fi

if [[ "$alias_eol" -gt 0 ]]; then
    echo "☠️  FCC alias 410 / EOL:"
    echo "   FCC reached an upstream model that is no longer available."
    echo "   The corresponding MODEL_* configuration must be replaced."
    echo

    hard_fail=1
fi

if [[ "$direct_unavailable" -gt 0 ]]; then
    echo "❌ Direct NVIDIA 404:"
    echo "   One or more configured model IDs are unavailable through NVIDIA."
    echo "   Verify the model name and current provider availability."
    echo

    hard_fail=1
fi

if [[ "$alias_unavailable" -gt 0 ]]; then
    echo "❌ FCC alias 404:"
    echo "   An FCC alias, route, or corresponding upstream model is unavailable."
    echo

    hard_fail=1
fi

if [[ "$direct_error" -gt 0 ]]; then
    echo "🔴 Direct NVIDIA errors:"
    echo "   One or more direct API requests failed for reasons other than known"
    echo "   temporary provider or transport conditions."
    echo

    hard_fail=1
fi

if [[ "$alias_error" -gt 0 ]]; then
    echo "🔴 FCC errors:"
    echo "   One or more FCC API requests failed for reasons other than known"
    echo "   temporary provider or transport conditions."
    echo

    hard_fail=1
fi

if [[ "$direct_rate_limit" -gt 0 ]]; then
    echo "🟡 Direct NVIDIA rate limiting:"
    echo "   NVIDIA is reachable but returned HTTP 429."
    echo

    temporary_problem=1
fi

if [[ "$alias_rate_limit" -gt 0 ]]; then
    echo "🟡 FCC alias rate limiting:"
    echo "   FCC reached the provider, but the upstream provider returned HTTP 429."
    echo

    temporary_problem=1
fi

if [[ "$direct_temporary" -gt 0 ]]; then
    echo "🟠 Direct NVIDIA temporary failures:"
    echo "   NVIDIA returned a temporary HTTP/server or transport failure"
    echo "   even after retries."
    echo

    temporary_problem=1
fi

if [[ "$alias_temporary" -gt 0 ]]; then
    echo "🟠 FCC temporary failures:"
    echo "   FCC returned a temporary server/upstream/transport failure."
    echo "   HTTP 529 is treated as temporary because FCC may use it to expose"
    echo "   an upstream NVIDIA 503/service_unavailable condition."
    echo
    echo "   Compare the direct NVIDIA result for the same model:"
    echo
    echo "      Direct fails + FCC fails -> probably NVIDIA/upstream."
    echo "      Direct works + FCC fails -> FCC/provider path is temporarily unstable."
    echo

    temporary_problem=1
fi

if [[ "$direct_inconclusive" -gt 0 ]]; then
    echo "🟡 Direct semantic checks inconclusive:"
    echo "   HTTP transport succeeded, but one or more models did not return"
    echo "   only the exact expected validation token."
    echo "   Thinking is disabled for this probe, so repeated failures are worth"
    echo "   investigating, but they are not considered transport failures."
    echo

    semantic_note=1
fi

if [[ "$alias_inconclusive" -gt 0 ]]; then
    echo "🟡 FCC semantic checks inconclusive:"
    echo "   FCC returned HTTP 200 and therefore the route is considered healthy."
    echo "   The model did not return only the expected validation token."
    echo "   Reasoning/thinking output may be exposed through the compatibility layer,"
    echo "   so this condition is informational and does not fail the health check."
    echo

    semantic_note=1
fi

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------

if [[ "$hard_fail" -eq 1 ]]; then
    echo "🔴 HARD FAILURES DETECTED"
    exit 1
fi

if [[ "$temporary_problem" -eq 1 && "$semantic_note" -eq 1 ]]; then
    echo "🟠 ROUTES ARE CONFIGURED, BUT TEMPORARY PROVIDER/TRANSPORT ISSUES AND SEMANTIC NOTES WERE DETECTED"
    exit 0
fi

if [[ "$temporary_problem" -eq 1 ]]; then
    echo "🟠 ROUTES ARE CONFIGURED, BUT TEMPORARY PROVIDER/TRANSPORT ISSUES WERE DETECTED"
    exit 0
fi

if [[ "$semantic_note" -eq 1 ]]; then
    echo "🟡 TRANSPORT IS HEALTHY; SEMANTIC PROBES WERE INCONCLUSIVE"
    exit 0
fi

echo "✅ ALL MODELS, ROUTES AND SEMANTIC PROBES ARE HEALTHY"

exit 0
