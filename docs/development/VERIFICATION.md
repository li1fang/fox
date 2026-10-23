# 重建与验证

## 干净环境

使用 Node 22（`.node-version`），然后 `npm run bootstrap`。macOS 另需 Python 3.12、Xcode 26.3 / 17C529、XcodeGen 2.45.x，以及已安装的 iPhone/iPad 模拟器运行时。

初始化安装仓库锁定的 npm 依赖、Playwright Chromium 及 `.venv` 中的 schema 依赖；不安装/切换全局 Xcode、不读取签名账户、不连接物理设备。Python 可通过 `FOX_BOOTSTRAP_PYTHON` 指定 3.12 可执行文件。XcodeGen 使用 [官方 2.45.3 发布包](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.3)；安装及 SHA-256 校验步骤见 [CI 配置](../../.github/workflows/ci.yml)。可解压到本地工具目录并将 `xcodegen/bin` 加到当前进程 PATH，不需全局安装。不要使用会浮动升级的 Homebrew 最新版本；不匹配时检查应停止。Linux 首次运行浏览器可能还需 `npx playwright install --with-deps chromium` 安装系统库。

`npm run doctor` 输出实际 Node、npm、Python、Swift、Xcode、SDK、XcodeGen 和可用模拟器版本。`DEVELOPER_DIR` 可指向对应 Xcode。模拟器构建 Fox 和 Fox Say 不需要 Apple 账号；实际设备构建另需本地 `FOX_DEVELOPMENT_TEAM`，不能把 Team ID 提交到仓库。

## 层级

| 入口 | 覆盖 | 明确不覆盖 |
| --- | --- | --- |
| `npm run verify:fast` | 类型、Web/API 单测、脚本/边界、核心/存储、合成 wire、Python 映射 | 全量 UI、私人录像、真实语音、设备 |
| `npm run verify:public` | fast + Fox/Fox Say 模拟器构建、App-host、iPad/iPhone UI、浏览器闭环 | 私人录像、真实系统语音、物理设备 |
| `npm run verify:private` | public + 固定私人语料、真实控制器、逐事件历史、后期标签核对、真实系统语音 | 新真人准确率、听感、签名/安装/物理性能 |
| `npm run test:trial -- <fresh-directory>` | 与 private 相同的严格兼容入口 | 不再依赖某个历史缓存目录；不自动完成设备门槛 |

可加 `-- --output .tmp/verification/<unique-run>`。公开层可用 `--component web` 或 `--component native` 分工，CI 必须两者都通过；单一 component 不代表完整 public。private 不允许分片绕过公开覆盖。

完整原生运行默认创建专属临时 iPad/iPhone 模拟器，使用已安装的机型/运行时，完成、失败或取消后仅清理本次创建的实例。已有模拟器和真机不删除。回执记录实例、运行时、所有权及清理状态；清理失败也不能通过。`doctor` 只读，fast/Web 不创建实例。诊断时可用 `FOX_TRIAL_IPAD_SIMULATOR` / `FOX_TRIAL_IPHONE_SIMULATOR` 指定已有 UDID；它们不会被清理，但其原有状态会影响结果，不属于干净环境证明。

模拟器创建/停止/删除使用异步命令，单次上限 60 秒；取消信号在清理及回执落盘期间仍被处理。强制终止（如 SIGKILL/主机掉电）无法执行清理，应把仍为 running 的回执视为未完成；人工处置时只针对回执中本次拥有的实例 ID，不能批量删除其他模拟器。

原生每个测试方法、其他测试每个文件都有明确分类。新增/删除/移动须更新目录并审核原因；文件内的全部 JS/浏览器/Python 用例会执行。公共层按分类不选择私人/语音/设备测试，并在回执中列出未覆盖，不通过 XCTest skip 假装成功。已选测试缺失、失败、重复或 skip 均失败。

Swift 方法扫描包括修饰符/属性后的 `test...` 声明，不认识的命名或多 XCTestCase 文件会明确失败；实际原生运行再次核对每个方法。Python 按分类清单逐文件加载，嵌套目录不依赖 `__init__.py`，任何空测试文件、skip 或 expected failure 都不能借其他文件的通过而变绿。

