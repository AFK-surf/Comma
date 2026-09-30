# ScrollArea

## 滚动条可见性

通过 `scrollbarVisibility` 选择且只选择一种策略：

- `always`：始终显示。
- `hover`：hover 滚动区域时显示；键盘焦点位于区域内时也保持显示。
- `scroll`：仅滚动时显示。这是默认策略。
- `scrollbar-hover`：只有 hover 到滚动条轨道位置时显示。

`scroll` 策略支持两个额外配置：

- `scrollbarHideDelay`：停止滚动后隐藏的延迟，单位为毫秒，默认 `500`。
- `scrollbarHoverReveal`：hover 到滚动条轨道位置时强制显示，默认 `true`。
- `scrollbarRevealSource`：`all` 会让任何滚动（包括应用自动定位）显示轨道；
  `interaction` 只响应滚轮、键盘、触摸和拖动轨道等直接用户交互。

隐藏状态下，用于轨道 hover 的透明命中区域会覆盖在内容上，其宽度或高度由
`scrollbar.size` 决定。不要在实例外再实现一套 hover 探测或滚动计时逻辑。
轨道在共享测量明确确认对应轴存在 overflow 前保持未渲染状态，不得让未测量的
透明轨道拦截内容交互。

For an anchored layout, enable the fixed-height shell only when actual content overflows.
Do not preserve an artificial scroll range for content that fits.
Use `onContentResize` and `onViewportResize` to update this decision.

If the shell hides inner size changes, pass the actual descendant element through
`contentResizeTarget`. Store the element in state with a callback ref so mounting,
replacement, and removal update the prop. A ref object alone does not trigger a render.
The shared `ResizeObserver` observes this target when `onContentResize` is present.
Do not add a local observer.

## 滚轮路由

滚动由浏览器原生完成（合成器线程），ScrollArea 只观察 `scroll` 事件来更新滚动条、
边缘状态和 `onMetricsChange`。主线程再忙（流式渲染、代码高亮、React 提交），滚动
也不会等它。不要在业务组件里接管 `wheel`、`preventDefault`，或为滚轮改写
`scrollTop` / `scrollLeft`。

- 纵向区域和 `both` 区域：滚轮完全交给浏览器，组件不注册可取消的 `wheel` 监听。
- 横向区域：普通鼠标没有横向滚轮，所以它的纵向滚轮会被映射为横向滚动——这是唯一
  由脚本处理的滚轮。该监听只在区域**确实横向溢出**时存在；内容放得下的代码块、表格
  上方的滚轮仍然只走合成器。触控板的横向增量由浏览器原生滚动；映射滚到尽头后不再
  取消事件，滚轮会按下面的规则交给外层。
- 横向溢出可以在没有任何盒尺寸变化的情况下出现（高亮后的代码替换掉同尺寸 `pre` 里的
  占位文本），共享 observer 看不到。这个答案只在指针位于区域上方时才有用（hover
  滚动条、滚轮映射），所以非纵向区域在指针进入时重新测量一次。不要为此再加 observer。
- 嵌套 `ScrollArea` 按轴向隔离：纵向滚轮来自内层区域时，即使内层已到达边界，也不会
  被外层横向区域重新解释为横向滚动。
- 链式滚动由 `overscroll-behavior` 决定：最外层区域是 `contain`，滚动不会传到页面，
  横向滑动也不会变成浏览器的前进/后退；嵌套在另一个 ScrollArea 内容里的区域是
  `auto`，它不处理的输入（代码块上的纵向滚轮、看板列上的横向滑动、滚到尽头的列表）
  按浏览器原生规则交给外层区域。Portal 出去的弹层不算嵌套，仍然是 `contain`。
- 每个区域的 `overflow` 和边缘遮罩只作用于**自己的** viewport（子选择器），不会落到
  嵌套区域上。
- `scrollbarRevealSource="interaction"`：滚轮和它引起的 `scroll` 是两个事件。滚轮输入
  后约 250ms 内发生的滚动算读者的，显示滚动条；前面没有滚轮的滚动算应用自己的
  （跟随到底、跳转），保持隐藏。键盘、触摸和拖动滚动条照旧直接显示。

## 使用约束

- 需要可见滚动条表现的 client 区域统一使用本组件，不要用原生
  `overflow-*` 和局部 scrollbar CSS 重建。
- `edgeEffect` 只选择 `none`、`mask` 或 `blur` 之一；方向由
  `orientation` 推导。
- 边缘效果的缓动只服务于“状态变化”。区域的第一个边缘状态（挂载即溢出、由拥有者
  直接定位到末尾的转录）随内容同帧落定，不缓动；某个状态保持两帧后，
  `data-edge-transition` 才会写到 viewport 和边缘元素上启用过渡，失去溢出后重新
  计时。不要在业务组件里用延时或关键帧给边缘渐变补“出现动画”。
- 内容尺寸变化优先使用 `onContentResize`，不要为每个实例新增
  `ResizeObserver`。
- 需要在可视区本身变化时重算业务布局，使用同一共享 observer
  提供的 `onViewportResize`；回调只会在共享测量确认 block-size 变化之后触发。
- 子内容需要以当前可视高度作为布局基准时，通过 `viewportClassName` 把 viewport
  声明为尺寸容器（`container-type: size`），子内容用容器查询单位（`100cqb`）
  取值。ScrollArea 不再把 viewport 尺寸发布成 CSS 自定义属性：写在根节点上的
  自定义属性会被整棵滚动子树继承，viewport 高度每变一次，子树里的每个元素都要
  重算一次样式。尺寸容器要求 viewport 的尺寸不依赖内容；由内容撑高的 ScrollArea
  没有可用的“可视高度”，不要在业务组件里再做一次测量来补。
- 滚动过程中会翻转的状态写在**消费它的元素**上，不写在根节点：滚动条的显隐状态
  `data-scrolling` 在区域自己的滚动条元素上，边缘模糊的 `data-visible` 在边缘元素
  上。浏览器的样式失效不区分子选择器和后代选择器，根节点属性一变，转录里每个代码块
  和表格的滚动条都要重算一次样式。业务 CSS 不要用 ScrollArea 根节点上随滚动变化的
  属性去选中后代。
- 分页列表用 `ScrollAreaLoadMore` 放在列表的末端（旧记录在上方时用
  `edge="start"`）加载下一页，不要再放“加载更多”按钮。读者滚动到距末端一个可视高度
  以内时请求下一页；一页落地后末端仍在范围内就继续请求，直到列表撑满或没有下一页。
  宿主必须如实传 `loading`：请求结束会让它重新检查末端。请求失败时传 `failed`，
  它不会自动重试，要等末端离开视野再回来，或读者按它给出的“重试”。几列共享同一个
  分页（任务看板）时给每列传 `onlyWhenScrollable`，短列可见的末端不算请求；
  宿主自己处理“没有一列能滚动”时的补页。宿主已有加载和失败样式（菜单）时传 `quiet`。
- 大型文档子树在 OS 窗口拖拽时因逐像素换行产生明显主线程阻塞，可启用
  `freezeContentInlineSizeOnWindowResize`。它只冻结内容的 inline layout size，
  viewport 仍逐像素贴合窗口，并在 resize 停止后执行一次最终重排。不要用于需要
  在拖拽过程中持续改变内部断点状态的内容。
