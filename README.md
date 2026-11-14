# Widgetify 本地定制版

本仓库保存本项目实际编写的修改工具与增强功能源码，**不是 Widgetify 原厂完整源码**。原厂 Swift/SwiftUI/AppKit 程序、第三方库及资源仍是编译后的成品，没有被恢复成完整可编辑工程。

当前版本：**v0.2.4**。安装包见 [Releases](https://github.com/userSywang/Widgetify/releases)。

## 当前功能

在喝水或文档整理组件上打开原设置弹层，即可切换“组件设置 / 喝水提醒”或“组件设置 / 文件夹管理”。应用菜单也可定位并打开对应组件设置，不再另外创建增强设置窗口。

- 喝水提醒按组件 ID 保存每日时间、开关、卡片/轻提示样式、停留时长、位置与声音。立即预览会使用当前选项实际显示；每日应用弹窗需要软件运行。
- 文件夹继续使用原卡片及其图标/列表、排序和主题。通过“添加文件夹引用…”收纳目录，原路径与内容不变，原管理页可移除入口。
- 仅隐藏当前组件已收纳的直接桌面目录；非桌面目录不隐藏。正常退出恢复由本功能隐藏的图标。
- 桌面“文件夹入口”包含原目录的 Finder 替身，软件未运行或异常退出时仍可访问；隐藏前验证替身目标，入口失败时保留原目录可见。
- 原杯容量、饮水记录、图案、主题及其他组件仍由原程序管理。

## v0.1.0 基础修改

基于本地 Widgetify 4.55（216），修改 Apple 芯片版本的本地高级状态判断。采用独立标识 `local.widgetify.custom`，不会创建 App Store 购买记录。重新签名后 Apple 天气等依赖开发者授权的服务可能不可用；未逐项验证所有组件。

## 本地构建

需要 macOS、Xcode 命令行工具、Python 3，以及原版 Widgetify 4.55（216）或校验通过的本项目定制版。基础程序不放入源码仓库。

```sh
python3 scripts/build.py --base-app "/Applications/Widgetify 0.2.4.app" --output dist
```

构建脚本校验原版 SHA-256，或校验定制版的原始程序代码指纹，在独立输出目录制作副本，不覆盖基础程序。

## 源码范围

- `src/Enhancements.m`：组件提醒调度、提醒窗口、正常退出恢复与导航。
- `src/ComponentIntegration.m`：原设置弹层集成与原卡片导入接口。
- `src/ComponentSettings.m`：组件内的提醒与文件夹选项。
- `src/WidgetContext.swift`：读取受支持原视图的组件 ID、配色与原设置回调；不写对象内存或使用固定偏移。
- `src/OriginalFolderBridge.m`：目录引用、访问书签、访达替身与隐藏恢复。
- `src/DirectoryReferences.m`：将受管理目录的搬移/复制替换成隐藏引用链接，原卡片负责显示与持久化；普通文件不受此目录策略影响。
- `src/ReminderSchedule.m`：共用的时间解析、到点与去重键规则。
- `scripts/test.sh`：编译检查、时间与桌面路径边界检查。
- `docs/使用说明.md`：安装、组件入口、退出后的使用与限制。
- `docs/架构与验收.md`：接入边界、数据链和实际验收记录。
- `scripts/patch_binary.py`：针对受支持版本的修改与校验。
- `scripts/build.py`：复制、构建、签名、打包。
- `VERSION`：定制版版本号，与原程序版本 4.55 区分。

原程序及资源不在此声明为本项目原创或授予开源许可。

## 命令行发布

首次用 `gh auth login` 登录自己的 GitHub 账号，然后运行 `gh auth setup-git`。凭据交给 GitHub CLI 管理，不写入仓库。构建完成、提交代码后执行：

```sh
python3 scripts/release.py --artifacts dist
```

发布脚本通过 Git 推送 main 和版本标签，通过 GitHub CLI 创建 Release、上传应用与源码压缩包，并核对远端附件的大小和 SHA-256。已有 Release 不覆盖，新增迭代需先更新 VERSION 和 CHANGELOG。全程不进行网页文件上传。网络需要代理时，在当前项目配置 `git config http.proxy <代理地址>`；发布脚本会沿用此配置。
