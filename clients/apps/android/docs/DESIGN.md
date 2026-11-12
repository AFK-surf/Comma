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
- 左右页边距 28dp。气泡边缘间距：同一方连续消息 6dp，用户到助手 12dp，助手到用户 20dp，与 iOS 一致。

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
- 任务卡片、附件和出错卡片不是气泡。系统消息是居中的状态行。

## 6. 动效

- 时长和曲线沿用 Mac 客户端的 `tokens/motion.ts`。Android 上用 `PathInterpolator` 实现。
- 系统打开“移除动画”时，所有动效都要关掉，直接跳到终点。
- **流式文字不用弹簧动画**，只用透明度淡入。
- 靠缩放出现或消失的东西，缩放范围保持完整（避免跳动），缩到一半及以下时必须完全看不见：透明度用 `DesignMotion.seenAt(scale)`，一半大小时为 0，原大时为 1。各端规则相同。

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

## 9. 玻璃材质（实验性）

设置里的“玻璃材质（实验性）”打开后，浮动 chrome 用 `LiquidGlass.kt` 的 AGSL 着色器绘制。默认关闭。关闭时走原来的磨砂路径。切换后界面重建。

- 取值从 iOS 系统玻璃在相同内容上实测得到。取色在 `token_glass_tint`、`token_glass_tint_menu`、`token_glass_rim`、`token_glass_line`、`token_glass_fall`。着色器负责染色和外投影，浮层自身的填充是透明的，只留描边，也不设 elevation。
- 采样靠 `BackdropBlurLayout`：chrome 必须浮在它上面，用 patch 或 group 声明形状。没有 patch 的 chrome 不要用透明填充。
- 菜单（`ActionMenu`、消息操作）打开时放进所在窗口的 `GlassMenuLayer`，不用 `PopupWindow`。
- Tab 栏按住时，指示器升起成透明大镜片（`TabBarLens`）：连续跟手，放大背后的 Tab，松手才切换。尺寸、放大倍率、边缘折射和色散都按 iOS 真机录屏逐帧测得。手指停在两个 Tab 之间时，镜片留在原处。
- 边缘沿法线实测 iOS 27：暗线上下约 -10%，过 45° 后迅速加深到约 -32%。紧贴暗线是一道很细的亮线，上下边最宽，绕到接近水平才消失。亮线按指数衰减，没有转折：峰值约 1px，淡尾向内约 20px。SDR 截图把它截断成白色，看起来有约 6px 宽，不能作基准。
- 玻璃内部有一层内阴影：从上方约 7.5dp 投下，最深 2.4%，向内 17dp 消失，沿两侧绕下，到底边消失。亮带是贴着这道暗槽才显亮的，所以两者要一起改。
- iOS 的高光比页面白亮 25–30%（HDR），截图是 SDR，看不出来。Android 这里不用 HDR：窗口进入 HDR 后，Tab 镜片内部会从 254 变灰到 240，原因未查明。
- 白底上的玻璃内部取约 250，比白略低，给高光留余量。内部再暗就会读成一层灰底。
- 列表上的悬浮控件（状态切换器）用更重的 `token_glass_tint_frosted`，内容透出得更淡，内部没有上下渐变。
- 滚动到底部按钮下面有内容滚过，用采样玻璃。它的位置、缩放和透明度逐帧同步给玻璃。
- 背后没有内容滚过的控件（Home 和收件箱的按钮组、sheet 的按钮）用 `GlassSurface`，在纯色上画同样的边缘，不需要采样。按钮组用 `GlassCapsule`，单个按钮用 `GlassIconButton`。
- 玻璃外阴影宽而淡：贴边最深约 2.2%，向外约 32dp 消失，下移 10dp，衰减用平方曲线。14dp 的短阴影看起来很硬。iOS 模拟器上这类按钮的阴影更淡（约 1%），这里按真机观感取值。
- 小玻璃控件打开菜单时，控件连续变成菜单（`GlassMenuMorph`）。路径取自 iOS 录屏：打开时先长高、宽度几乎不变，随后才变宽，圆角直到最后才收成 26dp，行内容从比卡片更大的模糊状态落定。关闭时水滴先略微收窄，再由两形状融合吸回控件。节奏不回弹：iOS 模拟器有过冲，但 macOS 菜单没有，真机上过冲显得过于活跃，所以这里取临界阻尼附近。阴影由玻璃着色器按同一形状绘制，不用系统投影：系统投影跟不上形状，会一跳一跳。动画等第一帧画完才开始，否则这一帧的耗时会让弹簧跳过开头。菜单盖在控件上打开；大锚点（如消息气泡）仍是原来的弹出。
- 玻璃支持着色：`glassControl(tint = ...)`，对应 iOS 的 `.glassProminent`。品牌色玻璃几乎不透明，只保留边缘和阴影；禁用时变成灰色玻璃，不是半透明的品牌色。按下时颜色向白色提升约三分之一，取自 iOS 模拟器录屏。
- 可交互的玻璃用 `GlassPress`，参数来自 iOS 按钮的逐帧实测：约 150ms 放大 1.47 倍，拖动时只偏移约 2dp，沿方向拉伸约 3%；松手约 85ms 回到原尺寸再回弹。长胶囊按宽高比缩小放大量，这部分 iOS 没有基准。跟手的光也没有基准：iOS 模拟器不渲染它，强度是估的。按下时表面只变亮，不压暗，这和 iOS 一致。按下效果都在页面白以内。不要用 HDR 做超白：页面窗口、独立图层和独立窗口都试过，只要屏幕余量变化，整屏就会闪一下，因为面板亮度和页面压暗不同步；按钮大小的图层系统也不提亮。指尖会挡住它下面的光，所以轮廓上也有一段亮线跟手，范围比光晕大。脚本截图没有手指，判断可见性时要考虑遮挡。
- 做不到的地方：Dialog 里看不到下面的页面，`SurfaceView` 的视频画面也采样不到。这些表面保持原样。
