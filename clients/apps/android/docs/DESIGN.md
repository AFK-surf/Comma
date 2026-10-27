# comma-android 视觉规范

视觉以 Mac 客户端为准。本文把 Mac 客户端的设计 token 映射到 Android。

- 来源：`clients/packages/ui/src/tokens/`（Figma 文件 `VnkgBb2xCr5bRp4KHrLrqs`）和聊天页样式 `clients/packages/app/src/styles.css`。token 有变化时，以 `clients/packages/ui` 为准。
- 单位换算：CSS 的 px 对应 Android 的 dp。字号的 px 对应 sp。
- 具体取值在代码里：颜色在 `res/values/colors_tokens.xml` 和 `res/values-night/colors_tokens.xml`，间距和圆角在 `res/values/dimens*.xml`，动效在 `DesignMotion.kt`。用法见 [design-foundation.md](design-foundation.md)。

## 1. 主题范围

- 支持浅色和深色，跟随系统设置。
- 不做 Mac 客户端的主题色调（`--cue-theme-l/c/h` 的 oklch 变换），只用中性的基础色。
- 用 Material 3 的主题做底，但颜色、字体、圆角全部用本规范的值覆盖。不用 Material 的动态取色。

## 2. 颜色

- 基础色和 markdown 色沿用 Mac 客户端的同名 token（`background.*`、`text.*`、`border.*`、`foreground.*`、`markdown.*`）。
- 首页标志（`token_mark_*`）和语音通话卡片（`token_call_*`）是安卓自有的 token。缩小后的通话卡片在两种主题下都是深色。
- 任务标签色来自 `clients/packages/app/src/components/tasks/labelColor.tsx`（预设名）和 `app/src/styles.css` 的 `.cue-label-dot`（取色）。浅色和深色主题共用同一个值。标签的 `color` 是预设名或用户自定义的 `#rrggbb`。没有颜色时按 gray 显示。

## 3. 字体

- 无衬线：**Inter Variable**。常规字重是 **450**，不是 400。字重：regular 450、medium 500、semibold 600、bold 700。
- 代码块和行内代码用系统等宽字体。
- 中文等 Inter 没有的字走系统回退字体（Noto Sans CJK）。回退字重统一用 `cjkFallbackWeight`：正文级（≤ 500）的中文取 500，600 和 700 不变。拉丁字形的字重不变。Inter（`DesignFonts`）和聊天用的系统 Roboto（`UiSansTypeface` / `uiSansAt`）都走这条规则。
- 数学公式用 KaTeX 字体（OFL，随公式排版库打包），只用来画公式里的字形。`\text{}` 里它没有的字走正文字体。这是唯一不走上面字体的地方。
- 非聊天界面沿用 Mac 的字号档位（micro、mini、small、regular、large、title3、title2、title1），不整体上调。`DesignTypography` 的“上调一档”开关保持关闭。

### 3.1 聊天内容排版

聊天消息的 Markdown 排版沿用 Nothing Chat 在手机上调好的数值，不用 Mac 的字号档位。颜色仍然用 §2 的 token。数值在 `MessageLayoutPrecomputer.kt` 和 `SelectableText.kt`。主要取值：

- 正文 16sp。助手行高 27sp，用户气泡行高 22sp。加粗字重 600。
- 标题 h1 到 h6 按正文字号的倍率缩放。
- 左右页边距 28dp。同一方连续消息间距 6dp，换人说话间距 28dp。

## 4. 间距、圆角、描边

- 间距（dp）：xxs 2、xs 4、sm 6、md 8、lg 12、xl 16、2xl 20、3xl 24、4xl 32、5xl 40、6xl 48。
- 圆角（dp）：xs 4、sm 6、md 8、lg 10、xl 12、2xl 16、3xl 20、4xl 24、5xl 32。5xl 是安卓自有的一档，用于浮在页面上的菜单卡片。
- 非聊天页面的左右边距是 16dp（Mac token `container.paddingMobile`）。
- 描边：0.5 和 1。0.5dp 的线用 1 个物理像素画，否则会糊。

## 5. 聊天页

- 用户气泡：底色 background.brandSolid，文字白色，圆角 20，内边距上下 12dp、左右 13dp。
- 聊天页的助手消息也用气泡：左对齐，底色 markdown.bgMessage，尺寸规则和用户气泡对称。气泡里的代码块和行内代码底色用 background.primary。只有图片的消息不加气泡。任务页不加气泡。
- 代码块和表格可以单独横向滚动。
- 回复不逐字显示。草稿进行中只显示正在回复的小气泡。正式消息一到就完整显示。
- 任务卡片、附件、回复按钮和出错卡片不是气泡。系统消息是居中的状态行。

## 6. 动效

- 时长和曲线沿用 Mac 客户端的 `tokens/motion.ts`。Android 上用 `PathInterpolator` 实现。
- 系统打开“移除动画”时，所有动效都要关掉，直接跳到终点。
- **流式文字不用弹簧动画**，只用透明度淡入。

### 6.1 弹簧

**规则**：位移、缩放、旋转、尺寸（宽高）一律用弹簧。只有透明度、颜色和流式文字的淡入用时长加曲线。

**例外**（不用弹簧，也不算违规）：

- 循环的加载指示，例如匀速无限循环的转圈。
- 由系统逐帧驱动的位置，例如跟随键盘动画（`WindowInsetsAnimationCompat`）时输入框的位置。
- `:scroll` 自带的滚动、惯性和越界回弹物理。

Android 用 `androidx.dynamicanimation` 的 `SpringForce`（质量为 1）。Mac 的 `response / dampingRatio` 换算成 `stiffness = (2π / response)²`，`dampingRatio` 不变。弹簧 token 在 `DesignMotion.kt`。`springScale` 和 `springRotation` 是暂定值，需要在真机上调。

**用法约定**：

- 改变目标时用 `animateToFinalPosition` 接着走，保留当前速度。不要每次从 0 重新开始。
- 手势松手时，把手指的速度作为弹簧的初始速度。
- 根据进度插值时**不要把进度钳在 0 到 1 之间**，否则回弹的那一段会被裁掉。

## 7. 图标

- 安卓把 Central Icons 转成 VectorDrawable（`res/drawable/ic_composer_*`、`ic_task_*`），保留原 viewBox 和路径，颜色由代码着色。
- 授权：Central Icons 是商业授权，可以用在 App 里，但**不能公开分享或再分发图标文件**。仓库私有期间可以放 VectorDrawable。**开源前必须移走或改成构建时生成**。
- 每个图标的来源登记在 `app/src/main/java/surf/comma/android/ui/icons/IconSources.kt`，开源前按它移除或替换。`IconSourcesTest` 检查登记和资源一致。
- VectorDrawable 不支持虚线。虚线图标要把虚线烤成一段段弧线。

## 7.5 App 图标

- dev 橙色，staging 蓝色，prod 白底黑色标志，照 Mac 客户端 `clients/apps/electron/build/icons/`。
- Mac 的 PNG 自带 macOS 圆角方块和透明边，**不能直接当 Android 图标用**。
- 用 Android 自适应图标，放在各 flavor 的 res 目录，同时提供 round 版本和单色层。标志矢量来自 `build/icons/tray/CommaTemplate.svg`。细节见 [design-foundation.md](design-foundation.md)。

## 8. 待确认

- 用户气泡在手机上的折叠阈值（§5）。
