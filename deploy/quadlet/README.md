# Vantage on rootless Podman Quadlet + Tailscale

一個單機版的部署方式：Vantage 以 **rootless Podman Quadlet**（systemd user units）執行，
只監控**這台主機**，並用 `tailscale serve` 發布到 tailnet（不對 LAN 或網際網路開 port）。

```
tailnet ──https──> tailscale serve :8448 ──https+insecure──> 127.0.0.1:8450
                                                              │
                                    vantage network (192.168.255.240/28, rootless)
                         vantage-frontend (nginx, .242) ──> vantage-backend ──> vantage-prometheus
                                                                    │                 │
                                      <tailscale IPv4>:9101  <──────┴─────────────────┘
                                      vantage-node-exporter (Network=host)
```

## 需求

- Podman 5+，systemd user session，建議開啟 linger：`sudo loginctl enable-linger $USER`
- `tailscale` 已登入，tailnet 開啟 MagicDNS 與 HTTPS certificates
- `openssl`、`curl`、`ss`（iproute2）；`jq` 或 `python3` 二選一

## 安裝

```bash
git clone https://github.com/<you>/vantage.git ~/vantage
cd ~/vantage
./deploy/quadlet/install.sh
```

可用環境變數調整（都可省略）：

| 變數 | 預設 | 用途 |
|---|---|---|
| `VANTAGE_LOCAL_PORT` | `8450` | frontend 在 127.0.0.1 上的 port |
| `VANTAGE_TS_PORT` | `8448` | tailnet 上的 HTTPS port |
| `VANTAGE_NODE_PORT` | `9101` | 內建 node_exporter 的 port |
| `VANTAGE_TS_NAME` | 自動偵測 | MagicDNS 名稱，例如 `myhost.tailnet-example.ts.net` |
| `VANTAGE_NO_SERVE` | `0` | 設 `1` 則不動 `tailscale serve` |

腳本會：

1. 在 `~/.config/vantage/secrets/` 產生 master key、Prometheus token、self-signed 憑證（已存在就保留），並建立對應的 Podman secrets。
2. 複製 `prometheus.yml` 和 `vantage.env`（`VANTAGE_PUBLIC_HOSTS` 自動填 `<MagicDNS>:<TS_PORT>`）。
3. 若主機上已有 node_exporter 在 `0.0.0.0:9100`（或 Tailscale IP）就沿用；否則安裝 `vantage-node-exporter`，只綁在 Tailscale IPv4 上。
4. 安裝 units 到 `~/.config/containers/systemd/`、拉 image、啟動、等健康檢查。
5. `tailscale serve --bg --https=<TS_PORT> https+insecure://127.0.0.1:<LOCAL_PORT>`（需要 root 或 `tailscale set --operator=$USER`）。
6. 印出一次性的 setup code 與要加入的主機位址。

## 安裝後

1. 在 tailnet 內任一台裝置開 `https://<MagicDNS>:8448`，用 setup code 建立第一個 admin。
2. **Devices → Add → Linux host**：Host 填腳本印出的 Tailscale IPv4，Port 填 9101（或沿用的 9100），Scheme `http`。
   請填 IP 而不是 MagicDNS 名稱：容器內不一定解析得到 MagicDNS。
3. **把 `~/.config/vantage/secrets/master.key` 備份到別台機器。** 遺失就解不開已存的憑證。

## 為什麼經由 Tailscale IP 抓 node_exporter

容器連不到主機的 loopback（Vantage 的 SSRF guard 也一律拒絕 loopback 和 link-local，
所以 `host.containers.internal` 不能用）。rootless 網路（pasta）下，主機的 LAN IP 在容器裡
會被當成容器自己；Tailscale 的 100.64.0.0/10 位址則會正確送回主機，而且在 guard 的預設允許清單內。
node_exporter 因此只綁在 Tailscale IP，tailnet 外看不到。若不想讓整個 tailnet 都能讀，
可在 Tailscale ACL 裡限制 `:9101`。

## 日常操作

```bash
systemctl --user status vantage-backend vantage-frontend vantage-prometheus
journalctl --user -u vantage-backend -f
podman exec vantage-backend python -m app.cli setup-code        # 重新產生 setup code
podman exec -it vantage-backend python -m app.cli reset-password <user>
```

升級：改 `vantage-backend.container` / `vantage-frontend.container` 的 image tag 與
`VANTAGE_RELEASE`，重跑 `install.sh`。

移除：`./deploy/quadlet/uninstall.sh`（保留資料與 secrets）；`--purge` 連資料一起刪。

## 已知限制

- 所有瀏覽器對 nginx 來說都是同一個來源位址（tailscale serve → loopback），
  所以 per-client 的登入速率限制會由所有使用者共用；per-account 鎖定不受影響。
- 預設只監控這台主機。其他設備（交換器 SNMP、Proxmox…）照一般方式從 UI 加即可。
