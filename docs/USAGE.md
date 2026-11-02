# 使用说明

## 模型与输入

在设置中选择语音引擎、具体模型和麦克风。英文 biomedical 课堂可先使用
Parakeet TDT 0.6B v2 English-only；其他引擎仍可按需要选择。
模型首次使用需要下载，下载结束后进行本地识别。

确认输入音量足够，避免距离讲者过远、扬声器回声或多人同时说话。

## 字幕与回顾

使用设置中的快捷键开始或停止录制。正常状态显示紧凑字幕。
按住 Shift 与浮窗交互并进入 Review，向上滚动查看历史；点击 `↓ LIVE`
回到最新字幕。展开后可以选择单词或句子，选择完成后复制到剪切板。

回顾视图保留最近一段字幕，不是完整录音的永久归档。

## 重点标记

录制时点击 `重点` 插入 `★ 重点标记`。停止后的最终文本会按照点击时间
插入标记；原始 ASR 文本保留独立结果。

## 课程术语

在词表界面一行一个输入术语，例如：

```text
platelet
megakaryocyte
von Willebrand factor
thromboxane A2
fibrinogen
```

启用需要的词条，再打开 vocabulary boosting。查看有效词条数量，
确认词表非空。CTC sidecar 准备完成后，支持的 Parakeet v2/v3 路径才会使用增强。

词表用于帮助识别，不会强制将所有近音词替换成词表中的词。

## 从源码启动

完整 Xcode 安装后，在仓库根目录运行：

```bash
MACPARAKEET_CONFIG=Release scripts/dev/run_app.sh
```

脚本为该次启动指定独立的开发版数据目录。关于直接双击开发版 App 的行为，
见 [已知问题](KNOWN_ISSUES.md)。
