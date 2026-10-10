# kaze-release

kaze 节点后端的发布包与安装脚本。源码为闭源商业软件,此仓库只提供编译好的程序。

- 📖 文档:https://kazeproxy.github.io/kaze-docs/
- ⬇️ 下载:见 [Releases](https://github.com/kazeproxy/kaze-release/releases/latest)

支持面板:Xboard(含机器模式)、V2board(含 v2node 节点)、PPanel。

## 一键安装(Linux + systemd)

```bash
bash <(curl -fsSL https://github.com/kazeproxy/kaze-release/raw/main/install.sh) install \
  --type xboard --node-id 1 \
  --panel-url https://你的面板 --panel-key 通讯密钥
```

## Xboard 机器模式

在 Xboard「服务器 → 机器」添加机器后,把面板给出的安装命令里的脚本地址换成 kaze 的,其余参数不变:

```bash
curl -fsSL https://github.com/kazeproxy/kaze-release/raw/main/install.sh | sudo bash -s -- --mode machine --panel 'https://你的面板' --token '机器令牌' --machine-id 1
```

## 手动下载

```bash
# amd64;arm64 把 amd64 换成 arm64
curl -fsSL -o kaze https://github.com/kazeproxy/kaze-release/releases/latest/download/kaze-linux-amd64
chmod +x kaze
```

每个版本附带 `SHA256SUMS`,下载后可核对:

```bash
curl -fsSL -O https://github.com/kazeproxy/kaze-release/releases/latest/download/SHA256SUMS
sha256sum kaze && grep kaze-linux SHA256SUMS
```

## Docker

```bash
docker run -d --name kaze --restart always --network host \
  -e type=xboard -e node_id=1 \
  -e panel_url=https://你的面板 -e panel_key=通讯密钥 \
  -v /etc/kaze:/etc/kaze \
  ghcr.io/kazeproxy/kaze:latest
```
