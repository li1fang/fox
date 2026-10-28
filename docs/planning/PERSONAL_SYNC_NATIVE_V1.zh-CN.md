# SYNC-3 原生接入

2026-10-28，产品与交付负责实施。接续 [同步契约](PERSONAL_SYNC_V1.zh-CN.md)。保留真实资料、本地改动，不自动删除，不改算法或 CI。

## 实施顺序和门槛

1. SYNC-3A：先测试 HTTPS 适配器的认证、限额、截断请求、限流与错误边界，再部署局域网入口。使用成熟 ASGI 运行时；TLS 私钥只在服务器，拒绝明文访问，不使用开放式 CORS。合成数据验证不动真实库。
2. SYNC-3B：原生协议和 TLS 信任、Keychain 配对凭据、本地 Journal 同事务 outbox、连续离线编辑、导入/删除及备份语义。必须针对旧库迁移和并发修改先补测试。当前删除物理移除历史，不能直接作为同步删除复用。
3. SYNC-3C：最小配对/前台同步 UI，保留记录首页和训练体验；失败、待同步、冲突明确显示，不把本地保存标成远端成功。
4. SYNC-3D：定向原生回归、两端原件备份核验后更新；需要用户解锁、配对时通知。手机同步未验收前不得宣布完成。

网络第一版只对本地局域网 IP 开监听，不开放公网/改路由器或系统信任。TLS 证书由服务器生成，配对时通过可信交接获得证书；原生端必须校验证书身份、有效期及主机名，不能无条件接受自签名证书。具体配对交付在 3B/3C 落实。私有配置/凭据/证书不进 Git。

停止条件：身份验证失败、服务端监听范围扩大、未知库版本、冲突数据丢失、源文件变化或不可验证的迁移。安全入口、原生存储、UI、真机分别验收，不降低完整验收要求。

## SYNC-3A 执行结果

2026-10-28：HTTPS 网关和独立原生传输模块通过限定验收。负责人：产品与交付，服务/协议维护归数据与服务。任务契约见 [SYNC-3A](../development/sync-3a-task.json)。本阶段没有修改 FoxJournalCore、App 界面、计数算法、CI 触发或设备版本。

- Linux 使用固定版本 Uvicorn，单独 venv 和内容指纹版本目录。`scripts/sync_https.py` 只开放 `POST /v1/rpc` 的配对领取、推拉和照片接口；邀请创建/撤销仍由已认证 SSH 管理，不开放 HTTP 管理端。
- 网关拒绝明文、浏览器 Origin、压缩请求、超限/截断内容；认证在照片接收之前完成。限制请求头、附件、读取时间、配对尝试与并发，不记录访问日志或反射记录/令牌到错误响应。线程任务被取消时，等待实际线程退出后才释放文件和并发槽。
- `FoxSyncCore` 独立承担 URLSession/TLS/传输限额，不把网络依赖塞进本地记录模块。指定可信交接获得的证书为独占锚，同时校验主机名与有效期；拒绝重定向。流式响应设置上限，错误响应立即取消。Probe 是开发端工具，不是 App 配对页面。
- 合成双副本完成图文推拉、照片字节核验；Mac 上实际 Swift HTTPS 探针返回同一合成记录。不是 iPhone/iPad 运行时验收。
- 经过用户明确授权启用服务账号的 systemd linger；稳定用户服务启用自启动，并在 SSH 断开超过用户管理器原退出窗口后再次确认 active。仅绑定局域网 IPv4，不改 SSH、路由器、防火墙或系统信任。不宣称公网可用或实测过主机重启。
- 正式同步库仍为空，与已有资料归档分离。两个试验设备凭据已撤销，试验服务停止；合成库与失败回执保留。真实记录、原照片/录像、设备及 Mac 原件未删除、未迁移。

## 验证与失败保留

| 验证 | 结果和证据上限 |
| --- | --- |
| Python 同步/网关/归档回归 | Mac 53 项通过；Linux 部署时同步 20 + 网关 7 项通过；归档 Linux 26 项沿用上一轮，不冒充本轮重跑 |
| Swift 传输回归 | Mac 6 项通过：URL/锚、帧限额、超大流、错误体、同一生产 TLS 校验函数的错锚/错主机/过期反例 |
| iOS 编译 | arm64 iOS SDK 编译通过；没有运行模拟器或真机测试 |
| 验证入口 | 59 项通过，新测试已登记并接入已有 native suite；不是完整产品回归 |
| 实际局域网 | Python 双副本/照片 + Swift 探针通过，匿名请求拒绝；系统默认信任仍拒绝私有证书 |
| 持续服务 | SSH 断开后 active、enabled、linger 和仅 LAN 监听通过；没有保持 Mac SSH 会话作为运行依赖 |
| 独立审查 | 新上下文静态复核通过；执行结果由本任务提供，不将静态审查写作远端测试 |

私有证据集中于 `.tmp/verification/sync-https-20261028/`：`accepted.json`、`python-final.log`、`native-final.log`、`verification-entry-fixed.log`、`native-final-probe.log`、`service-final.log`。它们不是公共附件，不随 Git 发布。

保留的失败及处理：

1. 原服务随用户管理器登出退出：环境/生命周期问题；明确授权 linger 后验证，不用持续 SSH 掩盖。
2. Swift 实际 HTTPS 的初版信任回调未覆盖任务级 challenge：传输实现问题；统一会话级/任务级校验，实际网络重测通过，没有关闭证书校验。
3. 审查发现完整缓冲后才限额、取消后线程仍访问临时文件：实现问题；先补可失败的流式及取消测试，再修复。失败日志保留。
4. 新原生测试目录导致验证入口 fixture 缺目录：测试夹具问题；补齐真实登记路径和断言，59 项通过，不静默跳过新模块。

## 运维与接续

同一 Mac 的私有 `~/.config/fox/sync-https.json` 提供 endpoint、vault、独立保存的公有证书路径/摘要及服务名称；不含设备令牌。SSH 连接沿用原共享配置。不要把该配置或 TLS 材料提交仓库，也不能把从不可信网络下载的证书自动当作锚。

服务端依赖通过 `python -m pip install -r scripts/sync-https-requirements.txt` 安装到隔离 venv。Uvicorn 以 `sync_https:app --factory` 启动，`FOX_SYNC_ROOT` 必须是绝对路径。实际安装的 user unit 固定 release、LAN 地址、端口及 TLS 文件；查看/停止用 `systemctl --user status/stop fox-sync-https`，更新须先验证新 release，再切换 unit 并保留旧证据，不能覆盖运行中的源码。邀请/撤销仍遵循 [同步契约](PERSONAL_SYNC_V1.zh-CN.md)。

证书本次为 90 天测试证书，自动续期、换锚分发和地址改变尚未实现；到期/身份变化应失败并明确提示，不回退明文或跳过验证。配对凭据将存 Keychain；本轮没有向设备分发任何凭据。暂停服务不删除资料；若未来停用 linger，应先核对同账号其他后台服务，不随意全局回退。

下一步 SYNC-3B 的验收门槛：旧 Journal 升级保留全部历史/照片；写记录与 outbox 原子提交；断网连续修改、重复上传、冲突保留、删除墓碑及备份恢复不损失附件。之后才做配对/前台同步 UI，再安排有备份的双设备验收。上述未完成项不是本阶段的通过项。

参考边界：[Uvicorn 设置](https://uvicorn.dev/settings/)、[运行行为](https://uvicorn.dev/server-behavior/)、[Apple 手动服务器信任校验](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication)。使用成熟 HTTP/TLS 运行时，不新增通用账号系统。
