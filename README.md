# Zhihu Reader for KOReader v132

在 KOReader 中浏览知乎推荐流，支持二维码登录和整页翻页阅读。

## 功能

- 二维码扫码登录知乎账号（扫码确认后自动完成登录）
- 知乎风控（人机验证）检测与浏览器验证流程，修复安卓扫码"无反应"
- 查看个性化推荐流（需登录，每批 12 条，可 Load More 加载更多）
- 基于 ScrollHtmlWidget 的图文混排阅读器
- 全部图片都能加载，并自动压缩到屏幕宽度（低内存设备也不会卡死）
- 图片持久化缓存：下载一次后按文章保存在 `zhihu_article_images/<问题ID>/` 文件夹，下次打开同一篇直接显示，不再重复下载
- 字体大小调节（Small/Medium/Large/Extra Large）
- 导出 HTML（base64 内联图片，自动打开）
- 导出 EPUB（自动打开，无重复标题）

## 安装

将 `zhihu.koplugin` 文件夹复制到 KOReader 插件目录：

- **Kindle**：`koreader/plugins/`
- **Kobo**：`.adds/koreader/plugins/`
- **PocketBook**：`applications/koreader/plugins/`
- **Android**：KOReader 数据目录下的 `plugins/`

重启 KOReader，在主菜单 → 工具 → Zhihu Reader 中打开。

## 使用

### 登录
1. 菜单中选择 Login with QR Code
2. 手机知乎 App 扫描二维码
3. 手机上确认登录，插件自动轮询并完成登录

### 安卓风控（人机验证）
部分网络环境（常见于手机流量、运营商 NAT 出口 IP）会被知乎风控拦截：扫码状态接口返回
HTTP 403 / 错误码 40352，并要求跳转 `zhihu.com/account/unhuman` 做滑块人机验证。旧版本会把
这种响应当作"等待中"无限轮询，表现为**扫码后没反应**。

v128 起的处理流程：
1. 检测到风控后自动停止轮询，弹出「Zhihu Verification Needed」菜单
2. 选择 **Open Verification in Browser**：调起系统浏览器打开验证页（安卓支持），完成滑块验证
   - 不支持调起浏览器的设备可选择 **Show Verification URL** 手动打开该链接
3. 验证完成后回到 KOReader，选择 **I Have Verified - Continue Login** 继续轮询，登录自动完成
4. 若仍被拦截，可选 **Restart Login (Fresh Cookies)**：丢弃被标记的 `d_c0` 设备标识、
   重新获取 cookie 并生成新二维码

> 说明：验证页是 JavaScript 滑块验证码，KOReader 的 HTML 渲染器无法运行 JS，因此无法在
> 插件内直接显示验证界面，需要借助系统/外部浏览器完成。验证会话与本客户端的 cookie 绑定，
> 在同一网络下于浏览器完成验证后，KOReader 的后续请求即可恢复。Kindle 等未被风控的设备
> 不受影响。

### 浏览推荐
登录后菜单出现 Recommended Feed，点击加载内容列表，每批显示 12 条。列表底部有 >>> Load More >>> 按钮按游标加载下一批。

### 阅读文章
点击列表项进入 ArticleViewer：
- 左右滑动/点击翻页
- 上下滑动关闭
- 按返回键退出

开启 Show Images 时，**文章里的每一张图片都会加载**：
- 下载进度显示在**屏幕最下方一条细状态栏**（如 `Images: 3/12`），不弹窗、不遮挡正文
- 状态栏**只在翻页时刷新**，不会每下载一张图就闪一次屏（e-ink 友好）
- **下载时可以正常翻页阅读**，不再被阻塞；图片下载完会原地刷新显示
- 宽度超过屏幕的图会自动压缩为屏幕宽度的 PNG（观感无差别，解码内存从几十 MB 降到约 2MB）
- **二次打开直接读缓存**：图片按文章保存在 KOReader 数据目录下的 `zhihu_article_images/<问题ID>/` 文件夹（如 `img_001.png`），首次打开时已下载并压缩好的图，下次打开**立即显示、不再走网络**；未缓存的图才会在后台下载并写入该文件夹

### 导出
阅读时打开菜单选择 Export HTML 或 Export EPUB，导出后自动在 KOReader 中打开。

## 文件结构

```
zhihu.koplugin/
  _meta.lua           -- 插件元数据
  main.lua            -- 主逻辑（菜单、UI、登录、导出）
  article_viewer.lua  -- 文章阅读器（ScrollHtmlWidget）
  epub_builder.lua    -- EPUB 生成器
  zhihu_client.lua    -- HTTP 客户端与 HTML 解析
  README.md           -- 本文件
```

## 更新日志

### v132
- **修复图片缓存未生效**：v131 实际丢失了上一版的缓存机制，每次打开文章都会重新下载——表现为"每次都走网络、底部进度条重新跑一遍"。两个根因：
  1. main.lua 只认 `img_%03d.png` 缓存名，但宽度没超过屏幕的图（知乎配图多为 690px，Kindle 屏宽约 758px）不会被压缩，仍是原始扩展名（如 `img_001.jpg`），于是**永远不被识别为缓存**
  2. article_viewer.lua 的 `ensureImage` 在 URL 本身以 `.png` 结尾时，`orig_path == png_path`，`os.remove(orig_path)` 把刚写好的缓存图删掉，导致**每次都重新下载**
