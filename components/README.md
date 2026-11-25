# Strata 组件

Strata 桌面应用的开发入口是仓库根目录的 [native/MoleDesktop](../native/MoleDesktop)。下列目录保留了迁入时各项目的源码、测试、构建脚本和许可证。Mole 的三个平台分别来自独立分支，各自使用本目录内的依赖和构建入口。

| 组件 | 迁入时的本地分支与提交 | 用途 |
| --- | --- | --- |
| [FineTune](FineTune) | `codex/follow-macos-output` · `bc9e2a3598a1` | 独立音频应用和 Strata 音频伴随应用。还包括迁移前工作区中的未提交改动和新文件。 |
| [Mole macOS](Mole/macos) | `main` · `efe987606c95` | 完整 macOS CLI。其 `native/MoleDesktop` 是旧桌面快照，当前桌面开发请使用上面链接的根目录入口。 |
| [Mole Linux](Mole/linux) | `linux` · `934b91046353` | Linux CLI，包含本地 Linux 修复提交。 |
| [Mole Windows](Mole/windows) | `windows` · `b5c286e71227` | Windows CLI，包含本地 Windows 修复提交。 |

## 在本机构建

下列命令从 Strata 仓库根目录开始。Go 工具链版本见各目录的 `go.mod`。首次构建需要取得 Go 模块或 Swift 包，已有完整依赖缓存时可以复用。

**macOS CLI** 使用 Make 和 Go 构建磁盘分析和状态工具。CLI 入口为 `./mo`。

```sh
cd components/Mole/macos
make build
./mo --help
go test ./...
```

**Linux CLI** 使用本机架构构建分析、状态和废纸篓工具。显式传入架构可用于 arm64 和 amd64 主机。

```sh
cd components/Mole/linux
make build GOARCH="$(go env GOARCH)"
./mo --help
go test ./...
```

**Windows CLI** 可在 Windows PowerShell 5.1 中构建。构建脚本生成磁盘分析和系统状态两个工具。启动器会查找同一目录中的 `mole.ps1`，因此在组件根目录生成 `mo.exe`。

```powershell
cd components/Mole/windows
.\scripts\build.ps1
go build -o mo.exe ./cmd/mo
.\mo.exe --help
go test ./...
```

**FineTune** 的独立应用使用 Xcode 项目中的 `FineTune` scheme。在完整 Xcode 环境中，以下命令可从源码生成供 Strata 嵌入的本地签名版本。目标路径须是尚未创建的应用包。

```sh
cd components/FineTune
python3 scripts/build-strata-companion.py build/FineTune.app
```

## 离线导出独立组件仓库

要在独立仓库中使用组件自己的 Git 钩子或开发工具，可在 Strata 根目录的 shell 中运行以下命令（Windows 使用 Git Bash）。需要已安装 `git subtree`。示例导出 Linux 组件。其他组件将 `component` 改为 `components/FineTune`、`components/Mole/macos` 或 `components/Mole/windows`，再设置所需的本地分支名。`HEAD` 应指向包含所需组件版本的 Strata 提交。尚未提交的工作区改动不在导出范围内。

```sh
source_repo=$(git rev-parse --show-toplevel)
component=components/Mole/linux
branch=linux
destination=$(mktemp -d)
revision=$(git -C "$source_repo" subtree split --prefix="$component" HEAD)
git init -b "$branch" "$destination"
git -C "$destination" fetch --no-tags "$source_repo" "$revision"
git -C "$destination" switch -C "$branch" FETCH_HEAD
test "$(git -C "$source_repo" rev-parse "HEAD:$component")" = \
     "$(git -C "$destination" rev-parse 'HEAD^{tree}')"
printf '导出目录 %s\n' "$destination"
```

这次 fetch 直接读取本机文件系统。树对象相同表示导出提交里的目录层次、文件内容、Git 记录的可执行位和符号链接都一致。导出的历史来自 Strata 中影响该目录的提交。原分支在迁移机器上的 Strata 仓库以 `archive/finetune/` 和 `archive/mole/` 开头，原标签分别以 `finetune/` 和 `mole/` 开头。例如可使用 `git log archive/mole/windows` 查看 Windows 修复历史。

## Git 工具与发布入口

在组件子目录执行 `git rev-parse --show-toplevel` 会得到 Strata 根目录。Mole macOS 的 `.githooks/pre-commit` 和 `.claude/hooks/format-on-edit.sh` 用该结果定位脚本。FineTune 的 `scripts/install-git-filters.sh` 会配置当前 Git 仓库的过滤器并调整项目文件的暂存状态。要单独配置这些开发工具，可在上面导出的组件仓库中运行。

Mole macOS 的 `scripts/audit_skill_commands.py` 默认读取 `origin/windows`，macOS 和 Windows 的 `scripts/risk_tier.py` 使用上游分支计算改动。离线导出只创建指定的本地分支。这类跨分支检查需要相应的 Git 引用。

Strata 的活动 CI 配置在[根目录的工作流](../.github/workflows)。每个组件保存的 `.github/workflows` 供独立项目使用，GitHub Actions 只从仓库根目录加载工作流。原 Mole 发布流程使用平台标签，安装器、更新器和部分发布步骤仍引用 `tw93/Mole`。FineTune 的原发布流程生成上游 Sparkle 更新源，并向 `origin/main` 推送 appcast。独立发布时须按实际仓库、下载地址、签名和分发渠道配置这些流程。本地源码构建使用上面的原生平台命令。
