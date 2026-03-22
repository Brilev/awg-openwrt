#!/bin/sh

set -e
echo "OpenWrt version:"
cat /etc/openwrt_release
echo "Detected firewall:"
uci get firewall.@defaults[0].forward

CONFIG_NAME="vpnmode"
CONFIG_SECTION="settings"

APPLY_SCRIPT="/usr/bin/vpn-mode-apply"
INIT_SCRIPT="/etc/init.d/vpnmode"

VIEW_DIR="/www/luci-static/resources/view/network"
VIEW_FILE="$VIEW_DIR/vpnmode.js"

MENU_DIR="/usr/share/luci/menu.d"
MENU_FILE="$MENU_DIR/vpnmode.json"

ACL_DIR="/usr/share/rpcd/acl.d"
ACL_FILE="$ACL_DIR/luci-app-vpnmode.json"


green() {
	printf "\033[32;1m%s\033[0m\n" "$1"
}

yellow() {
	printf "\033[33;1m%s\033[0m\n" "$1"
}

red() {
	printf "\033[31;1m%s\033[0m\n" "$1"
}

require_interface() {
	local ifname="$1"

	if ! uci -q get "network.$ifname" >/dev/null 2>&1; then
		red "Required interface network.$ifname not found"
		exit 1
	fi
}

require_peer_section() {
	local section="$1"

	if ! uci -q get "network.$section" >/dev/null 2>&1; then
		red "Required peer section network.$section not found"
		exit 1
	fi
}

ensure_mode_config() {
	green "Ensuring /etc/config/$CONFIG_NAME"

	if ! uci -q get "$CONFIG_NAME.$CONFIG_SECTION" >/dev/null 2>&1; then
		uci set "$CONFIG_NAME.$CONFIG_SECTION=main"
	fi

	if ! uci -q get "$CONFIG_NAME.$CONFIG_SECTION.mode" >/dev/null 2>&1; then
		uci set "$CONFIG_NAME.$CONFIG_SECTION.mode=domain"
	fi

	uci commit "$CONFIG_NAME"
}

find_zone_by_network() {
	local net="$1"
	local sec networks

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=zone/\1/p"); do
		networks="$(uci -q get firewall.$sec.network || true)"
		for n in $networks; do
			[ "$n" = "$net" ] && {
				echo "$sec"
				return 0
			}
		done
	done

	return 1
}

get_zone_name_by_network() {
	local net="$1"
	local sec

	if sec="$(find_zone_by_network "$net")"; then
		uci -q get firewall.$sec.name
		return 0
	fi

	return 1
}

ensure_zone_for_network() {
	local net="$1"
	local want_name="$2"
	local sec

	if sec="$(find_zone_by_network "$net")"; then
		green "Firewall zone for network $net already exists: $(uci -q get firewall.$sec.name)"
		return 0
	fi

	green "Creating firewall zone $want_name for network $net"
	sec="$(uci add firewall zone)"
	uci set "firewall.$sec.name=$want_name"
	uci set "firewall.$sec.network=$net"
	uci set "firewall.$sec.input=REJECT"
	uci set "firewall.$sec.output=ACCEPT"
	uci set "firewall.$sec.forward=REJECT"
	uci set "firewall.$sec.masq=1"
	uci set "firewall.$sec.mtu_fix=1"
	uci set "firewall.$sec.family=ipv4"
}

find_forwarding_by_src_dest() {
	local src="$1"
	local dest="$2"
	local sec

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=forwarding/\1/p"); do
		[ "$(uci -q get firewall.$sec.src)" = "$src" ] || continue
		[ "$(uci -q get firewall.$sec.dest)" = "$dest" ] || continue
		echo "$sec"
		return 0
	done

	return 1
}

