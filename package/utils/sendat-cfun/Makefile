include $(TOPDIR)/rules.mk

PKG_NAME:=sendat-cfun
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/sendat-cfun
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Send AT+CFUN commands on boot
  DEPENDS:=+sendat
endef

define Package/sendat-cfun/description
  A script to send AT+CFUN=0 and AT+CFUN=1 commands 1 minute after boot.
endef

define Build/Configure
  true
endef

define Build/Compile
  true
endef

define Package/sendat-cfun/install
    # 安装启动脚本
    $(INSTALL_DIR) $(1)/etc/init.d
    $(INSTALL_BIN) ./files/sendat-cfun.init $(1)/etc/init.d/sendat-cfun

    # 安装日志文件（可选）
    $(INSTALL_DIR) $(1)/tmp
endef

$(eval $(call BuildPackage,sendat-cfun))
