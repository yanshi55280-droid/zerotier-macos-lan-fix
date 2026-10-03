#!/bin/bash
# macOS 自带 Bash 3.2 可运行；仅调整 IPv4 有限广播的主机路由。
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
TARGET=255.255.255.255

finish() {
    echo
    if [ -t 0 ]; then read -r -p '按回车关闭……' unused; fi
    exit "$1"
}

echo '设置游戏局域网广播出口'
echo '请先连接用于游戏的 ZeroTier 网络。'
echo '脚本会列出有 IPv4 地址且处于 active 状态的 feth 网卡。'
echo 'feth 也可能由其他软件创建，请核对地址与 ZeroTier 中显示的一致。'
echo

interfaces=()
addresses=()
for iface in $(ifconfig -l); do
    case "$iface" in feth[0-9]*) ;; *) continue ;; esac
    info=$(ifconfig "$iface" 2>/dev/null) || continue
    printf '%s\n' "$info" | grep -q 'status: active' || continue
    while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        interfaces[${#interfaces[@]}]="$iface"
        addresses[${#addresses[@]}]="$addr"
    done < <(printf '%s\n' "$info" | awk '$1 == "inet" && $2 !~ /^169\.254\./ {print $2}')
done

count=${#interfaces[@]}
if [ "$count" -eq 0 ]; then
    echo '未找到符合条件的网卡。请确认 ZeroTier 已连接且已分配 IPv4 地址。'
    finish 1
fi

for ((i=0; i<count; i++)); do
    printf '%d. %s  IP：%s\n' "$((i+1))" "${interfaces[$i]}" "${addresses[$i]}"
done

index=0
if [ "$count" -gt 1 ]; then
    echo
    read -r -p '请输入用于游戏的网络编号（其他输入退出）：' choice
    case "$choice" in ''|*[!0-9]*) echo '已取消。'; finish 1 ;; esac
    if [ "${#choice}" -gt 4 ]; then echo '编号无效。'; finish 1; fi
    choice=$((10#$choice))
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo '编号无效。'; finish 1
    fi
    index=$((choice-1))
fi

iface=${interfaces[$index]}
addr=${addresses[$index]}
echo
echo "目标：$TARGET → $iface（$addr）"
echo '仅修改这个广播地址，不修改默认上网路由。'

before=$(route -n get "$TARGET" 2>/dev/null)
current=$(printf '%s\n' "$before" | awk '$1 == "interface:" {print $2}')
if [ "$current" = "$iface" ]; then
    echo '当前出口已经正确，无需修改。'
    finish 0
fi

echo '如提示 Password，请输入 Mac 登录密码；输入时不显示字符。'
sudo -v || { echo '未取得管理员权限，未修改路由。'; finish 1; }

# 授权期间可能发生网络切换，修改前重新确认选中的地址。
if ! ifconfig "$iface" 2>/dev/null | awk -v ip="$addr" '$1=="inet" && $2==ip {found=1} END {exit !found}'; then
    echo '网络地址已变化，请重新运行脚本。'
    finish 1
fi

result=$(sudo route -n add -host "$TARGET" -interface "$addr" 2>&1)
status=$?
printf '%s\n' "$result"
if [ "$status" -ne 0 ]; then
    # 只在已有手动静态主机路由时尝试替换；不删除系统路由。
    existing=$(route -n get "$TARGET" 2>/dev/null)
    if printf '%s\n' "$result" | grep -qi 'File exists' &&
       printf '%s\n' "$existing" | grep -Eq 'flags:.*[<,]STATIC[,>]' &&
       printf '%s\n' "$existing" | grep -Eq 'destination:[[:space:]]+255\.255\.255\.255$'; then
        echo '发现已有静态广播路由，尝试更新到当前地址……'
        sudo route -n change -host "$TARGET" -interface "$addr" || {
            echo '更新失败。请复制以上输出，不要手动删除系统路由。'; finish 1;
        }
    else
        echo '添加失败。请复制以上输出以便排查。'
        finish 1
    fi
fi

after=$(route -n get "$TARGET" 2>&1)
actual=$(printf '%s\n' "$after" | awk '$1 == "interface:" {print $2}')
echo
if [ "$actual" = "$iface" ]; then
    echo "验证成功：广播出口现在是 $iface。"
    echo '请重新进入游戏的局域网列表测试。路由正确不代表游戏一定能发现房间。'
    echo '下次更换 ZeroTier 网络后，再运行本脚本即可。'
    echo
    echo '如需撤销本次设置，在网络仍连接时运行：'
    echo "sudo route -n delete -host $TARGET -interface $addr"
    finish 0
else
    echo '未验证到预期出口。请复制以下结果以便排查：'
    printf '%s\n' "$after"
    finish 1
fi
