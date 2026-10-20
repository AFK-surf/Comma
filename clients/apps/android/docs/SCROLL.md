# comma 滚动模块

Gradle 模块为 `:scroll`，namespace 为 `surf.comma.android.scroll`。

- `widget`：RecyclerView、LinearLayoutManager、LinearSmoothScroller、ListAdapter、DiffUtil、ConcatAdapter 和 ItemTouchHelper，以及它们依赖的实现。
- `physics`：惯性滚动、橡皮筋、回弹、速度采样和 Android 适配器。
- `ScrollPhysicsConfig`：集中管理物理参数。列表边缘与任务下拉刷新共用这些参数。

`ScrollContainer` 用于单个内容视图。它由模块的 RecyclerView 和 LinearLayoutManager 承载，物理行为和列表相同。默认竖向，横向设置 `orientation = ScrollContainer.HORIZONTAL`。它支持 `addView(content)`、`isFillViewport` 和 `fullScroll(View.FOCUS_RIGHT)`。XML 使用完整类名，配合 `android:orientation="horizontal"` 或 `android:fillViewport="true"`。

窗口 inset 由页面统一处理，容器不重复消费 inset。

`:app:checkScrollUsage` 检查 `app/src` 中的 Kotlin、Java 源码和 XML 布局，禁止系统滚动容器与 AndroidX RecyclerView。所有 app lint 任务依赖它。`python3 scripts/verify-scroll-usage.py` 验证这个检查确实拦截违规写法。

修改物理行为前，必须单独确认手感变更。运行模块物理回归测试，以及 README 中的构建、单元测试、lint 和产物隔离检查。在手机或模拟器上验收手感前，先获得使用者许可。

消费端 ProGuard 规则随 release AAR 发布，保留布局管理器的反射构造方法。

原版权与许可证文件头保持完整。修改过的文件标有 `Modified by the comma authors.`。第三方署名见 [NOTICE](../NOTICE)，许可证全文位于 `app/src/main/assets/licenses/Apache-2.0.txt`。
