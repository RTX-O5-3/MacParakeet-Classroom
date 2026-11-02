# MacParakeet Classroom

给英文课堂和 seminar 使用的 macOS 实时字幕工具，重点面向 biomedical 课程。
基于 [MacParakeet](https://github.com/moona3k/macparakeet)，保留模型选择能力，
增加适合听课的紧凑字幕、历史回顾和重点标记。

## 可以做什么

- 紧凑字幕浮窗，减少遮挡课件。
- 按住 Shift 进入展开回顾，向上浏览历史字幕。
- 选择文本并复制，点击 `↓ LIVE` 返回最新字幕。
- 录制时添加 `★ 重点标记`，在回顾和最终文本中保留。
- 多行粘贴课程术语，查看词条数量并切换词汇增强。
- 保留 Parakeet、Whisper 等现有引擎选择；英文课堂推荐先选择
  **Parakeet TDT 0.6B v2 English-only**。

## 使用前准备

- Apple Silicon Mac，macOS 14.2 或更高版本。
- 首次使用时下载所选语音模型。
- 按系统提示授予麦克风权限；全局快捷键需要相应的系统权限。

语音识别在模型准备后本地运行。模型下载、更新和上游保留的可选云端功能
会按各自设置访问网络。

## 从源码运行

本仓库提供源码，安装包尚未在 Releases 发布。从源码构建需要完整 Xcode
及其 Swift 工具链。在仓库根目录执行：

```bash
MACPARAKEET_CONFIG=Release scripts/dev/run_app.sh
```

脚本会构建并启动开发版 App。首次构建需要获取 Swift 依赖，耗时取决于网络和机器。

## 课堂使用

1. 在设置中选择语音引擎与模型，确认麦克风输入正确。
2. 设置开始／停止录制的快捷键，开始字幕。
3. 按住 Shift 与字幕交互、展开回顾；点击 `↓ LIVE` 返回最新位置。
4. 遇到重点时点击标记按钮。
5. 需要专业词增强时，将术语一行一个粘贴进词表并启用增强。

CTC 词汇增强需要支持的 Parakeet v2/v3 路径、开关开启、有效词表非空，
以及 sidecar 模型已准备好。空词表不会产生增强效果。

详细说明见 [使用说明](docs/USAGE.md)；当前行为限制见
[已知问题](docs/KNOWN_ISSUES.md)。

## 版权与致谢

本项目是 **Daniel Moon / moona3k 的 MacParakeet** 的修改分支，
由 `RTX-O5-3` 维护课堂字幕相关改动。

语音运行时使用 [FluidAudio](https://github.com/FluidInference/FluidAudio)。
原项目、模型及第三方组件保留各自的版权与许可。

- [原项目](https://github.com/moona3k/macparakeet)
- [版权和分支署名](COPYRIGHT.md)
- [GPL-3.0 许可证](LICENSE)
- [第三方软件许可](THIRD_PARTY_LICENSES.md)
