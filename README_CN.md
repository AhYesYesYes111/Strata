# Strata

Strata 是一款原生 macOS 应用。你可以看清哪些文件夹占用了磁盘空间，在清理前审阅候选项目，也能在窗口和菜单栏查看实时系统状态。界面采用 SwiftUI，支持简体中文和英语。

[构建 Strata](#构建-strata) · [使用 Strata](#使用-strata) · [Mole CLI](#上游-mole-cli) · [English](README.md)

![Strata 的空间清理首页，显示本机存储用量和常用目录入口](docs/img/strata-clean-zh.png)

## 构建 Strata

应用支持 **macOS 13 及以上版本**。从源码构建需要 **Python 3** 和 **包含 macOS 26 或更新版 SDK 的 Apple 开发工具**。

```sh
git clone https://github.com/AhYesYesYes111/Strata.git
cd Strata
python3 native/MoleDesktop/build.py
open native/MoleDesktop/build/Strata.app
```

如果已克隆仓库，在仓库根目录运行最后两条命令即可。脚本会按当前 Mac 的架构构建应用，进行本地签名，并生成 `native/MoleDesktop/build/Strata.zip`。

## 使用 Strata

| 页面 | 可以做什么 |
| --- | --- |
| **磁盘分析** | 浏览启动盘或选择一个文件夹。点击色块逐层查看空间占用，也可以重新扫描来刷新上次的结果。 |
| **空间清理** | 先扫描缓存、日志和卸载残留，估算可回收空间。报告可搜索，也可导出为文本。 |
| **状态** | 查看 CPU、内存、磁盘读写、网络和电池。可搜索和排序进程，也可在菜单栏快速查看概况。 |
| **应用** | 搜索已安装的软件、查看版本，并在访达中定位。 |
| **维护** | 预览系统维护任务，查看哪些任务会被跳过及其原因。 |

> **确认清理前，请先审阅报告。** 搜索仅筛选报告的显示内容。确认后，Mole 会重新扫描，并按当前保护规则执行整轮清理。符合条件的项目会被永久删除，个人废纸篓默认也会清空。

需要测量受 macOS 保护的目录时，可从右上角的**授权**进入「完全磁盘访问权限」设置。权限、快捷键、报告导出和测试命令见桌面使用指南。[桌面使用指南](native/MoleDesktop/README.md) · [桌面应用源码](native/MoleDesktop/Sources)

## 上游 Mole CLI

Strata 内置了 Mole CLI 的清理和维护脚本。Mole CLI 是由 tw93 和贡献者维护的命令行工具。上游也发布了自己的桌面应用 Mole Mac。[Mole CLI 源码](https://github.com/tw93/Mole) · [Mole Mac](https://mole.fit/)

## 开源协议

Strata 和随应用打包的 Mole CLI 均采用 GNU 通用公共许可证第 3 版（GPLv3）。[许可证全文](LICENSE) · [组件来源与商标说明](LICENSES.md)
