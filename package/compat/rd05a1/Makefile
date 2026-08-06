# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=rd05a1
PKG_VERSION:=1.000
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/rd05a1
  SECTION:=utils
  CATEGORY:=ROOter
  SUBMENU:=Router Specific
  DEPENDS:=+ath9k-htc-firmware +kmod-ath10k-ct +kmod-ath9k-htc
  TITLE:=Install scripts for RD05A1
  PKGARCH:=all
endef

define Package/rd05a1/description
 Helper scripts to install scripts for RD05A1. This compatibility definition
 uses the concrete ath10k-ct provider shipped by the 23.05 mac80211 package.
endef

define Build/Compile
endef

define Package/rd05a1/install
	$(CP) $(TOPDIR)/feeds/modem/rooter/0routerspecfic/rd05a1/files/* $(1)/
endef

$(eval $(call BuildPackage,rd05a1))
