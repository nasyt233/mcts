#!/usr/bin/env bash
# mcts —— Minecraft Mod 语言文件批量翻译器
# Version: 1.0.0
set -uo pipefail

PROG="mcts"; VERSION="1.0.0"

if (( BASH_VERSINFO[0] < 4 )); then
  echo "错误: $PROG 需要 bash 4.0+（当前 ${BASH_VERSION}）" >&2; exit 1
fi

missing=()
for cmd in dialog jq curl md5sum awk wc find; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
(( ${#missing[@]} > 0 )) && { echo "错误: 缺少依赖: ${missing[*]}" >&2; exit 1; }

# ============ 全局 ============
HEADLESS=0; QUIET=0
API_NAME=""; API_TYPE=""; API_URL=""; API_KEY=""; API_SECRET=""
API_REGION=""; MODEL=""; PROJECT_ID=""
TARGET_LANG="Simplified Chinese"; TARGET_CODE=""
CONCURRENCY=3; REQUEST_DELAY=0
MYMEMORY_EMAIL="${MYMEMORY_EMAIL:-}"
USE_BATCH=1; BATCH_SIZE=20; USE_INDEX=1; USE_DEDUP=1; SKIP_NOOP=1

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mc-translate"
CONFIG_FILE="${MC_TRANSLATE_CONFIG:-$CONFIG_DIR/config.sh}"

TMPDIR_RUN=$(mktemp -d)
TOKENS_LOG="$TMPDIR_RUN/tokens.log"; export TOKENS_LOG
CURRENT_INPUT=""; CURRENT_OUTPUT=""; CURRENT_NDJSON=""
WORKER_PID=""; REBUILDER_PID=""
MCTS_FILE_RESULT=""

cleanup() {
  trap - EXIT HUP INT TERM
  [[ -n "$WORKER_PID" ]] && kill -TERM "$WORKER_PID" 2>/dev/null
  [[ -n "$REBUILDER_PID" ]] && kill -TERM "$REBUILDER_PID" 2>/dev/null
  sleep 1 2>/dev/null
  if [[ -n "$CURRENT_NDJSON" && -s "$CURRENT_NDJSON" && -n "$CURRENT_INPUT" && -n "$CURRENT_OUTPUT" ]]; then
    rebuild_output "$CURRENT_INPUT" "$CURRENT_NDJSON" "$CURRENT_OUTPUT" 2>/dev/null || true
  fi
  if (( ! HEADLESS )); then
    tput cnorm 2>/dev/null || true
    echo 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ============ 配置 ============
load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true; }

save_config() {
  local dir old_umask
  dir=$(dirname "$CONFIG_FILE")
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
    CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mc-translate.conf"
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
  fi
  old_umask=$(umask); umask 077
  {
    echo "# mcts v${VERSION} 配置"
    echo "# 路径: $CONFIG_FILE"
    echo "# 警告: 此文件含密钥，权限已设为 600"
    echo
    printf 'API_NAME=%q\n' "$API_NAME"
    printf 'API_TYPE=%q\n' "$API_TYPE"
    printf 'API_URL=%q\n' "$API_URL"
    printf 'API_KEY=%q\n' "$API_KEY"
    printf 'API_SECRET=%q\n' "$API_SECRET"
    printf 'API_REGION=%q\n' "$API_REGION"
    printf 'MODEL=%q\n' "$MODEL"
    printf 'PROJECT_ID=%q\n' "$PROJECT_ID"
    printf 'TARGET_LANG=%q\n' "$TARGET_LANG"
    printf 'TARGET_CODE=%q\n' "$TARGET_CODE"
    echo "CONCURRENCY=$CONCURRENCY"
    echo "REQUEST_DELAY=$REQUEST_DELAY"
    printf 'MYMEMORY_EMAIL=%q\n' "$MYMEMORY_EMAIL"
    echo "USE_BATCH=$USE_BATCH"
    echo "BATCH_SIZE=$BATCH_SIZE"
    echo "USE_INDEX=$USE_INDEX"
    echo "USE_DEDUP=$USE_DEDUP"
    echo "SKIP_NOOP=$SKIP_NOOP"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  umask "$old_umask"
}

[[ ! -f "$CONFIG_FILE" ]] && save_config
load_config

# ============ 内置 API ============
BUILTIN_APIS=(
  "DeepSeek|openai|https://api.deepseek.com/v1/chat/completions|deepseek-chat"
  "OpenAI|openai|https://api.openai.com/v1/chat/completions|gpt-4o-mini"
  "Moonshot (Kimi)|openai|https://api.moonshot.cn/v1/chat/completions|moonshot-v1-8k"
  "通义千问|openai|https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions|qwen-plus"
  "智谱 GLM|openai|https://open.bigmodel.cn/api/paas/v4/chat/completions|glm-4-flash"
  "本地 Ollama|openai|http://localhost:11434/v1/chat/completions|qwen2.5:14b"
  "MyMemory (免密钥)|mymemory|https://api.mymemory.translated.net/get|"
  "B站翻译 (免密钥)|bilibili|https://index-translate.bilibili.com|"
  "谷歌翻译|google|https://translation.googleapis.com/v3/projects/__PROJECT__:translateText|"
  "有道翻译|youdao|https://openapi.youdao.com/api|"
  "百度翻译|baidu|https://fanyi-api.baidu.com/api/trans/vip/translate|"
  "必应翻译|azure|https://api.cognitive.microsofttranslator.com/translate?api-version=3.0|"
  "自定义|__CUSTOM__|__CUSTOM__|__CUSTOM__"
)

LANG_MAP=(
  "简体中文|Simplified Chinese|zh-CN|zh-CHS|zh|zh-Hans|zh-CN|zh"
  "繁體中文|Traditional Chinese|zh-TW|zh-CHT|cht|zh-Hant|zh-TW|zh"
  "English|English|en|en|en|en|en|en"
  "日本語|Japanese|ja|ja|jp|ja|ja|ja"
  "한국어|Korean|ko|ko|kor|ko|ko|ko"
  "Русский|Russian|ru|ru|ru|ru|ru|ru"
  "Français|French|fr|fr|fra|fr|fr|fr"
  "Deutsch|German|de|de|de|de|de|de"
  "Español|Spanish|es|es|spa|es|es|es"
  "自定义|__CUSTOM__|__CUSTOM__|__CUSTOM__|__CUSTOM__|__CUSTOM__|__CUSTOM__|__CUSTOM__"
)

# ============ 基础工具 ============
die() { echo "错误: $*" >&2; exit 1; }
c_info() { (( QUIET )) || echo "$@"; }

mask_secret() {
  local s="$1"
  if [[ -z "$s" ]]; then echo "(未设置)"
  elif (( ${#s} <= 8 )); then echo "********"
  else echo "${s:0:4}****${s: -4}"; fi
}

lang_code_for() {
  local display="$1" type="$2" row d prompt g y b a m bb
  for row in "${LANG_MAP[@]}"; do
    IFS='|' read -r d prompt g y b a m bb <<<"$row"
    if [[ "$d" == "$display" ]]; then
      case "$type" in
        google) echo "$g" ;; youdao) echo "$y" ;; baidu) echo "$b" ;;
        azure) echo "$a" ;; mymemory) echo "$m" ;; bilibili) echo "$bb" ;;
        *) echo "Simplified Chinese" ;;
      esac
      return 0
    fi
  done
  echo ""
}

supports_batch() {
  case "$API_TYPE" in
    openai|google|azure|bilibili) return 0 ;;
    *) return 1 ;;
  esac
}

is_noop() {
  local v="$1" stripped="$v" re
  [[ -z "${v//[[:space:][:punct:][:digit:]]/}" ]] && return 0
  re='^https?://[^[:space:]]+$'
  [[ "$v" =~ $re ]] && return 0
  while [[ "$stripped" =~ %[0-9]+\$[sd] ]]; do stripped="${stripped//${BASH_REMATCH[0]}/}"; done
  while [[ "$stripped" =~ %[0-9]*(\.[0-9]+)?[fFdD] ]]; do stripped="${stripped//${BASH_REMATCH[0]}/}"; done
  while [[ "$stripped" =~ %[sd] ]]; do stripped="${stripped//${BASH_REMATCH[0]}/}"; done
  while [[ "$stripped" =~ \{[0-9]*\} ]]; do stripped="${stripped//${BASH_REMATCH[0]}/}"; done
  while [[ "$stripped" =~ §. ]]; do stripped="${stripped//${BASH_REMATCH[0]}/}"; done
  [[ -z "${stripped//[[:space:][:punct:][:digit:]]/}" ]] && return 0
  return 1
}

_ESC=""
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  _ESC="$s"
}

declare -A IDX_TO_VALUE=() IDX_TO_KEYS=()
declare -a IDX_ORDER=()

build_index() {
  local groups_file="$1" idx key value
  IDX_ORDER=(); IDX_TO_VALUE=(); IDX_TO_KEYS=()
  while IFS= read -r -d '' idx && IFS= read -r -d '' key && IFS= read -r -d '' value; do
    if [[ -z "${IDX_TO_VALUE[$idx]+x}" ]]; then
      IDX_ORDER+=("$idx"); IDX_TO_VALUE[$idx]="$value"
    fi
    IDX_TO_KEYS[$idx]+="$key"$'\n'
  done < "$groups_file"
}

