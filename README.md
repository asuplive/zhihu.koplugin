# Zhihu Reader for KOReader v37

在 KOReader 中浏览知乎推荐流，支持二维码登录和整页翻页阅读，专为电子墨水屏设备优化。

## 功能特性

- 二维码扫码登录知乎账号（URL 文本方式）
- 查看个性化推荐流（需登录）
- 推荐列表带刷新按钮，加载更多内容
- 整页翻页阅读（点击屏幕左右区域翻页）
- 字体大小调节（18/22/26/30 四档）

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
3. 点击列表项查看详情（TextViewer 整页翻页阅读）
4. 列表底部有「>>> Refresh >>>」按钮，点击加载更多推荐内容

### 阅读文章

TextViewer 支持：
- 点击屏幕右侧 = 下一页，左侧 = 上一页
- 硬件按键翻页
- 点击标题栏关闭按钮或按返回键退出

### 调整字体大小

主菜单 → 工具 → Zhihu Reader → Font Size → 选择合适的大小

## 目录结构

```
zhihu.koplugin/
  _meta.lua           -- 插件元数据
  main.lua            -- 主逻辑（菜单、UI、二维码登录、翻页）
  zhihu_client.lua    -- HTTP 客户端（Cookie 管理、API 调用、HTML 解析）
  README.md           -- 本文件
```

## 技术说明

### API 端点

| 功能 | API 端点 |
|------|----------|
| 推荐流 | `api/v4/feed/topstory/recommend?limit=20` |
| 回答 | `api/v4/questions/{id}/answers?limit=5` → HTML fallback |
| 专栏文章 | `zhuanlan.zhihu.com/p/{id}` |
| 用户名 | `api/v4/me` |
| QR token | `api/v3/account/api/login/qrcode` (POST) |
| QR 状态 | `api/v3/account/api/login/qrcode/{token}/scan_info` |

### Cookie 管理

- CookieJar 管理所有 HTTP Cookie
- Cookie 持久化到 `koreader/settings/zhihu_cookies.lua`
- 关键 Cookie：`_xsrf`（CSRF）、`d_c0`（设备标识）、`z_c0`（登录凭证）
- 用户名缓存：登录后缓存用户名，避免每次打开菜单都发起 API 请求

## 常见问题

### Q: 为什么不用二维码图片显示？

Android 端 KOReader 的 `ImageViewer` 组件存在稳定性问题，会导致 `pthread_mutex_lock on destroyed mutex` 崩溃。v31 改用 URL 文本方式，更稳定可靠。

### Q: 错误信息中的括号内容是什么？

错误信息格式如 `Load failed: unknown (Page HTTP 403)`，括号内是具体失败步骤，方便诊断。

## 兼容性

- KOReader 2022.01+
- 需要 `ssl.https`、`ltn12`、`socketutil`、`rapidjson`（dkjson 回退）、`NetworkMgr`
- 支持 Kindle / Kobo / PocketBook / Android 等所有 KOReader 支持的平台
- 越狱 Kindle 推荐使用

## 许可证

MIT License