ensure_forwarding() {
	local src="$1"
	local dest="$2"
	local name="$3"
	local sec

	if sec="$(find_forwarding_by_src_dest "$src" "$dest")"; then
		green "Forwarding $src -> $dest already exists"
		uci set "firewall.$sec.name=$name"
		uci set "firewall.$sec.family=ipv4"
	else
		green "Creating forwarding $src -> $dest"
		sec="$(uci add firewall forwarding)"
		uci set "firewall.$sec.name=$name"
		uci set "firewall.$sec.src=$src"
		uci set "firewall.$sec.dest=$dest"
		uci set "firewall.$sec.family=ipv4"
	fi
}

install_apply_script() {
	green "Installing $APPLY_SCRIPT"

	cat > "$APPLY_SCRIPT" <<'EOF'
#!/bin/sh

set -e

MODE="$(uci -q get vpnmode.settings.mode || echo domain)"

find_zone_by_network() {
	local net="$1"
	local sec networks

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=zone/\1/p"); do
		networks="$(uci -q get firewall.$sec.network || true)"
		for n in $networks; do
			[ "$n" = "$net" ] && {
				echo "$sec"
				return 0
			}
		done
	done

	return 1
}

get_zone_name_by_network() {
	local net="$1"
	local sec

	if sec="$(find_zone_by_network "$net")"; then
		uci -q get firewall.$sec.name
		return 0
	fi

	return 1
}

find_forwarding_by_src_dest() {
	local src="$1"
	local dest="$2"
	local sec

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=forwarding/\1/p"); do
		[ "$(uci -q get firewall.$sec.src)" = "$src" ] || continue
		[ "$(uci -q get firewall.$sec.dest)" = "$dest" ] || continue
		echo "$sec"
		return 0
	done

	return 1
}

set_forwarding_enabled_by_src_dest() {
	local src="$1"
	local dest="$2"
	local enabled="$3"
	local sec

	if ! sec="$(find_forwarding_by_src_dest "$src" "$dest")"; then
		return 0
	fi

	if [ "$enabled" = "1" ]; then
		uci -q delete "firewall.$sec.enabled" || true
	else
		uci set "firewall.$sec.enabled=0"
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

LAN_ZONE="$(get_zone_name_by_network lan || echo lan)"
WAN_ZONE="$(get_zone_name_by_network wan || echo wan)"
AWG0_ZONE="$(get_zone_name_by_network awg0 || echo awg0)"
AWG1_ZONE="$(get_zone_name_by_network awg1 || echo awg1)"

case "$MODE" in
	full)
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$WAN_ZONE" 0
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG0_ZONE" 0
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG1_ZONE" 1

		uci set network.@amneziawg_awg1[0].route_allowed_ips='1'
		uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

		set_service_state getdomains 0
	;;

	domain)
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$WAN_ZONE" 1
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG0_ZONE" 1
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG1_ZONE" 0

		uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
		uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

		set_service_state getdomains 1
	;;

	off)
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$WAN_ZONE" 1
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG0_ZONE" 0
		set_forwarding_enabled_by_src_dest "$LAN_ZONE" "$AWG1_ZONE" 0

		uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
		uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

		set_service_state getdomains 0
	;;

	*)
		logger -t vpnmode "Unknown mode: $MODE"
		exit 1
	;;
esac

uci commit firewall
uci commit network

/etc/init.d/firewall restart
/etc/init.d/network restart

logger -t vpnmode "Applied mode: $MODE"
EOF

	chmod +x "$APPLY_SCRIPT"
}

install_init_script() {
	green "Installing $INIT_SCRIPT"

	cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /bin/sh -c 'sleep 1d'
	procd_set_param respawn
	procd_close_instance
}

reload_service() {
	/usr/bin/vpn-mode-apply
}

service_triggers() {
	procd_add_reload_trigger vpnmode
}
EOF

	chmod +x "$INIT_SCRIPT"
	/etc/init.d/vpnmode enable
	/etc/init.d/vpnmode restart || /etc/init.d/vpnmode start
}