## 私人输入

设置 `FOX_PRIVATE_INPUT_MANIFEST` 为本地清单的绝对路径，再运行 private。没有默认私人路径，也不从另一份 checkout 借缓存。清单格式：

```json
{"schema":"fox.private_inputs.v1","assets":{"logical.id":{"path":"/absolute/private/file","bytes":123,"sha256":"64-hex-digest"}}}
```

实际所需 ID 和原始字节哈希在 [只读输入契约](../../apps/ipad/FoxTrainingCore/Sources/FoxTestSupport/Resources/private-inputs.contract.json)。清单路径只存在本地；契约不包含媒体、关键点、个人记录或绝对路径。缺项会列出清单，哈希变化或自行重签清单不能变绿。历史预期事件来自冻结基线，不允许用当前算法刷新预期来修测试。

公开 synthetic 样本只验证逻辑和存储格式，不属于摄像头真实数据。缺少私人输入不是准确性失败，但确实意味着 private 验收失败。不要为了测试把素材上传 GitHub。

## 回执与失败

每次运行独占目录，输出 `suite.json` 及实时追加的逐步日志。包含 scope/component、commit、源码指纹、dirty 状态、工具版本、输入哈希、选择/未覆盖用例、时间、结果和明确的 `deviceVerified: false`。开始、完成、失败、取消都保留。禁止复用旧目录；源码/提交/输入变化会使运行失效。源码指纹覆盖全部非忽略文件，包含 docs 和 Git commit 身份。

不得重试到绿后隐去失败；修正必须说明原因并新建运行。GitHub 使用无重试的浏览器与原生批次；上传范围仅公开 suite/log，不上传 `.data`、私有 xcresult 或用户截图。

本轮遇到一次旧模拟器旋转后窗口仍为竖屏：同一原断言在旧实例复现失败，在同型号/运行时的新实例通过。这证明结果受实例状态影响，尚未证明系统根因。因此增加实例隔离而不修改产品或放宽横屏断言；原失败、对照运行及最终完整运行分别保留。

再次使用回执前运行 `npm run verify:receipt -- <suite.json> --scope public`（分片加 `--component web` 或 `native`，私人回归用 `--scope private`）。它重新核对当前提交/源码、输入、所有步骤、日志哈希、所选测试覆盖和历史事件；跨提交的旧绿色不能复用。

完整旧套件约 38 分钟，其中 UI 约 31 分钟。这是历史基线而非性能承诺。fast 从结构上移除 UI，未从完整 public/private 中删掉原覆盖；最终以本轮回执的计时和实际用例核对。

## 发布边界

真实设备测试、联网状态、签名期限、安装前后记录哈希与正常启动另行验收。默认不运行、不调网络。本轮只保留已有试用候选。日志中的锁屏/开发者验证/签名过期属于环境问题，不归因于视觉算法。

公开 PR 只携带已审计源码和合成资料。新鲜 reviewer 用仓库入口核对数据保护、兼容性、断言改动和证据说法；本地通过不等于 GitHub CI 通过，CI 通过不等于真人试用通过。

提交后、推送前运行 `npm run verify:history -- origin/main`，扫描每个新增提交的变更内容，而不只检查最终目录。仍需人工/独立上下文核对公开权限。旧远端已经公开的历史不被本轮重写。

本轮初始化发现旧开发依赖告警；使用范围内修复并将 Vitest 定到 4.1.12，保留 Vite 6 系列与既有测试配置，随后重新跑原测试及依赖审计。依据：[Vitest 官方安全说明](https://github.com/vitest-dev/vitest/security/advisories/GHSA-82fw-gwwq-j7x9)。不使用强制升级到所有最新主版本的方式。

工具链来源：[GitHub macOS 26 runner 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。明确选择 Xcode 26.3；云端缺版本时报告环境失败，不退回默认 Xcode。
