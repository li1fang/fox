# V2 count-only 客户端接入

2026-11-01。产品集成基线 `18dab41a56c53a47723c26c2d420f43d7e6e75f0`。本包是开发接入，不是独立准确率、自然相机或内部用户试用验收；不开普通用户入口，不推送或安装到物理设备。

- 原侧面弯举、正面侧平举、背面高位下拉和无相机凯格尔的路由保持默认。`TrainingActivity`/`VisionExercise`原枚举不扩张；新的侧面徒手深蹲入口按动作独立准入，当前只出现在开发活动选择器。近正面弯举辅助是显式构图开关，不按次数挑算法。
- DEBUG 且 `FOX_COUNT_ONLY_DEVELOPMENT=1`（兼容 `FOX_ASSISTED_CURL_DEVELOPMENT=1`）才显示开发入口。普通内测动作集合为`CountOnlyAvailability.admittedActions`，当前为空；能力未过门前全部普通入口关闭。集合只能准入深蹲，弯举在本包已止损，仍仅开发可见，不随深蹲开放。未来独立门通过且冻结目标Apple/预处理/PTS与实际消费者等价后，才允许本树单写者据证据改集合；该代码出口不等于已经准入。
- 准入深蹲后，首页显示“内测 · 侧面徒手深蹲”，本组设置选择固定近侧腿；既有活动选择器可切回原四动作，关闭视觉可人工记录。旧弯举辅助档在仅深蹲准入时仍保留事实、人工继续；普通开关不会悄悄恢复其算法。
- 只将纯运行时移入产品Core：连续弯举来自 `19cfd1888971e05b98ee1cb0019d5c52a98a3111`，深蹲 `SquatSelectedCounter.swift`统一复用`b587c21`发布runtime（SHA `8781f2bf97e30bff63d860a37f7828723fa73b1c2d30cd92addca95b31eba588`）；其纯 `SquatCountOnly.swift`固定摘要 `835fc68a49a664f893684bc018d071c2102a66d4fed803d696aabbbcdfc03d6a`。实验CLI、评估器和原始资料不进入App依赖。

## 输入和连续性

`PoseCamera`使用原采集PTS秒（Double，不是完整CMTime的value/timescale/epoch）、Vision normalized bottom-left坐标和旋转后的像素尺寸，原12Hz节流不重采样。前置预览镜像与算法坐标独立；真实相机传输固定不镜像，replay没有来源证明时镜像为unknown。每个记录run保存坐标约定、镜像事实、Apple revision与独立PTS秒原点。外部原整数时钟需按冻结times索引映回，不能将Double字段称为整数PTS已保留。

用户开始训练后立即计时；相机/必要点缺失、多人归属歧义、时间缺口仅丢半次并保留完成次数，不调用训练pause/end/reprepare。后续可靠输入自动从完整周期继续。相机源/页面生命周期区分观察run，不拼接半次或推断跨run节奏。用户主动暂停、结束和实际进程重启另行保留原训练生命周期语义；进程终止后的未知运动时间不补造。

弯举保留原中央肩中心和原同臂/计数门；深蹲按固定近侧髋中心选择，候选须同侧髋膝踝均有效且raw confidence≥0.5，与冻结counter一致。初始化使用既有中央区域；bound仅沿原局部跳变及歧义门继续，不把初始化x范围当成每帧硬裁切；不同候选归属不明则本帧不计，完全相同点位的重复观察可互换。不把区域选择称作长期人物身份识别，也不宣称普遍多人容忍。

## 持久化和呈现

`CountOnlyEvidence`提供动作、算法版本、原PTS、完成事件和观察段；`WorkoutCountOnlyEvidence`将其绑定到session/exercise/set/attempt及多个观察run。接受新snapshot时校验版本、来源、固定侧、Apple revision、时间顺序和已接受事件前缀；实际`LocalTrainingRepository`保存/重开使用同一校验。

只有首次写入此类证据才将训练档案升到v3，并在覆盖前以原字节SHA命名保留原v1/v2备份（仍逐字节复核）；writer失败后的普通v2修改不会与上次备份冲突。旧记录字段不重写；旧App将拒绝v3，不能以忽略未知字段的方式回写并丢失新证据。关闭开发准入后重开新档案时，保留自动事实并允许人工继续，不能留死的继续按钮。关闭新模式是本客户端内的算法回退，不能用安装旧App覆盖v3档案来实现。

人工次数保存在原reps/sideRepetitions，自动事实另存；未知、明确0和更正均独立。零个接受事件不提供自动零建议，相等人工数也不升级成视觉真值。count-only记录不构造`CurlRepetition`，不填阶段0秒，不生成rhythm/form assessment。引导只消费已提交自动数及训练生命周期；显式countOnly标记禁止计划/观察阶段动画和阶段语音，实际语音听感仍未验。

## 验证边界

新增软件回归登记于既有catalogue，包含真实repository roundtrip、写入失败重试、旧默认、阶段未知、中央冲突、缺点恢复和来源时钟边界。公开合成检查不是新相机准确率。失败与后续定向修复以忽略目录追加保留；完整public、真实App相机输入等价及能力独立门仍由campaign统一验收，不能拼接不同候选回执称整产品通过。

## 公开输入诊断出口