fetch_models() {
  local base_url="$1" key="$2" models_url
  if [[ "$base_url" == *"/chat/completions" ]]; then
    models_url="${base_url%/chat/completions}/models"
  elif [[ "$base_url" == *"/v1" ]]; then
    models_url="${base_url}/models"
  else
    models_url="${base_url%/}/models"
  fi
  local resp models
  resp=$(curl -sS --max-time 20 --connect-timeout 10 -X GET "$models_url" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" 2>/dev/null) || return 1
  models=$(printf '%s' "$resp" | jq -r '(.data // .models // [])[]? | (.id // .name // empty)' 2>/dev/null | sort -u)
  [[ -z "$models" ]] && return 1
  printf '%s\n' "$models"
}

# ============ Token / 时间统计 ============
STAT_PT=0; STAT_CT=0; STAT_TT=0

_record_usage() {
  local resp="$1" line p c t
  line=$(printf '%s' "$resp" | jq -r \
    '"\(.usage.prompt_tokens // 0) \(.usage.completion_tokens // 0) \(.usage.total_tokens // 0)"' \
    2>/dev/null) || line="0 0 0"
  [[ -z "$line" ]] && line="0 0 0"
  read -r p c t <<< "$line"
  (( ${t:-0} > 0 )) && printf '%s %s %s\n' "${p:-0}" "${c:-0}" "${t:-0}" \
    >> "${TOKENS_LOG:-/dev/null}" 2>/dev/null
  return 0
}

_read_token_stats() {
  STAT_PT=0; STAT_CT=0; STAT_TT=0
  [[ -s "${TOKENS_LOG:-}" ]] || return 0
  local p c t
  read -r p c t < <(
    awk '{p+=$1; c+=$2; t+=$3} END {print p+0, c+0, t+0}' "$TOKENS_LOG" 2>/dev/null
  ) || return 0
  STAT_PT=${p:-0}; STAT_CT=${c:-0}; STAT_TT=${t:-0}
  return 0
}

_format_duration() {
  local secs="$1"
  if (( secs < 60 )); then echo "${secs} 秒"
  elif (( secs < 3600 )); then echo "$((secs / 60)) 分 $((secs % 60)) 秒"
  else echo "$((secs / 3600)) 时 $(( (secs % 3600) / 60 )) 分 $((secs % 60)) 秒"
  fi
}

# ============ 文件选择器（优化版）============
# 结果写入全局变量 MCTS_FILE_RESULT
# 返回 0 = 选中，1 = 取消
_mcts_fb_scan() {
  local dir="$1"
  local -n _dirs="$2" _files="$3"
  _dirs=(); _files=()
  local path name
  shopt -s nullglob dotglob
  for path in "$dir"/*; do
    [[ -e "$path" ]] || continue
    name=$(basename "$path")
    [[ "$name" == "." || "$name" == ".." ]] && continue
    if [[ -d "$path" ]]; then _dirs+=("$name")
    else _files+=("$name")
    fi
  done
  shopt -u nullglob dotglob
}

mcts_file_browser() {
  local start_dir="${1:-.}"
  local title="${2:-文件选择器 / File Explorer}"
  local current_dir sel name size count
  local -a menu_items=() dirs=() files=()

  if ! current_dir=$(cd "$start_dir" 2>/dev/null && pwd); then
    dialog --title "错误" --msgbox "目录不存在: $start_dir" 8 60
    return 1
  fi
  MCTS_FILE_RESULT=""

  while true; do
    menu_items=()
    _mcts_fb_scan "$current_dir" dirs files

    if [[ "$current_dir" != "/" ]]; then
      menu_items+=(".." "📁 ← 返回上级")
    fi

    local d f
    for d in "${dirs[@]}"; do
      count=$(find "$current_dir/$d" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
      menu_items+=("$d" "📁 $d/  ($count 项)")
    done
    for f in "${files[@]}"; do
      size=$(du -h "$current_dir/$f" 2>/dev/null | cut -f1)
      if [[ "$f" == *.json ]]; then
        menu_items+=("$f" "📄 $f  [$size]  ✓")
      else
        menu_items+=("$f" "📄 $f  [$size]")
      fi
    done

    if (( ${#dirs[@]} == 0 && ${#files[@]} == 0 )); then
      if [[ "$current_dir" == "/" ]]; then
        dialog --title "$title" --msgbox "目录为空: $current_dir" 8 60
        return 1
      fi
      dialog --title "$title" --msgbox "目录为空:\n$current_dir\n\n按 OK 返回上级" 10 60
      current_dir=$(dirname "$current_dir")
      continue
    fi

    sel=$(dialog --stdout --title "$title" \
      --menu "目录: $current_dir\n  ${#dirs[@]} 个文件夹 · ${#files[@]} 个文件" \
      24 90 16 "${menu_items[@]}") || return 1

    if [[ "$sel" == ".." ]]; then
      current_dir=$(dirname "$current_dir")
    elif [[ -d "$current_dir/$sel" ]]; then
      current_dir="$current_dir/$sel"
    elif [[ -f "$current_dir/$sel" ]]; then
      if dialog --title "确认选择" --yesno "文件: $sel\n\n路径: $current_dir/$sel\n\n确认选择此文件？" 12 70; then
        MCTS_FILE_RESULT="$current_dir/$sel"
        return 0
      fi
    fi
  done
}

# ============ 单条翻译 ============
translate_one_openai() {
  local text="$1" payload resp
  payload=$(jq -n --arg model "$MODEL" \
    --arg sys "Translate the following Minecraft mod string into ${TARGET_LANG}. Keep placeholders like %s %d {0} and § codes unchanged. Output ONLY the translation, no quotes, no explanations." \
    --arg user "$text" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:$user}], temperature:0}')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "$API_URL" \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$payload") || return 1
  printf '%s' "$resp" | jq -e '.choices[0].message.content' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  _record_usage "$resp"
  printf '%s' "$resp" | jq -r '.choices[0].message.content' \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*//; s/[[:space:]]*```[[:space:]]*$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/'
}

translate_one_google() {
  local text="$1" payload resp
  payload=$(jq -n --arg target "$TARGET_CODE" --arg q "$text" \
    '{targetLanguageCode:$target, contents:[$q], mimeType:"text/plain"}')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "$API_URL" \
    -H "Content-Type: application/json" -H "X-Goog-Api-Key: $API_KEY" -d "$payload") || return 1
  printf '%s' "$resp" | jq -e '.translations[0].translatedText' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  printf '%s' "$resp" | jq -r '.translations[0].translatedText'
}

translate_one_youdao() {
  local text="$1" salt curtime sign sign_input resp
  salt=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
  curtime=$(date +%s)
  if (( ${#text} > 20 )); then sign_input="${text:0:10}${#text}${text: -10}"; else sign_input="$text"; fi
  sign=$(printf '%s' "${API_KEY}${sign_input}${salt}${curtime}${API_SECRET}" | openssl dgst -sha256 | awk '{print $NF}')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "$API_URL" \
    --data-urlencode "q=$text" --data-urlencode "from=auto" --data-urlencode "to=$TARGET_CODE" \
    --data-urlencode "appKey=$API_KEY" --data-urlencode "salt=$salt" \
    --data-urlencode "curtime=$curtime" --data-urlencode "sign=$sign" --data-urlencode "signType=v3") || return 1
  printf '%s' "$resp" | jq -e '.errorCode == "0"' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  printf '%s' "$resp" | jq -r '.translation[0]'
}

translate_one_baidu() {
  local text="$1" salt sign resp
  salt=$(date +%s%N | cut -c1-10)
  sign=$(printf '%s' "${API_KEY}${text}${salt}${API_SECRET}" | md5sum | awk '{print $1}')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "$API_URL" \
    --data-urlencode "q=$text" --data-urlencode "from=auto" --data-urlencode "to=$TARGET_CODE" \
    --data-urlencode "appid=$API_KEY" --data-urlencode "salt=$salt" --data-urlencode "sign=$sign") || return 1
  printf '%s' "$resp" | jq -e '.trans_result' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  printf '%s' "$resp" | jq -r '.trans_result[0].dst'
}

translate_one_azure() {
  local text="$1" arr resp
  arr=$(jq -n --arg q "$text" '[{Text:$q}]')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "${API_URL}&to=$TARGET_CODE" \
    -H "Ocp-Apim-Subscription-Key: $API_KEY" \
    -H "Ocp-Apim-Subscription-Region: $API_REGION" \
    -H "Content-Type: application/json" -d "$arr") || return 1
  printf '%s' "$resp" | jq -e '.[0].translations[0].text' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  printf '%s' "$resp" | jq -r '.[0].translations[0].text'
}

translate_one_mymemory() {
  local text="$1" resp
  text="${text:0:480}"
  local extra=()
  [[ -n "$MYMEMORY_EMAIL" ]] && extra=(--data-urlencode "de=$MYMEMORY_EMAIL")
  resp=$(curl -sS --max-time 30 --connect-timeout 10 -G "$API_URL" \
    --data-urlencode "q=$text" --data-urlencode "langpair=en|${TARGET_CODE}" "${extra[@]}") || return 1
  printf '%s' "$resp" | jq -e '.responseData.translatedText' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  printf '%s' "$resp" | jq -r '.responseData.translatedText'
}

translate_one_bilibili() {
  local text="$1" payload resp
  payload=$(jq -n --arg model "index-mt-9b-syllable" \
    --arg sys "Translate into ${TARGET_LANG}. Keep placeholders and § codes. Output ONLY translation." \
    --arg user "$text" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:$user}], temperature:0}')
  resp=$(curl -sS --max-time 60 --connect-timeout 10 -X POST "${API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" -d "$payload") || return 1
  printf '%s' "$resp" | jq -e '.choices[0].message.content' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  _record_usage "$resp"
  printf '%s' "$resp" | jq -r '.choices[0].message.content' \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*//; s/[[:space:]]*```[[:space:]]*$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/'
}

translate_one() {
  case "$API_TYPE" in
    openai) translate_one_openai "$1" ;;
    google) translate_one_google "$1" ;;
    youdao) translate_one_youdao "$1" ;;
    baidu) translate_one_baidu "$1" ;;
    azure) translate_one_azure "$1" ;;
    mymemory) translate_one_mymemory "$1" ;;
    bilibili) translate_one_bilibili "$1" ;;
    *) return 1 ;;
  esac
}

