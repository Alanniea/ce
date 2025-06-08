ce - VPS 流量限速自动管理工具

ce 是一个适用于 Linux VPS 的轻量级流量控制工具。它通过集成 vnStat 与 tc，实现对每日出入流量的监控和限速策略，超限自动限速，每日定时恢复，并配备交互式控制台命令，让管理更简单。


---

✨ 功能亮点

📊 每日流量监控：使用 vnstat 持续监控流量

🚦 自动限速：每日超过指定流量后自动限速（默认 20GiB 限速为 512kbit）

⏰ 每日定时解限：每天 0 点自动解除限速并刷新流量统计

🧩 交互式管理面板：内置 ce 命令，图形化管理一目了然

🛠 支持多平台：兼容 Ubuntu / Debian / CentOS 系列

🔧 配置灵活持久化：配置文件写入 /etc/limit_config.conf，重启不丢失

📨 可拓展通知功能：预留 Telegram 等通知集成功能接口



---

📦 安装方法

推荐使用一条命令自动部署：

bash <(curl -sSL https://raw.githubusercontent.com/Alanniea/ce/main/install_limit.sh)

或：

wget -qO- https://raw.githubusercontent.com/Alanniea/ce/main/install_limit.sh | bash


---

🛠 使用方式

安装完成后，输入命令：

ce

进入交互式控制台：

1：检查当前流量是否已超出限制

2：手动解除限速

3：查看当前限速状态（tc qdisc）

4：查看每日流量统计（vnstat -d）

5：删除限速脚本和控制台命令

6：修改每日流量限制 / 限速速率

7：退出


示例界面：

╔════════════════════════════════════════════════╗
║        🚦 流量限速管理控制台（ce）              ║
╚════════════════════════════════════════════════╝
当前网卡：eth0
已用流量：6.3 GiB / 20 GiB（31.5%）


---

⚙️ 默认配置

配置项	默认值	说明

流量限制	20 GiB	每日限制上限，超过后开始限速
限速速率	512kbit	超限后限制的上传+下载速率
检测频率	每小时一次	cron 每小时自动运行检查脚本
解限时间	每天 0 点	自动解除限速，并刷新 vnstat 数据
主用网卡	自动识别第一个非虚拟网卡（如 eth0）	
配置文件路径	/etc/limit_config.conf	



---

🚀 开发计划（计划中）

✅ 多用户 VPS 支持（基于流量配额隔离）

✅ Telegram 限速通知提醒

✅ 自定义限速时间段

✅ Docker 镜像支持



---

🧹 卸载方式

ce
# 选择 5 删除所有限速相关脚本和控制台命令

或手动删除：

rm -f /root/limit_bandwidth.sh /root/clear_limit.sh /usr/local/bin/ce /etc/limit_config.conf


---

🤝 参与贡献

欢迎提 Issue 或 PR，一起让 ce 更强大：

🛠 修复 bug

📖 改进文档

🌟 添加通知、限速策略等增强功能



---

📄 License

本项目使用 MIT License。


---

> 由 Alanniea 开发维护。感谢你的使用与支持！



