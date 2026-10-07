# CF 助手 (iOS)

参照 Android 版 CloudFlareAssistant 功能，用 SwiftUI 重写的 iOS 版（非官方，代码为重新实现）。

## 功能
- 概览：域名 / Workers / DNS / D1 统计，隧道告警，用量环（Workers 请求、KV 读取、D1 行读取、R2 A 类操作），域名列表
- 登录：API Token，或 邮箱 + Global API Key（凭据存钥匙串）
- 域名：Zone 列表、DNS 记录 增 / 改 / 删
- Workers：创建（Start with Hello World! 等模板，自动开启 workers.dev）、编辑、部署、删除；变量和机密、自定义域名、workers.dev 开关
- Pages：项目、部署记录、重试 / 回滚 / 删除；部署新站点（Hello World 模板，或选择文件 / 文件夹上传）；生产 / 预览环境变量和机密、自定义域名
- 存储：KV、D1（执行 SQL）、R2
- 开发者：Tunnels 状态与运行 Token
- 多账户切换

## Token 权限建议
用量环需要 Account Analytics:Read；Workers / Pages / KV / D1 / R2 / Tunnels 各需对应的 Edit 或 Read 权限。
权限不足的功能只会显示 “—” 或报错，不影响其它功能。

## 编译（GitHub Actions，无需 Mac）
1. 所有 .swift 文件、project.yml 放在仓库根目录，再手动创建 `.github/workflows/build-ipa.yml`
2. Actions → Build unsigned IPA → Run workflow
3. 下载 Artifact `CFAssistant-unsigned-ipa`，解压得到 `CFAssistant-unsigned.ipa`
4. 用 TrollStore / Sideloadly / AltStore / 自有证书 签名安装