# ============ 批量翻译 ============
translate_batch_openai() {
  local batch_json="$1" system_prompt
  if [[ "$USE_INDEX" == 1 ]]; then
    system_prompt="Translate the VALUES of this JSON object into ${TARGET_LANG}. Keys are numeric indices; keep ALL keys EXACTLY unchanged. Preserve placeholders like %s %d %1\$s {0} and § color codes. Return ONLY a valid JSON object with the same keys, no markdown, no explanations."
  else
    system_prompt="Translate the VALUES of this JSON object into ${TARGET_LANG}. Keep ALL keys EXACTLY unchanged. Preserve placeholders like %s %d %1\$s {0} and § color codes. Return ONLY a valid JSON object with the same keys, no markdown, no explanations."
  fi
  local payload
  payload=$(jq -n --arg model "$MODEL" --arg sys "$system_prompt" --arg user "$batch_json" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:$user}], temperature:0}')
  local resp content
  resp=$(curl -sS --max-time 180 --connect-timeout 10 -X POST "$API_URL" \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" -d "$payload") || return 1
  printf '%s' "$resp" | jq -e '.choices[0].message.content' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  _record_usage "$resp"
  content=$(printf '%s' "$resp" | jq -r '.choices[0].message.content' \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*//; s/[[:space:]]*```[[:space:]]*$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s' "$content" | jq empty >/dev/null 2>&1 || { printf '%s' "$content" >&2; return 1; }
  printf '%s' "$content"
}

translate_batch_google() {
  local batch_json="$1" contents keys payload resp
  contents=$(printf '%s' "$batch_json" | jq -c '[.[]]')
  keys=$(printf '%s' "$batch_json" | jq -c 'keys')
  payload=$(jq -n --arg target "$TARGET_CODE" --argjson contents "$contents" \
    '{targetLanguageCode:$target, contents:$contents, mimeType:"text/plain"}')
  resp=$(curl -sS --max-time 180 --connect-timeout 10 -X POST "$API_URL" \
    -H "Content-Type: application/json" -H "X-Goog-Api-Key: $API_KEY" -d "$payload") || return 1
  printf '%s' "$resp" | jq -e '.translations' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  jq -n --argjson keys "$keys" --argjson t "$(printf '%s' "$resp" | jq '.translations')" \
    'reduce range(0; $keys|length) as $i ({}; .[$keys[$i]] = $t[$i].translatedText)'
}

translate_batch_azure() {
  local batch_json="$1" arr keys resp
  arr=$(printf '%s' "$batch_json" | jq -c '[.[] | {Text: .}]')
  keys=$(printf '%s' "$batch_json" | jq -c 'keys')
  resp=$(curl -sS --max-time 180 --connect-timeout 10 -X POST "${API_URL}&to=$TARGET_CODE" \
    -H "Ocp-Apim-Subscription-Key: $API_KEY" \
    -H "Ocp-Apim-Subscription-Region: $API_REGION" \
    -H "Content-Type: application/json" -d "$arr") || return 1
  printf '%s' "$resp" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 || { printf '%s' "$resp" >&2; return 1; }
  jq -n --argjson keys "$keys" --argjson r "$resp" \
    'reduce range(0; $keys|length) as $i ({}; .[$keys[$i]] = $r[$i].translations[0].text)'
}

translate_batch() {
  case "$API_TYPE" in
    openai|bilibili) translate_batch_openai "$1" ;;
    google) translate_batch_google "$1" ;;
    azure) translate_batch_azure "$1" ;;
    *) return 1 ;;
  esac
}

