# 上传到你的 GitHub

建议仓库名：`codex-work-quota-bar`。

建议仓库描述：`在 macOS 菜单栏查看 Codex 的 5 小时与每周剩余额度，支持 ChatGPT / Work。`

本目录已经整理为源码仓库根目录。保留 `LICENSE`、`NOTICE` 和 README 中的上游来源；当前版本为 `1.1.1`，是基于上游 `v1.0.0` 的适配版本。

## 方式一：网页上传

1. 在 GitHub 创建一个空仓库；无需再生成另一份 README 或许可证。
2. 解压提供的源码 ZIP，进入里面的项目文件夹。
3. 在仓库页面选择 **Add file → Upload files**，上传项目里的文件和文件夹，保持目录结构。
4. 确认 `README.md` 直接位于仓库根目录，然后提交。

不要只把整个源码 ZIP 当作一个文件上传，否则首页不会自动展示 README，也无法正常浏览源码。

Finder 默认隐藏 `.github`、`.gitignore`、`.gitattributes`。可按 `⌘⇧.` 显示隐藏文件，确认它们也被上传。若网页上传无法保留这些文件，建议改用 Git 或 GitHub Desktop。没有 `.github/workflows` 也能展示项目，但不会自动构建。

## 方式二：Git 上传（完整保留所有文件）

在解压后的项目根目录打开终端。将下面的 `YOUR_GITHUB_NAME` 替换成你的 GitHub 用户名；若仓库名不同，也一起替换。不要原样复制占位符。

```bash
git init -b main
git add .
git status --short
git commit -m "Add Codex Work Quota Bar macOS adaptation"
git remote add origin https://github.com/YOUR_GITHUB_NAME/codex-work-quota-bar.git
git push -u origin main
```

这些命令需要你已经完成 GitHub 登录及 Git 的用户名 / 邮箱配置。项目不包含或代为配置你的 GitHub 凭据。

## 发布可下载的应用

源码放仓库，应用 ZIP 放 **Releases 的附件**，方便普通用户下载运行。

### 手动发布

1. 先检查当前提交，确认就是你准备分享的版本。
2. 仓库页面打开 **Releases → Draft a new release**。
3. 使用标签 `v1.1.1`，标题可写 `Codex Work Quota Bar v1.1.1`。
4. 复制 `docs/RELEASE_NOTES.md` 的内容作为说明。
5. 添加配套发布文件中的 `CodexWorkQuotaBar-macOS.zip` 和 `.sha256`。
6. 检查后自行发布；悬浮跟随仍在验证中，可按需要标记为预发布。

手动发布与下方自动流程选一种，避免为同一标签重复创建 Release。

### 自动构建 Release 草稿

已提供 `.github/workflows/macos.yml`。推送主分支 / PR 会测试和构建；在本机推送标签后，会创建 Release 草稿：

```bash
git tag v1.1.1
git push origin v1.1.1
```

工作流在 GitHub 的 macOS runner 中运行，使用仓库自动提供的 `GITHUB_TOKEN` 创建草稿，不需要把个人 Token 写进源码。草稿已附带应用包和校验文件，你检查后再发布。若仓库策略禁用 Actions 或限制写权限，需要按仓库策略处理，也可以改为手动发布。

## 发布前确认

- 根目录包含 README、LICENSE、NOTICE、macos、docs 和隐藏的 `.github` 等文件。
- 不包含 `.codex`、`auth.json`、`.env`、个人日志、账号截图、验证探针或本机绝对路径。
- README 配图使用示意数据。
- 安装包与当前源码匹配；构建输出目录已被 `.gitignore` 排除。
- 保留 ad-hoc 签名、权限用途与已知兼容性限制的说明。

参考：[GitHub 文件上传说明](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)、[GitHub Releases 说明](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)。
