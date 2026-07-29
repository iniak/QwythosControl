# Qwythos Control

[English](README.md)

Qwythos Control 是一款 macOS 菜单栏应用，用于在本机部署和管理
Qwythos 9B 模型服务。包含部署资源的正式构建可通过原生向导完成整个
安装过程，不需要 Homebrew、管理员权限、远程安装脚本或手动运行终端命令。

仓库中的代码并不表示当前这台 Mac 已经安装了应用、服务、运行时或模型。

## 系统要求

- 仅支持 Apple Silicon（`arm64`），暂不支持 Intel Mac
- macOS 13 或更高版本
- 至少 16 GB 统一内存；8 GB 内存的 Mac 不在支持范围内
- 所选安装磁盘至少有 8 GB 可用空间
- 可写的安装位置，以及可用的本地端口 `18080`

16 GB 内存的 Mac 默认使用 8K 上下文；24 GB 或更高内存默认使用 16K。
向导还可选择 4K、8K 或 16K。选择自定义安装位置时，建议使用一个专用的
空文件夹：应用会保留未知的同级文件，但记录中的运行时版本目录会整体视为
受管理内容。

## 一键部署

打开 Qwythos Control 菜单栏状态菜单，选择 **Deploy Qwythos...**。向导会先
检查设备与存储条件，再让你确认安装位置、上下文长度和网络访问方式；确认页
会列出所有选择，之后才能开始部署。

确认后，应用会自动：

1. 下载固定版本的 Apple Silicon `llama.cpp` 运行时与 Q4_K_M 模型。
2. 在安装前校验两份文件的大小和 SHA-256 摘要。
3. 在暂存位置验证 `llama-server`，然后切换到受管理运行时。
4. 为当前用户写入 LaunchAgent 并启动服务。
5. 仅在健康检查成功后记录安装状态。

固定下载总量为 6,227,864,749 字节，约 6.23 GB（十进制）或 5.80 GiB。
8 GB 可用空间要求为下载、暂存和最终安装预留了空间。

模型来源：
[llmfan46/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-GGUF](https://huggingface.co/llmfan46/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-GGUF)。

## 网络访问

默认采用“仅此 Mac”模式：服务绑定到 `127.0.0.1:18080`，其他设备无法通过
局域网访问。

可选的“在局域网共享”模式会绑定 `0.0.0.0:18080`，并生成随机 API Key。密钥
以严格 `0600` 权限保存在安装目录的 `config/api-keys.txt`，不会写入
LaunchAgent、安装记录或日志。客户端请求必须包含：

```http
Authorization: Bearer <key>
```

局域网共享不是公网托管：应用不会添加防火墙例外、配置路由器端口转发、启用
UPnP 或创建公网隧道。仅在可信局域网中开启，并谨慎保管 API Key。

## 存储、恢复与维护

默认安装位置：

```text
~/Library/Application Support/Qwythos Control/
```

你也可以选择其他可写文件夹或外接磁盘。使用自定义或可移动磁盘时，请在服务
启动和运行期间保持挂载；应用会记住该位置，磁盘暂时不可用时会显示恢复状态，
不会悄悄切换到其他路径。

下载可断点续传。关闭向导不会取消已开始的部署；退出应用会在安全边界暂停，
已下载的 `.partial` 文件会保留。重新打开后，可在向导中选择继续或重试。

管理页面提供：

- **Repair**：只重新下载或修复损坏的组件。
- **Update Runtime / Reinstall Runtime**：重新安装运行时，保留模型和设置；
  新运行时健康检查失败时自动恢复旧版本。
- **迁移**：识别兼容的旧 Qwythos `llama-server` LaunchAgent，备份旧配置并在
  新服务健康后完成切换。
- **卸载**：默认保留模型；显式勾选后才会删除通过摘要匹配的受管理模型。未知
  文件、Homebrew、缓存和不相关用户内容不会被删除。

详细的安装目录、迁移、故障恢复、密钥、修复和卸载行为请阅读
[部署与运维文档](docs/deployment.md)。

## 从源码构建

要求 Xcode 及其命令行工具。构建正式 App：

```sh
./scripts/build-app.sh
```

输出位于：

```text
build/Qwythos Control.app
```

运行测试：

```sh
swift test --disable-sandbox
```

## 项目结构

```text
Sources/QwythosControlApp/   菜单栏应用和部署向导
Sources/QwythosCore/         服务状态与系统命令控制
Sources/QwythosDeployment/   下载、校验、安装、迁移与维护逻辑
Tests/                       单元测试与端到端测试
docs/deployment.md           部署与运维说明
```

## 安全边界

部署过程中会校验运行时和模型摘要；自定义目录的关键文件操作通过不跟随符号链接
的描述符路径完成，并对文件替换、运行时压缩包替换和跨设备递归删除采取失败即
停止的策略。服务只以当前用户的 LaunchAgent 运行，不会请求管理员权限。
