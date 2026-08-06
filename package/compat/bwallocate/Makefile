# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=bwallocate
PKG_VERSION:=4.500
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/bwallocate
  SECTION:=utils
  CATEGORY:=ROOter
  SUBMENU:=Optional Applications
  DEPENDS:=@BROKEN +msmtp
  TITLE:=Bandwidth Allocation (disabled: throttle helper removed upstream)
  PKGARCH:=all
endef

define Package/bwallocate/description
 Disabled because the latest modem feed no longer supplies its required
 ext-throttle implementation.
endef

define Build/Compile
endef

define Package/bwallocate/install
	$(CP) $(TOPDIR)/feeds/modem/rooter/0optionalapps/bwallocate/files/* $(1)/
endef

$(eval $(call BuildPackage,bwallocate))
