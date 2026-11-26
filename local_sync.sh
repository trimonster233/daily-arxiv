#!/usr/bin/env bash
set -euo pipefail

# 方案一：本机抓取 + 内网 LLM 总结 + 自动推送数据到 GitHub data 分支（供 GitHub Pages 展示）

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# 允许通过命令行覆盖推送开关，例如：bash local_sync.sh --push / --push-only
FORCE_PUSH=""
PUSH_ONLY="false"
for arg in "$@"; do
  case "$arg" in
    --push) FORCE_PUSH="true" ;;
    --no-push) FORCE_PUSH="false" ;;
    --push-only) FORCE_PUSH="true"; PUSH_ONLY="true" ;;
  esac
done

# 1. 加载本地 .env 配置
if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

# 2. 解析 API Key（优先 OPENAI_API_KEY，其次从 OPENAI_API_KEY_ENV 环境变量或 ~/.bashrc 读取）
if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY_ENV:-}" ]; then
  OPENAI_API_KEY="${!OPENAI_API_KEY_ENV:-}"
  if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.bashrc" ]; then
    OPENAI_API_KEY="$(
      bash -c "grep -E '^[[:space:]]*(export[[:space:]]+)?${OPENAI_API_KEY_ENV}=' \"\$HOME/.bashrc\" | tail -n 1" \
        | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${OPENAI_API_KEY_ENV}=//" \
        | sed -E 's/^["'\'']|["'\'']$//g'
    )"
  fi
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "❌ 未检测到 OPENAI_API_KEY（也未在环境或 ~/.bashrc 中找到 ${OPENAI_API_KEY_ENV:-bigai_deepseek_api}）" >&2
  exit 1
fi

export OPENAI_API_KEY
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://183.230.173.202:36789/v1}"
export MODEL_NAME="${MODEL_NAME:-deepseek-v4-flash-s1}"
export CATEGORIES="${CATEGORIES:-eess.AS, cs.SD}"
export LANGUAGE="${LANGUAGE:-Chinese}"
export MAX_WORKERS="${MAX_WORKERS:-4}"
export PUSH_TO_GITHUB="${FORCE_PUSH:-${PUSH_TO_GITHUB:-false}}"
export GIT_REMOTE="${GIT_REMOTE:-origin}"
export DATA_BRANCH="${DATA_BRANCH:-data}"

# 3. 为内网 LLM 主机追加 NO_PROXY（不影响 arXiv / GitHub 走代理）
if [ -n "${LLM_NO_PROXY_HOST:-}" ]; then
  CURRENT_NO_PROXY="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"
  case ",${CURRENT_NO_PROXY}," in
    *",${LLM_NO_PROXY_HOST},"*) ;;
    *) CURRENT_NO_PROXY="${CURRENT_NO_PROXY},${LLM_NO_PROXY_HOST}" ;;
  esac
  export NO_PROXY="$CURRENT_NO_PROXY"
  export no_proxy="$CURRENT_NO_PROXY"
fi

# 4. 检查虚拟环境
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
SCRAPY_BIN="$ROOT_DIR/.venv/bin/scrapy"
if [ ! -x "$PYTHON_BIN" ] || [ ! -x "$SCRAPY_BIN" ]; then
  echo "❌ 未找到 .venv，请先在项目根目录运行: uv sync" >&2
  exit 1
fi

TODAY="${TARGET_DATE:-$(date '+%Y-%m-%d')}"
export TARGET_DATE="$TODAY"

mkdir -p "$ROOT_DIR/data" "$ROOT_DIR/assets"

echo "=========================================="
echo "📅 日期: $TODAY"
echo "📚 分类: $CATEGORIES"
echo "🤖 模型: $MODEL_NAME @ $OPENAI_BASE_URL"
echo "🌐 语言: $LANGUAGE | 并发: $MAX_WORKERS"
echo "🚀 推送到 GitHub: $PUSH_TO_GITHUB ($GIT_REMOTE/$DATA_BRANCH)"
echo "=========================================="

# 5-9. 若非 --push-only，执行爬取、去重、AI 总结与 Markdown 转换
RAW_FILE="$ROOT_DIR/data/${TODAY}.jsonl"
AI_FILE="$ROOT_DIR/data/${TODAY}_AI_enhanced_${LANGUAGE}.jsonl"

