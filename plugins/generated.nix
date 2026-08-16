# 由 update.py 生成,勿手改(nix run github:FWW321/nixdsh#dsh-plugins-update)
{
  "dsh-status-rotator" = { owner = "01Virex"; repo = "dsh-status-rotator"; rev = "v0.2.0"; version = "v0.2.0"; hash = "sha256-oj5svK/rFp+qIFl0UByc4ubjV6lW3AMxG8DQngy/3oQ="; };
  "@deepseek-harness-tui/dsh-tui" = { owner = "ccch1mneyyy"; repo = "dsh-TUI"; rev = "v0.7.2"; version = "v0.7.2"; hash = "sha256-Zgg4xyXfw8KZ2aIah/qh5ZvVMq9s8ZYOdfOn814ndQo="; bundlePatch = "./cordis.patch.yml"; peers = [ "@deepseek-ai/cordis" "@deepseek-ai/dsh-invariants" ]; needsBuild = true; pnpmHash = "sha256-esk0i4wYeV/VaDhegmXPpDbODQ/3e+rHPIJlZ2piE5U="; };
}
