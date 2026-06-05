#!/bin/bash
#
# 定时检查「哎哟嚯Radio」播客是否有新单集，有新单集时通过QQ邮箱通知
#
# 依赖: curl, python3, 以及运行中的 xyz 服务 (localhost:23020)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.podcast_state"
LOG_FILE="$SCRIPT_DIR/check_episodes.log"
PID="5fceeaa0dee9c1e16d8cc295"
BASE_URL="http://localhost:23020"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ---- load state ----
if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
else
    log "首次运行，没有状态文件，稍后初始化"
    ACCESS_TOKEN=""
    REFRESH_TOKEN=""
    LAST_EID=""
fi

# ---- helper: call API ----
call_api() {
    local endpoint="$1"
    local token="$2"
    local body="$3"
    curl -s -X POST "$BASE_URL$endpoint" \
        -H "Content-Type: application/json" \
        -H "x-jike-access-token: $token" \
        -d "$body"
}

# ---- refresh token ----
refresh_token() {
    log "Token 过期，尝试刷新..."
    local resp
    resp=$(curl -s -X POST "$BASE_URL/refresh_token" \
        -H "Content-Type: application/json" \
        -d "{\"x-jike-access-token\":\"$ACCESS_TOKEN\",\"x-jike-refresh-token\":\"$REFRESH_TOKEN\"}")

    local code
    code=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',0))" 2>/dev/null || echo "0")

    if [[ "$code" != "200" ]]; then
        log "ERROR: Token 刷新失败！$resp"
        return 1
    fi

    local new_access new_refresh
    new_access=$(echo "$resp" | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']
print(d.get('x-jike-access-token',''))
" 2>/dev/null)
    new_refresh=$(echo "$resp" | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']
print(d.get('x-jike-refresh-token',''))
" 2>/dev/null)

    if [[ -z "$new_access" || -z "$new_refresh" ]]; then
        log "ERROR: Token 刷新响应异常"
        return 1
    fi

    ACCESS_TOKEN="$new_access"
    REFRESH_TOKEN="$new_refresh"
    save_state
    log "Token 刷新成功"
}

# ---- save state ----
save_state() {
    cat > "$STATE_FILE" << EOF
ACCESS_TOKEN="$ACCESS_TOKEN"
REFRESH_TOKEN="$REFRESH_TOKEN"
LAST_EID="$LAST_EID"
EOF
}

# ---- fetch episodes ----
fetch_episodes() {
    local resp
    resp=$(call_api "/episode_list" "$ACCESS_TOKEN" "{\"pid\":\"$PID\",\"order\":\"desc\",\"limit\":\"5\"}")

    local code
    code=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',0))" 2>/dev/null || echo "0")

    # 401 = token expired
    if [[ "$code" == "401" ]]; then
        echo "TOKEN_EXPIRED"
        return
    fi

    if [[ "$code" != "200" ]]; then
        log "ERROR: 获取单集列表失败 code=$code"
        log "$resp"
        return 1
    fi

    echo "$resp"
}

# ---- main ----
main() {
    if [[ -z "${ACCESS_TOKEN:-}" ]]; then
        log "ERROR: 没有 access_token，请先登录获取 token 并手动设置到 $STATE_FILE"
        exit 1
    fi

    # fetch episodes
    local resp
    resp=$(fetch_episodes)

    if [[ "$resp" == "TOKEN_EXPIRED" ]]; then
        refresh_token || exit 1
        resp=$(fetch_episodes)
        if [[ "$resp" == "TOKEN_EXPIRED" ]]; then
            log "ERROR: Token 刷新后仍然失败，请重新登录"
            exit 1
        fi
    fi

    # parse episodes
    local episodes
    episodes=$(echo "$resp" | python3 -c "
import json,sys
eps = json.load(sys.stdin)['data']['data']
for ep in eps:
    print(f\"{ep['eid']}|{ep['title']}|{ep.get('pubDate','')}|{ep.get('duration',0)}\")
")

    local latest_eid
    latest_eid=$(echo "$episodes" | head -1 | cut -d'|' -f1)

    log "当前最新单集: $latest_eid ($(echo "$episodes" | head -1 | cut -d'|' -f2))"

    # first run: just save state
    if [[ -z "${LAST_EID:-}" ]]; then
        LAST_EID="$latest_eid"
        save_state
        log "首次运行，记录当前最新单集: $LAST_EID，不发通知"
        exit 0
    fi

    # no update
    if [[ "$latest_eid" == "$LAST_EID" ]]; then
        log "无更新"
        exit 0
    fi

    # new episodes found
    log "检测到新单集！"

    # collect new episodes (those newer than LAST_EID)
    local new_eps=""
    local found=0
    while IFS= read -r line; do
        local eid title pub_date duration
        eid=$(echo "$line" | cut -d'|' -f1)
        title=$(echo "$line" | cut -d'|' -f2)
        pub_date=$(echo "$line" | cut -d'|' -f3)
        duration=$(echo "$line" | cut -d'|' -f4)

        if [[ "$eid" == "$LAST_EID" ]]; then
            break
        fi
        found=1
        new_eps="${new_eps}${title}|${pub_date}|${duration}\n"
    done <<< "$episodes"

    if [[ "$found" -eq 0 ]]; then
        log "新单集不在前5条内，以最新为准"
        local first_line
        first_line=$(echo "$episodes" | head -1)
        new_eps="$(echo "$first_line" | cut -d'|' -f2)|$(echo "$first_line" | cut -d'|' -f3)|$(echo "$first_line" | cut -d'|' -f4)\n"
    fi

    # send email
    log "发送邮件通知..."
    if python3 "$SCRIPT_DIR/send_qq_email.py" "哎哟嚯Radio更新了！" "$(echo -e "$new_eps")"; then
        log "邮件发送成功"
        LAST_EID="$latest_eid"
        save_state
    else
        log "ERROR: 邮件发送失败"
        exit 1
    fi
}

main "$@"
