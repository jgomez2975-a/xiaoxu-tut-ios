# root 的登录 shell 配置
# /etc/profile 会先读 /etc/profile.d/*.sh，再读这个。
# 非登录 shell（比如 npclab-exec 起的）靠 ENV=$HOME/.ashrc。

# npclab 工具都在 /usr/local/bin，确保在 PATH 里
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) PATH="/usr/local/bin:$PATH"; export PATH ;;
esac

# 登录时把 motd 打出来（iSH 的 login 不一定读 /etc/motd）
[ -f /etc/motd ] && cat /etc/motd

# 进 root 目录
cd /root 2>/dev/null || true
