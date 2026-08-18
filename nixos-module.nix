# filepath: ~/nixos-config/pkgs/dsh/nixos-module.nix
# dsh NixOS 薄模块 —— 共享 modules/options.nix,仅 systemPackages 消费面
# 当前无 system-wide 服务场景(单用户桌面),本文件为抽独立 flake 时的
# 双模块完备性预留:未在 flake.nix 挂载,import 无副作用
{ config, lib, pkgs, ... }:

let
  dshLib = import ./lib { inherit lib; };
  cfg = config.programs.dsh;
  applied = dshLib.applyPlugins { inherit cfg pkgs; };
  wrapper = dshLib.renderWrapper { inherit cfg pkgs applied; name = cfg.binName; };
in
{
  imports = [ ./modules/options.nix ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ wrapper ];
  };
}