- **修复后的缓存行为**：
  - 下载与压缩结果**持久保存在 `zhihu_article_images/<问题ID>/` 文件夹**（`img_NNN.png` 优先，原扩展名文件 `img_NNN.<ext>` 作为小图/无法重编码图的缓存）
  - 打开文章时 main.lua 先查这两个缓存名，**命中即直接渲染、不走网络**
  - 超过 8MB 的缓存文件会被视为异常大图，自动重新下载并压缩（防止超大全分辨率图占满内存）
  - 卸载/清缓存只需删除 `zhihu_article_images/` 目录即可
- 版本号、About 信息与文档同步更新为 v132

### v131
- **下载进度改为底部状态栏**：移除居中的 `InfoMessage` 弹窗（会遮挡正文），改为屏幕最下方预留一条
  细状态栏（22px），显示 `Images: 3/12`，**不覆盖任何文字**
- **只在翻页时刷新**：下载计数只更新内存中的值，屏幕仅在**翻页时**（检测到 `page_number` 变化）
  重绘状态栏，避免每下载一张图就全屏刷新一次（e-ink 不再闪烁）；下载开始与结束时各刷新一次
- **下载期间可以正常阅读**：取消下载时的输入阻塞（滑动/tap/关闭都不再被吞掉），可以边读边等；
  背景下载完成才做一次原地刷新
- 布局改动用 `pcall` 保护：若底部状态栏构建失败，自动回退为整屏正文（不影响阅读）
- 版本号、About 信息与文档同步更新为 v131

### v130
- **所有图片都能加载**：移除 v129 的「每篇最多 10 张 / 单张最大 3MB」硬限额，一篇文章里的
  每一张图片都会下载并显示
- **改用"自动压缩"代替限额来防卡死**：下载后凡宽度超过屏幕的图，通过
  `RenderImage:renderImageFile` → `scaleBlitBuffer` → `writePng` 管道缩放为屏幕宽度的 PNG
  （6 寸 e-ink 屏上观感无差别，但单图解码内存从几十 MB 降到约 2MB），并把结果缓存下来，
  再次打开直接命中缓存
- **自动修复旧缓存**：v129 及更早缓存下来的原图，会在首次打开时被自动转换成屏幕宽 PNG，
  无需手动清理图片缓存
- **导出不再跳图**：Export HTML / Export EPUB 取消 3MB 大小限制，导出完整图片
- 保留 v129 的下载进度提示（i/N）与失败回落占位符机制
- 版本号、About 信息与文档同步更新为 v130

### v129
- **修复 Kindle 打开图片多的文章直接卡死**。原因有三，叠加生效：
  1. 每张图片的下载都是同步 HTTP 请求，会阻塞 UI 线程——Kindle 的 CPU/WiFi 都慢，几十张图
     就是连续数分钟无响应；
  2. 下载期间 tap/swipe/翻页全部被拦截，屏幕上又没有任何进度提示，看起来与死机无异；
  3. 下载结束后的 `setContent` 一次性把所有图片同时解码渲染，慢速 e-ink CPU 上 burst 解码
     长时间占死，大图还可能耗尽内存造成真死机
- **图片数量上限**：每篇文章最多加载 10 张（`MAX_ARTICLE_IMAGES`），其余保持 [图片N] 占位符，
  仍可通过 View Images 菜单逐张查看原图
- **图片大小上限**：单张超过 3MB（`MAX_IMAGE_BYTES`）的图片直接跳过（缓存中的超限文件也会
  被清理），避免大图解码拖垮低内存设备
- **下载进度提示**：后台下载时显示「Downloading images (i/N)...」，关闭阅读器时自动清除，
  不再"无声卡住"
- **修复刷新后失败图片变空白**：后台刷新时，未能加载（下载失败/被跳过/超限）的图片现在回落
  为 [图片] 占位符，而不是残留一个加载不出来的远程地址
- **导出保护**：Export EPUB 下载图片时也显示进度（此前完全静默）；Export HTML / Export EPUB
  均跳过超过 3MB 的图片，防止纯 Lua base64 编码大文件时卡死
- 版本号、About 信息与文档同步更新为 v129

### v128
- **修复安卓扫码登录"无反应"**：根因是知乎风控——移动网络下 `scan_info` 接口返回 HTTP 403 / 错误码 40352（"网络环境存在异常，需要人机验证"），响应中没有 `status` 字段，旧代码将其当作 `"waiting"` 无限轮询，扫码确认后毫无反馈。现在识别为独立状态并进入验证流程
- **新增风控验证流程**：检测到风控后停止轮询并弹出「Zhihu Verification Needed」菜单：
  - `Open Verification in Browser`：通过 `Device:openLink` 调起系统浏览器打开 `account/unhuman` 验证页（安卓可用；验证页为 JS 滑块验证码，KOReader 无法内嵌渲染，必须借助浏览器）
  - `Show Verification URL`：不支持外链的设备显示验证 URL 文本，可手动打开
  - `I Have Verified - Continue Login`：验证完成后恢复轮询，登录自动完成
  - `Restart Login (Fresh Cookies)`：`resetSession()` 清空被风控标记的 `d_c0` 设备 cookie 并重新获取初始 cookie、重新生成二维码
  - `Cancel Login`：关闭二维码界面与菜单