# ============ 输出重建 ============
rebuild_output() {
  local input="$1" ndjson="$2" output="$3" tmp="$TMPDIR_RUN/rebuild.tmp"
  local input_copy="$TMPDIR_RUN/rebuild_input.json"
  jq -c '.' "$input" > "$input_copy" || return 1
  if [[ -s "$ndjson" ]]; then
    jq -s --slurpfile orig "$input_copy" '
      (reduce .[] as $x ({}; . + {($x.key): $x.value})) as $t
      | $orig[0] | with_entries(.value = ($t[.key] // .value))
    ' "$ndjson" > "$tmp" 2>/dev/null && mv "$tmp" "$output"
  else
    cp "$input_copy" "$output"
  fi
}

# ============ 预处理 ============
prepare_groups() {
  local pending_file="$1" groups_file="$2" stats_file="$3"
  local -A val_to_group
  local skip_count=0 dedup_count=0 unique_count=0 total=0 group_idx=0
  local stream="$TMPDIR_RUN/stream.bin"
  jq -j 'to_entries[] | .key, "\u0000", .value, "\u0000"' "$pending_file" > "$stream" || return 1
  exec 4>"$groups_file"
  local key value idx
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    total=$((total+1))
    if (( SKIP_NOOP == 1 )) && is_noop "$value"; then skip_count=$((skip_count+1)); continue; fi
    if (( USE_DEDUP == 1 )) && [[ -n "${val_to_group[$value]+x}" ]]; then
      idx="${val_to_group[$value]}"
      dedup_count=$((dedup_count+1))
    else
      val_to_group["$value"]="$group_idx"
      idx="$group_idx"
      unique_count=$((unique_count+1))
      group_idx=$((group_idx+1))
    fi
    printf '%s\0%s\0%s\0' "$idx" "$key" "$value" >&4
  done < "$stream"
  exec 4>&-
  rm -f "$stream"
  printf 'TOTAL=%d\nSKIP=%d\nDEDUP=%d\nUNIQUE=%d\n' "$total" "$skip_count" "$dedup_count" "$unique_count" > "$stats_file"
}

# ============ 单条模式 ============
process_entries_single() {
  local groups_file="$1" ndjson="$2" errfile="$3" total="$4" baseline="$5"
  build_index "$groups_file"
  local unique_total=${#IDX_ORDER[@]}
  echo "5"; echo "XXX"
  echo "启动（逐条）：总 $total，已完成 $baseline，待译唯一 $unique_total，并发 $CONCURRENCY"
  echo "XXX"
  (( unique_total == 0 )) && { echo "100"; echo "XXX"; echo "无待翻译"; echo "XXX"; return 0; }
  exec 3>>"$ndjson"
  local -a pids=()
  local completed=0 max_jobs=$CONCURRENCY
  local recent_log="$TMPDIR_RUN/recent.log"; : > "$recent_log"
  local idx value
  for idx in "${IDX_ORDER[@]}"; do
    value="${IDX_TO_VALUE[$idx]}"
    local keys_str="${IDX_TO_KEYS[$idx]}"
    (
      local t
      t=$(translate_one "$value" 2>>"$errfile") || t=""
      [[ -z "$t" ]] && t="$value"
      case "$API_TYPE" in youdao) sleep 1.1 ;; baidu) sleep 0.6 ;; mymemory) sleep 0.5 ;; esac
      (( REQUEST_DELAY > 0 )) && sleep "$REQUEST_DELAY"
      _json_escape "$t"; local ev="$_ESC" k
      while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        _json_escape "$k"
        printf '{"key":"%s","value":"%s"}\n' "$_ESC" "$ev" >&3
      done <<< "$keys_str"
    ) &
    pids+=($!)
    if (( ${#pids[@]} >= max_jobs )); then
      wait "${pids[0]}" 2>/dev/null
      pids=("${pids[@]:1}")
      completed=$((completed+1))
      local current_count pct last_line
      current_count=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
      last_line=$(tail -n 1 "$ndjson" 2>/dev/null)
      [[ -n "$last_line" ]] && printf '%s => %s\n' \
        "$(printf '%s' "$last_line" | jq -r '.key' 2>/dev/null)" \
        "$(printf '%s' "$last_line" | jq -r '.value[:50]' 2>/dev/null)" >> "$recent_log"
      tail -n 3 "$recent_log" > "$recent_log.tmp" 2>/dev/null && mv "$recent_log.tmp" "$recent_log" 2>/dev/null
      pct=$(( current_count * 100 / total )); (( pct > 99 )) && pct=99
      echo "$pct"; echo "XXX"
      echo "进度: $current_count / $total  唯一组: $completed / $unique_total"
      echo ""; echo "最近完成:"; sed 's/^/  /' "$recent_log" 2>/dev/null
      echo "XXX"
    fi
  done
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null
    completed=$((completed+1))
    local current_count pct
    current_count=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
    pct=$(( current_count * 100 / total )); (( pct > 99 )) && pct=99
    echo "$pct"; echo "XXX"
    echo "进度: $current_count / $total"
    echo "最近完成:"; sed 's/^/  /' "$recent_log" 2>/dev/null
    echo "XXX"
  done
  exec 3>&-
  echo "100"; echo "XXX"; echo "本轮完成"; echo "XXX"
}

# ============ 单批任务 ============
_process_batch_job() {
  local start="$1" end="$2" ndjson_fd="$3" errfile="$4"
  local batch_json="{" first=1 j
  for (( j=start; j<end; j++ )); do
    local idx="${IDX_ORDER[$j]}" value="${IDX_TO_VALUE[$idx]}" k
    if (( USE_INDEX == 1 )); then k="$idx"; else k="${IDX_TO_KEYS[$idx]%%$'\n'*}"; fi
    _json_escape "$value"
    (( first )) || batch_json+=","
    batch_json+="\"$k\":\"$_ESC\""
    first=0
  done
  batch_json+="}"
  local result ok=0 attempt
  for attempt in 1 2 3; do
    if result=$(translate_batch "$batch_json" 2>>"$errfile"); then
      local expected got
      expected=$(printf '%s' "$batch_json" | jq -cS 'keys')
      got=$(printf '%s' "$result" | jq -cS 'keys' 2>/dev/null || echo "[]")
      if [[ "$expected" == "$got" ]]; then ok=1; break; fi
    fi
    sleep 3
  done
  if (( ok == 1 )); then
    local idx_keys_json
    idx_keys_json=$(
      for (( j=start; j<end; j++ )); do
        local idx="${IDX_ORDER[$j]}"
        if (( USE_INDEX == 1 )); then echo "$idx"
        else echo "${IDX_TO_KEYS[$idx]%%$'\n'*}"
        fi
      done | jq -Rn '[inputs]'
    )
    local -a trans_array=()
    mapfile -t trans_array < <(printf '%s' "$result" | jq -r --argjson keys "$idx_keys_json" '.[$keys[]] // ""')
    for (( j=start; j<end; j++ )); do
      local idx="${IDX_ORDER[$j]}"
      local translation="${trans_array[$((j-start))]}"
      [[ -z "$translation" ]] && translation="${IDX_TO_VALUE[$idx]}"
      _json_escape "$translation"; local ev="$_ESC" k
      while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        _json_escape "$k"
        printf '{"key":"%s","value":"%s"}\n' "$_ESC" "$ev" >&"$ndjson_fd"
      done <<< "${IDX_TO_KEYS[$idx]}"
    done
  else
    printf '[批量失败，逐条回退]\n' >> "$errfile"
    for (( j=start; j<end; j++ )); do
      local idx="${IDX_ORDER[$j]}" value="${IDX_TO_VALUE[$idx]}" t
      t=$(translate_one "$value" 2>>"$errfile") || t=""
      [[ -z "$t" ]] && t="$value"
      _json_escape "$t"; local ev="$_ESC" k
      while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        _json_escape "$k"
        printf '{"key":"%s","value":"%s"}\n' "$_ESC" "$ev" >&"$ndjson_fd"
      done <<< "${IDX_TO_KEYS[$idx]}"
    done
  fi
}

# ============ 批量模式 ============
process_entries_batched() {
  local groups_file="$1" ndjson="$2" errfile="$3" total="$4" baseline="$5"
  build_index "$groups_file"
  local unique_total=${#IDX_ORDER[@]}
  echo "5"; echo "XXX"
  echo "启动（批量）：总 $total，待译唯一 $unique_total，每批 $BATCH_SIZE，并发 $CONCURRENCY 批"
  echo "XXX"
  (( unique_total == 0 )) && { echo "100"; echo "XXX"; echo "无待翻译"; echo "XXX"; return 0; }
  exec 4>>"$ndjson"
  local NDJSON_FD=4
  local batches=$(( (unique_total + BATCH_SIZE - 1) / BATCH_SIZE ))
  local batch_idx=0 start=0
  local recent_log="$TMPDIR_RUN/recent.log"; : > "$recent_log"
  local -a pids=()
  local completed_batches=0 max_jobs=$CONCURRENCY
  while (( start < unique_total )); do
    batch_idx=$((batch_idx+1))
    local end=$(( start + BATCH_SIZE ))
    (( end > unique_total )) && end=$unique_total
    _process_batch_job "$start" "$end" "$NDJSON_FD" "$errfile" &
    pids+=($!)
    if (( ${#pids[@]} >= max_jobs )); then
      wait "${pids[0]}" 2>/dev/null
      pids=("${pids[@]:1}")
      completed_batches=$((completed_batches+1))
      local current_count pct last_preview
      current_count=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
      pct=$(( current_count * 100 / total )); (( pct > 99 )) && pct=99
      last_preview=$(tail -n 1 "$ndjson" 2>/dev/null | jq -r '"\(.key) => \(.value[:40])"' 2>/dev/null)
      [[ -n "$last_preview" ]] && echo "$last_preview" >> "$recent_log"
      tail -n 3 "$recent_log" > "$recent_log.tmp" 2>/dev/null && mv "$recent_log.tmp" "$recent_log" 2>/dev/null
      echo "$pct"; echo "XXX"
      echo "批次 $completed_batches/$batches 完成  → 条目 $current_count / $total  并发运行中: ${#pids[@]}"
      echo ""; echo "最近完成:"; sed 's/^/  /' "$recent_log"
      echo "XXX"
      (( REQUEST_DELAY > 0 )) && sleep "$REQUEST_DELAY"
    fi
    start=$end
  done
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null
    completed_batches=$((completed_batches+1))
    local current_count pct
    current_count=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
    pct=$(( current_count * 100 / total )); (( pct > 99 )) && pct=99
    echo "$pct"; echo "XXX"
    echo "批次 $completed_batches/$batches 完成  → 条目 $current_count / $total"
    echo "最近完成:"; sed 's/^/  /' "$recent_log" 2>/dev/null
    echo "XXX"
  done
  exec 4>&-
  echo "100"; echo "XXX"; echo "全部批次完成"; echo "XXX"
}

# ============ 主翻译流程 ============
run_translation() {
  local input="$1" pending_file="$2" existing_ok_file="$3" output="$4"
  local total="$5" baseline="$6"
  local ndjson="$TMPDIR_RUN/results.ndjson"
  local errfile="$TMPDIR_RUN/worker.err"
  local fifo="$TMPDIR_RUN/progress.fifo"
  local groups_file="$TMPDIR_RUN/groups.bin"
  local stats_file="$TMPDIR_RUN/stats.txt"

  rm -f "$ndjson" "$errfile" "$fifo" "$groups_file" "$stats_file" "$TOKENS_LOG"
  : > "$TOKENS_LOG"
  cp "$existing_ok_file" "$ndjson" 2>/dev/null || touch "$ndjson"
  mkfifo "$fifo"
  CURRENT_INPUT="$input"; CURRENT_OUTPUT="$output"; CURRENT_NDJSON="$ndjson"

  local mode="逐条"
  if (( USE_BATCH == 1 )) && supports_batch; then
    mode="批量（每批 $BATCH_SIZE 条，并发 $CONCURRENCY 批）"
  fi

  local start_time; start_time=$(date +%s)

  (
    _worker_cleanup() {
      local j
      for j in $(jobs -p 2>/dev/null); do kill "$j" 2>/dev/null; done
      exec 3>&-
      exit 0
    }
    trap _worker_cleanup TERM

    exec 3>"$fifo"
    echo "0" >&3; echo "XXX" >&3
    echo "准备中：读取输入（$total 条）..." >&3
    echo "XXX" >&3

    rebuild_output "$input" "$ndjson" "$output"

    echo "2" >&3; echo "XXX" >&3
    echo "准备中：预处理（跳过/去重）..." >&3
    echo "XXX" >&3

    prepare_groups "$pending_file" "$groups_file" "$stats_file"

    local st_skip st_dedup st_unique
    st_skip=$(grep '^SKIP=' "$stats_file" 2>/dev/null | cut -d= -f2); st_skip=${st_skip:-0}
    st_dedup=$(grep '^DEDUP=' "$stats_file" 2>/dev/null | cut -d= -f2); st_dedup=${st_dedup:-0}
    st_unique=$(grep '^UNIQUE=' "$stats_file" 2>/dev/null | cut -d= -f2); st_unique=${st_unique:-0}

    local est_requests
    if (( USE_BATCH == 1 )) && supports_batch; then
      est_requests=$(( (st_unique + BATCH_SIZE - 1) / BATCH_SIZE ))
    else
      est_requests=$st_unique
    fi

    echo "5" >&3; echo "XXX" >&3
    echo "预处理完成: 跳过 $st_skip / 去重 $st_dedup / 唯一 $st_unique，预估 $est_requests 次请求" >&3
    echo "开始翻译..." >&3
    echo "XXX" >&3

    if [[ "$mode" == 逐条* ]]; then
      process_entries_single "$groups_file" "$ndjson" "$errfile" "$total" "$baseline" >&3 2>&1
    else
      process_entries_batched "$groups_file" "$ndjson" "$errfile" "$total" "$baseline" >&3 2>&1
    fi
    exec 3>&-
  ) &
  WORKER_PID=$!

  (
    sleep 10
    local last=$baseline
    while kill -0 "$WORKER_PID" 2>/dev/null; do
      local c
      c=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
      if (( c - last >= 500 )); then
        rebuild_output "$input" "$ndjson" "$output" 2>/dev/null
        last=$c
      fi
      sleep 3
    done
  ) &
  REBUILDER_PID=$!

  if (( HEADLESS )); then
    local current_pct=0 last_shown_pct=-1 last_msg="正在准备..." is_tty=0
    [[ -t 1 ]] && is_tty=1
    while IFS= read -r line; do
      if [[ "$line" == "XXX" ]]; then
        if (( ! QUIET )) && (( current_pct != last_shown_pct )); then
          (( ${#last_msg} > 70 )) && last_msg="${last_msg:0:67}..."
          if (( is_tty )); then
            printf '\r\033[K[%3d%%] %s' "$current_pct" "$last_msg"
          else
            printf '[%3d%%] %s\n' "$current_pct" "$last_msg"
          fi
          last_shown_pct=$current_pct
        fi
        continue
      fi
      if [[ "$line" =~ ^[0-9]+$ ]]; then current_pct="$line"; continue; fi
      [[ -z "$line" ]] && continue
      [[ "$line" == "最近完成:" ]] && continue
      [[ "$line" == *"=>"* ]] && continue
      last_msg="$line"
    done < "$fifo"
    (( is_tty && ! QUIET )) && printf '\n'
  else
    dialog --title "翻译中 —— $mode —— $API_NAME${MODEL:+ / $MODEL} / $TARGET_LANG" \
      --gauge "正在准备，请稍候..." 22 110 0 < "$fifo" || true
  fi

  wait "$WORKER_PID" 2>/dev/null
  kill "$REBUILDER_PID" 2>/dev/null
  wait "$REBUILDER_PID" 2>/dev/null
  rm -f "$fifo"
  WORKER_PID=""; REBUILDER_PID=""

  rebuild_output "$input" "$ndjson" "$output"
  CURRENT_INPUT=""; CURRENT_OUTPUT=""; CURRENT_NDJSON=""

  local end_time duration
  end_time=$(date +%s); duration=$(( end_time - start_time ))
  _read_token_stats

  local count fail
  count=$(wc -l < "$ndjson" 2>/dev/null || echo 0)
  fail=$(( total - count ))

  local st_total st_skip st_dedup st_unique
  st_total=$(grep '^TOTAL=' "$stats_file" 2>/dev/null | cut -d= -f2); st_total=${st_total:-0}
  st_skip=$(grep '^SKIP=' "$stats_file" 2>/dev/null | cut -d= -f2); st_skip=${st_skip:-0}
  st_dedup=$(grep '^DEDUP=' "$stats_file" 2>/dev/null | cut -d= -f2); st_dedup=${st_dedup:-0}
  st_unique=$(grep '^UNIQUE=' "$stats_file" 2>/dev/null | cut -d= -f2); st_unique=${st_unique:-0}

  local est_requests
  if (( USE_BATCH == 1 )) && supports_batch; then
    est_requests=$(( (st_unique + BATCH_SIZE - 1) / BATCH_SIZE ))
  else
    est_requests=$st_unique
  fi
  local old_requests=$st_total saved_pct=0
  (( old_requests > 0 )) && saved_pct=$(( (old_requests - est_requests) * 100 / old_requests ))

  local dur_str; dur_str=$(_format_duration "$duration")

  local report=""
  report+="完成: $count / $total"
  (( fail > 0 )) && report+=$'\n'"仍未翻译: $fail 条"
  report+=$'\n'"耗时: $dur_str"
  if (( STAT_TT > 0 )); then
    report+=$'\n'"Token: 输入 $STAT_PT / 输出 $STAT_CT / 合计 $STAT_TT"
  fi
  report+=$'\n\n── 优化统计 ──'
  report+=$'\n'"总条目: $st_total"
  report+=$'\n'"跳过: $st_skip  |  去重: $st_dedup  |  唯一: $st_unique"
  report+=$'\n'"模式: $mode"
  report+=$'\n'"请求: $est_requests 次（原逐条 $old_requests，省 $saved_pct%）"
  report+=$'\n'"引擎: $API_NAME${MODEL:+ / $MODEL} / $TARGET_LANG"
  report+=$'\n'"输出: $output"

  if (( HEADLESS )); then
    echo ""
    echo "═══════════════════════════════════════"
    printf '%s\n' "$report"
    echo "═══════════════════════════════════════"
  else
    dialog --title "翻译完成" --msgbox "$report" 24 80
  fi
}

# ============ 语言/API 解析 ============
resolve_api() {
  local input="$1"
  if [[ "$input" == http* ]]; then
    API_URL="$input"
    [[ -z "$API_TYPE" ]] && { API_TYPE="openai"; API_NAME="自定义"; }
    return 0
  fi
  local entry lname
  for entry in "${BUILTIN_APIS[@]}"; do
    lname="${entry%%|*}"
    if [[ "${lname,,}" == "${input,,}" ]]; then
      local _n _t _u _m
      IFS='|' read -r _n _t _u _m <<<"$entry"
      API_NAME="$_n"; API_TYPE="$_t"; API_URL="$_u"
      [[ -n "$_m" && -z "$MODEL" ]] && MODEL="$_m"
      return 0
    fi
  done
  case "${input,,}" in
    ds|deepseek)   API_NAME="DeepSeek";  API_TYPE="openai";   API_URL="https://api.deepseek.com/v1/chat/completions"; [[ -z "$MODEL" ]] && MODEL="deepseek-chat" ;;
    oai|openai|gpt) API_NAME="OpenAI";   API_TYPE="openai";   API_URL="https://api.openai.com/v1/chat/completions"; [[ -z "$MODEL" ]] && MODEL="gpt-4o-mini" ;;
    kimi|moonshot) API_NAME="Moonshot";  API_TYPE="openai";   API_URL="https://api.moonshot.cn/v1/chat/completions"; [[ -z "$MODEL" ]] && MODEL="moonshot-v1-8k" ;;
    qwen|tongyi)   API_NAME="通义千问";  API_TYPE="openai";   API_URL="https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"; [[ -z "$MODEL" ]] && MODEL="qwen-plus" ;;
    glm|zhipu)     API_NAME="智谱GLM";   API_TYPE="openai";   API_URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"; [[ -z "$MODEL" ]] && MODEL="glm-4-flash" ;;
    ollama)        API_NAME="Ollama";    API_TYPE="openai";   API_URL="http://localhost:11434/v1/chat/completions"; [[ -z "$MODEL" ]] && MODEL="qwen2.5:14b" ;;
    mymemory|mm)   API_NAME="MyMemory";  API_TYPE="mymemory"; API_URL="https://api.mymemory.translated.net/get" ;;
    bilibili|bili) API_NAME="B站翻译";   API_TYPE="bilibili"; API_URL="https://index-translate.bilibili.com" ;;
    google)        API_NAME="谷歌";      API_TYPE="google";   API_URL="https://translation.googleapis.com/v3/projects/__PROJECT__:translateText" ;;
    youdao)        API_NAME="有道";      API_TYPE="youdao";   API_URL="https://openapi.youdao.com/api" ;;
    baidu)         API_NAME="百度";      API_TYPE="baidu";    API_URL="https://fanyi-api.baidu.com/api/trans/vip/translate" ;;
    azure|bing)    API_NAME="Azure";     API_TYPE="azure";    API_URL="https://api.cognitive.microsofttranslator.com/translate?api-version=3.0" ;;
    *) return 1 ;;
  esac
  return 0
}

