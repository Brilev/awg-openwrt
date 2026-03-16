#!/bin/sh
#set -x

APP_NAME="vpn-mode-switch"
CONFIG_NAME="vpnmode"
CONFIG_SECTION="settings"
SCRIPT_APPLY="/usr/bin/vpn-mode-apply"
LUA_CONTROLLER="/usr/lib/lua/luci/controller/vpnmode.lua"
LUA_CBI="/usr/lib/lua/luci/model/cbi/vpnmode.lua"

green() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

red() {
    printf "\033[31;1m%s\033[0m\n" "$1"
}

check_requirements() {
    green "Checking required interfaces and peers..."

    if ! uci -q get network.awg0 >/dev/null 2>&1; then
        red "Interface network.awg0 not found. First configure domain-routing-openwrt with AWG."
        exit 1
    fi

    if ! uci -q get network.awg1 >/dev/null 2>&1; then
        red "Interface network.awg1 not found. First configure Brilev/awg-openwrt."
        exit 1
    fi

    if ! uci show network | grep -q "amneziawg_awg0"; then
        red "Peer section amneziawg_awg0 not found."
        exit 1
    fi

    if ! uci show network | grep -q "amneziawg_awg1"; then
        red "Peer section amneziawg_awg1 not found."
        exit 1
    fi
}

ensure_firewall_zone() {
    local zone_name="$1"
    local ifname="$2"

    if uci show firewall | grep -q "@zone.*name='$zone_name'"; then
        green "Firewall zone $zone_name already exists"
    else
        green "Creating firewall zone $zone_name"
        uci add firewall zone
        uci set firewall.@zone[-1].name="$zone_name"
        uci set firewall.@zone[-1].network="$ifname"
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
    fi
}

ensure_forwarding() {
    local src="$1"
    local dest="$2"
    local name="$3"

    if uci show firewall | grep -q "@forwarding.*name='$name'"; then
        green "Forwarding $name already exists"
    else
        green "Creating forwarding $name"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="$name"
        uci set firewall.@forwarding[-1].src="$src"
        uci set firewall.@forwarding[-1].dest="$dest"
        uci set firewall.@forwarding[-1].family='ipv4'
    fi
}

ensure_mode_config() {
    green "Creating /etc/config/$CONFIG_NAME"
    uci -q batch <<-EOF
        set $CONFIG_NAME.$CONFIG_SECTION=main
        set $CONFIG_NAME.$CONFIG_SECTION.mode='domain'
        commit $CONFIG_NAME
EOF
}

install_apply_script() {
    green "Installing $SCRIPT_APPLY"

    cat > "$SCRIPT_APPLY" <<'EOF'
#!/bin/sh
#set -x

MODE="$(uci -q get vpnmode.settings.mode || echo domain)"

log() {
    logger -t vpnmode "$*"
}

set_forwarding_enabled_by_name() {
    local name="$1"
    local enabled="$2"
    local sec

    sec="$(uci show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding/\1/p" | while read -r s; do
        [ "$(uci -q get firewall.$s.name)" = "$name" ] && echo "$s" && break
    done)"

    [ -n "$sec" ] || return 0

    if [ "$enabled" = "1" ]; then
        uci -q delete firewall."$sec".enabled || true
    else
        uci set firewall."$sec".enabled='0'
    fi
}

set_service_state() {
    local svc="$1"
    local enabled="$2"

    [ -x "/etc/init.d/$svc" ] || return 0

    if [ "$enabled" = "1" ]; then
        /etc/init.d/"$svc" enable || true
        /etc/init.d/"$svc" restart || /etc/init.d/"$svc" start || true
    else
        /etc/init.d/"$svc" disable || true
        /etc/init.d/"$svc" stop || true
    fi
}

