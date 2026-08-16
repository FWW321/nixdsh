{
  description = "nixdsh — DeepSeek Harness (dsh) 的 Nix 打包与 nixvim 式声明配置:profile 即 derivation,插件即 option";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    { self, nixpkgs, systems }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (system:
        let pkgs = import nixpkgs { inherit system; }; in
        {
          default = pkgs.callPackage ./package.nix { };
          dsh = pkgs.callPackage ./package.nix { };
        });

      # pkgs.dsh + pkgs.dshPlugins.<name>(names.txt + update.py 生成;
      # hostDsh 注入使插件 derivation 内可回链 peer 包 → 宿主安装)
      overlays.default = final: _prev: {
        dsh = final.callPackage ./package.nix { };
        dshPlugins = final.callPackage ./plugins/overlay.nix {
          hostDsh = final.dsh;
        };
      };

      homeManagerModules = rec {
        default = dsh;
        dsh = import ./hm-module.nix;
        # per-plugin typed modules(nixvim modules/plugins 同构,按需 import;
        # 底层形态 plugins.<name> 无需任何 module 即可用)
        dsh-status-rotator = import ./plugins-modules/status-rotator.nix;
      };

      nixosModules = rec {
        default = dsh;
        dsh = import ./nixos-module.nix;
      };

      # profile 模型验证:结构/正例 boot/负例 fail-loud
      checks = forEachSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        import ./checks { inherit pkgs; });

      # dshPlugins 集合更新器(vimPlugins update.py 个人规模 transpose,Python)
      apps = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        in
        {
          dsh-plugins-update = {
            type = "app";
            program = "${pkgs.writers.writePython3 "dsh-plugins-update" {
              libraries = [ ];
            } (builtins.readFile ./plugins/update.py)}";
          };
        });

      # nixvim 式独立实例化 API(与 mkDsh 同构;checks/外部消费者用)
      lib.mkDsh = { pkgs ? import nixpkgs { system = "x86_64-linux"; overlays = [ self.overlays.default ]; }, modules ? [ ], extraSpecialArgs ? { } }:
        (import ./lib { inherit (nixpkgs) lib; }).mkDsh { inherit pkgs modules extraSpecialArgs; };
    };
}
