# Widgetify 本地定制版

本仓库保存本项目实际编写的修改工具与增强功能源码，**不是 Widgetify 原厂完整源码**。原厂 Swift/SwiftUI/AppKit 程序、第三方库及资源仍是编译后的成品，没有被恢复成完整可编辑工程。

当前版本：**v0.2.0**。安装包见 [Releases](https://github.com/userSywang/Widgetify/releases)。

## 当前功能

- 菜单“Widgetify → 文件夹集中管理”：集中保存原文件夹入口。桌面文件夹仅隐藏图标，其他目录不改动；支持恢复显示、移除管理和放到桌面。
- 菜单“Widgetify → 增强设置…”：配置每日多个喝水提醒时间点、开关和测试通知。首次使用需允许系统通知。
- 应用信息和增强窗口明确显示 0.2.0。
- 文件夹集中管理为新增原生组件，原“文档整理”条目不会自动迁移。

## v0.1.0 基础修改

基于本地 Widgetify 4.55（216），修改 Apple 芯片版本的本地高级状态判断。采用独立标识 `local.widgetify.custom`，不会创建 App Store 购买记录。重新签名后 Apple 天气等依赖开发者授权的服务可能不可用；未逐项验证所有组件。

## 本地构建

需要 macOS、Xcode 命令行工具、Python 3，以及单独安装的原版 Widgetify 4.55（216）。基础程序不放入源码仓库。

```sh
python3 scripts/build.py --base-app /Applications/Widgetify.app --output dist
```

构建脚本校验基础程序版本与 SHA-256，在独立输出目录制作副本，不覆盖基础程序。已安装的是定制版时，请使用另行保留的原始安装来源作为构建输入。

## 源码范围

- `src/Enhancements.m`：文件夹管理和每日喝水提醒的完整新增源码，含测试入口。
- `scripts/test.sh`：时间输入、每日触发器和路径边界检查。
- `docs/使用说明.md`：安装与功能说明。
- `scripts/patch_binary.py`：针对受支持版本的修改与校验。
- `scripts/build.py`：复制、构建、签名、打包。
- `VERSION`：定制版版本号，与原程序版本 4.55 区分。

原程序及资源不在此声明为本项目原创或授予开源许可。
