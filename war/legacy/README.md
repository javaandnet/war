# legacy/v0.1 —— 原始实现归档

本目录是 v0.1（2025-06-28）的原始代码，未经任何修改。

保存原因：这批文件从未提交进 git 仓库（`git ls-files` 里只有 README/LICENSE/.gitignore），
v0.2 重构直接覆盖了工作副本，因此从编辑器本地历史（Cursor Local History）按
"最后一次保存快照 + 字节数逐一致对"的方式恢复出原始版本。

- ai.js 16866B / field.js 5977B / item.js 5717B / game.js 20322B / index.html 13240B
  与原目录列表记录的字节数完全一致，行数亦与重构前读取到的内容一致。

要看差异：

```bash
diff -u legacy/v0.1/ai.js ai.js
```
