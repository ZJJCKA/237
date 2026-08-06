# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=feed-compat
PKG_RELEASE:=1

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

# The current QModem feed uses the upstream names for two MHI umbrella
# packages. This 5.4 tree carries the same drivers under mhi-bus and mhi-net.
define KernelPackage/mhi-pci-generic
  SUBMENU:=Other modules
  TITLE:=MHI PCI generic compatibility package
  DEPENDS:=+kmod-mhi-bus
endef

define KernelPackage/mhi-pci-generic/description
 Compatibility name for the MHI PCI generic driver supplied by kmod-mhi-bus.
endef

define KernelPackage/mhi-wwan
  SUBMENU:=Network Devices
  TITLE:=MHI WWAN compatibility package
  DEPENDS:=+kmod-mhi-net
endef

define KernelPackage/mhi-wwan/description
 Compatibility name for the generic MHI network support in kmod-mhi-net.
endef

# T7xx entered mainline long after Linux 5.4, while rmnet-nss is specific to
# Qualcomm NSS targets that are not present in this MediaTek buildroot. Keep
# their feed references resolvable but impossible to select or build here.
define KernelPackage/mtk-t7xx
  SUBMENU:=Network Devices
  TITLE:=MediaTek T7xx WWAN driver (unsupported on Linux 5.4)
  DEPENDS:=@BROKEN
endef

define KernelPackage/mtk-t7xx/description
 Disabled compatibility entry: the MediaTek T7xx driver requires a newer kernel.
endef

define KernelPackage/rmnet-nss
  SUBMENU:=Network Devices
  TITLE:=Qualcomm NSS rmnet driver (unsupported on this target)
  DEPENDS:=@BROKEN
endef

define KernelPackage/rmnet-nss/description
 Disabled compatibility entry for a Qualcomm NSS-only QModem package.
endef

define KernelPackage/qca-nss-drv
  SUBMENU:=Network Devices
  TITLE:=Qualcomm NSS core driver (unsupported on this target)
  DEPENDS:=@BROKEN
endef

define KernelPackage/qca-nss-drv/description
 Disabled compatibility entry for a Qualcomm NSS-only kernel dependency.
endef

# The newest 5G-Modem-Support feed still references a removed optional helper.
# Marking it BROKEN also makes bwallocate unselectable instead of pretending
# that its traffic-throttling implementation exists.
define Package/ext-throttle
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=ROOter throttle helper (unavailable)
  DEPENDS:=@BROKEN
  PKGARCH:=all
endef

define Package/ext-throttle/description
 Disabled compatibility entry for the removed ROOter ext-throttle helper.
endef

$(eval $(call KernelPackage,mhi-pci-generic))
$(eval $(call KernelPackage,mhi-wwan))
$(eval $(call KernelPackage,mtk-t7xx))
$(eval $(call KernelPackage,rmnet-nss))
$(eval $(call KernelPackage,qca-nss-drv))
$(eval $(call BuildPackage,ext-throttle))
