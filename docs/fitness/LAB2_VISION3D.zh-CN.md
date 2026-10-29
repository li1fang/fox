# LAB-2 Apple Vision 3D 旁路

2026-10-29。基线0dd5f56；本树单写。统一计划在维护树CAPTURE_LAB_V1_20261029，不复制共享状态。

编辑前契约：新增纯3D值类型、Apple提取器、独立有界离线入口；不改2D相机/Controller/录像器/project.yml/计数/阈值/部署最低版本/CI。成功只接受完整17关节；无观察、不可用、错误和忙丢弃显式记录。原PTS整数/时基/epoch和流/连续段/帧号保留，推理单调耗时独立，米制模型坐标不是实测距离；无置信概率或阶段真值。

测试先行：先令验证器未实施而观察反例失败，再验证17关节完整性、矩阵/数值、尺度来源、失败互斥、PTS/帧序连续性、同帧关联不证明同人、编码往返；SDK适配替身验证错误/无观察/修订/忙丢弃/原PTS和方向；真实Vision有界单片检查另记，无替身准确率宣称。新测试登记catalogue。全部缓存与证据外盘，RES租约fail-fast，内盘低于2GiB停止，冲突/源码漂移停止。旧51c8dd1与原片保留。

## 消费接口与文件

- 核心 `Pose3D.swift`：Pose3DTime、Pose3DFrameContext、Pose3DJointName/Joint/Skeleton、Pose3DFrame、Pose3DComparison；不依赖Vision，不变更既有PoseFrame。
- 独立产品 `FoxVision3D`：AppleVision3DExtractor.extract(_:orientation:context:) 接收原CMSampleBuffer；另一个重载接收CVPixelBuffer、原CMTime、orientation、context及可选cameraIntrinsics Data。帧宽高、方向和PTS的value/timescale/epoch必须与原样本完全一致；可选内参以原数据附件传给Vision。旧最低iOS16/macOS13保留，调用在iOS17/macOS14检查内；不可用返回unsupported。
- 每次请求独立创建Vision对象，不跨帧复用历史。单实例仅一个in-flight，NSLock.try失败立刻返回dropped，domain=fox.pose3d.busy，无等待队列。客户端仍须在录制队列外调用；此同步接口不能抢占一个正在执行的Vision调用。没有假reset接口：连续性改变时使用新segmentID，旧返回保留旧身份，消费者不得并入新段。missingFrames(after:)报告同段跳号，重复/倒序或跨段比较拒绝；不插值。
- `Package.swift`只增加上述库产品、离线可执行目标和测试依赖。客户端后续把FoxVision3D产品接入App；本包不改project.yml或原相机接线。

## 旁路行与坐标

schema=fox.pose3d_frame.v1，默认JSONEncoder，键为Swift字段名（外层实验包可继续snake_case，不隐式改本schema）。context含streamID/segmentID/frameIndex、pts、width/height、orientation和sourceMirrored。pts.value和epoch为Int64十进制字符串，timescale为正Int32。推理耗时inferenceNanoseconds是独立的UInt64单调时钟差，不用来替换源PTS；它不是host_received_ns。

streamID使用外层同一camera source_id，segmentID是该来源的连续段，frameIndex使用同一源帧seq；capture_id由外层source关联，不能按行顺序或大致时间配对。JSON中的原PTS可直接关联LabRationalTime.value/timescale，epoch额外保留。

成功outcome=observed必须actualRevision等于requestedRevision、全17个唯一命名关节；失败无骨架，保留domain/code但不导出可能泄露路径的localizedDescription。空结果为noObservation，不等于零次。invalidInput、invalidOutput、requestFailed、unsupported、dropped独立。这个schema无计数/阶段字段，不生成关节置信概率。

skeleton.coordinateSystem=apple_vision_root_relative，units=meters，matrixLayout=column_major_4x4。modelTransform是Apple原始根关节（两髋之间）参考矩阵，不转换成屏幕左右或AR世界坐标；cameraOriginMatrix按Apple根到相机语义保留。关节左右是解剖左右。heightSource=reference或measured，bodyHeightMeters保留框架输出；reference约1.8m是模型参考尺度，不是测距。measured也只是框架报告的估计方法，不等于Fox已校准深度精度。没有显式AVDepthData注入，也不要求后置或深度摄像头。

Pose3DComparison记录2D/3D产物引用及各自context；sameSourceFrame按身份/原片时间/方向计算，subjectCorrespondence始终unverified，仅为Swift计算属性。不得把它当同人证明或精度指标。2D原生关节若直接来自Vision，需由2D来源契约声明normalized/lower-left，不能和3D米制数值直接相减。

## 有界离线入口

`fox-vision3d-replay INPUT OUTPUT_DIRECTORY MAX_FRAMES EXIF_ORIENTATION`。输入现有小窗口（普通文件、<=64MiB），输出必须新目录，MAX_FRAMES=1...30。方向显式提供1...8：工具不自动再应用track transform。解码前限制轨道像素<=4194304、单边<=4096；逐帧及启动检查内盘>=2GiB。输入摘要、行流和receipt分开；失败保留partial，外层受控命令回执保留错误。CLI不是视频剪辑工具，不下载素材或改原片。调用仍沿RES租约；不支持平台非零退出。

## 本轮实际结果与边界

- 纯值验证先红：5项/12条失败断言；实现后连同适配器和原视觉核心定向96项通过，无skip。审查发现原PTS等值分数改写问题，新增反例实测失败后改成原整数/时基精确匹配。最初SDK编译因CMAttachmentMode符号错误失败，修正为SDK常量，旧回执保留。
- iOS SDK模块编译通过：FoxTrainingCore和FoxVision3D保持arm64-apple-ios16.0目标，未提高部署最低版本。这不是完整App链接/运行验收。
- 真实Vision：复用已获准公开RepCount-A train951.mp4的前6帧，Linux CPU生成23,542字节短窗口，原帧PTS与派生摘要另存；Mac实际仅推理前2帧，均返回revision1、17关节、reference尺度。原始视频未改，不复制大视频。AVFoundation两帧PTS时基不同，适配器分别原样保留。冷/热两次耗时只在行中记录，不据此预测持续吞吐。
- 没有人工阶段/3D真值，不报告准确率；没有实际2D/3D同人对照或设备持续性能。本包不修改2D算法，原弯举/侧平举/下拉、门禁、未知返回回归通过。后续App接线、包级同源对应和实际相机/热状态由LAB-4/LAB-H承担。

官方来源：Apple“Identifying 3D human body poses in images”与WWDC23 111241；本地Xcode SDK VNStatefulRequest/VNObservation/VNDetectHumanBodyPose3DRequest头文件用于核实签名和时间戳要求。回执、样片和SDK产物均保留外盘，不进Git。
