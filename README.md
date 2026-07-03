# lite-install

`frp-manager-lite` public one-click installer.

Source code is private; this repository only hosts the deployment script. The script pulls the public image from Aliyun ACR:

```text
registry.cn-hangzhou.aliyuncs.com/dxlx/frp-manager-lite:latest
```

## One-click install

```bash
curl -fsSL https://raw.githubusercontent.com/bohu-t/lite-install/main/deploy-image-production.sh | sudo bash
```

## Non-interactive example

```bash
PANEL_DOMAIN=panel.example.com \
PANEL_HTTPS_PORT=8443 \
FRPS_DOMAIN=frp.example.com \
FML_ADMIN_PASSWORD='change-me' \
FRP_AUTH_TOKEN='change-me' \
sudo -E bash deploy-image-production.sh
```

## Update script

This repository should be updated whenever the private `frp-manager-lite` deployment script changes.

## 添加 frps 节点

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohu-t/lite-install/main/add-frps-node.sh)
```