resolve_lang() {
  local input="$1" row d prompt g y b a m bb
  for row in "${LANG_MAP[@]}"; do
    IFS='|' read -r d prompt g y b a m bb <<<"$row"
    if [[ "${d,,}" == "${input,,}" || "${prompt,,}" == "${input,,}" ]]; then
      TARGET_LANG="$prompt"; return 0
    fi
  done
  for row in "${LANG_MAP[@]}"; do
    IFS='|' read -r d prompt g y b a m bb <<<"$row"
    if [[ "$g" == "$input" || "$y" == "$input" || "$b" == "$input" || "$a" == "$input" || "$m" == "$input" || "$bb" == "$input" ]]; then
      TARGET_LANG="$prompt"; return 0
    fi
  done
  TARGET_LANG="$input"
}

# ============ TUI 组件 ============
msg() { dialog --title "${2:-提示}" --msgbox "$1" 14 70; }
err() { dialog --title "错误" --msgbox "$1" 18 70; }
confirm() { dialog --title "${2:-确认}" --yesno "$1" 16 70; }

choose_model_from_list() {
  local base_url="$1" key="$2" default_model="$3"
  dialog --title "获取模型列表" --infobox "正在请求 /v1/models ..." 8 50
  local models rc
  models=$(fetch_models "$base_url" "$key"); rc=$?
  if (( rc != 0 )) || [[ -z "$models" ]]; then
    MODEL=$(dialog --stdout --title "模型（无法自动获取）" \
      --inputbox "无法获取模型列表，请手动输入模型 ID:" 12 70 "$default_model") || return
    return
  fi
  local items=() i=1 name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    items+=("$i" "$name"); i=$((i+1))
  done <<< "$models"
  local manual_idx=$i
  items+=("$manual_idx" "手动输入...")
  local sel
  sel=$(dialog --stdout --title "选择模型" \
    --menu "API: $API_NAME\n获取到 $((i-1)) 个模型:" 28 78 18 "${items[@]}") || return
  if [[ "$sel" == "$manual_idx" ]]; then
    MODEL=$(dialog --stdout --title "模型名称" --inputbox "手动输入模型 ID:" 10 70 "$default_model") || return
  else
    MODEL="${items[$((sel*2-1))]}"
  fi
}

