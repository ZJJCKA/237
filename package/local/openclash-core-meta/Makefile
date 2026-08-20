include $(TOPDIR)/rules.mk

PKG_NAME:=openclash-core-meta
PKG_VERSION:=20260814
PKG_RELEASE:=1
PKG_FILE_DEPENDS:=$(CURDIR)/files/clash_meta

CORE_BIN:=$(CURDIR)/files/clash_meta
CORE_SHA256:=453066ac9e5045d95d035a96b5c02fb593fdc0427c3c9153ff4d6a4403feab6a
CORE_UPSTREAM_VERSION:=alpha-ge183c58
CORE_UPSTREAM_COMMIT:=7dedf5508d1aba0360820bff3532eb4257c79fae
CORE_UPSTREAM_ARCHIVE_SHA256:=8252d16726041872825cdd9089c798c318f8862466b40b34d8bf62225ef57e34
CORE_UPSTREAM_URL:=https://raw.githubusercontent.com/vernesong/OpenClash/7dedf5508d1aba0360820bff3532eb4257c79fae/master/meta/clash-linux-arm64.tar.gz

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:

define Package/openclash-core-meta
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Pinned AArch64 OpenClash Meta core
  DEPENDS:=@aarch64
endef

define Package/openclash-core-meta/description
  Pinned AArch64 Meta core preinstalled for OpenClash.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	printf '%s  %s\n' '$(CORE_SHA256)' '$(CORE_BIN)' | sha256sum -c -
endef

define Build/Compile
endef

define Package/openclash-core-meta/install
	$(INSTALL_DIR) $(1)/etc/openclash/core
	$(INSTALL_BIN) $(CORE_BIN) $(1)/etc/openclash/core/clash_meta
endef

$(eval $(call BuildPackage,openclash-core-meta))
