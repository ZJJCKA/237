# Copyright (C) 2023 Siriling <siriling@qq.com>
# This is free software, licensed under the GNU General Public License v3.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-modem
LUCI_TITLE:=LuCI support for Modem
LUCI_PKGARCH:=all
PKG_VERSION:=1.4.6
PKG_RELEASE:=11
PKG_LICENSE:=GPLv3
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Siriling <siriling@qq.com>
LUCI_DEPENDS:=+luci-compat \
		+kmod-usb2 +kmod-usb3 +kmod-usb-net-sierrawireless +kmod-usb-ohci +kmod-usb-serial-option +kmod-usb-serial +kmod-usb-serial-qualcomm +kmod-usb-acm \
		+kmod-usb-net \
		+kmod-usb-wdm +kmod-usb-net-qmi-wwan \
		+kmod-usb-net-cdc-ether \
		+kmod-usb-net-cdc-mbim \
		+kmod-usb-net-rndis \
		+kmod-usb-net-cdc-ncm \
		+usbutils \
		+kmod-pcie_mhi +pciutils +quectel-CM-5G \
		+sms-tool \
		+bc +jq +rdisc6 +ndisc6 +coreutils-timeout \
		+sendat

define Package/luci-app-modem/conffiles
/etc/config/modem
/etc/config/custom_at_commands
endef

# Older releases did not declare custom_at_commands as a conffile. Preserve a
# locally edited copy across the first upgrade to this release.
define Package/luci-app-modem/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
backup=/etc/config/.custom_at_commands.luci-app-modem.pre-r6
backup_tmp="$${backup}.$$$$"
if [ -f /etc/config/custom_at_commands ] && [ ! -e "$${backup}" ]; then
	umask 077
	rm -f "$${backup_tmp}"
	cp -p /etc/config/custom_at_commands "$${backup_tmp}" || {
		rm -f "$${backup_tmp}"
		exit 1
	}
	# A same-directory hard link provides atomic no-clobber semantics. If a
	# previous/interrupted install won the race, keep its backup untouched.
	ln "$${backup_tmp}" "$${backup}" 2>/dev/null || {
		rm -f "$${backup_tmp}"
		[ -e "$${backup}" ] || exit 1
	}
	rm -f "$${backup_tmp}"
fi
exit 0
endef

define Package/luci-app-modem/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
backup=/etc/config/.custom_at_commands.luci-app-modem.pre-r6
if [ -f "$${backup}" ]; then
	cp -p "$${backup}" /etc/config/custom_at_commands || exit 1
	chmod 0600 /etc/config/custom_at_commands
	rm -f "$${backup}"
fi
rm -f /tmp/luci-indexcache
killall -HUP rpcd >/dev/null 2>&1 || true
exit 0
endef

override LUCI_LANGUAGES:=

define Build/Prepare/ModemI18n
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/lib/lua/luci/i18n
	po2lmo $(CURDIR)/po/zh_Hans/modem.po $(PKG_BUILD_DIR)/root/usr/lib/lua/luci/i18n/modem.zh-cn.lmo
endef
Hooks/Prepare/Post += Build/Prepare/ModemI18n

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