apply_mode() {
    case "$MODE" in
        full)
            # lan -> awg1
            set_forwarding_enabled_by_name "lan-wan" 0
            set_forwarding_enabled_by_name "awg0-lan" 0
            set_forwarding_enabled_by_name "awg1-lan" 1

            # awg1 full tunnel on
            uci set network.@amneziawg_awg1[0].route_allowed_ips='1'

            # awg0 domain-routing peer stays without default route
            uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

            # domain list updater off
            set_service_state getdomains 0
        ;;

        domain)
            # lan -> wan + awg0
            set_forwarding_enabled_by_name "lan-wan" 1
            set_forwarding_enabled_by_name "awg0-lan" 1
            set_forwarding_enabled_by_name "awg1-lan" 0

            # no default route through awg1
            uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
            uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

            # domain list updater on
            set_service_state getdomains 1
        ;;

        off)
            # only plain internet
            set_forwarding_enabled_by_name "lan-wan" 1
            set_forwarding_enabled_by_name "awg0-lan" 0
            set_forwarding_enabled_by_name "awg1-lan" 0

            uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
            uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

            set_service_state getdomains 0
        ;;

        *)
            log "Unknown mode: $MODE"
            exit 1
        ;;
    esac

    uci commit firewall
    uci commit network

    /etc/init.d/firewall restart
    /etc/init.d/network restart

    log "Applied mode: $MODE"
    exit 0
}

apply_mode
EOF

    chmod +x "$SCRIPT_APPLY"
}

install_luci_controller() {
    green "Installing LuCI controller"

    mkdir -p /usr/lib/lua/luci/controller

    cat > "$LUA_CONTROLLER" <<'EOF'
module("luci.controller.vpnmode", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/vpnmode") then
        return
    end

    entry({"admin", "network", "vpnmode"}, cbi("vpnmode"), _("VPN Mode"), 90)
end
EOF
}

install_luci_cbi() {
    green "Installing LuCI CBI model"

    mkdir -p /usr/lib/lua/luci/model/cbi

    cat > "$LUA_CBI" <<'EOF'
local sys = require "luci.sys"

m = Map("vpnmode", "VPN Mode", "Режим переключения между awg0 и awg1")

s = m:section(TypedSection, "main", "")
s.anonymous = true

mode = s:option(ListValue, "mode", "Mode")
mode:value("off", "Off")
mode:value("domain", "Domain routing via awg0")
mode:value("full", "Full tunnel via awg1")
mode.default = "domain"

function m.on_after_commit(self)
    sys.call("/usr/bin/vpn-mode-apply >/tmp/vpn-mode-apply.log 2>&1")
end

return m
EOF
}

ensure_named_forwardings() {
    green "Ensuring forwarding entries"

    # stock forwarding lan -> wan often exists without name
    local lan_wan_sec
    lan_wan_sec="$(uci show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding/\1/p" | while read -r s; do
        [ "$(uci -q get firewall.$s.src)" = "lan" ] || continue
        [ "$(uci -q get firewall.$s.dest)" = "wan" ] || continue
        echo "$s"
        break
    done)"

    if [ -n "$lan_wan_sec" ]; then
        if [ "$(uci -q get firewall.$lan_wan_sec.name)" != "lan-wan" ]; then
            uci set firewall."$lan_wan_sec".name='lan-wan'
        fi
    else
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name='lan-wan'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='wan'
        uci set firewall.@forwarding[-1].family='ipv4'
    fi

    ensure_forwarding "lan" "awg0" "awg0-lan"
    ensure_forwarding "lan" "awg1" "awg1-lan"

    uci commit firewall
}

restart_services() {
    green "Restarting LuCI and firewall/network"
    /etc/init.d/uhttpd restart
    /etc/init.d/firewall restart
    /etc/init.d/network restart
}

show_result() {
    green "Installed successfully"
    echo
    echo "LuCI menu:"
    echo "  Network -> VPN Mode"
    echo
    echo "Modes:"
    echo "  off    - only lan -> wan"
    echo "  domain - lan -> wan + awg0, getdomains enabled"
    echo "  full   - lan -> awg1, awg1 route_allowed_ips=1"
    echo
    echo "Manual apply command:"
    echo "  /usr/bin/vpn-mode-apply"
}

main() {
    check_requirements
    ensure_firewall_zone "awg0" "awg0"
    ensure_firewall_zone "awg1" "awg1"
    ensure_named_forwardings
    ensure_mode_config
    install_apply_script
    install_luci_controller
    install_luci_cbi
    restart_services
    show_result
}

main