show_config() {
  local batch_info="关闭"
  (( USE_BATCH == 1 )) && batch_info="开（每批 $BATCH_SIZE 条）"
  local content
  content=$(cat <<EOF
配置文件:
  $CONFIG_FILE

API 提供商 : ${API_NAME:-(未配置)}
API 类型   : ${API_TYPE:-(未配置)}
API URL    : ${API_URL:-(空)}
模型       : ${MODEL:-(空)}
API Key    : $(mask_secret "$API_KEY")
API Secret : $(mask_secret "$API_SECRET")
Region     : ${API_REGION:-(空)}
Project ID : ${PROJECT_ID:-(空)}

目标语言   : $TARGET_LANG
语言代码   : ${TARGET_CODE:-(未推导)}
并发数     : $CONCURRENCY
请求间隔   : ${REQUEST_DELAY}s

── Token 优化 ──
批量翻译   : $batch_info
索引代替key: $([[ "$USE_INDEX" == 1 ]] && echo 开 || echo 关)
去重       : $([[ "$USE_DEDUP" == 1 ]] && echo 开 || echo 关)
跳过无需翻 : $([[ "$SKIP_NOOP" == 1 ]] && echo 开 || echo 关)
EOF
)
  dialog --title "当前配置" --msgbox "$content" 30 78
}

reload_config() {
  [[ -f "$CONFIG_FILE" ]] || { err "配置文件不存在:\n$CONFIG_FILE"; return; }
  API_NAME=""; API_TYPE=""; API_URL=""; API_KEY=""; API_SECRET=""
  API_REGION=""; MODEL=""; PROJECT_ID=""
  TARGET_LANG="Simplified Chinese"; TARGET_CODE=""
  CONCURRENCY=3; REQUEST_DELAY=0; MYMEMORY_EMAIL=""
  USE_BATCH=1; BATCH_SIZE=20; USE_INDEX=1; USE_DEDUP=1; SKIP_NOOP=1
  load_config
  msg "配置已重新加载。" "已加载"
}

choose_api() {
  local items=() i=1 entry name type url model
  for entry in "${BUILTIN_APIS[@]}"; do
    name="${entry%%|*}"; items+=("$i" "$name"); i=$((i+1))
  done
  local sel
  sel=$(dialog --stdout --title "选择 API" --menu "请选择:" 26 72 14 "${items[@]}") || return
  entry="${BUILTIN_APIS[$((sel-1))]}"
  IFS='|' read -r name type url model <<<"$entry"
  if [[ "$type" == "__CUSTOM__" ]]; then
    type=$(dialog --stdout --title "自定义" --menu "接口类型:" 14 60 7 \
      1 "OpenAI 兼容" 2 "谷歌" 3 "有道" 4 "百度" 5 "Azure" 6 "MyMemory" 7 "B站") || return
    case "$type" in
      1) type=openai ;; 2) type=google ;; 3) type=youdao ;;
      4) type=baidu ;; 5) type=azure ;; 6) type=mymemory ;; 7) type=bilibili ;;
    esac
    url=$(dialog --stdout --title "URL" --inputbox "端点 URL:" 10 80 "") || return
  fi
  API_NAME="$name"; API_TYPE="$type"; API_URL="$url"; MODEL="$model"
  API_KEY=""; API_SECRET=""; API_REGION=""; PROJECT_ID=""
  case "$type" in
    openai)
      API_KEY=$(dialog --stdout --title "API Key" --insecure --passwordbox "API Key:" 10 70 "") || return
      [[ -n "$API_KEY" && -n "$API_URL" ]] && choose_model_from_list "$API_URL" "$API_KEY" "$model"
      ;;
    google)
      PROJECT_ID=$(dialog --stdout --title "项目 ID" --inputbox "PROJECT_ID:" 10 70 "") || return
      API_URL="${API_URL//__PROJECT__/$PROJECT_ID}"
      API_KEY=$(dialog --stdout --title "Google Key" --insecure --passwordbox "API Key:" 10 70 "") || return ;;
    youdao)
      API_KEY=$(dialog --stdout --title "有道 AppKey" --inputbox "AppKey:" 10 70 "") || return
      API_SECRET=$(dialog --stdout --title "有道 AppSecret" --insecure --passwordbox "AppSecret:" 10 70 "") || return ;;
    baidu)
      API_KEY=$(dialog --stdout --title "百度 APP ID" --inputbox "APP ID:" 10 70 "") || return
      API_SECRET=$(dialog --stdout --title "百度密钥" --insecure --passwordbox "SECRET_KEY:" 10 70 "") || return ;;
    azure)
      API_KEY=$(dialog --stdout --title "Azure Key" --insecure --passwordbox "订阅密钥:" 10 70 "") || return
      API_REGION=$(dialog --stdout --title "Azure Region" --inputbox "Region:" 10 70 "global") || return ;;
    mymemory)
      MYMEMORY_EMAIL=$(dialog --stdout --title "MyMemory 邮箱(可选)" --inputbox "日额度 5000→50000:" 10 70 "$MYMEMORY_EMAIL") || true ;;
    bilibili) msg "B站翻译免密钥。" "免密钥" ;;
  esac
  TARGET_CODE=$(lang_code_for "$TARGET_LANG" "$API_TYPE")
  if [[ -z "$TARGET_CODE" || "$TARGET_CODE" == "__CUSTOM__" ]]; then
    TARGET_CODE=$(dialog --stdout --title "语言代码" --inputbox "目标语言代码:" 10 60 "zh") || return
  fi
  case "$type" in
    youdao|baidu|mymemory) CONCURRENCY=1 ;;
    *) [[ "$CONCURRENCY" -lt 2 ]] && CONCURRENCY=3 ;;
  esac
  save_config
  msg "已配置并保存:\n\n$API_NAME\n模型: ${MODEL:-(空)}\n语言: $TARGET_LANG ($TARGET_CODE)\n并发: $CONCURRENCY" "完成"
}

choose_model_only() {
  [[ "$API_TYPE" != "openai" ]] && { msg "当前 API 类型为 $API_TYPE，不支持 /v1/models。" "提示"; return; }
  [[ -z "$API_KEY" ]] && { msg "尚未设置 API Key。" "提示"; return; }
  local prev="$MODEL"
  choose_model_from_list "$API_URL" "$API_KEY" "$MODEL"
  if [[ "$MODEL" != "$prev" && -n "$MODEL" ]]; then
    save_config; msg "模型已切换为:\n\n$MODEL" "完成"
  fi
}

choose_lang() {
  local items=() i=0 row
  for row in "${LANG_MAP[@]}"; do items+=("$i" "${row%%|*}"); i=$((i+1)); done
  local sel
  sel=$(dialog --stdout --title "语言" --menu "目标语言:" 22 60 12 "${items[@]}") || return
  IFS='|' read -r _ prompt _ <<<"${LANG_MAP[$sel]}"
  TARGET_LANG="$prompt"
  [[ "$prompt" == "__CUSTOM__" ]] && TARGET_LANG=$(dialog --stdout --title "自定义" --inputbox "英文名:" 10 70 "Simplified Chinese") || true
  if [[ -n "$API_TYPE" ]]; then
    TARGET_CODE=$(lang_code_for "$TARGET_LANG" "$API_TYPE")
    if [[ -z "$TARGET_CODE" || "$TARGET_CODE" == "__CUSTOM__" ]]; then
      TARGET_CODE=$(dialog --stdout --title "语言代码" --inputbox "代码:" 10 60 "zh") || return
    fi
  fi
  save_config
}

