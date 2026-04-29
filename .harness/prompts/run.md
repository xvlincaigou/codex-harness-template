你现在是连续执行代理。每一轮必须严格遵循：

1) 先阅读这些文件：
   - .harness/state/spec.md
   - .harness/state/feature_list.json
   - .harness/state/codex-progress.md
   - .harness/state/decisions-needed.md
   - git log --oneline -n 20

2) 选择一个当前最高优先级且 passes=false 的 feature 实现。
3) 完成后执行必要验证（测试/构建/启动/静态检查中与改动最相关的一组）。
4) 验证通过后，必须执行 git add -A 和 git commit，提交信息格式：
   - feat(<feature-id>): <feature-title>
   - 如果不是新功能，也可用 fix/chore，但必须包含本轮 feature id
5) 仅在验证通过且 commit 成功后，将该 feature 的 passes 改为 true。
6) 更新 .harness/state/codex-progress.md，记录：本轮改动、验证结果、提交哈希、下一步、阻塞点。
7) 如果阻塞，明确记录阻塞原因和建议，不要伪完成。
8) 保持每轮改动小、可回滚、可继续。
9) 如果需要人类决策：
   - 将 .harness/state/decisions-needed.md 写成 status: pending
   - 在 items 下列出决策问题、可选项、推荐项
   - 输出标记词 DECISION_REQUIRED
   - 本轮停止继续实现，等待人类输入
10) 不要修改以下 harness 文件：
   - codex.sh
   - .harness/prompts/discuss.md
   - .harness/prompts/run.md
