# options 参考文档:pkgs.nixosOptionsDoc(HM 官方文档同款渲染器)。
# description 是唯一真源 → 渲染为 CommonMark + JSON,120+ option 免手写。
# 产物:nix build .#checks.x86_64-linux.dsh-options-doc → options.md/json
# (optionsJSON 供工具/搜索管线消费;CommonMark 可直接阅读)
{ pkgs, lib, dshLib }:

let
  # 收录全部 option 面:核心 modules/options.nix + per-plugin typed 模块
  # (status-rotator 默认关,求值零行为影响,只为收录其 options;
  # 传路径使 declarations 指向真实文件,transformOptions 才能映射成链接)
  eval = dshLib.mkDsh {
    inherit pkgs;
    modules = [ ../plugins-modules/status-rotator.nix ];
  };

  # 声明位置 → GitHub 链接(treefmt options-doc 同款 transform;
  # 非本仓声明直接 assert 拦下,fail-loud)
  # 注意:本文件在 checks/ 内,仓库根是 ./..(一级;勿写 ../.. 那是 /nix/store)
  root = toString ./..;
  rel = path: lib.removePrefix "${root}/" (toString path);
  transformDeclaration =
    d:
    assert lib.hasPrefix root (toString d);
    {
      name = rel d;
      url = "https://github.com/FWW321/nixdsh/blob/main/${rel d}";
    };

  doc = pkgs.nixosOptionsDoc {
    # _module.* 是 evalModules 内部选项,不入文档(treefmt 同款剔除)
    options = removeAttrs eval.options [ "_module" ];
    documentType = "none";
    transformOptions = opt: opt // {
      declarations = map transformDeclaration opt.declarations;
    };
  };

  optionCount = builtins.length (builtins.attrNames eval.options);
in
{
  dsh-options-doc = pkgs.runCommand "dsh-options-doc"
    {
      meta.description = "programs.dsh.* / programs.dsh.status-rotator.* options reference (CommonMark + JSON)";
    }
    ''
      install -Dm644 ${doc.optionsCommonMark} $out/options.md
      # optionsJSON 是目录型输出,文件在固定的 share/doc/nixos/ 段
      install -Dm644 ${doc.optionsJSON}/share/doc/nixos/options.json $out/options.json
      echo "rendered ${toString optionCount} options" >&2
    '';
}
