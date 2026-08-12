#!/usr/bin/env python3
"""Stop hook: 直近のターンを cwd 配下の _conversation-logs/<date>.md に追記する。

挙動:
- cwd が $HOME 直下 / Workspace ルートのときは保存しない（マルチプロジェクト混在 dir）。
- 1 日 1 ファイル `_conversation-logs/YYYY-MM-DD.md` に追記する（連番は使わない）。
- ユーザー/Claude の発話が両方含まれているときだけ保存する。
"""

import json
import sys
import os
from pathlib import Path
from datetime import datetime


def should_skip(cwd: str) -> bool:
    try:
        resolved = Path(cwd).resolve()
    except Exception:
        return False
    if resolved == Path.home().resolve():
        return True
    if resolved.name == "Workspace":
        return True
    # _templates/ 配下はプロジェクトではなく「ひな形」なので会話ログを残さない
    # （ひな形を直接 CWD にして作業すると配布物に _conversation-logs/ が混入するため）
    if any(part == "_templates" for part in resolved.parts):
        return True
    return False


def extract_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            t = item.get('type', '')
            if t == 'text':
                parts.append(item.get('text', ''))
            elif t == 'tool_use':
                name = item.get('name', 'unknown')
                inp = item.get('input', {})
                parts.append(f'*[Tool: {name}]*')
                if isinstance(inp, dict):
                    for k, v in list(inp.items())[:3]:
                        parts.append(f'  - {k}: {str(v)[:100]}')
            elif t == 'tool_result':
                pass  # skip tool results
        return '\n'.join(p for p in parts if p)
    return str(content) if content else ''


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()

    if should_skip(cwd):
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    transcript_path = data.get('transcript_path', '')
    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    messages = []
    with open(transcript_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue

            role = None
            content = None

            # Format A: {"role": "user/assistant", "content": ...}
            if 'role' in entry and entry['role'] in ('user', 'assistant'):
                role = entry['role']
                content = entry.get('content', '')

            # Format B: {"type": "user/assistant", "message": {...}}
            elif entry.get('type') in ('user', 'assistant'):
                msg = entry.get('message', {})
                if isinstance(msg, dict):
                    role = msg.get('role', entry['type'])
                    content = msg.get('content', '')
                elif isinstance(msg, str):
                    role = entry['type']
                    content = msg

            if role in ('user', 'assistant') and content is not None:
                text = extract_text(content)
                if text.strip():
                    messages.append({'role': role, 'text': text.strip()})

    # Only save if there's at least one user+assistant exchange
    has_user = any(m['role'] == 'user' for m in messages)
    has_assistant = any(m['role'] == 'assistant' for m in messages)
    if not (has_user and has_assistant):
        sys.exit(0)

    log_dir = Path(cwd) / '_conversation-logs'
    log_dir.mkdir(parents=True, exist_ok=True)

    today = datetime.now().strftime('%Y-%m-%d')
    filename = log_dir / f'{today}.md'
    is_new = not filename.exists()
    mode = 'w' if is_new else 'a'

    with open(filename, mode, encoding='utf-8') as f:
        if is_new:
            f.write(f'# 会話ログ — {today}\n\n')
            f.write(f'> Project: `{cwd}`\n\n')
        f.write('---\n\n')
        f.write(f'## Turn @ {datetime.now().strftime("%H:%M:%S")}\n\n')
        for msg in messages:
            if msg['role'] == 'user':
                f.write(f'### ユーザー\n\n{msg["text"]}\n\n')
            else:
                f.write(f'### Claude\n\n{msg["text"]}\n\n')


if __name__ == '__main__':
    main()