choose_perf() {
  local conc delay
  conc=$(dialog --stdout --title "并发数" --inputbox "并发请求数(1-20):" 14 70 "$CONCURRENCY") || return
  [[ "$conc" =~ ^[0-9]+$ ]] && (( conc >= 1 && conc <= 20 )) && CONCURRENCY="$conc"
  delay=$(dialog --stdout --title "请求间隔" --inputbox "每批完成后额外等待秒数:" 10 70 "$REQUEST_DELAY") || return
  [[ "$delay" =~ ^[0-9]+$ ]] && REQUEST_DELAY="$delay"
  save_config
}

choose_token_opt() {
  while true; do
    local b="关" i="关" d="关" s="关"
    (( USE_BATCH == 1 )) && b="开"
    (( USE_INDEX == 1 )) && i="开"
    (( USE_DEDUP == 1 )) && d="开"
    (( SKIP_NOOP == 1 )) && s="开"
    local choice
    choice=$(dialog --stdout --title "Token 优化" --menu \
      "【1】批量翻译 : $b（每批 $BATCH_SIZE）\n【2】索引代替key : $i\n【3】去重 : $d\n【4】跳过无需翻 : $s\n\n选择:" 22 78 6 \
      1 "切换 批量翻译" 2 "切换 索引" 3 "切换 去重" 4 "切换 跳过" \
      5 "设置每批条数（当前 $BATCH_SIZE）" 6 "返回") || return
    case "$choice" in
      1) USE_BATCH=$((1 - USE_BATCH)) ;;
      2) USE_INDEX=$((1 - USE_INDEX)) ;;
      3) USE_DEDUP=$((1 - USE_DEDUP)) ;;
      4) SKIP_NOOP=$((1 - SKIP_NOOP)) ;;
      5)
        local bs
        bs=$(dialog --stdout --title "批量大小" --inputbox "每批条数（5-100）:" 12 70 "$BATCH_SIZE") || continue
        [[ "$bs" =~ ^[0-9]+$ ]] && (( bs >= 5 && bs <= 100 )) && BATCH_SIZE="$bs"
        ;;
      6) save_config; return ;;
    esac
    save_config
  done
}

do_translate() {
  if [[ -z "$API_URL" && "$API_TYPE" != "mymemory" && "$API_TYPE" != "bilibili" ]]; then
    msg "尚未配置 API" "提示"; return
  fi

  # ★ 用文件浏览器代替 --fselect
  mcts_file_browser "$PWD" "选择输入 JSON 文件" || return
  local input="$MCTS_FILE_RESULT"
  [[ -z "$input" ]] && return
  [[ -f "$input" ]] || { err "文件不存在: $input"; return; }
  jq -e 'type == "object"' "$input" >/dev/null 2>&1 || { err "不是合法 JSON 对象:\n$input"; return; }

  local default_out
  default_out="$(dirname "$input")/$(basename "${input%.json}").translated.json"
  local output
  output=$(dialog --stdout --title "输出文件" --inputbox "输出路径:" 10 80 "$default_out") || return
  [[ -z "$output" ]] && return

  local input_copy="$TMPDIR_RUN/input_copy.json"
  jq -c '.' "$input" > "$input_copy" || { err "输入文件不是合法 JSON"; return 1; }

  local existing_file="$TMPDIR_RUN/existing.json"
  printf '{}\n' > "$existing_file"

  if [[ -f "$output" ]] && jq -e 'type=="object"' "$output" >/dev/null 2>&1; then
    local cnt
    cnt=$(jq 'length' "$output" 2>/dev/null || echo 0)
    if confirm "检测到输出文件已存在，共 $cnt 条内容:\n$output\n\nYes = 断点续传（跳过已翻译的）\nNo  = 从零开始（覆盖）" "断点续传"; then
      cp "$output" "$existing_file"
    fi
  fi

  local pending_file="$TMPDIR_RUN/pending.json"
  if ! jq -n --slurpfile input "$input_copy" --slurpfile done "$existing_file" '
    $input[0] | with_entries(
      . as $e
      | select(
          (($done[0] | has($e.key)) | not) or ($done[0][$e.key] == $e.value)
        )
    )
  ' > "$pending_file"; then
    err "计算待翻译列表失败"; return 1
  fi

  local existing_ok_file="$TMPDIR_RUN/existing_ok.ndjson"
  if ! jq -n --slurpfile input "$input_copy" --slurpfile done "$existing_file" '
    $done[0] | to_entries[]
    | select(.key as $k | $input[0] | has($k))
    | select(.value != $input[0][.key])
    | {key, value}
  ' > "$existing_ok_file"; then
    err "计算已翻译列表失败"; return 1
  fi

  local pending_count existing_ok_count total
  pending_count=$(jq 'length' "$pending_file" 2>/dev/null || echo 0)
  existing_ok_count=$(wc -l < "$existing_ok_file" 2>/dev/null || echo 0)
  total=$(jq 'length' "$input_copy" 2>/dev/null || echo 0)
  [[ "$pending_count" =~ ^[0-9]+$ ]] || pending_count=0
  [[ "$existing_ok_count" =~ ^[0-9]+$ ]] || existing_ok_count=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  (( total == 0 )) && { err "输入文件为空"; return 1; }
  if (( pending_count == 0 )); then
    msg "所有条目已翻译完成！\n\n总条目: $total\n已翻译: $existing_ok_count\n\n若想强制重翻，请选『从零开始』。" "无需翻译"
    return
  fi

  local mode_desc="逐条"
  (( USE_BATCH == 1 )) && supports_batch && mode_desc="批量 $BATCH_SIZE/批（并发 $CONCURRENCY 批）"

  confirm "确认开始？\n\n输入: $input\n输出: $output\n总条目: $total\n已翻译: $existing_ok_count（跳过）\n待翻译: $pending_count\n引擎: $API_NAME ($API_TYPE)\n模型: ${MODEL:-(空)}\n语言: $TARGET_LANG ($TARGET_CODE)\n模式: $mode_desc" "开始" || return

  run_translation "$input" "$pending_file" "$existing_ok_file" "$output" "$total" "$existing_ok_count"
}

# ============ CLI ============
cli_help() {
  cat <<EOF
${PROG} v${VERSION} —— Minecraft Mod 语言文件批量翻译器

用法:
  ${PROG}                      启动 TUI
  ${PROG} <input.json> [选项]  直接翻译
  ${PROG} translate <input> [选项]  同上（完整写法）
  ${PROG} models [选项]        列出 API 可用模型
  ${PROG} config               显示当前配置
  ${PROG} help                 本帮助
  ${PROG} version              版本

选项:
  -o, --output <file>    输出文件（默认 <input>.translated.json）
  -a, --api <name>       API 提供商（短名/全名/URL）
  -k, --key <key>        API Key
  -m, --model <model>    模型名
  -l, --lang <lang>      目标语言
  -j, --jobs <n>         并发数（默认 3）
  -b, --batch <n>        每批条数（默认 20）
  -d, --delay <sec>      每批间隔秒数
  -F, --fresh            从零开始（忽略已有输出）
  -q, --quiet            安静模式
  -O, --no-optimize      关闭所有 token 优化
      --secret <s>       有道/百度 AppSecret
      --region <r>       Azure Region
      --project <id>     谷歌 Cloud 项目 ID

API 短名:
  ds/deepseek  oai/openai  kimi  qwen  glm  ollama
  mm/mymemory  bili        google  youdao  baidu  azure/bing
  也可以直接传 URL: -a https://xxx/v1/chat/completions

示例:
  ${PROG} en_us.json
  ${PROG} en_us.json -a deepseek -l zh-CN
  ${PROG} en_us.json -a openai -m gpt-4o-mini -j 5 -o zh_cn.json
  ${PROG} en_us.json -a bili -F
  ${PROG} models -a deepseek

配置文件:
  ${CONFIG_FILE}
EOF
}

cli_show_config() {
  echo "配置文件: $CONFIG_FILE"
  echo "═══════════════════════════════════════"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "(配置文件不存在)"; return
  fi
  grep -v '^#' "$CONFIG_FILE" | grep -v '^$' \
    | sed 's/^API_KEY=.*/API_KEY=***REDACTED***/; s/^API_SECRET=.*/API_SECRET=***REDACTED***/'
}

cli_list_models() {
  local key=""
  while (( $# )); do
    case "$1" in
      -a|--api) shift; resolve_api "$1" || die "未知 API: $1"; shift ;;
      -k|--key) shift; key="$1"; shift ;;
      -h|--help) echo "用法: $PROG models [-a <api>] [-k <key>]"; return 0 ;;
      *) die "未知选项: $1" ;;
    esac
  done
  [[ -z "$API_URL" ]] && die "未配置 API，请用 -a 指定"
  [[ -z "$key" ]] && key="$API_KEY"
  [[ -z "$key" ]] && die "缺少 API Key，请用 -k 指定"
  echo "API: $API_NAME ($API_TYPE)"; echo "端点: $API_URL"
  echo "───────────────────────────────────────"
  local models
  models=$(fetch_models "$API_URL" "$key") || die "获取模型列表失败"
  echo "$models"
}

