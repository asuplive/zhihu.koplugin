# Zhihu Reader for KOReader v125

在 KOReader 中浏览知乎推荐流，支持二维码登录和整页翻页阅读。

## 功能

- 二维码扫码登录知乎账号
- 查看个性化推荐流（需登录）
- 基于 ScrollHtmlWidget 的图文混排阅读器
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
2. 手机知乎 App 扫描二维码或输入 URL
3. 确认登录后，菜单点击 Complete Login

### 浏览推荐
登录后菜单出现 Recommended Feed，点击加载内容列表。列表底部有 >>> Refresh >>> 按钮加载更多。

### 阅读文章
点击列表项进入 ArticleViewer：
- 左右滑动/点击翻页
- 上下滑动关闭
- 按返回键退出

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
