#!/bin/sh

set -e

CONFIG_NAME="vpnmode"
CONFIG_SECTION="settings"

APPLY_SCRIPT="/usr/bin/vpn-mode-apply"
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

	uci set "$CONFIG_NAME.$CONFIG_SECTION.mode=domain"
	uci commit "$CONFIG_NAME"
}

find_zone_by_name() {
	local name="$1"
	local sec

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=zone/\1/p"); do
		[ "$(uci -q get firewall.$sec.name)" = "$name" ] && {
			echo "$sec"
			return 0
		}
	done

	return 1
}

ensure_firewall_zone() {
	local zone_name="$1"
	local ifname="$2"
	local sec

	if sec="$(find_zone_by_name "$zone_name")"; then
		green "Firewall zone $zone_name already exists"
		uci set "firewall.$sec.network=$ifname"
		uci set "firewall.$sec.input=REJECT"
		uci set "firewall.$sec.output=ACCEPT"
		uci set "firewall.$sec.forward=REJECT"
		uci set "firewall.$sec.masq=1"
		uci set "firewall.$sec.mtu_fix=1"
		uci set "firewall.$sec.family=ipv4"
	else
		green "Creating firewall zone $zone_name"
		sec="$(uci add firewall zone)"
		uci set "firewall.$sec.name=$zone_name"
		uci set "firewall.$sec.network=$ifname"
		uci set "firewall.$sec.input=REJECT"
		uci set "firewall.$sec.output=ACCEPT"
		uci set "firewall.$sec.forward=REJECT"
		uci set "firewall.$sec.masq=1"
		uci set "firewall.$sec.mtu_fix=1"
		uci set "firewall.$sec.family=ipv4"
	fi
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

ensure_forwardings() {
	green "Ensuring forwardings"
	ensure_forwarding "lan" "wan"  "lan-wan"
	ensure_forwarding "lan" "awg0" "awg0-lan"
	ensure_forwarding "lan" "awg1" "awg1-lan"
	uci commit firewall
}

install_apply_script() {
	green "Installing $APPLY_SCRIPT"

	cat > "$APPLY_SCRIPT" <<'EOF'
#!/bin/sh

set -e

MODE="$(uci -q get vpnmode.settings.mode || echo domain)"

find_forwarding_by_name() {
	local name="$1"
	local sec

	for sec in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)=forwarding/\1/p"); do
		[ "$(uci -q get firewall.$sec.name)" = "$name" ] && {
			echo "$sec"
			return 0
		}
	done

	return 1
}

set_forwarding_enabled_by_name() {
	local name="$1"
	local enabled="$2"
	local sec

	if ! sec="$(find_forwarding_by_name "$name")"; then
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

apply_mode() {
	case "$MODE" in
		full)
			set_forwarding_enabled_by_name "lan-wan" 0
			set_forwarding_enabled_by_name "awg0-lan" 0
			set_forwarding_enabled_by_name "awg1-lan" 1

			uci set network.@amneziawg_awg1[0].route_allowed_ips='1'
			uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

			set_service_state getdomains 0
		;;

		domain)
			set_forwarding_enabled_by_name "lan-wan" 1
			set_forwarding_enabled_by_name "awg0-lan" 1
			set_forwarding_enabled_by_name "awg1-lan" 0

			uci set network.@amneziawg_awg1[0].route_allowed_ips='0'
			uci set network.@amneziawg_awg0[0].route_allowed_ips='0'

			set_service_state getdomains 1
		;;

		off)
			set_forwarding_enabled_by_name "lan-wan" 1
			set_forwarding_enabled_by_name "awg0-lan" 0
			set_forwarding_enabled_by_name "awg1-lan" 0

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
}

apply_mode
EOF

	chmod +x "$APPLY_SCRIPT"
}

install_js_view() {
	green "Installing JS view"
	mkdir -p "$VIEW_DIR"

	cat > "$VIEW_FILE" <<'EOF'
'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return uci.load('vpnmode');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('vpnmode', _('VPN Mode'),
			_('Переключение между режимами awg0 / awg1 без Lua runtime.'));

		s = m.section(form.NamedSection, 'settings', 'main');
		s.anonymous = true;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('off', _('Off'));
		o.value('domain', _('Domain routing via awg0'));
		o.value('full', _('Full tunnel via awg1'));
		o.default = 'domain';
		o.rmempty = false;

		this.map = m;
		return m.render();
	},

	handleSave: function(ev) {
		return this.map.save();
	},

	handleSaveApply: function(ev) {
		var self = this;

		return self.map.save()
			.then(function() {
				return fs.exec('/usr/bin/vpn-mode-apply', []);
			})
			.then(function(res) {
				if (res.code === 0) {
					ui.addNotification(null, E('p', _('VPN mode applied successfully.')));
				} else {
					ui.addNotification(null, E('p', _('vpn-mode-apply returned non-zero exit code: %d').format(res.code)), 'danger');
				}
			})
			.catch(function(err) {
				ui.addNotification(null, E('p', _('Failed to apply VPN mode: %s').format(err)), 'danger');
			});
	},

	handleReset: function(ev) {
		return this.map.reset();
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
      "uci": [ "vpnmode", "network", "firewall" ],
      "file": {
        "exec": [ "/usr/bin/vpn-mode-apply" ]
      }
    },
    "write": {
      "uci": [ "vpnmode", "network", "firewall" ],
      "file": {
        "exec": [ "/usr/bin/vpn-mode-apply" ]
      }
    }
  }
}
EOF
}

remove_legacy_lua() {
	green "Removing legacy Lua LuCI files if present"
	rm -f /usr/lib/lua/luci/controller/vpnmode.lua
	rm -f /usr/lib/lua/luci/model/cbi/vpnmode.lua
}

restart_services() {
	green "Restarting rpcd and uhttpd"
	rm -rf /tmp/luci-*
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
}

apply_default_mode() {
	green "Applying default mode"
	"$APPLY_SCRIPT"
}

main() {
	require_interface "awg0"
	require_interface "awg1"
	require_peer_section "@amneziawg_awg0[0]"
	require_peer_section "@amneziawg_awg1[0]"

	ensure_mode_config
	ensure_firewall_zone "awg0" "awg0"
	ensure_firewall_zone "awg1" "awg1"
	ensure_forwardings

	install_apply_script
	install_js_view
	install_menu_json
	install_acl_json
	remove_legacy_lua

	uci commit firewall
	uci commit network

	restart_services
	apply_default_mode

	green "Done"
	echo
	echo "Open LuCI: Network -> VPN Mode"
	echo
	echo "Modes:"
	echo "  off    - lan -> wan only"
	echo "  domain - lan -> wan + awg0, getdomains enabled"
	echo "  full   - lan -> awg1, route_allowed_ips on awg1 enabled"
}

main "$@"