复用DEBUG `VisionReplayBatch`，显式`FOX_COUNT_ONLY_DIAGNOSTIC=1`及全新UUID的`FOX_POSE_BATCH_JOB`才启动countOnly诊断。输入为App Documents/FoxReplay/Jobs/UUID/job.json，kind=cache、mode=countOnly，case固定动作/近侧和原秒半开窗口；不接收expected count或参考端点来驱动链。raw首行`fox.count_only_pose_input.v1`声明public Apple2D或public_synthetic、sourceSHA256、revision=1、source_pts_seconds、bottom-left/pixel-up和镜像事实，后续沿既有PoseVideoRow。files可同时绑定原times.jsonl的bytes/SHA；只做完整性索引，不参与counter。schema/容量/非法坐标/单调原时钟/重复runID/文件SHA校验沿用既有边界；不支持新视频解码或推理。

每case使用独立archiveURL与preferences:nil，资料写入FoxReplayRuns/UUID，不写默认training-records；原源origin+2秒为正式边界，前2秒真实输入只预览。原秒逐帧走实际PoseCamera共享greedy cadence，再由WorkoutVisionCoordinator/CountOnlySession消费，不重采样或用ready延迟删源分母。真实保存、重开count-only记录后，人工确认保持unknown；没有阶段和节奏。输出sourcePTSSeconds/admittedFramePTSSeconds/completedAtSourcePTSSeconds明确是原PTS秒Double，包含run/segment与逐帧trace；事件是计数确认时刻，不能充当精确站立端点。原整数tick由外部冻结时钟一对一映回，仅容忍浮点尾差。

本轮联合定向App-host在冻结快照执行30/30、零跳过，含11消费者、2诊断、9旧batch、8原D1/引导。此前按动作准入红测1项3断言失败、诊断mode红测失败均保留；本结果不等于完整public、独立能力门、设备候选或用户可用性。已知公开UI两条定向与后续整包验收单独记录，不将旧绿色拼成新候选全绿。

回放诊断沿用既有传输枚举：记录`source=fixture`、run `source=cachedPose`表示通过缓存/回放入口消费，并不表示原视频是人工合成，也不表示live camera。原来源事实在inputProvenance明确保留public/apple_vision_2d（或单独的public_synthetic/synthetic_fixture）、sourceSHA256、原秒及原times文件哈希；外部报告须同时阅读这两层来源。

真实公开输入首次App run触发严格档案对比失败：实际档案的墙上时间保留毫秒，旧诊断JSON编码截为整秒；原PTS和自动事实未变。该失败及精确回归红测保留，新countOnly result改复用repository毫秒encoder，旧诊断mode不改，不放宽actualarchive逐字段比对。UI测试只在既有FOX_UI_TESTING命名空间注入.squat能力；普通gate仍为空，测试不开放curl。新流程最终以phone/pad各一条共享故事验收，覆盖准备/训练竖横屏、真实侧别选中、unknown/0分存重开及返回旧动作。

准备提示只声明“侧面较宽画面，近侧髋膝踝完整入镜”，不把必要链资格误说成已支持下半身局部裁切，也不增加必须拍头/全身的永久算法条件。

既有CLI `scripts/vision-batch.mjs prepare <public-raw> --kind cache --mode countOnly --cases <cases.json> --asset <times.jsonl>`可冻结原时钟附件；run仅此模式附加显式diagnostic环境，verify/pull/import沿原入口回读每case实际v3档案及对应原字节v2备份。事件须落在已送入原秒帧，容忍仅1e-9秒浮点尾差，不作运动边界容差。既有vision-evidence归档/index保存countOnly_cache、自动事件数与原档案/备份哈希；参考数、误差、返回间隔和重置指标保持null，acceptance仍not_assessed。模拟回放的墙上时间来自诊断replay clock，不表示原人物的真实训练日期。

最终软件收口：工具/归档71项聚焦通过；早期App-host30/30及后继14/14均按各自冻结子集保留，不拼成同一提交的全量结果。最后侧别选择修复与实际弹层视口加强后，仅复核受影响两条共享UI：手机198.436秒、平板216.634秒，均实际通过、零跳过，自有模拟器及canonical租约释放。两条故事覆盖准备/训练竖横屏、无输入继续训练、unknown与明确0分别保存重启回看、固定右侧事实、阶段未提供及返回旧弯举。原窗口范围通过的证据上限保留；最终辅助事实、人工值与阶段文字均须完整滚入window∩实际ScrollView视口，并排除导航条。

公开194帧新UUID实际App回放完成，原source窗口/原raw与times字节未改；20帧预览、174帧正式，7个接受事件逐原整数tick与冻结CLI一致。实际档案与嵌record全部JSON严格相等，主档和原v2备份2资产SHA回读通过，manual仍unknown、phase仍not_provided。这是已冻结消费者组件等价，不是7个真人TP或新相机准确率；UI侧别输入修复后，ReplayConsumer/算法/codec/协调器等6源SHA未变，保留该组件parity，不再次计数。非XCTest回放被临时外层误标native:true后出现“No completed tests”的审计失败按编排问题保留，leaf/ref/readback和外部parity分账，不改写整批通过。

准备页固定近侧曾出现真实右段触点后仍左选中；新UI红测及录屏保留。仅深蹲改为同步保存clientState后提交局部状态，写失败恢复原选择并保留错误，旧curl默认路径不变。原最初未捕获实际文字的caption失败仍保留未知标记，不用后续通过倒写根因。Xcode辅助诊断采集的simctl error72也保留，测试通过不等于该采集过程无错。

source/独立门未过，普通qualifiedActions为空。C2、完整public与C4均未通过；本轮未启动昂贵完整public、未安装到物理设备、未推送或开PR。该默认关闭软件包保全后等待范围决定，不以本包软件结果代替能力准入。
