# Windows 斗鱼 FLV 提前续流

此更新基于 Taj-x/dart_simple_live 的 8c005f9，保留上一版断线自动重新取址补丁。

## 更新和编译

1. 解压 douyu-seamless-update.zip。
2. 在自己的 GitHub 仓库根目录选择 Add file → Upload files，拖入解压得到的 simple_live_app、.github 两个文件夹和本说明，保留目录结构并提交。
3. Actions → Build Windows ZIP → Run workflow。流程先运行中继测试、检查播放接入代码，再编译 Windows。
4. 下载完整 Artifacts ZIP，解压，关闭旧版并启动新版 EXE。

必需的运行代码：
- simple_live_app/lib/services/flv_lease_relay.dart（新文件）
- simple_live_app/lib/modules/live_room/live_room_controller.dart（替换）

测试与构建文件：
- simple_live_app/tool/flv_lease_relay_test.dart（新文件）
- .github/workflows/build-windows.yml（替换）

## 行为和范围

只对 Windows 上的斗鱼、HTTP(S) FLV、expire > 0 的地址启用中继。
expire=300 时，在请求地址起约 255 秒后开始续期。软件获取相同画质的新地址，保持旧连接输出，预热新连接，找到同一时间轴上尚未输出的 H.264 关键帧，再切换上游连接。播放器始终读取同一个本地 HTTP 地址，不重新调用 player.open。

中继只监听 127.0.0.1 的随机端口和随机路径，无需用户配置。
保留画质和线路索引；新地址没有对应线路时回退到第一条。
配置包跟随新关键帧输出，丢弃重叠音视频包，避免重复播放和时间戳倒退。
换画质、换线路、关闭直播间会释放连接。

预热失败时继续输出旧连接。不同时间轴、非 H.264 视频等无法安全衔接的情况，不强行拼接；地址真正断开后，仍由上一版重连补丁恢复，可能出现一次刷新。
超清 expire=0 和其他平台继续直连。双连接只在续期预热阶段短暂存在，会暂时增加网络带宽。

## 验证

本地 Dart 协议测试已通过：分片输入、扩展时间戳、损坏数据、多个连续续期、HTTP 403 回退、时间轴不一致回退、关闭连接。
真实编码的 H.264/AAC 本地测试流在多次续期后通过 FFmpeg 解码检查；FFprobe 检测视频最大 DTS 间隔 40 ms、音频 24 ms，无倒退和重复。
中继及测试文件通过 Dart 静态分析。
本地完整 Flutter 初始化被自动审批拦截（意外请求云实例元数据地址）；Flutter 接入检查及 Windows 编译由附带的 Actions 工作流执行。尚未实测 Windows 上真实斗鱼连续续期，因此不能保证所有线路完全无感。

打开设置 → 其他设置 → 开启日志记录，用原画或蓝光播放 15–20 分钟，并在日志列表检查：
- 斗鱼已启用FLV提前续流
- 斗鱼FLV提前续期：旧连接继续播放，正在预热新连接
- 斗鱼FLV关键帧续流完成，播放器连接保持不变

若只有“播放中断，重新获取…”日志，则走了旧的故障重连兜底，需要结合“预热未成功”的原因继续排查。

独立测试命令（在 simple_live_app 目录）：

    dart tool/flv_lease_relay_test.dart

可选 FFmpeg 解码验证（需要本机 FFmpeg）：

    ffmpeg -f lavfi -i testsrc2=size=160x90:rate=25 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 8 -c:v libx264 -preset ultrafast -tune zerolatency -g 25 -bf 0 -c:a aac -f flv fixture.flv -y
    dart tool/flv_lease_relay_test.dart fixture.flv captured.flv
    ffmpeg -v error -i captured.flv -f null -
