# CF 助手 (iOS)

参照 Android 版 CloudFlareAssistant 功能，用 SwiftUI 重写的 iOS 版（非官方，代码为重新实现）。

## 功能
- 概览：域名 / Workers / DNS / D1 统计，隧道告警，用量环（Workers 请求、KV 读取、D1 行读取、R2 A 类操作），域名列表
- 登录：API Token，或 邮箱 + Global API Key（凭据存钥匙串）
- 域名：Zone 列表、点进域名后有：DNS 记录（增改删、BIND / CSV 导出、BIND 导入）、流量分析（请求 / 缓存 / 流量 / 威胁图表）、SSL·缓存·安全设置（加密模式、始终 HTTPS、开发模式、安全级别等）、清除缓存（全部 / 按 URL）、Workers 路由、邮件路由（目标地址、转发规则、兜底规则）
- Workers：创建（Start with Hello World! 等模板，自动开启 workers.dev）、编辑、部署、删除；变量和机密、自定义域名、workers.dev 开关
- Pages：项目、部署记录、重试 / 回滚 / 删除；部署新站点（Hello World 模板，或选择文件 / 文件夹上传）；生产 / 预览环境变量和机密、自定义域名
- 存储：KV（按前缀搜索、批量导入）、D1（执行 SQL）、R2
- 设置：API Token 管理（查看、创建、重新生成、删除）
- Pages 项目页（仿控制台）：部署（详情、构建日志终端、浏览器打开）/ 指标 / 自定义域名 / 设置（变量和机密、KV·D1·R2 绑定、构建与兼容性信息）
- 优选 IP（移植自 BestCF 本地优选脚本，无需登录即可用）：多源抓取（域名 / IP / ip:port / CIDR / JSON / 粘贴文本）→ 去重 → 并发快测（TCP 延迟、TLS、/cdn-cgi/trace 取 Colo、纯度）→ 过滤（纯度 / 国家 / Colo）→ 复测（丢包 / 抖动）→ 下载测速 → 综合排序 → 导出 TXT / CSV / JSON → 一键写入 Cloudflare DNS，或写入 Worker / Pages 变量
- 开发者：Tunnels（连接器与连接详情、清理失效连接、公共主机名增删并自动建 CNAME、运行令牌与安装命令）、优选 IP
- 多账户切换

## Token 权限建议
用量环需要 Account Analytics:Read；Workers / Pages / KV / D1 / R2 / Tunnels 各需对应的 Edit 或 Read 权限。
权限不足的功能只会显示 “—” 或报错，不影响其它功能。

## 编译（GitHub Actions，无需 Mac）
1. 所有 .swift 文件、project.yml 放在仓库根目录，再手动创建 `.github/workflows/build-ipa.yml`
2. Actions → Build unsigned IPA → Run workflow
3. 下载 Artifact `CFAssistant-unsigned-ipa`，解压得到 `CFAssistant-unsigned.ipa`
4. 用 TrollStore / Sideloadly / AltStore / 自有证书 签名安装