if [ "$PUSH_ONLY" != "true" ]; then
  rm -f "$RAW_FILE"

  echo ">>> [1/5] 爬取 arXiv 论文..."
  (
    cd "$ROOT_DIR/daily_arxiv"
    "$SCRAPY_BIN" crawl arxiv -o "$RAW_FILE"
  )

  if [ ! -s "$RAW_FILE" ]; then
    echo "ℹ️ 今日 ($TODAY) 未抓取到目标分类的新论文，结束本次运行。"
    rm -f "$RAW_FILE"
    exit 0
  fi

  # 6. 多日去重检查
  echo ">>> [2/5] 执行历史去重检查..."
  set +e
  (
    cd "$ROOT_DIR/daily_arxiv"
    "$PYTHON_BIN" daily_arxiv/check_stats.py
  )
  DEDUP_CODE=$?
  set -e

  if [ "$DEDUP_CODE" -eq 1 ]; then
    echo "ℹ️ 去重后无新增论文，跳过 AI 总结与推送。"
    exit 0
  elif [ "$DEDUP_CODE" -ne 0 ]; then
    echo "❌ 去重检查异常退出 (code=$DEDUP_CODE)" >&2
    exit "$DEDUP_CODE"
  fi

  # 7. AI 结构化总结
  echo ">>> [3/5] 调用内网 LLM 进行 AI 总结..."
  (
    cd "$ROOT_DIR/ai"
    "$PYTHON_BIN" enhance.py --data "$RAW_FILE" --max_workers "$MAX_WORKERS"
  )

  if [ ! -s "$AI_FILE" ]; then
    echo "❌ 未生成 AI 增强文件: $AI_FILE" >&2
    exit 1
  fi

  # 8. 生成 Markdown
  echo ">>> [4/5] 转换为 Markdown..."
  (
    cd "$ROOT_DIR/to_md"
    "$PYTHON_BIN" convert.py --data "$AI_FILE"
  )

  # 9. 更新本地文件列表（用于本地预览）
  echo ">>> [5/5] 更新本地文件列表..."
  (
    cd "$ROOT_DIR"
    ls data/*.jsonl | sed 's|^data/||' | sort > assets/file-list.txt
  )
  echo "✅ 本地处理完成！文件位于:"
  echo "   - $RAW_FILE"
  echo "   - $AI_FILE"
  echo "   - $ROOT_DIR/data/${TODAY}.md"
else
  if [ ! -s "$RAW_FILE" ] || [ ! -s "$AI_FILE" ]; then
    echo "❌ --push-only 模式下未找到今日数据文件: $RAW_FILE 或 $AI_FILE" >&2
    exit 1
  fi
  echo ">>> --push-only 模式：直接推送已有数据 ($TODAY)..."
fi

# 10. 可选：使用 git worktree 推送数据到 GitHub data 分支（不干扰 main 分支）
if [ "$PUSH_TO_GITHUB" = "true" ]; then
  REMOTE_URL="$(git remote get-url "$GIT_REMOTE")"
  if [[ "$REMOTE_URL" == *"dw-dengwei/daily-arXiv-ai-enhanced"* ]]; then
    echo "❌ 安全保护：当前 $GIT_REMOTE 仍指向原作者仓库 ($REMOTE_URL)。" >&2
    echo "   请先执行: git remote set-url origin <你的仓库地址>" >&2
    exit 1
  fi

  WORKTREE_DIR="$ROOT_DIR/.data-worktree"
  cleanup_worktree() {
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
    rm -rf "$WORKTREE_DIR"
  }
  trap cleanup_worktree EXIT
  cleanup_worktree

  echo ">>> 同步数据到 $GIT_REMOTE/$DATA_BRANCH ..."
  if git ls-remote --heads "$GIT_REMOTE" "$DATA_BRANCH" | grep -q "refs/heads/${DATA_BRANCH}$"; then
    git fetch "$GIT_REMOTE" "$DATA_BRANCH"
    git worktree add -B "$DATA_BRANCH" "$WORKTREE_DIR" "FETCH_HEAD"
  else
    git worktree add --detach "$WORKTREE_DIR"
    (
      cd "$WORKTREE_DIR"
      git checkout --orphan "$DATA_BRANCH"
      git rm -rf . >/dev/null 2>&1 || true
      mkdir -p data assets
      echo "# Data Branch" > README.md
    )
  fi

  mkdir -p "$WORKTREE_DIR/data" "$WORKTREE_DIR/assets"
  cp "$RAW_FILE" "$WORKTREE_DIR/data/"
  cp "$AI_FILE" "$WORKTREE_DIR/data/"
  [ -f "$ROOT_DIR/data/${TODAY}.md" ] && cp "$ROOT_DIR/data/${TODAY}.md" "$WORKTREE_DIR/data/"

  (
    cd "$WORKTREE_DIR"
    ls data/*.jsonl | sed 's|^data/||' | sort > assets/file-list.txt
    git add data/ assets/file-list.txt
    [ -f README.md ] && git add README.md
    if git diff --staged --quiet; then
      echo "ℹ️ $DATA_BRANCH 分支无新数据变更，跳过推送。"
    else
      git commit -m "update: $TODAY arXiv papers ($CATEGORIES)"
      git push "$GIT_REMOTE" "$DATA_BRANCH"
      echo "✅ 已成功推送到 $GIT_REMOTE/$DATA_BRANCH !"
    fi
  )
fi