install_js_view() {
	green "Installing JS view"
	mkdir -p "$VIEW_DIR"

	cat > "$VIEW_FILE" <<'EOF'
'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('vpnmode');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('vpnmode', _('VPN Mode'),
			_('Switch between off / domain via awg0 / full via awg1.'));

		s = m.section(form.NamedSection, 'settings', 'main');
		s.anonymous = true;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('off', _('Off'));
		o.value('domain', _('Domain routing via awg0'));
		o.value('full', _('Full tunnel via awg1'));
		o.default = 'domain';
		o.rmempty = false;

		return m.render();
	}
});
EOF
}

install_menu_json() {
	green "Installing menu JSON"
	mkdir -p "$MENU_DIR"

	cat > "$MENU_FILE" <<'EOF'
{
  "admin/network/vpnmode": {
    "title": "VPN Mode",
    "order": 95,
    "depends": {
      "acl": [ "luci-app-vpnmode" ]
    },
    "action": {
      "type": "view",
      "path": "network/vpnmode"
    }
  }
}
EOF
}

install_acl_json() {
	green "Installing ACL JSON"
	mkdir -p "$ACL_DIR"

	cat > "$ACL_FILE" <<'EOF'
{
  "luci-app-vpnmode": {
    "description": "Grant access to VPN Mode configuration",
    "read": {
      "uci": [ "vpnmode", "network", "firewall" ]
    },
    "write": {
      "uci": [ "vpnmode", "network", "firewall" ]
    }
  }
}
EOF
}

remove_legacy_lua() {
	green "Removing legacy Lua files if present"
	rm -f /usr/lib/lua/luci/controller/vpnmode.lua
	rm -f /usr/lib/lua/luci/model/cbi/vpnmode.lua
}

restart_luci() {
	green "Restarting LuCI"
	rm -rf /tmp/luci-*
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
}

apply_current_mode() {
	green "Applying current/default VPN mode"
	"$APPLY_SCRIPT"
}

main() {
	require_interface "awg0"
	require_interface "awg1"
	require_peer_section "@amneziawg_awg0[0]"
	require_peer_section "@amneziawg_awg1[0]"

	ensure_mode_config

	ensure_zone_for_network "awg0" "awg"
	ensure_zone_for_network "awg1" "awg1"
	uci commit firewall

	LAN_ZONE="$(get_zone_name_by_network lan || echo lan)"
	WAN_ZONE="$(get_zone_name_by_network wan || echo wan)"
	AWG0_ZONE="$(get_zone_name_by_network awg0 || echo awg0)"
	AWG1_ZONE="$(get_zone_name_by_network awg1 || echo awg1)"

	green "Resolved zones:"
	echo "  lan  -> $LAN_ZONE"
	echo "  wan  -> $WAN_ZONE"
	echo "  awg0 -> $AWG0_ZONE"
	echo "  awg1 -> $AWG1_ZONE"

	ensure_forwarding "$LAN_ZONE" "$WAN_ZONE"  "lan-wan"
	ensure_forwarding "$LAN_ZONE" "$AWG0_ZONE" "lan-awg0"
	ensure_forwarding "$LAN_ZONE" "$AWG1_ZONE" "lan-awg1"
	uci commit firewall

	install_apply_script
	install_init_script
	install_js_view
	install_menu_json
	install_acl_json
	remove_legacy_lua

	restart_luci
	apply_current_mode

	green "Done"
	echo
	echo "Open LuCI: Network -> VPN Mode"
	echo
	echo "Detected zones:"
	echo "  lan  -> $LAN_ZONE"
	echo "  wan  -> $WAN_ZONE"
	echo "  awg0 -> $AWG0_ZONE"
	echo "  awg1 -> $AWG1_ZONE"
	echo
	echo "Modes:"
	echo "  off    - LAN -> WAN only"
	echo "  domain - LAN -> WAN + awg0 zone, getdomains enabled"
	echo "  full   - LAN -> awg1 zone, awg1 route_allowed_ips enabled"
}

main "$@"
