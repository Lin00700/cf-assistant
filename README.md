# CF 助手 (iOS)

参照 Android 版 CloudFlareAssistant 功能，用 SwiftUI 重写的 iOS 版（非官方，代码为重新实现）。

## 功能
- 登录：API Token，或 邮箱 + Global API Key（凭据存钥匙串）
- 域名：Zone 列表、DNS 记录 增 / 改 / 删
- Workers：列表、查看 / 编辑脚本并部署、新建、删除（自动识别 ES Module / Service Worker）
- Pages：项目、部署记录、重试 / 回滚 / 删除
- 存储：KV（键值读写）、D1（执行 SQL）、R2（存储桶列表 / 删除）
- Zero Trust：Tunnels 列表、连接状态、运行 Token
- 多账户切换

## 编译（GitHub Actions，无需 Mac）
1. 新建 GitHub 仓库，把本目录全部内容（含隐藏的 `.github`）推送到 `main`
2. 打开 Actions → Build unsigned IPA → 等待完成
3. 在运行结果的 Artifacts 下载 `CFAssistant-unsigned-ipa`，解压得到 `CFAssistant-unsigned.ipa`
4. 用 TrollStore / Sideloadly / AltStore / 自有证书 签名安装

## 本地编译
```
brew install xcodegen && xcodegen generate && open CFAssistant.xcodeproj
```
