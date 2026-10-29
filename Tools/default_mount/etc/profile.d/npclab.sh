# NpcLab 的 shell 环境
# 由 /etc/profile 通过 profile.d 机制加载（登录 shell）
# 非登录 shell 靠 ENV 指向 .ashrc

# ash 的命令历史与行编辑
export HISTFILE="$HOME/.ash_history"
export HISTSIZE=1000
export ENV="$HOME/.ashrc"

# $BROWSER 会被内核直接注入进程 envp（见 NpcLinux.c 的 kEnv），
# 所以非登录 shell 里也能用。这里再设一次是为了 login shell 覆盖。
export BROWSER=npclab-open
export EDITOR=npclab-open
# 没有完整 VT100，分页器一律直出，否则 less / git log 会花屏
export PAGER=cat
export GIT_PAGER=cat

# 常用别名
alias ll='ls -alh'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# 提示符。注意：ash 不认 bash 的 \[ \] 标记，颜色必须放真实 ESC 字符；
# \w 这类反斜杠转义仍然由 ash 自己解释。
_NPC_ESC=$(printf '\033')
export PS1="${_NPC_ESC}[32mroot@npclab${_NPC_ESC}[0m:${_NPC_ESC}[34m\w${_NPC_ESC}[0m# "
unset _NPC_ESC
