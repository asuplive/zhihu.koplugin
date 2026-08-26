# Zhihu Reader for KOReader v112

在 KOReader 中浏览知乎推荐流，支持二维码登录和整页翻页阅读，专为电子墨水屏设备优化。

## 功能特性

- 二维码扫码登录知乎账号（URL 文本方式）
- 查看个性化推荐流（需登录）
- 推荐列表带刷新按钮，加载更多内容
- **自定义文章阅读器**（基于 ScrollHtmlWidget，原生图文混排）
- 整页翻页（点击屏幕左右区域翻页，符合阅读器习惯）
- 字体大小调节（18/22/26/30 四档）
- 导出为 HTML 文件（含 base64 内联图片，自动在 KOReader 中打开，支持整页翻页）

## 安装方法

### 方式一：直接拷贝（推荐）

1. 将 `zhihu.koplugin` 文件夹完整拷贝到 KOReader 的插件目录：
   - **Kindle**：`koreader/plugins/`
   - **Kobo**：`.adds/koreader/plugins/`
   - **PocketBook**：`applications/koreader/plugins/`
   - **Android**：KOReader 数据目录下的 `plugins/`

2. 重启 KOReader

3. 打开主菜单（顶部下拉或菜单按钮）→ 工具 → Zhihu Reader

### 方式二：通过 SSH 安装（适合越狱设备）

```bash
# Kindle 示例（通过 SSH 连接后）
cp -r zhihu.koplugin /mnt/us/koreader/plugins/

# Kobo 示例
cp -r zhihu.koplugin /.kobo/koreader/plugins/
```

然后重启 KOReader。

## 使用说明

### 二维码登录

1. 打开 KOReader 主菜单 → 工具 → Zhihu Reader → Login with QR Code
2. 在 TextViewer 窗口中查看扫描 URL
3. 打开手机知乎 App → 扫描或输入该 URL → 确认登录
4. 关闭文本窗口，在菜单中点击「Complete Login」
5. 显示「Login successful!」即表示登录成功，菜单自动刷新显示用户名
6. 登录状态会自动保存，下次打开无需重新登录

> 二维码有效期约 2 分钟，超时后需重新获取。

### 浏览推荐流（需登录）

1. 登录后，菜单中会出现「Recommended Feed」选项
2. 点击进入，加载推荐内容列表
3. 点击列表项查看详情（ArticleViewer 整页翻页阅读）
4. 列表底部有「>>> Refresh >>>」按钮，点击加载更多推荐内容

### 阅读文章（v72 新增）

v72 使用基于 ScrollHtmlWidget 的自定义弹窗阅读器，替代了旧的 TextViewer：

- **图文混排**：文字和图片在同一页面内显示，无需切换查看器
- **整页翻页**：点击屏幕左/右半区翻页，符合阅读器习惯
- **滑动滚动**：左右滑动翻页，上下滑动关闭阅读器
- **返回键关闭**：按硬件返回键退出阅读器
- **CSS 排版**：支持段落缩进、作者加粗、投票数样式、图片边框等
- **图片本地缓存**：开启「显示图片」后，图片下载到临时目录，离线可看

### 调整字体大小

主菜单 → 工具 → Zhihu Reader → Font Size → 选择合适的大小

### 导出 HTML

阅读回答时选择菜单中的 **Export HTML**：
- 自动下载图片并内联为 base64 编码（无需网络即可查看图片）
- 导出后自动在 KOReader 中打开
- 支持整页翻页阅读
- 图片文件仍保存到 `images/` 文件夹，方便单独查看

## 目录结构

```
zhihu.koplugin/
  _meta.lua           -- 插件元数据
  main.lua            -- 主逻辑（菜单、UI、二维码登录、翻页）
  article_viewer.lua  -- 自定义文章阅读器（ScrollHtmlWidget 图文混排）
  zhihu_client.lua    -- HTTP 客户端（Cookie 管理、API 调用、HTML 解析）
  README.md           -- 本文件
```

## 技术说明

### 阅读器架构（v72）

- **ScrollHtmlWidget**：KOReader 内置的 HTML/CSS 渲染引擎（基于 MuPDF）
- 图片下载到 `koreader/zhihu_article_images/` 临时目录
- 通过 `html_resource_directory` 参数让 MuPDF 解析相对图片路径
- CSS 注入控制排版样式（字体、行距、缩进、图片边框等）

### API 端点

- 推荐流：`https://www.zhihu.com/api/v4/moments?limit=5`
- 回答详情：`https://www.zhihu.com/api/v4/questions/{id}/answers?limit=5`
- 文章详情：`https://zhuanlan.zhihu.com/p/{id}`
- 二维码：`https://www.zhihu.com/api/v3/account/api/login/qrcode`

### 已知限制

- 部分功能需要登录后的 Cookie
- 二维码有效期约 2 分钟
- 推荐流需要已登录状态

## 故障排除

### 插件不显示在菜单中

1. 确认 `_meta.lua` 文件存在且没有语法错误
2. 确认插件目录路径正确
3. 重启 KOReader

### 无法获取推荐

1. 确认已登录（菜单中显示用户名）
2. 确认网络连接正常
3. 尝试刷新推荐流

### 阅读器中图片不显示

1. 确认菜单中「Show Images」选项已开启
2. 确认网络连接正常（首次加载需下载图片）
3. 图片缓存目录：`koreader/zhihu_article_images/`

### 导出 HTML 失败

1. 确认设备存储空间充足
2. 检查错误提示中的路径信息
3. 尝试重新导出

## 更新日志

### v72
- 新增 `article_viewer.lua`：基于 ScrollHtmlWidget 的自定义阅读弹窗
- 替换 TextViewer 为 ArticleViewer，支持原生图文混排
- 图片下载到本地临时目录，通过相对路径引用
- 注入 CSS 控制排版（段落缩进、作者加粗、图片边框等）
- 支持整页翻页（点击左/右半区）、滑动关闭、返回键关闭
- 保留导出 HTML 功能（base64 内联图片独立流程）

### v68
- 修复图片重复显示问题（知乎 noscript 块导致 img 标签重复）
- 图片内联为 base64，无需依赖文件路径
- 优化 e-ink 屏幕排版（更大字号、更高对比度）

### v67
- 支持导出为 HTML 文件（含图片，自动打开）
- 支持 base64 内联图片
- 修复 HTML 文件写入失败问题
- 优化 e-ink 屏幕排版

## 许可证

MIT License
