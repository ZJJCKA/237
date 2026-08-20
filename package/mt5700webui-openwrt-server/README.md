# MT5700 WebUI OpenWrt Server

这是一个面向 OpenWrt 的 MT5700 WebUI 和 LuCI 管理插件，包含独立的 AT WebServer 服务，以及 LuCI 中的配置、日志和 WebUI 首页。

## 本次版本功能

- LuCI 菜单 `服务 → AT WebServer` 新增“首页”。
- 首页直接在 LuCI 页面内嵌 `/5700/` WebUI，不再自动打开新页面。
- Tab 顺序为：首页、配置、日志查看。
- iframe 使用同源相对路径，自动继承当前 LuCI 的协议、主机地址和端口；用户修改 IPv4 管理地址后无需修改插件配置。
- 配置页面的 Web 管理界面入口改为返回 LuCI 内嵌首页。
- MT5700 流量累计值默认每 5 秒查询一次，但运行期间只更新内存，不周期写入 `/etc`。
- 服务正常停止、重启或系统正常重启/关机时，后端会最后查询一次模组计数，再原子固化到 eMMC；下次启动恢复记录并继续累计。
- WebUI 的“流量统计清零”会同时清除模组计数和持久化记录；这是运行期间唯一的即时落盘例外，避免旧累计在断电后复活。

## 页面入口

安装并启用服务后，在 LuCI 中打开：

```
服务 → AT WebServer → 首页
```

独立 WebUI 仍可通过以下路径访问：

```
http://路由器IP/5700/
```

## 安装与开发

本仓库包含两个 OpenWrt 软件包：

- `at-webserver`：AT WebSocket 服务、CGI 接口和 `/www/5700/` WebUI。
- `luci-app-at-webserver`：LuCI 菜单、首页 iframe、配置和日志页面。

请在 OpenWrt SDK 或完整 buildroot 中编译对应软件包。LuCI 首页相关源码位于：

```
luci-app-at-webserver/htdocs/luci-static/resources/view/at-webserver/home.js
luci-app-at-webserver/root/usr/share/luci/menu.d/luci-app-at-webserver.json
```

仅重新打包不含原生二进制的 `at-webserver` 时，也可运行：

```sh
python3 tools/build_at_webserver_ipk.py
python3 tools/build_luci_at_webserver_ipk.py
python3 tools/build_source_archive.py
```

输出为 `dist/at-webserver_1.0-33_all.ipk` 和 `dist/luci-app-at-webserver_1.0-31_all.ipk`，脚本会同时校验 IPK 成员、控制字段、文件内容、Unix 换行符和权限。`at-webserver` 依赖本机优化版 `luci-app-modem`，在 R3 Mini + MT5700 + `/dev/ttyUSB1` 时等待其开机 CFUN 初始化完成后再连接串口。该精确硬件组合还会每 5 秒通过 at-server 自身的 AT 命令锁更新 `/var/run/at-webserver/chiptemp.status`，供风扇插件只读使用，不写入 eMMC。

源码归档脚本输出 `mt5700webui-openwrt-server-1.0-33-source.tar.gz`，固定顶层为
`mt5700webui-openwrt-server/`，排除 `dist`、缓存文件和审计临时产物，并复核所有
源码内容与 Unix 权限，可直接解压到编译机后复制两个软件包目录。

这两个脚本用于快速构建和结构验证；正式固件请以 OpenWrt buildroot 编译结果为准。快速构建的 `at-webserver` IPK 不模拟 buildroot 自动生成的维护脚本，首次安装后需手动执行 `/etc/init.d/at-webserver enable` 和 `/etc/init.d/at-webserver restart`。

### 流量统计持久化

默认状态文件为 `/etc/at-webserver/traffic-stats.json`。运行期间默认每 5 秒读取一次模组计数并只在内存中累计，不执行周期性 eMMC 写入。服务收到正常停止信号时，会在 AT 连接仍可用的情况下最后查询一次，然后通过临时文件、文件 `fsync`、原子替换和目录 `fsync` 固化一次；正常重启后会恢复该快照并继续累计。

```sh
uci set at-webserver.config.traffic_persist_enabled='1'
uci set at-webserver.config.traffic_poll_interval='5'
uci commit at-webserver
/etc/init.d/at-webserver restart
```

正常运行期间不因采样而写入持久层；每次正常停止、服务重启、系统重启或关机最多固化一次。主动执行流量清零时会额外立即固化一次。突然断电、强制断电、服务异常崩溃、内核崩溃或 `kill -9` 不执行正常退出固化，因此本次开机尚未固化的增量可能丢失，重启后从上一次成功固化的快照继续累计。异常退出不落盘也可避免 procd 启动失败循环反复磨损 eMMC。

---

## 预编译版本

已经编译好的版本可直接下载，安装前请确认依赖包已经存在：

链接：https://www.123865.com/s/BwcjVv-PexFd?pwd=GweY#
提取码：GweY

<img width="2104" height="1326" alt="HT495J9_)2B7_F2{{PNV9R2" src="https://github.com/user-attachments/assets/229ee8de-6309-43c0-99a3-14cb36b770a2" />
<img width="2455" height="1322" alt="D%P)4D)A($VUZOIYHT4Y1LB" src="https://github.com/user-attachments/assets/cff3c45c-7d5c-4c77-af75-8e16fe94a25b" />
<img width="2443" height="1328" alt="APUCD096I V))XV@Y6QUB~E" src="https://github.com/user-attachments/assets/64d9ee66-6d4d-4005-b7de-93cdd3652162" />
<img width="2457" height="1326" alt="9(TM7)SQA1G0Q}6V9Y3JO)Y" src="https://github.com/user-attachments/assets/a002f79c-335a-4dfd-9a5d-8df1a1dac736" />
<img width="2443" height="1335" alt="`SQWWP VX7%L~B8J%3C(X8" src="https://github.com/user-attachments/assets/a9a0a84c-5ea5-4c4f-96b9-35f2d53f269d" />
<img width="2452" height="1318" alt="`RR6H0LRW9L5{M5{L82NX_2" src="https://github.com/user-attachments/assets/d4290143-69fc-4211-8d97-b1527f77d7ff" />