- **登录成功/登出时同步清理风控对话框状态**（`_risk_menu` / `_risk_verify_url`）
- 版本号、About 信息与文档同步更新为 v128

### v127
- **推荐流列表改为每批 12 条**：`getRecommendFeed` 增加累积上限（12 条）并在满批后截断；「Load More」游标在计数判断之前就已推进，始终从真实的下一页继续
- **修复 `image_map` 作用域 bug**：v126 的「刷新后保留已缓存图片」修复实际从未生效——`cached_map` 声明在 `if` 块内部，传给 ArticleViewer 的 `image_map` 引用的是未定义的全局变量（恒为 nil）。已提升为函数级局部变量
- **修复纯文本残留 `>` 字符**：`htmlToText` 的 `<[^>]+` 模式只匹配到 `>` 之前，标签结尾的 `>` 会残留在输出中，改为 `<[^>]*>`
- **修复二维码下载失败仍进入扫码界面**：原来 `pcall` 成功即认为下载成功，未校验返回值与文件是否落盘；现在两项都检查
- **修复 UTF-8 截断乱码**：列表摘要与加载提示按字节截断会把汉字切成半个产生乱码，新增 `utf8Truncate` 按多字节边界截断
- **修复图片查看器把 webp/png 强改名为 .jpg**：保留 URL 中的真实扩展名
- **登出时清空推荐流游标**（`feed_next_url`），换账号后 Load More 不再复用旧游标
- **删除重复定义的 `showRecommendFeed`**：两处完全相同的定义，后者静默覆盖前者
- **删除失效占位函数 `getAltQrImageUrl`**：返回不可用的占位 URL 且从未被调用
- **gsub 替换串改用函数形式**：URL/文件路径含 `%` 时不再被当作模式替换符（EPUB 导出与阅读器后台刷新两处）
- 阅读器文本模式回退的标签剥离模式 `<[^>]-[>]-` 修正为 `<[^>]*>`
- 版本号、About 信息与文档同步更新为 v127

### v126 (代码评审修复)
- **修复扫码登录崩溃**：`main.lua` 误调用了不存在的 `generateQrToken()` / `getQrImageUrl()`，已改为正确的 `getQrCodeToken()` / `getQrCodeImageUrl()`
- **铺满一页：推荐流多页累积 + 游标翻页**：原 `getRecommendFeed` 只抓单页且推荐流类型解析过严，列表往往只有几条。现改为跟随知乎返回的 `paging.next` 游标连抓最多 3 页并去重累积，同时正确识别文章/专栏/问题类卡片、过滤视频/广告/直播等不可打开项；菜单「Load More」按游标加载下一批而非重复抓顶部
- **修复推荐流 item_type 错误**：推荐项来自 `target.type`，之前被硬编码为 `answer`，文章类内容现在能正确识别
- **修复阅读器后台刷新后已缓存图片丢失**：新增 `image_map`，刷新时保留已缓存图片的本地引用
- **修复 webp 图片被错误改名成 .jpg**：删除强制 `webp→jpg` 改名，保留真实扩展名
- **修复导出 HTML 图片错位**：改为按 URL 匹配 base64 内联（而非按位置序号），并转义 `<title>`
- **修复含单引号的标题导致 `mkdir` 失败**：`os.execute` 改为统一走 `shellQuote` 安全引用
- **重做扫码登录为「点击→出码→自动登录」**：移除手动「Complete Login」按钮。根因是 `checkScanStatus` 只认 `set-cookie` 头里的 `z_c0`，而知乎扫码确认后登录 cookie 通常经由 `scan_info` 响应 JSON 的 `cookie` 字段下发，导致始终拿不到登录态。现已在确认时解析并写入该字段；并在出码后自动轮询扫码状态（每 2.5s），确认即保存 cookie、关闭二维码、原地刷新菜单为已登录态（Recommended Feed / Logout / User）
- **删除 Hot Feed（知乎热点）**：应需求移除了 `getHotList()`、`showHotFeed` / `_loadHotFeed` 及相关菜单项
- **删除冗余备份文件**：移除了 `article_viewer_v111.lua`、`article_viewer_v115.lua`、`main.lua_epub_export.lua`

### v125
- EPUB 导出后自动打开
- 修复 EPUB 双标题问题
- 优化阅读器页面边距
- 菜单项字号改为 Font Size

### v72
- 新增 ScrollHtmlWidget 阅读器
- 图文混排，整页翻页
- 图片本地缓存

### v68
- 修复图片重复显示
- base64 内联图片
- 优化 e-ink 排版

### v67
- 支持导出 HTML
- 优化 e-ink 屏幕排版

## 许可证

MIT License
