# codex-harness-template

一个可直接复制的 Codex Harness 模板，目标是：

1. 先和 Codex 交互式讨论，把需求澄清并落盘。
2. 再让 Codex 以 `codex exec` 持续循环执行，每轮增量推进。
3. 遇到额度/网络等暂时错误时，自动退避重试。
4. 需要你拍板时自动暂停，避免“瞎继续”。
5. 默认保护核心 harness 文件，避免执行阶段把框架本身改坏。

## 为什么这样设计

- 讨论阶段与执行阶段分离，避免“边做边改需求”导致漂移。
- 使用仓库内状态文件（spec / feature list / progress）做持久化，任何中断都可恢复。
- 每轮只推进一个 feature，并要求验证后再标记 `passes=true`。
- 决策门控（Decision Gate）确保关键分歧回到人类决策。
- Harness 保护（Harness Protect）避免脚本和系统 prompt 被 agent 改写。

## 目录

```text
.
├── codex.sh
└── .harness/
    ├── prompts/
    │   ├── discuss.md
    │   └── run.md
    ├── state/
    │   ├── spec.md
    │   ├── feature_list.json
    │   ├── codex-progress.md
    │   └── decisions-needed.md
    └── logs/
```

## 快速开始

1. 进入仓库

```bash
cd ~/workspace/codex-harness-template
```

2. 登录 Codex（首次）

```bash
codex login
```

3. 一键运行（先讨论，后循环执行）

```bash
bash codex.sh
```

## 常用命令

```bash
bash codex.sh discuss          # 只进行需求讨论
bash codex.sh run              # 只进行连续执行
bash codex.sh status           # 查看状态
bash codex.sh unlock           # 解锁讨论阶段（重新讨论）
bash codex.sh clear-decisions  # 清空决策门控（恢复执行）
bash codex.sh protect-refresh  # 刷新保护基线（你有意改了 harness 后执行）
bash codex.sh reset-logs       # 清理日志
```

## 关键环境变量

```bash
MODEL=gpt-5.4
SANDBOX=workspace-write
APPROVAL=on-failure
ENABLE_SEARCH=0

MAX_ITERS=9999
BACKOFF_MIN_SECONDS=60
BACKOFF_MAX_SECONDS=3600
SUCCESS_PAUSE_SECONDS=1
AUTO_LOCK_AFTER_DISCUSS=0

DECISION_GATE=1
HARNESS_PROTECT=1
PROTECTED_FILES="codex.sh .harness/prompts/discuss.md .harness/prompts/run.md"

# 默认使用仓库内会话目录，避免 ~/.codex 权限问题
CODEX_HOME=.codex-home
```

示例：

```bash
# 当前目录内尽量自动执行
APPROVAL=on-failure SANDBOX=workspace-write bash codex.sh run

# 如果你明确接受更激进策略
APPROVAL=never SANDBOX=workspace-write bash codex.sh run
```

## 权限行为说明

- `SANDBOX=workspace-write`：工作区内读写可执行，越界操作会受限。
- `APPROVAL=on-failure`（默认）：先自动执行，失败后再请求你授权（更贴近“当前文件夹内自动跑”）。
- `APPROVAL=on-request`：模型可主动请求你审批（更保守）。
- `APPROVAL=never`：不请求审批（风险最高，不建议默认长期使用）。

## 决策门控（Decision Gate）

开启 `DECISION_GATE=1` 时：

- 当代理需要你做决策，会把 `.harness/state/decisions-needed.md` 写成 `status: pending`。
- Harness 检测到后自动暂停循环。
- 你补充/拍板后，执行：

```bash
bash codex.sh clear-decisions
bash codex.sh run
```

## Harness 保护（Harness Protect）

开启 `HARNESS_PROTECT=1` 时：

- 运行开始时会记录受保护文件哈希基线。
- 每轮执行后校验：`codex.sh`、`prompts` 是否被改动。
- 若被改动则暂停并生成告警：`.harness/state/harness-protect-alert.md`。
- 如果改动是你故意做的，执行：

```bash
bash codex.sh protect-refresh
```

## 关于“额度问题”的处理

脚本会把下面这类错误视为可重试：

- `rate limit`
- `insufficient quota`
- `429`
- `network error`
- `stream disconnected`
- `timeout`

然后执行指数退避（`BACKOFF_MIN_SECONDS` 到 `BACKOFF_MAX_SECONDS`）。

## 建议实践

- 保持 `.harness/state/feature_list.json` 粒度小，单个 feature 可在 1~2 轮完成。
- 每轮都让 Codex 更新 `codex-progress.md`，确保可接力。
- 在 CI 里加基础校验（json 格式、脚本可执行、状态文件存在）。

## 参考

- https://www.anthropic.com/engineering/harness-design-long-running-apps
- https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- https://openai.com/zh-Hans-CN/index/harness-engineering/
