# SPDX-License-Identifier: MIT
# 参照 VIKINGYFY/OpenWRT-CI 的 rust-prebuilt.mk
#
# 保留 OpenWrt 正常的 host stamp，但不下载源码、不自举。
# Host/Compile 只打印版本，Host/Install 只做三个符号链接。
# 这样 rustc 的 30~60 分钟自举变成几秒。

PKG_SOURCE:=
PKG_SOURCE_URL:=

define Host/Prepare
endef

define Host/Configure
endef

define Host/Compile
	"$(CI_RUST_ROOT)/bin/rustc" --version
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR)/host/bin
	ln -sfn "$(CI_RUST_ROOT)/bin/cargo" "$(STAGING_DIR)/host/bin/cargo"
	ln -sfn "$(CI_RUST_ROOT)/bin/rustc" "$(STAGING_DIR)/host/bin/rustc"
	ln -sfn "$(CI_RUST_ROOT)/bin/rustdoc" "$(STAGING_DIR)/host/bin/rustdoc"
endef

define Host/Uninstall
	rm -f $(addprefix $(STAGING_DIR)/host/bin/,cargo rustc rustdoc)
endef