cli_translate() {
  local input="" output="" fresh=0
  while (( $# )); do
    case "$1" in
      -o|--output) shift; output="$1"; shift ;;
      -a|--api) shift; resolve_api "$1" || die "未知 API: $1"; shift ;;
      -k|--key) shift; API_KEY="$1"; shift ;;
      -m|--model) shift; MODEL="$1"; shift ;;
      -l|--lang) shift; resolve_lang "$1"; shift ;;
      -j|--jobs|--concurrency) shift; CONCURRENCY="$1"; shift ;;
      -b|--batch|--batch-size) shift; BATCH_SIZE="$1"; shift ;;
      -d|--delay) shift; REQUEST_DELAY="$1"; shift ;;
      -s|--secret) shift; API_SECRET="$1"; shift ;;
      -r|--region) shift; API_REGION="$1"; shift ;;
      --project) shift; PROJECT_ID="$1"; shift ;;
      -O|--no-optimize) USE_BATCH=0; USE_INDEX=0; USE_DEDUP=0; SKIP_NOOP=0; shift ;;
      -F|--fresh) fresh=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help) cli_help; return 0 ;;
      --) shift; input="$1"; shift; (( $# > 0 )) && die "只支持一个输入文件" ;;
      -*) die "未知选项: $1（'$PROG help' 查看用法）" ;;
      *) input="$1"; shift ;;
    esac
  done

  [[ -z "$input" ]] && die "缺少输入文件\n用法: $PROG <input.json> [选项]"
  [[ -f "$input" ]] || die "文件不存在: $input"
  jq -e 'type == "object"' "$input" >/dev/null 2>&1 || die "不是合法 JSON 对象: $input"

  [[ -z "$output" ]] && output="$(dirname "$input")/$(basename "${input%.json}").translated.json"

  if [[ "$API_TYPE" == "google" ]]; then
    [[ -z "$PROJECT_ID" ]] && die "谷歌翻译需要 --project <PROJECT_ID>"
    API_URL="${API_URL//__PROJECT__/$PROJECT_ID}"
  fi

  if [[ -z "$API_URL" && "$API_TYPE" != "mymemory" && "$API_TYPE" != "bilibili" ]]; then
    die "未配置 API\n  方式1: 先运行一次 $PROG 配置\n  方式2: -a <api> [-k <key>] [-m <model>]"
  fi

  case "$API_TYPE" in
    openai|google|azure)
      [[ -z "$API_KEY" ]] && die "$API_NAME 需要 API Key（-k 或配置文件）" ;;
    youdao|baidu)
      [[ -z "$API_KEY" || -z "$API_SECRET" ]] && die "$API_NAME 需要 AppKey 和 AppSecret" ;;
  esac

  if [[ -z "$TARGET_CODE" || "$TARGET_CODE" == "__CUSTOM__" ]]; then
    TARGET_CODE=$(lang_code_for "$TARGET_LANG" "$API_TYPE")
  fi
  [[ -z "$TARGET_CODE" ]] && TARGET_CODE="zh"

  [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] && (( CONCURRENCY >= 1 && CONCURRENCY <= 50 )) || CONCURRENCY=3
  [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] && (( BATCH_SIZE >= 1 && BATCH_SIZE <= 200 )) || BATCH_SIZE=20
  [[ "$REQUEST_DELAY" =~ ^[0-9]+$ ]] || REQUEST_DELAY=0

  local input_copy="$TMPDIR_RUN/input_copy.json"
  jq -c '.' "$input" > "$input_copy" || die "输入文件不是合法 JSON"

  local existing_file="$TMPDIR_RUN/existing.json"
  printf '{}\n' > "$existing_file"

  if (( ! fresh )) && [[ -f "$output" ]] && jq -e 'type=="object"' "$output" >/dev/null 2>&1; then
    cp "$output" "$existing_file"
    local cnt
    cnt=$(jq 'length' "$output" 2>/dev/null || echo 0)
    c_info "[续传] 检测到已有输出 $cnt 条，将跳过已翻译"
  elif (( fresh )) && [[ -f "$output" ]]; then
    c_info "[从零开始] 忽略已有输出"
  fi

  local pending_file="$TMPDIR_RUN/pending.json"
  jq -n --slurpfile input "$input_copy" --slurpfile done "$existing_file" '
    $input[0] | with_entries(
      . as $e
      | select(
          (($done[0] | has($e.key)) | not) or ($done[0][$e.key] == $e.value)
        )
    )
  ' > "$pending_file" || die "计算待翻译列表失败"

  local existing_ok_file="$TMPDIR_RUN/existing_ok.ndjson"
  jq -n --slurpfile input "$input_copy" --slurpfile done "$existing_file" '
    $done[0] | to_entries[]
    | select(.key as $k | $input[0] | has($k))
    | select(.value != $input[0][.key])
    | {key, value}
  ' > "$existing_ok_file" || die "计算已翻译列表失败"

  local pending_count existing_ok_count total
  pending_count=$(jq 'length' "$pending_file" 2>/dev/null || echo 0)
  existing_ok_count=$(wc -l < "$existing_ok_file" 2>/dev/null || echo 0)
  total=$(jq 'length' "$input_copy" 2>/dev/null || echo 0)
  [[ "$pending_count" =~ ^[0-9]+$ ]] || pending_count=0
  [[ "$existing_ok_count" =~ ^[0-9]+$ ]] || existing_ok_count=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  c_info "───────────────────────────────────────"
  c_info "输入   : $input"
  c_info "输出   : $output"
  c_info "引擎   : $API_NAME${MODEL:+ / $MODEL} ($API_TYPE)"
  c_info "语言   : $TARGET_LANG ($TARGET_CODE)"
  local mode_desc
  if (( USE_BATCH == 1 )) && supports_batch; then
    mode_desc="批量 $BATCH_SIZE/批 × 并发 $CONCURRENCY"
  else
    mode_desc="逐条 × 并发 $CONCURRENCY"
  fi
  c_info "模式   : $mode_desc"
  c_info "条目   : 总 $total / 已翻译 $existing_ok_count / 待翻译 $pending_count"
  c_info "───────────────────────────────────────"

  if (( pending_count == 0 )); then
    c_info "所有条目已翻译完成！"
    return 0
  fi

  run_translation "$input" "$pending_file" "$existing_ok_file" "$output" "$total" "$existing_ok_count"
}

# ============ TUI 主循环 ============
run_tui() {
  while true; do
    local api_display="${API_NAME:-未配置}"
    [[ -n "$API_TYPE" ]] && api_display="$api_display [$API_TYPE]"
    local model_display="${MODEL:-(未选择)}"
    local key_status; key_status="$(mask_secret "$API_KEY")"
    local batch_mode="逐条（并发 $CONCURRENCY）"
    if (( USE_BATCH == 1 )) && supports_batch 2>/dev/null; then
      batch_mode="批量 $BATCH_SIZE/批 × 并发 $CONCURRENCY"
    fi
    local choice
    choice=$(dialog --stdout --title " ${PROG} v${VERSION} " --menu \
      "当前配置:\n  API: $api_display\n  模型: $model_display\n  Key: $key_status\n  语言: $TARGET_LANG ${TARGET_CODE:+($TARGET_CODE)}\n  模式: $batch_mode\n\n请选择:" \
      0 0 0 \
      1 "开始翻译" \
      2 "设置 API（含选择模型）" \
      3 "切换模型（仅 OpenAI 兼容）" \
      4 "设置语言" \
      5 "性能设置（并发/间隔）" \
      6 "Token 优化设置" \
      7 "查看当前配置" \
      8 "重新加载配置文件" \
      9 "帮助" \
      10 "退出") || exit 0
    case "$choice" in
      1) do_translate ;;
      2) choose_api ;;
      3) choose_model_only ;;
      4) choose_lang ;;
      5) choose_perf ;;
      6) choose_token_opt ;;
      7) show_config ;;
      8) reload_config ;;
      9) dialog --title "帮助" --msgbox "本脚本由NAS油条制作,deepseek协助开发\n欢迎加入NAS油条技术交流群\n有什么技术可以进来交流\n群号:610699712\n\n${PROG} v${VERSION}\n\nTUI: 无参数启动\n\nCLI: $PROG <input.json> [选项]\n     $PROG models / config / help\n\n配置文件:\n  $CONFIG_FILE" 22 78 ;;
      10) exit 0 ;;
    esac
  done
}

# ============ 入口分发 ============
(( $# == 0 )) && { run_tui; exit 0; }

ACTION="$1"
if [[ "$ACTION" == *.json ]]; then
  HEADLESS=1
  cli_translate "$@"
  exit $?
fi

shift
case "$ACTION" in
  translate|tr) HEADLESS=1; cli_translate "$@"; exit $? ;;
  models|list-models) HEADLESS=1; cli_list_models "$@"; exit $? ;;
  config) cli_show_config; exit $? ;;
  help|--help|-h) cli_help; exit 0 ;;
  version|--version|-v|-V) echo "$PROG v$VERSION"; exit 0 ;;
  *)
    echo "错误: 未知命令或文件: $ACTION" >&2
    echo "可用命令: translate / models / config / help / version" >&2
    echo "或直接传 .json 文件: $PROG <input.json>" >&2
    exit 1 ;;
esac